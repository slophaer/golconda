//! Admin vars from the deploy host (docs/design/trust.md, "Secrets and vars").
//!
//! An admin var is a value the image names but never contains: a host certificate, a key
//! revocation list. The deploy host keeps it age-encrypted in the configuration repository
//! ([`Store`]: `vars/<host>/<var>/<file>.age`, to the recipients in `vars/recipients.txt`),
//! and pushes it over ssh ([`Remote`]); the machine seals it with its own `systemd-creds`
//! (`golconda-var-run --admin`). The machine's manifests (`/usr/lib/golconda/vars.d/*.json`)
//! say which vars and files exist and which units to restart, so [`push`] reads them from the
//! machine it pushes to, never from an evaluation.
//!
//! `age` and `ssh` are programs, not libraries: `GOLCONDA_AGE` and `GOLCONDA_SSH` name them,
//! with arguments (split at spaces), so ssh options and age/rage both fit.

use serde_json::Value;
use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::thread;
use std::time;
use std::{env, fs, result};
use tempfile::Builder;

/// Where the machine keeps the manifests, the runner, the sealed credentials and the publics.
const VARS_D: &str = "/usr/lib/golconda/vars.d";
const RUNNER: &str = "/usr/lib/golconda/golconda-var-run";
const CREDSTORE: &str = "/etc/credstore.encrypted";
const PUB_DIR: &str = "/var/lib/golconda/vars";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Class {
    Local,
    Admin,
}

/// One var's manifest, as the image declares it (modules/lib/var.nix).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub name: String,
    pub class: Class,
    /// the files: an admin var's `files`, a local var's `secrets`
    pub files: Vec<String>,
    /// the units a push restarts (admin vars; empty for local ones)
    pub consumers: Vec<String>,
}

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct Error(pub String);

type Result<T> = result::Result<T, Error>;

fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

/// A host, var or file name: one path component, no shell or JSON metacharacters.
pub fn word(s: &str) -> Result<&str> {
    let ok = !s.is_empty()
        && s != "."
        && s != ".."
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    if ok {
        Ok(s)
    } else {
        err(format!("'{s}' is not a name (letters, digits, - _ .)"))
    }
}

/// A unit name as Golconda's grammar has it (modules/lib/fragment.nix unitName): letters, digits
/// and `: _ . @ -`, not first a dash, and a unit suffix. Consumers become words of a command on
/// the machine's shell.
pub fn unit(s: &str) -> Result<&str> {
    let suffix = [
        ".service", ".target", ".socket", ".timer", ".path", ".mount", ".slice",
    ]
    .iter()
    .any(|x| s.len() > x.len() && s.ends_with(x));
    let ok = suffix
        && !s.starts_with('-')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '_' | '.' | '@' | '-'));
    if ok {
        Ok(s)
    } else {
        err(format!("'{s}' is not a unit name"))
    }
}

/// The manifests in `text`: the concatenated JSON documents `cat vars.d/*.json` prints.
pub fn parse_manifests(text: &str) -> Result<Vec<Manifest>> {
    let strings = |v: &Value, key: &str| -> Result<Vec<String>> {
        v.get(key)
            .and_then(Value::as_array)
            .map_or(Some(Vec::new()), |a| {
                a.iter()
                    .map(|x| x.as_str().map(str::to_owned))
                    .collect::<Option<_>>()
            })
            .ok_or_else(|| Error(format!("manifest field {key} is not a list of strings")))
    };
    let mut out = Vec::new();
    for v in serde_json::Deserializer::from_str(text).into_iter::<Value>() {
        let v = v.map_err(|e| Error(format!("a manifest is not JSON: {e}")))?;
        let name = word(v["name"].as_str().unwrap_or_default())?.to_owned();
        let (class, files) = match v["class"].as_str() {
            Some("admin") => (Class::Admin, strings(&v, "files")?),
            Some("local") => (Class::Local, strings(&v, "secrets")?),
            c => return err(format!("var {name}: unknown class {c:?}")),
        };
        for f in &files {
            word(f)?;
        }
        let consumers = strings(&v, "consumers")?;
        for c in &consumers {
            unit(c)?;
        }
        out.push(Manifest {
            name,
            class,
            files,
            consumers,
        });
    }
    Ok(out)
}

/// The credential id of a var's file, `<var>.<file>` (modules/lib/var.nix credentialId).
fn var_file(var: &str, file: &str) -> String {
    format!("{var}.{file}")
}

/// A program and its leading arguments, from an environment variable or a default.
#[derive(Debug, Clone)]
pub struct Program {
    argv: Vec<OsString>,
    dir: Option<PathBuf>,
    env: Vec<(OsString, OsString)>,
}

impl Program {
    /// `var`'s value split at spaces, or `default` when it is unset or empty.
    pub fn from_env(var: &str, default: &str) -> Program {
        let value = env::var_os(var).filter(|v| !v.is_empty());
        let text = value
            .as_deref()
            .unwrap_or(default.as_ref())
            .to_string_lossy()
            .into_owned();
        Program {
            argv: text.split_whitespace().map(OsString::from).collect(),
            dir: None,
            env: Vec::new(),
        }
    }

    /// A program and its leading arguments, as given.
    pub fn new(argv: Vec<OsString>) -> Program {
        Program {
            argv,
            dir: None,
            env: Vec::new(),
        }
    }

    /// The same program, run in `dir`.
    #[must_use]
    pub fn in_dir(&self, dir: &Path) -> Program {
        Program {
            dir: Some(dir.to_path_buf()),
            ..self.clone()
        }
    }

    /// The same program, run with the variable `name` set to `value`.
    #[must_use]
    pub fn with_env(&self, name: impl Into<OsString>, value: impl Into<OsString>) -> Program {
        let mut p = self.clone();
        p.env.push((name.into(), value.into()));
        p
    }

    /// Runs the program with `args`, `stdin` on its standard input; its standard output.
    ///
    /// # Errors
    ///
    /// When it cannot start or exits with a failure: the message names it, its arguments and
    /// what it wrote to standard error.
    pub fn run<S: AsRef<OsStr>>(&self, args: &[S], stdin: Option<&[u8]>) -> Result<Vec<u8>> {
        let out = self.output(args, stdin)?;
        if !out.status.success() {
            return err(format!(
                "{} {}: {}: {}",
                self.name(),
                args.iter()
                    .map(|a| a.as_ref().to_string_lossy())
                    .collect::<Vec<_>>()
                    .join(" "),
                out.status,
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(out.stdout)
    }

    fn name(&self) -> String {
        self.argv
            .first()
            .map_or_else(String::new, |p| p.to_string_lossy().into_owned())
    }

    /// Starts the program with its output piped. ETXTBSY: the program is still open for
    /// writing somewhere, typically a file just written whose descriptor a process forked
    /// meanwhile holds until it execs. That passes within moments; wait up to half a second.
    fn spawn<S: AsRef<OsStr>>(&self, args: &[S], stdin: bool) -> Result<Child> {
        let (program, lead) = self
            .argv
            .split_first()
            .ok_or(Error("an empty program".into()))?;
        let spawn = || {
            let mut c = Command::new(program);
            if let Some(d) = &self.dir {
                c.current_dir(d);
            }
            c.envs(self.env.iter().map(|(k, v)| (k, v)));
            c.args(lead)
                .args(args)
                .stdin(if stdin { Stdio::piped() } else { Stdio::null() })
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
        };
        let mut tries = 0;
        loop {
            match spawn() {
                Err(e) if e.raw_os_error() == Some(26) && tries < 50 => {
                    tries += 1;
                    thread::sleep(time::Duration::from_millis(10));
                }
                other => {
                    return other.map_err(|e| Error(format!("cannot run {}: {e}", self.name())));
                }
            }
        }
    }

    /// Like [`Program::run`], but a program still running after `limit` is killed.
    ///
    /// # Errors
    ///
    /// When it cannot start, runs past `limit`, or exits with a failure.
    pub fn run_within<S: AsRef<OsStr>>(
        &self,
        args: &[S],
        limit: time::Duration,
    ) -> Result<Vec<u8>> {
        let mut child = self.spawn(args, false)?;
        let (mut out_pipe, mut err_pipe) = (child.stdout.take(), child.stderr.take());
        // both pipes are read in threads: a program that fills one must not wait for us
        let out = thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(p) = out_pipe.as_mut() {
                let _ = p.read_to_end(&mut bytes);
            }
            bytes
        });
        let errors = thread::spawn(move || {
            let mut text = String::new();
            if let Some(p) = err_pipe.as_mut() {
                let _ = p.read_to_string(&mut text);
            }
            text
        });
        let started = time::Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if started.elapsed() < limit => {
                    thread::sleep(time::Duration::from_millis(20));
                }
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return err(format!(
                        "{} did not finish within {} s",
                        self.name(),
                        limit.as_secs().max(1)
                    ));
                }
                Err(e) => return err(format!("{}: {e}", self.name())),
            }
        };
        let (out, stderr) = (
            out.join().unwrap_or_default(),
            errors.join().unwrap_or_default(),
        );
        if status.success() {
            Ok(out)
        } else {
            err(format!("{}: {status}: {}", self.name(), stderr.trim()))
        }
    }

    /// Runs the program and hands each line of its standard output to `line` as it comes; then
    /// whether it succeeded, and its standard error.
    ///
    /// # Errors
    ///
    /// When it cannot start.
    pub fn stream<S: AsRef<OsStr>>(
        &self,
        args: &[S],
        line: &mut dyn FnMut(&str),
    ) -> Result<(bool, String)> {
        let mut child = self.spawn(args, false)?;
        let mut err_pipe = child.stderr.take();
        // standard error in a thread of its own: a full pipe there must not stop the output
        let stderr = thread::spawn(move || {
            let mut text = String::new();
            if let Some(p) = err_pipe.as_mut() {
                let _ = p.read_to_string(&mut text);
            }
            text
        });
        if let Some(out) = child.stdout.take() {
            for l in BufReader::new(out).lines() {
                match l {
                    Ok(l) => line(&l),
                    Err(_) => break,
                }
            }
        }
        let status = child
            .wait()
            .map_err(|e| Error(format!("{}: {e}", self.name())))?;
        Ok((status.success(), stderr.join().unwrap_or_default()))
    }

    /// Runs the program and returns how it ended, whatever its status: for a caller that
    /// tells one failure (a file that is not there) from the others.
    ///
    /// # Errors
    ///
    /// When it cannot start.
    pub fn output<S: AsRef<OsStr>>(&self, args: &[S], stdin: Option<&[u8]>) -> Result<Output> {
        let name = self.name();
        let mut child = self.spawn(args, stdin.is_some())?;
        if let Some(input) = stdin
            && let Some(mut pipe) = child.stdin.take()
        {
            // a child that exits early closes the pipe; its status says why
            let _ = pipe.write_all(input);
        }
        child
            .wait_with_output()
            .map_err(|e| Error(format!("{name}: {e}")))
    }
}

/// The encrypted values on the deploy host.
pub struct Store {
    root: PathBuf,
    age: Program,
}

impl Store {
    pub fn new(root: impl Into<PathBuf>, age: Program) -> Store {
        Store {
            root: root.into(),
            age,
        }
    }

    /// `<root>/<host>/<var>/<file>.age`
    pub fn path(&self, host: &str, var: &str, file: &str) -> Result<PathBuf> {
        Ok(self
            .root
            .join(word(host)?)
            .join(word(var)?)
            .join(format!("{}.age", word(file)?)))
    }

    /// Encrypts `value` to `<root>/recipients.txt` and stores it (through a temporary file).
    pub fn set(&self, host: &str, var: &str, file: &str, value: &[u8]) -> Result<PathBuf> {
        let path = self.path(host, var, file)?;
        let recipients = self.root.join("recipients.txt");
        if !recipients.is_file() {
            return err(format!(
                "{} is missing: list the age recipients (one public key per line)",
                recipients.display()
            ));
        }
        let dir = path
            .parent()
            .ok_or_else(|| Error(format!("{} has no directory", path.display())))?;
        fs::create_dir_all(dir).map_err(|e| Error(format!("{}: {e}", dir.display())))?;
        // age writes into a directory of its own (new, mode 0700, removed on drop), so two
        // `set` of one file at once do not share a name and nothing planted is followed
        let scratch = Builder::new()
            .prefix(&format!(".{}.tmp-", word(file)?))
            .tempdir_in(dir)
            .map_err(|e| Error(format!("{}: {e}", dir.display())))?;
        let tmp = scratch.path().join("out");
        let (r, t) = (recipients.to_string_lossy(), tmp.to_string_lossy());
        self.age.run(&["-e", "-R", &r, "-o", &t], Some(value))?;
        fs::rename(&tmp, &path).map_err(|e| Error(format!("{}: {e}", path.display())))?;
        Ok(path)
    }

    /// Decrypts a stored value with the age identity file `identity`.
    pub fn get(&self, identity: &Path, host: &str, var: &str, file: &str) -> Result<Vec<u8>> {
        let path = self.path(host, var, file)?;
        if !path.is_file() {
            return err(format!(
                "{} is not stored ({})",
                var_file(var, file),
                path.display()
            ));
        }
        self.age.run(
            &[
                "-d",
                "-i",
                &identity.to_string_lossy(),
                &path.to_string_lossy(),
            ],
            None,
        )
    }

    pub fn has(&self, host: &str, var: &str, file: &str) -> bool {
        self.path(host, var, file).is_ok_and(|p| p.is_file())
    }
}

/// A machine, reached with `ssh <destination> <command>`.
pub struct Remote {
    ssh: Program,
    destination: String,
}

impl Remote {
    pub fn new(ssh: Program, destination: &str) -> Result<Remote> {
        Ok(Remote {
            ssh,
            destination: word(destination)?.to_owned(),
        })
    }

    fn run(&self, command: &str, stdin: Option<&[u8]>) -> Result<Vec<u8>> {
        self.ssh.run(&[&self.destination, command], stdin)
    }

    /// Every var the running image declares.
    pub fn manifests(&self) -> Result<Vec<Manifest>> {
        let out = self.run(&format!("cat {VARS_D}/*.json"), None)?;
        parse_manifests(&String::from_utf8_lossy(&out))
    }

    /// The credential ids sealed on the machine.
    pub fn sealed(&self) -> Result<BTreeSet<String>> {
        // the directory is missing until the first var is sealed: that is an empty list
        let out = self.run(&format!("ls -1A {CREDSTORE} 2>/dev/null || true"), None)?;
        Ok(String::from_utf8_lossy(&out)
            .lines()
            .map(str::to_owned)
            .collect())
    }

    /// A public file of a local var (`/var/lib/golconda/vars/<var>/pub/<file>`).
    pub fn public(&self, var: &str, file: &str) -> Result<Vec<u8>> {
        self.run(
            &format!("cat {PUB_DIR}/{}/pub/{}", word(var)?, word(file)?),
            None,
        )
    }
}

/// What [`push`] did.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Pushed {
    /// the credential ids sealed, in order
    pub sealed: Vec<String>,
    /// the units restarted
    pub restarted: Vec<String>,
}

/// Pushes the admin vars `only` (every admin var the machine declares when empty) from the
/// store to `host`: checks that every file is stored before it sends any, seals each on the
/// machine, then restarts the union of their consumers once.
pub fn push(
    store: &Store,
    identity: &Path,
    remote: &Remote,
    host: &str,
    only: &[String],
) -> Result<Pushed> {
    let declared = remote.manifests()?;
    let admin = |name: &str| {
        declared
            .iter()
            .find(|m| m.name == name && m.class == Class::Admin)
    };
    let chosen: Vec<&Manifest> = if only.is_empty() {
        declared
            .iter()
            .filter(|m| m.class == Class::Admin)
            .collect()
    } else {
        only.iter()
            .map(|v| admin(v).ok_or_else(|| Error(format!("{host} declares no admin var {v}"))))
            .collect::<Result<_>>()?
    };
    // every file must be stored before anything is sent
    let missing: Vec<String> = chosen
        .iter()
        .flat_map(|m| m.files.iter().map(move |f| (m, f)))
        .filter(|(m, f)| !store.has(host, &m.name, f))
        .map(|(m, f)| format!("{}/{f}", m.name))
        .collect();
    if !missing.is_empty() {
        return err(format!("not stored for {host}: {}", missing.join(", ")));
    }
    let mut pushed = Pushed::default();
    let mut consumers = BTreeSet::new();
    for m in chosen {
        for f in &m.files {
            let value = store.get(identity, host, &m.name, f)?;
            remote.run(&format!("{RUNNER} --admin {} {f}", m.name), Some(&value))?;
            pushed.sealed.push(var_file(&m.name, f));
        }
        consumers.extend(m.consumers.iter().cloned());
    }
    if !consumers.is_empty() {
        let units: Vec<String> = consumers.into_iter().collect();
        remote.run(&format!("systemctl try-restart {}", units.join(" ")), None)?;
        pushed.restarted = units;
    }
    Ok(pushed)
}

/// One line per file of each admin var: stored here, sealed there.
pub fn list(store: &Store, remote: &Remote, host: &str) -> Result<String> {
    let sealed = remote.sealed()?;
    let mut out = String::new();
    for m in remote
        .manifests()?
        .iter()
        .filter(|m| m.class == Class::Admin)
    {
        for f in &m.files {
            let stored = if store.has(host, &m.name, f) {
                "stored"
            } else {
                "missing"
            };
            let on = if sealed.contains(&var_file(&m.name, f)) {
                "sealed"
            } else {
                "not-sealed"
            };
            out.push_str(&format!("{} {f} {stored} {on}\n", m.name));
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::os::unix::fs::PermissionsExt;
    use std::thread;
    use std::time;
    use tempfile::{Builder, TempDir};

    fn script(dir: &Path, name: &str, body: &str) -> Program {
        let p = dir.join(name);
        fs::write(&p, format!("#!/bin/sh\n{body}")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        Program::new(vec![p.into_os_string()])
    }

    /// A stand-in for age: `-e -R FILE -o OUT` writes "AGE(" + recipients + ")" + stdin to
    /// OUT; `-d -i ID FILE` checks the identity exists and prints FILE without the wrapper.
    fn fake_age(dir: &Path) -> Program {
        script(
            dir,
            "age",
            r#"set -eu
case $1 in
  -e) r=$(cat "$3"); { printf 'AGE(%s)' "$r"; cat; } > "$5" ;;
  -d) [ -f "$3" ] || exit 3; sed 's/^AGE([^)]*)//' "$4" ;;
  *) exit 2 ;;
esac
"#,
        )
    }

    /// A stand-in for ssh: logs "DEST: COMMAND" and the stdin it got to LOG, and answers the
    /// commands the tool sends from a machine tree under ROOT.
    fn fake_ssh(dir: &Path) -> Program {
        let root = dir.join("machine");
        let log = dir.join("ssh.log");
        script(
            dir,
            "ssh",
            &format!(
                r#"set -eu
root={root}
log={log}
dest=$1; shift
cmd="$*"
in=$(cat)
printf '%s: %s\n' "$dest" "$cmd" >> "$log"
[ -z "$in" ] || printf '  stdin: %s\n' "$in" >> "$log"
case $cmd in
  "cat {VARS_D}/"*) cat "$root{VARS_D}"/*.json ;;
  "ls -1A {CREDSTORE}"*) ls -1A "$root{CREDSTORE}" 2>/dev/null || true ;;
  "{RUNNER} --admin "*) set -- $cmd; mkdir -p "$root{CREDSTORE}"; printf '%s' "$in" > "$root{CREDSTORE}/$3.$4" ;;
  "cat {PUB_DIR}/"*) cat "$root${{cmd#cat }}" ;;
  "systemctl try-restart "*) ;;
  *) echo "unknown command: $cmd" >&2; exit 9 ;;
esac
"#,
                root = root.display(),
                log = log.display(),
            ),
        )
    }

    /// The machine tree: two admin vars (one shared consumer) and a local one.
    fn machine(dir: &Path) {
        let d = dir.join(format!("machine{VARS_D}"));
        fs::create_dir_all(&d).unwrap();
        fs::write(d.join("sshd-host-cert.json"), r#"{"class":"admin","consumers":["sshd.service"],"credentials":["sshd-host-cert.cert"],"files":["cert"],"name":"sshd-host-cert"}"#).unwrap();
        fs::write(d.join("sshd-revoked-keys.json"), r#"{"class":"admin","consumers":["sshd.service"],"credentials":["sshd-revoked-keys.krl"],"files":["krl"],"name":"sshd-revoked-keys"}"#).unwrap();
        fs::write(d.join("sshd-hostkey.json"), r#"{"after":[],"class":"local","credentials":["sshd-hostkey.key"],"name":"sshd-hostkey","publics":["key.pub"],"secrets":["key"]}"#).unwrap();
        let p = dir.join(format!("machine{PUB_DIR}/sshd-hostkey/pub"));
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("key.pub"), "ssh-ed25519 AAAA host").unwrap();
    }

    fn setup(name: &str) -> (TempDir, Store, Remote, PathBuf) {
        let s = Builder::new()
            .prefix(&format!("golconda-vars-{name}-"))
            .tempdir()
            .unwrap();
        machine(s.path());
        let store = Store::new(s.path().join("vars"), fake_age(s.path()));
        fs::create_dir_all(s.path().join("vars")).unwrap();
        fs::write(s.path().join("vars/recipients.txt"), "age1op\n").unwrap();
        let id = s.path().join("id.txt");
        fs::write(&id, "AGE-SECRET-KEY-1").unwrap();
        let remote = Remote::new(fake_ssh(s.path()), "web1").unwrap();
        (s, store, remote, id)
    }

    #[test]
    fn words() {
        for ok in ["web1", "sshd-host-cert", "cert", "key.pub", "a_b"] {
            assert!(word(ok).is_ok(), "{ok}");
        }
        for bad in [
            "", ".", "..", "a/b", "a b", "-x", "a\"b", "a$b", "a;b", "a'b", "a\nb",
        ] {
            assert!(word(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn manifests_concatenated() {
        let m = parse_manifests(
            r#"{"class":"admin","consumers":["sshd.service"],"credentials":["a.cert"],"files":["cert"],"name":"a"}{"after":[],"class":"local","credentials":["b.key"],"name":"b","publics":[],"secrets":["key"]}"#,
        )
        .unwrap();
        assert_eq!(
            m,
            vec![
                Manifest {
                    name: "a".into(),
                    class: Class::Admin,
                    files: vec!["cert".into()],
                    consumers: vec!["sshd.service".into()],
                },
                Manifest {
                    name: "b".into(),
                    class: Class::Local,
                    files: vec!["key".into()],
                    consumers: vec![],
                },
            ]
        );
        assert_eq!(parse_manifests("").unwrap(), vec![]);
        assert!(parse_manifests(r#"{"class":"x","name":"a","files":[]}"#).is_err());
        assert!(parse_manifests(r#"{"class":"admin","name":"../a","files":[]}"#).is_err());
        assert!(parse_manifests("{").is_err());
    }

    #[test]
    fn consumers_are_unit_names() {
        let with = |c: &str| {
            parse_manifests(&format!(
                r#"{{"class":"admin","consumers":[{c}],"files":["f"],"name":"a"}}"#
            ))
        };
        assert!(with(r#""sshd.service", "getty@tty1.service", "a:b-c_d.socket""#).is_ok());
        // they become words of `systemctl try-restart` on the machine's shell
        for bad in [
            r#""x; reboot""#,
            r#""$(id).service""#,
            r#""-H.service""#,
            r#""""#,
            r#""sshd""#,
        ] {
            assert!(with(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_program_still_open_for_writing_is_run_once_it_is_closed() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        let p = dir.join("prog");
        // open for writing, as a script being written is (or one a forked child still holds)
        let mut f = fs::File::create(&p).unwrap();
        f.write_all(b"#!/bin/sh\necho ran\n").unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        let closer = thread::spawn(move || {
            thread::sleep(time::Duration::from_millis(50));
            drop(f);
        });
        let prog = Program::new(vec![p.clone().into_os_string()]);
        assert_eq!(prog.run::<&str>(&[], None).unwrap(), b"ran\n");
        closer.join().unwrap();
    }

    #[test]
    fn a_program_gets_the_variables_it_is_given() {
        let tmp = TempDir::new().unwrap();
        let p = script(tmp.path(), "show", "printf '%s' \"$GOLCONDA_TEST_SHOWN\"\n");
        let shown = p.with_env("GOLCONDA_TEST_SHOWN", "here");
        assert_eq!(shown.run::<&str>(&[], None).unwrap(), b"here");
        assert_eq!(
            p.run::<&str>(&[], None).unwrap(),
            b"",
            "the original has none"
        );
    }

    #[test]
    fn a_program_that_takes_too_long_is_stopped() {
        let tmp = TempDir::new().unwrap();
        let slow = script(tmp.path(), "slow", "sleep 20\n");
        let started = time::Instant::now();
        let e = slow
            .run_within::<&str>(&[], time::Duration::from_millis(300))
            .unwrap_err();
        assert!(e.to_string().contains("did not finish within"), "{e}");
        assert!(started.elapsed() < time::Duration::from_secs(10));
        let quick = script(tmp.path(), "quick", "echo done\n");
        let out = quick.run_within::<&str>(&[], time::Duration::from_secs(30));
        assert_eq!(out.unwrap(), b"done\n");
        let fails = script(tmp.path(), "fails", "echo why >&2; exit 3\n");
        let e = fails.run_within::<&str>(&[], time::Duration::from_secs(30));
        assert!(e.unwrap_err().to_string().contains("why"));
    }

    #[test]
    fn program_from_env() {
        // SAFETY: tests in this module touch only their own variable names
        unsafe { env::set_var("GOLCONDA_TEST_PROG", "ssh -p 10022 -o X=y") };
        let p = Program::from_env("GOLCONDA_TEST_PROG", "ssh");
        assert_eq!(p.argv, ["ssh", "-p", "10022", "-o", "X=y"]);
        let d = Program::from_env("GOLCONDA_TEST_UNSET", "age");
        assert_eq!(d.argv, ["age"]);
    }

    #[test]
    fn store_set_get() {
        let (s, store, _, id) = setup("store");
        let p = store
            .set("web1", "sshd-host-cert", "cert", b"CERT")
            .unwrap();
        assert_eq!(p, s.path().join("vars/web1/sshd-host-cert/cert.age"));
        assert_eq!(fs::read_to_string(&p).unwrap(), "AGE(age1op)CERT");
        assert!(store.has("web1", "sshd-host-cert", "cert"));
        assert_eq!(
            store.get(&id, "web1", "sshd-host-cert", "cert").unwrap(),
            b"CERT"
        );
        // no temporary file stays
        let dir: Vec<_> = fs::read_dir(p.parent().unwrap()).unwrap().collect();
        assert_eq!(dir.len(), 1);
        assert!(store.set("../x", "v", "f", b"x").is_err());
        assert!(store.get(&id, "web1", "nope", "cert").is_err());
    }

    #[test]
    fn store_needs_recipients() {
        let (s, store, _, _) = setup("norecipients");
        fs::remove_file(s.path().join("vars/recipients.txt")).unwrap();
        let e = store.set("web1", "v", "f", b"x").unwrap_err();
        assert!(e.0.contains("recipients.txt"), "{e}");
    }

    #[test]
    fn push_all() {
        let (s, store, remote, id) = setup("push");
        store
            .set("web1", "sshd-host-cert", "cert", b"CERT")
            .unwrap();
        store
            .set("web1", "sshd-revoked-keys", "krl", b"KRL")
            .unwrap();
        let r = push(&store, &id, &remote, "web1", &[]).unwrap();
        assert_eq!(
            r,
            Pushed {
                sealed: vec!["sshd-host-cert.cert".into(), "sshd-revoked-keys.krl".into()],
                restarted: vec!["sshd.service".into()],
            }
        );
        let m = s.path().join(format!("machine{CREDSTORE}"));
        assert_eq!(
            fs::read_to_string(m.join("sshd-host-cert.cert")).unwrap(),
            "CERT"
        );
        let log = fs::read_to_string(s.path().join("ssh.log")).unwrap();
        // one restart, after the last seal
        assert_eq!(log.matches("systemctl try-restart").count(), 1);
        assert!(
            log.trim_end()
                .ends_with("web1: systemctl try-restart sshd.service"),
            "{log}"
        );
        assert!(log.contains(&format!(
            "web1: {RUNNER} --admin sshd-host-cert cert\n  stdin: CERT"
        )));
    }

    #[test]
    fn push_checks_everything_first() {
        let (s, store, remote, id) = setup("pushmissing");
        store
            .set("web1", "sshd-host-cert", "cert", b"CERT")
            .unwrap();
        let e = push(&store, &id, &remote, "web1", &[]).unwrap_err();
        assert!(e.0.contains("sshd-revoked-keys/krl"), "{e}");
        let log = fs::read_to_string(s.path().join("ssh.log")).unwrap();
        assert!(!log.contains("--admin"), "nothing is pushed: {log}");
    }

    #[test]
    fn push_some() {
        let (_scratch, store, remote, id) = setup("pushsome");
        store
            .set("web1", "sshd-host-cert", "cert", b"CERT")
            .unwrap();
        let r = push(&store, &id, &remote, "web1", &["sshd-host-cert".into()]).unwrap();
        assert_eq!(r.sealed, ["sshd-host-cert.cert"]);
        // a local var or an undeclared one is refused by name
        for v in ["sshd-hostkey", "nope"] {
            let e = push(&store, &id, &remote, "web1", &[v.into()]).unwrap_err();
            assert!(e.0.contains(v), "{e}");
        }
    }

    #[test]
    fn list_and_public() {
        let (_scratch, store, remote, id) = setup("list");
        store
            .set("web1", "sshd-host-cert", "cert", b"CERT")
            .unwrap();
        push(&store, &id, &remote, "web1", &["sshd-host-cert".into()]).unwrap();
        assert_eq!(
            list(&store, &remote, "web1").unwrap(),
            "sshd-host-cert cert stored sealed\nsshd-revoked-keys krl missing not-sealed\n"
        );
        assert_eq!(
            remote.public("sshd-hostkey", "key.pub").unwrap(),
            b"ssh-ed25519 AAAA host"
        );
        assert!(remote.public("../etc", "shadow").is_err());
    }
}
