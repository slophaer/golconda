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
use std::io::Write;
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
        }
    }

    /// The program at `path`, with no arguments of its own (a path may hold spaces).
    pub fn at(path: &Path) -> Program {
        Program {
            argv: vec![path.as_os_str().to_owned()],
            dir: None,
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

/// The admin vars an enrolment pushes, in the order it seals them: the KRL first, the host
/// certificate last. A sealed certificate is what ends plain-key login on the machine
/// (`golconda-sshd-enrolled.service`), so it is sealed only once the KRL is.
pub const ENROL_VARS: [(&str, &str); 2] =
    [("sshd-revoked-keys", "krl"), ("sshd-host-cert", "cert")];
/// The local var whose public file is the host key the CA signs.
pub const HOSTKEY: (&str, &str) = ("sshd-hostkey", "key.pub");

/// The CA key that signs host certificates, through `ssh-keygen` (`GOLCONDA_SSH_KEYGEN`).
pub struct Signer {
    pub keygen: Program,
    /// The CA's private key file; with `module`, its public key file, whose private half the
    /// token holds (ssh-keygen finds a token's key by its public half)
    pub ca: PathBuf,
    /// The token's PKCS#11 module (`ssh-keygen -D`)
    pub module: Option<PathBuf>,
}

/// What `golconda vars enrol` is asked to do.
pub struct Enrol<'a> {
    pub host: &'a str,
    /// The certificate's principals, the names clients reach the machine by (empty: `host`)
    pub principals: &'a [String],
    /// ssh-keygen's `-V`
    pub validity: &'a str,
    /// The current KRL; `None` keeps the one stored for the host
    pub krl: Option<&'a [u8]>,
    /// The fingerprint the console printed (`SHA256:…`); `None` asks the operator
    pub fingerprint: Option<&'a str>,
}

/// What [`enrol`] did.
#[derive(Debug)]
pub struct Enrolled {
    /// ssh-keygen's fingerprint line of the host key
    pub fingerprint: String,
    /// the encrypted files written, the KRL (when given) and the certificate
    pub stored: Vec<PathBuf>,
    pub pushed: Pushed,
}

/// Enrols `req.host`: reads its host key, has the operator confirm the fingerprint (`confirm`
/// gets ssh-keygen's fingerprint line and says yes or no) or compares it with
/// `req.fingerprint`, signs it as a host certificate, stores the certificate and the KRL, and
/// pushes both.
pub fn enrol(
    store: &Store,
    identity: &Path,
    remote: &Remote,
    signer: &Signer,
    req: &Enrol,
    confirm: &mut dyn FnMut(&str) -> bool,
) -> Result<Enrolled> {
    let host = word(req.host)?;
    let default = [host.to_owned()];
    let principals = if req.principals.is_empty() {
        &default[..]
    } else {
        req.principals
    };
    enrol_checks(store, remote, req, host, principals)?;

    // the host key, in a directory of its own: ssh-keygen writes the certificate beside it
    let scratch = Builder::new()
        .prefix("golconda-enrol-")
        .tempdir()
        .map_err(|e| Error(format!("a scratch directory: {e}")))?;
    let key = scratch.path().join("host.pub");
    let public = remote.public(HOSTKEY.0, HOSTKEY.1)?;
    fs::write(&key, &public).map_err(|e| Error(format!("{}: {e}", key.display())))?;
    let line = signer.fingerprint(&key)?;
    check_key(host, &line, req.fingerprint, confirm)?;

    let cert = signer
        .sign(&key, host, principals, req.validity)
        .map_err(|e| Error(format!("{e}: nothing is stored or pushed")))?;
    let mut stored = Vec::new();
    if let Some(krl) = req.krl {
        let (krl_var, krl_file) = ENROL_VARS[0];
        stored.push(
            store
                .set(host, krl_var, krl_file, krl)
                .map_err(|e| Error(format!("{e}: nothing is pushed")))?,
        );
    }
    let (cert_var, cert_file) = ENROL_VARS[1];
    stored.push(
        store
            .set(host, cert_var, cert_file, &cert)
            .map_err(|e| Error(format!("{e}: nothing is pushed")))?,
    );
    // the KRL first: the certificate is sealed last, and sshd restarts after both
    let only: Vec<String> = ENROL_VARS.iter().map(|(v, _)| (*v).to_owned()).collect();
    let pushed = push(store, identity, remote, host, &only).map_err(|e| {
        Error(format!(
            "{e}\nthe certificate and the KRL are stored here. {host} seals the certificate \
             last and restarts sshd after it, so plain keys log in there until a push \
             finishes. Push again with: golconda vars push -i IDENTITY {host} {}",
            only.join(" ")
        ))
    })?;
    Ok(Enrolled {
        fingerprint: line.trim().to_owned(),
        stored,
        pushed,
    })
}

/// What [`enrol`] checks before it reads the host key: the principals are names, a KRL is
/// given or stored, and the machine declares both admin vars.
fn enrol_checks(
    store: &Store,
    remote: &Remote,
    req: &Enrol,
    host: &str,
    principals: &[String],
) -> Result<()> {
    for p in principals {
        if p.is_empty()
            || p.chars()
                .any(|c| c == ',' || c.is_whitespace() || c.is_control())
        {
            return err(format!(
                "'{p}' is not a principal (one name, no commas or spaces)"
            ));
        }
    }
    // sshd needs a KRL: a certificate sealed without one ends plain-key login while the
    // fallback list still refuses every user certificate, and nobody could log in
    let (krl_var, krl_file) = ENROL_VARS[0];
    if req.krl.is_none() && !store.has(host, krl_var, krl_file) {
        return err(format!(
            "no KRL for {host}: give --krl FILE, the deployment's current revocation list \
             (an empty one is `ssh-keygen -k -f FILE`); nothing is signed, stored or pushed"
        ));
    }
    let declared = remote.manifests()?;
    for (var, _) in ENROL_VARS {
        if !declared
            .iter()
            .any(|m| m.name == var && m.class == Class::Admin)
        {
            return err(format!(
                "{host} declares no admin var {var} (its release has no /services/sshd): \
                 nothing is signed, stored or pushed"
            ));
        }
    }
    Ok(())
}

/// The host key is the one on the console: the fingerprint in `line` (ssh-keygen's) is `want`,
/// or, without one, the operator says so.
fn check_key(
    host: &str,
    line: &str,
    want: Option<&str>,
    confirm: &mut dyn FnMut(&str) -> bool,
) -> Result<()> {
    let fingerprint = line.split_whitespace().nth(1).unwrap_or_default();
    match want {
        Some(want) => {
            let bare = |f: &str| f.trim().trim_start_matches("SHA256:").to_owned();
            if bare(want) != bare(fingerprint) {
                return err(format!(
                    "{host}'s host key is {fingerprint}, not {want}: nothing is signed, stored \
                     or pushed. Compare with the console's line `golconda: ssh host key …`: a \
                     different key is another machine, or one in the middle"
                ));
            }
        }
        None => {
            if !confirm(line.trim()) {
                return err("not confirmed: nothing is signed, stored or pushed");
            }
        }
    }
    Ok(())
}

impl Signer {
    /// ssh-keygen's fingerprint line of the public key file `key`: `256 SHA256:… comment (TYPE)`.
    pub fn fingerprint(&self, key: &Path) -> Result<String> {
        let out = self.keygen.run(
            &[
                OsStr::new("-l"),
                OsStr::new("-E"),
                OsStr::new("sha256"),
                OsStr::new("-f"),
                key.as_os_str(),
            ],
            None,
        )?;
        let line = String::from_utf8_lossy(&out).trim().to_owned();
        if line.lines().count() != 1 || !line.contains(" SHA256:") {
            return err(format!("the host key is not one public key: {line}"));
        }
        Ok(line)
    }

    /// Signs the public key file `key` as a host certificate (`ssh-keygen -s CA -h`, with the
    /// token's module `-D`), key id `id`; the certificate.
    pub fn sign(
        &self,
        key: &Path,
        id: &str,
        principals: &[String],
        validity: &str,
    ) -> Result<Vec<u8>> {
        let mut args: Vec<OsString> = Vec::new();
        if let Some(m) = &self.module {
            args.extend(["-D".into(), m.into()]);
        }
        args.extend([
            "-s".into(),
            self.ca.clone().into(),
            "-h".into(),
            "-I".into(),
            id.into(),
            "-n".into(),
            principals.join(",").into(),
            "-V".into(),
            validity.into(),
            key.into(),
        ]);
        self.keygen.run(&args, None)?;
        let stem = key.file_stem().unwrap_or_default().to_string_lossy();
        let cert = key.with_file_name(format!("{stem}-cert.pub"));
        fs::read(&cert).map_err(|e| Error(format!("ssh-keygen wrote no {}: {e}", cert.display())))
    }
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

    fn program(path: PathBuf) -> Program {
        Program {
            argv: vec![path.into_os_string()],
            dir: None,
        }
    }

    fn script(dir: &Path, name: &str, body: &str) -> Program {
        let p = dir.join(name);
        fs::write(&p, format!("#!/bin/sh\n{body}")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        program(p)
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
        let prog = program(p.clone());
        assert_eq!(prog.run::<&str>(&[], None).unwrap(), b"ran\n");
        closer.join().unwrap();
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

    /// A stand-in for ssh-keygen: logs its arguments to keygen.log; `-l` prints a fingerprint
    /// line; a signing run writes `<key>-cert.pub` = "CERT(" + the key + ")", or with `fail`
    /// exits 1.
    fn fake_keygen(dir: &Path, fail: bool) -> Program {
        let log = dir.join("keygen.log");
        script(
            dir,
            "ssh-keygen",
            &format!(
                r#"set -eu
printf '%s\n' "$*" >> {log}
case $1 in
  -l) echo "256 SHA256:fakefp root@web1 (ED25519)" ;;
  *) [ {fail} = 0 ] || {{ echo 'no CA here' >&2; exit 1; }}
     for a; do last=$a; done
     {{ printf 'CERT('; cat "$last"; printf ')'; }} > "${{last%.pub}}-cert.pub" ;;
esac
"#,
                log = log.display(),
                fail = u8::from(fail),
            ),
        )
    }

    fn signer(dir: &Path, fail: bool, module: Option<&str>) -> Signer {
        Signer {
            keygen: fake_keygen(dir, fail),
            ca: dir.join("ca"),
            module: module.map(PathBuf::from),
        }
    }

    fn request<'a>(krl: Option<&'a [u8]>, fingerprint: Option<&'a str>) -> Enrol<'a> {
        Enrol {
            host: "web1",
            principals: &[],
            validity: "-5m:+52w",
            krl,
            fingerprint,
        }
    }

    fn log(dir: &Path, name: &str) -> String {
        fs::read_to_string(dir.join(name)).unwrap_or_default()
    }

    /// Nothing is stored and nothing is sealed on the machine.
    fn untouched(s: &TempDir, store: &Store) {
        for (var, file) in ENROL_VARS {
            assert!(!store.has("web1", var, file), "{var} is stored");
        }
        let ssh = log(s.path(), "ssh.log");
        assert!(!ssh.contains("--admin"), "something was sealed: {ssh}");
        assert!(!ssh.contains("systemctl"), "something restarted: {ssh}");
    }

    #[test]
    fn enrol_confirmed() {
        let (s, store, remote, id) = setup("enrol");
        let mut asked = Vec::new();
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, None),
            &request(Some(b"KRL"), None),
            &mut |line| {
                asked.push(line.to_owned());
                true
            },
        )
        .unwrap();
        // the operator saw the fingerprint once, before anything was signed
        assert_eq!(asked, ["256 SHA256:fakefp root@web1 (ED25519)"]);
        assert_eq!(e.fingerprint, "256 SHA256:fakefp root@web1 (ED25519)");
        // a host certificate, named for the machine, its name the principal
        let keygen = log(s.path(), "keygen.log");
        let ca = s.path().join("ca");
        assert!(
            keygen.contains(&format!(
                "-s {} -h -I web1 -n web1 -V -5m:+52w ",
                ca.display()
            )),
            "{keygen}"
        );
        assert!(!keygen.contains("-D"), "{keygen}");
        assert_eq!(
            store.get(&id, "web1", "sshd-host-cert", "cert").unwrap(),
            b"CERT(ssh-ed25519 AAAA host)"
        );
        assert_eq!(
            store.get(&id, "web1", "sshd-revoked-keys", "krl").unwrap(),
            b"KRL"
        );
        assert_eq!(e.stored.len(), 2);
        // the KRL is sealed before the certificate, and sshd restarts once, last
        assert_eq!(
            e.pushed,
            Pushed {
                sealed: vec!["sshd-revoked-keys.krl".into(), "sshd-host-cert.cert".into()],
                restarted: vec!["sshd.service".into()],
            }
        );
        let ssh = log(s.path(), "ssh.log");
        let krl = ssh.find("--admin sshd-revoked-keys krl").unwrap();
        let cert = ssh.find("--admin sshd-host-cert cert").unwrap();
        let restart = ssh.find("systemctl try-restart").unwrap();
        assert!(krl < cert && cert < restart, "{ssh}");
    }

    #[test]
    fn enrol_not_confirmed() {
        let (s, store, remote, id) = setup("enrolno");
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, None),
            &request(Some(b"KRL"), None),
            &mut |_| false,
        )
        .unwrap_err();
        assert!(e.0.contains("not confirmed"), "{e}");
        assert!(e.0.contains("nothing"), "{e}");
        assert!(!log(s.path(), "keygen.log").contains("-s "), "signed");
        untouched(&s, &store);
    }

    #[test]
    fn enrol_fingerprint_given() {
        let (s, store, remote, id) = setup("enrolfp");
        let mut never = |_: &str| -> bool { panic!("asked though --fingerprint was given") };
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, None),
            &request(Some(b"KRL"), Some("SHA256:otherfp")),
            &mut never,
        )
        .unwrap_err();
        assert!(
            e.0.contains("SHA256:otherfp") && e.0.contains("SHA256:fakefp"),
            "{e}"
        );
        assert!(!log(s.path(), "keygen.log").contains("-s "), "signed");
        untouched(&s, &store);
        // the right one goes through without a question
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, None),
            &request(Some(b"KRL"), Some("SHA256:fakefp")),
            &mut never,
        )
        .unwrap();
        assert_eq!(e.pushed.sealed.len(), 2);
    }

    #[test]
    fn enrol_with_a_token() {
        let (s, store, remote, id) = setup("enroltoken");
        enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, Some("/lib/libykcs11.so")),
            &request(Some(b"KRL"), None),
            &mut |_| true,
        )
        .unwrap();
        let keygen = log(s.path(), "keygen.log");
        let ca = s.path().join("ca");
        assert!(
            keygen.contains(&format!("-D /lib/libykcs11.so -s {} -h ", ca.display())),
            "{keygen}"
        );
    }

    #[test]
    fn enrol_principals() {
        let (s, store, remote, id) = setup("enrolnames");
        let names = ["web1.example.com".to_owned(), "10.0.0.1".to_owned()];
        let req = Enrol {
            principals: &names,
            ..request(Some(b"KRL"), None)
        };
        let sign = signer(s.path(), false, None);
        enrol(&store, &id, &remote, &sign, &req, &mut |_| true).unwrap();
        let keygen = log(s.path(), "keygen.log");
        assert!(
            keygen.contains("-I web1 -n web1.example.com,10.0.0.1 "),
            "{keygen}"
        );
        // a principal is one name: ssh-keygen splits -n at commas
        for bad in ["a,b", "a b", ""] {
            let names = [bad.to_owned()];
            let req = Enrol {
                principals: &names,
                ..request(Some(b"KRL"), None)
            };
            assert!(
                enrol(&store, &id, &remote, &sign, &req, &mut |_| true).is_err(),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn enrol_needs_a_krl() {
        let (s, store, remote, id) = setup("enrolkrl");
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, None),
            &request(None, None),
            &mut |_| true,
        )
        .unwrap_err();
        assert!(e.0.contains("--krl"), "{e}");
        assert!(!log(s.path(), "keygen.log").contains("-s "), "signed");
        untouched(&s, &store);
        // a stored KRL is kept and pushed
        store
            .set("web1", "sshd-revoked-keys", "krl", b"OLD-KRL")
            .unwrap();
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, None),
            &request(None, None),
            &mut |_| true,
        )
        .unwrap();
        assert_eq!(e.stored.len(), 1, "only the certificate is written");
        assert_eq!(
            store.get(&id, "web1", "sshd-revoked-keys", "krl").unwrap(),
            b"OLD-KRL"
        );
        assert!(
            log(s.path(), "ssh.log").contains("--admin sshd-revoked-keys krl\n  stdin: OLD-KRL")
        );
    }

    #[test]
    fn enrol_signing_fails() {
        let (s, store, remote, id) = setup("enrolfail");
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), true, None),
            &request(Some(b"KRL"), None),
            &mut |_| true,
        )
        .unwrap_err();
        assert!(e.0.contains("no CA here"), "{e}");
        assert!(e.0.contains("nothing"), "{e}");
        untouched(&s, &store);
    }

    #[test]
    fn enrol_needs_the_vars_declared() {
        let (s, store, remote, id) = setup("enrolundeclared");
        fs::remove_file(
            s.path()
                .join(format!("machine{VARS_D}/sshd-host-cert.json")),
        )
        .unwrap();
        let e = enrol(
            &store,
            &id,
            &remote,
            &signer(s.path(), false, None),
            &request(Some(b"KRL"), None),
            &mut |_| true,
        )
        .unwrap_err();
        assert!(e.0.contains("sshd-host-cert"), "{e}");
        assert!(!log(s.path(), "keygen.log").contains("-s "), "signed");
        untouched(&s, &store);
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
