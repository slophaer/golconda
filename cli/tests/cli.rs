//! The `golconda` binary: `vars` against stand-ins for age and ssh, `release` against a release
//! directory in a scratch directory with a stand-in for gpgv, and rclone and git as they are.
//! `release build` needs a Golconda checkout and nix-build, so its pieces are unit tests
//! (src/release.rs).

use ring::digest;
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use tempfile::TempDir;

fn golconda(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_golconda"))
        .args(args)
        .output()
        .expect("run golconda")
}

fn stdout(o: &Output) -> String {
    assert!(
        o.status.success(),
        "golconda failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout.clone()).unwrap()
}

fn sha256(path: &Path) -> String {
    let sum = digest::digest(&digest::SHA256, &fs::read(path).unwrap());
    sum.as_ref().iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

#[test]
fn usage_errors_exit_2() {
    let o = golconda(&["frobnicate"]);
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).contains("Usage: golconda"));
}

#[test]
fn version_and_help() {
    let v = stdout(&golconda(&["--version"]));
    assert_eq!(v, format!("golconda {}\n", env!("CARGO_PKG_VERSION")));
    let help = stdout(&golconda(&["--help"]));
    assert!(help.contains("Usage: golconda <COMMAND>"), "{help}");
    assert!(help.contains("vars") && help.contains("release"), "{help}");
}

/// `golconda vars` with stand-ins for age and ssh (GOLCONDA_AGE, GOLCONDA_SSH): the wiring of
/// set, push and list. The logic is tested in src/vars.rs.
#[test]
fn vars_set_push_list() {
    let tmp = TempDir::new().unwrap();
    let dir = tmp.path();
    fs::create_dir_all(dir.join("vars")).unwrap();
    fs::write(dir.join("vars/recipients.txt"), "age1op\n").unwrap();
    fs::write(dir.join("id.txt"), "AGE-SECRET-KEY-1").unwrap();
    let exe = |name: &str, body: &str| {
        let p = dir.join(name);
        fs::write(&p, format!("#!/bin/sh\nset -eu\n{body}")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        p
    };
    // age: -e -R R -o OUT copies stdin; -d -i ID FILE prints FILE
    let age = exe(
        "age",
        "case $1 in -e) cat > \"$5\" ;; -d) cat \"$4\" ;; esac\n",
    );
    // ssh DEST CMD: one admin var; seals by logging; nothing sealed yet for list
    let log = dir.join("ssh.log");
    let ssh = exe(
        "ssh",
        &format!(
            "shift; case \"$*\" in\n\
             \"cat /usr/lib/golconda/vars.d/\"*) printf '%s' '{{\"class\":\"admin\",\"consumers\":[\"sshd.service\"],\"credentials\":[\"c.cert\"],\"files\":[\"cert\"],\"name\":\"c\"}}' ;;\n\
             \"ls -1A \"*) ;;\n\
             *) printf '%s|%s\\n' \"$*\" \"$(cat)\" >> {} ;;\n\
             esac\n",
            log.display()
        ),
    );
    let run = |args: &[&str], stdin: &str| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_golconda"))
            .args(args)
            .current_dir(dir)
            .env("GOLCONDA_AGE", &age)
            .env("GOLCONDA_SSH", &ssh)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        c.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
        c.wait_with_output().unwrap()
    };
    let o = run(&["vars", "set", "web1", "c", "cert"], "CERT");
    assert!(stdout(&o).contains("vars/web1/c/cert.age"));
    let o = run(&["vars", "list", "web1"], "");
    assert_eq!(stdout(&o), "c cert stored not-sealed\n");
    let o = run(&["vars", "push", "-i", "id.txt", "web1"], "");
    assert_eq!(stdout(&o), "sealed c.cert\nrestarted sshd.service\n");
    let pushed = fs::read_to_string(&log).unwrap();
    assert!(
        pushed.starts_with("/usr/lib/golconda/golconda-var-run --admin c cert|CERT\n"),
        "{pushed}"
    );
    // push needs an identity
    let o = run(&["vars", "push", "web1"], "");
    assert_eq!(
        o.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
}

fn exe(dir: &Path, name: &str, body: &str) -> PathBuf {
    let p = dir.join(name);
    fs::write(&p, format!("#!/bin/sh\nset -eu\n{body}")).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
    p
}

/// A deploy host and a machine for `vars enrol`: a store with recipients, an identity, an age
/// that copies, and an ssh that serves the two admin vars' manifests and `host.pub` as the host
/// key, seals into `sealed/` and logs every command to ssh.log.
fn enrol_fixture() -> (TempDir, Vec<(&'static str, PathBuf)>) {
    let tmp = TempDir::new().unwrap();
    let dir = tmp.path();
    fs::create_dir_all(dir.join("vars")).unwrap();
    fs::create_dir_all(dir.join("sealed")).unwrap();
    fs::write(dir.join("vars/recipients.txt"), "age1op\n").unwrap();
    fs::write(dir.join("id.txt"), "AGE-SECRET-KEY-1").unwrap();
    fs::write(dir.join("krl"), "KRL").unwrap();
    let age = exe(
        dir,
        "age",
        "case $1 in -e) cat > \"$5\" ;; -d) cat \"$4\" ;; esac\n",
    );
    let manifest = |name: &str, file: &str| {
        format!(
            r#"{{"class":"admin","consumers":["sshd.service"],"credentials":["{name}.{file}"],"files":["{file}"],"name":"{name}"}}"#
        )
    };
    let ssh = exe(
        dir,
        "ssh",
        &format!(
            "d={dir}\nshift; printf '%s\\n' \"$*\" >> \"$d/ssh.log\"\ncase \"$*\" in\n\
             \"cat /usr/lib/golconda/vars.d/\"*) printf '%s' '{}{}' ;;\n\
             \"cat /var/lib/golconda/vars/sshd-hostkey/pub/key.pub\") cat \"$d/host.pub\" ;;\n\
             \"/usr/lib/golconda/golconda-var-run --admin \"*) set -- $*; cat > \"$d/sealed/$3.$4\" ;;\n\
             \"systemctl try-restart \"*) ;;\n\
             *) exit 9 ;;\n\
             esac\n",
            manifest("sshd-host-cert", "cert"),
            manifest("sshd-revoked-keys", "krl"),
            dir = dir.display(),
        ),
    );
    (tmp, vec![("GOLCONDA_AGE", age), ("GOLCONDA_SSH", ssh)])
}

/// `golconda ARGS` in `dir` with `env`, `stdin` on its standard input.
fn run_in(dir: &Path, env: &[(&str, PathBuf)], args: &[&str], stdin: &str) -> Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_golconda"));
    c.args(args).current_dir(dir);
    for (k, v) in env {
        c.env(k, v);
    }
    let mut c = c
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    c.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    c.wait_with_output().unwrap()
}

/// `golconda vars enrol` with stand-ins for ssh, age and ssh-keygen: the question, the answer,
/// and the token's arguments. The logic is tested in src/vars.rs.
#[test]
fn vars_enrol_asks() {
    let (tmp, mut env) = enrol_fixture();
    let dir = tmp.path();
    fs::write(dir.join("host.pub"), "ssh-ed25519 AAAA root@web1\n").unwrap();
    let keygen = exe(
        dir,
        "ssh-keygen",
        &format!(
            "printf '%s\\n' \"$*\" >> {}/keygen.log\n\
             case $1 in -l) echo '256 SHA256:fakefp root@web1 (ED25519)' ;;\n\
             *) for a; do last=$a; done; echo CERT > \"${{last%.pub}}-cert.pub\" ;; esac\n",
            dir.display()
        ),
    );
    env.push(("GOLCONDA_SSH_KEYGEN", keygen));
    let enrol = [
        "vars", "enrol", "-i", "id.txt", "web1", "--ca-key", "ca", "--krl", "krl",
    ];

    // no: nothing signed, nothing sealed
    let o = run_in(dir, &env, &enrol, "no\n");
    assert_eq!(o.status.code(), Some(1));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(
        err.contains("web1's host key: 256 SHA256:fakefp root@web1 (ED25519)"),
        "{err}"
    );
    assert!(err.contains("Type yes to sign it"), "{err}");
    assert!(err.contains("not confirmed"), "{err}");
    assert_eq!(fs::read_dir(dir.join("sealed")).unwrap().count(), 0);
    // no answer at all is a no
    let o = run_in(dir, &env, &enrol, "");
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(fs::read_dir(dir.join("sealed")).unwrap().count(), 0);

    // yes: signed, stored, sealed, the KRL first
    let o = run_in(dir, &env, &enrol, "yes\n");
    let out = stdout(&o);
    assert!(
        out.ends_with(
            "sealed sshd-revoked-keys.krl\nsealed sshd-host-cert.cert\nrestarted sshd.service\n"
        ),
        "{out}"
    );
    assert_eq!(
        fs::read_to_string(dir.join("sealed/sshd-host-cert.cert")).unwrap(),
        "CERT\n"
    );
    assert_eq!(
        fs::read_to_string(dir.join("sealed/sshd-revoked-keys.krl")).unwrap(),
        "KRL"
    );

    // a token: -D MODULE, and the CA named by its public key file
    let mut token = enrol.to_vec();
    token.extend([
        "--pkcs11-module",
        "/lib/libykcs11.so",
        "--fingerprint",
        "SHA256:fakefp",
    ]);
    token[6] = "ca.pub";
    stdout(&run_in(dir, &env, &token, ""));
    let log = fs::read_to_string(dir.join("keygen.log")).unwrap();
    assert!(
        log.contains("-D /lib/libykcs11.so -s ca.pub -h -I web1 -n web1 "),
        "{log}"
    );
    // a mismatch is refused without a question
    let last = token.len() - 1;
    token[last] = "SHA256:other";
    let o = run_in(dir, &env, &token, "yes\n");
    assert_eq!(o.status.code(), Some(1));
    assert!(!String::from_utf8_lossy(&o.stderr).contains("Type yes"));
    // a pkcs11: URI is explained, not passed on
    token[6] = "pkcs11:id=%04";
    let o = run_in(dir, &env, &token, "");
    assert_eq!(o.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&o.stderr).contains("public half"));
    // enrol needs an identity and a CA key
    for args in [
        &["vars", "enrol", "web1", "--ca-key", "ca"][..],
        &["vars", "enrol", "-i", "id.txt", "web1"],
    ] {
        let o = run_in(dir, &[], args, "");
        assert_eq!(o.status.code(), Some(2), "{args:?}");
    }
}

/// ssh-keygen as it is, in `dir`: its standard output.
fn keygen(dir: &Path, args: &[&str]) -> String {
    let o = Command::new("ssh-keygen")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(
        o.status.success(),
        "ssh-keygen {args:?}: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout).unwrap()
}

/// The enrol fixture with a real host key, `host.pub`, and its fingerprint.
fn real_host_key() -> (TempDir, Vec<(&'static str, PathBuf)>, String) {
    let (tmp, env) = enrol_fixture();
    let dir = tmp.path();
    keygen(
        dir,
        &[
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "root@web1",
            "-f",
            "host",
        ],
    );
    let fp = keygen(dir, &["-l", "-f", "host.pub"]);
    let fp = fp.split_whitespace().nth(1).unwrap().to_owned();
    (tmp, env, fp)
}

/// `vars enrol` of web1 as web1 and web1.example.com, with the CA `ca` and `extra` arguments.
fn enrol_real(dir: &Path, env: &[(&str, PathBuf)], fp: &str, ca: &str, extra: &[&str]) -> Output {
    let mut args = vec![
        "vars",
        "enrol",
        "-i",
        "id.txt",
        "web1",
        "--ca-key",
        ca,
        "--krl",
        "krl",
        "--principal",
        "web1",
        "--principal",
        "web1.example.com",
        "--fingerprint",
        fp,
    ];
    args.extend(extra);
    run_in(dir, env, &args, "")
}

/// The certificate sealed on the machine, as ssh-keygen -L reads it: a host certificate of the
/// host key, key id web1, both names, a validity that ends, signed by the CA of `ca_pub`.
fn check_host_cert(dir: &Path, fp: &str, ca_pub: &str) {
    let cert = dir.join("sealed/sshd-host-cert.cert");
    fs::copy(&cert, dir.join("got-cert.pub")).unwrap();
    let l = keygen(dir, &["-L", "-f", "got-cert.pub"]);
    assert!(
        l.contains("Type: ssh-ed25519-cert-v01@openssh.com host certificate"),
        "{l}"
    );
    assert!(l.contains("Key ID: \"web1\""), "{l}");
    assert!(
        l.contains("Principals: \n                web1\n                web1.example.com\n"),
        "{l}"
    );
    assert!(!l.contains("forever"), "{l}");
    assert!(l.contains(&format!("Public key: ED25519-CERT {fp}")), "{l}");
    let ca = keygen(dir, &["-l", "-f", ca_pub]);
    let ca = ca.split_whitespace().nth(1).unwrap();
    let signer = l
        .lines()
        .find(|x| x.contains("Signing CA: "))
        .unwrap_or_default();
    assert!(signer.contains(&format!(" {ca} ")), "{l}");
}

/// ssh-keygen as it is: `vars enrol` signs a real host key with a CA key file, and `ssh-keygen -L`
/// reads a host certificate with the machine's names and key id, signed by that CA.
#[test]
fn vars_enrol_signs_with_a_ca_key_file() {
    let (tmp, env, fp) = real_host_key();
    let dir = tmp.path();
    keygen(dir, &["-q", "-t", "ed25519", "-N", "", "-f", "file-ca"]);
    stdout(&enrol_real(dir, &env, &fp, "file-ca", &[]));
    check_host_cert(dir, &fp, "file-ca.pub");
}

/// ssh-keygen and SoftHSM as they are (GOLCONDA_TEST_PKCS11_MODULE names SoftHSM's module): the
/// CA key is only on the token, its file deleted; `vars enrol --pkcs11-module` signs with it, and
/// with a wrong PIN signs and seals nothing.
#[test]
fn vars_enrol_signs_with_a_ca_key_on_a_token() {
    let module = env::var("GOLCONDA_TEST_PKCS11_MODULE")
        .expect("GOLCONDA_TEST_PKCS11_MODULE names SoftHSM's libsofthsm2.so");
    let (tmp, mut env, fp) = real_host_key();
    let dir = tmp.path();
    fs::create_dir_all(dir.join("tokens")).unwrap();
    let conf = dir.join("softhsm2.conf");
    fs::write(
        &conf,
        format!(
            "directories.tokendir = {}/tokens\nobjectstore.backend = file\nlog.level = ERROR\n",
            dir.display()
        ),
    )
    .unwrap();
    let util = |args: &[&str]| {
        let o = Command::new("softhsm2-util")
            .args(["--module", module.as_str()])
            .args(args)
            .env("SOFTHSM2_CONF", &conf)
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(
            o.status.success(),
            "softhsm2-util {args:?}: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    };
    util(&[
        "--init-token",
        "--free",
        "--label",
        "golconda-test",
        "--pin",
        "1234",
        "--so-pin",
        "5678",
    ]);
    // a YubiKey's PIV keys are ECDSA or RSA; SoftHSM imports PKCS#8
    keygen(
        dir,
        &[
            "-q", "-t", "ecdsa", "-m", "PKCS8", "-N", "", "-f", "token-ca",
        ],
    );
    util(&[
        "--import",
        "token-ca",
        "--token",
        "golconda-test",
        "--label",
        "host-ca",
        "--id",
        "04",
        "--pin",
        "1234",
    ]);
    fs::remove_file(dir.join("token-ca")).unwrap();
    // ssh-keygen asks for the PIN on the terminal, or through SSH_ASKPASS
    env.extend([
        ("SOFTHSM2_CONF", conf.clone()),
        ("SSH_ASKPASS_REQUIRE", PathBuf::from("force")),
    ]);
    let token = ["--pkcs11-module", module.as_str()];

    // a wrong PIN: the token does not sign, nothing is sealed
    let mut wrong = env.clone();
    wrong.push(("SSH_ASKPASS", exe(dir, "askpass-wrong", "echo 0000\n")));
    let o = enrol_real(dir, &wrong, &fp, "token-ca.pub", &token);
    assert_eq!(
        o.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&o.stdout)
    );
    assert_eq!(fs::read_dir(dir.join("sealed")).unwrap().count(), 0);

    env.push(("SSH_ASKPASS", exe(dir, "askpass", "echo 1234\n")));
    stdout(&enrol_real(dir, &env, &fp, "token-ca.pub", &token));
    check_host_cert(dir, &fp, "token-ca.pub");
}

#[test]
fn vars_usage_errors_exit_2() {
    for args in [
        &["vars", "set", "web1", "c"][..],
        &["vars", "list"],
        &["vars", "pub", "web1", "v"],
        &["vars", "frobnicate"],
    ] {
        let o = golconda(args);
        assert_eq!(o.status.code(), Some(2), "{args:?}");
    }
}

/// A copy of `doc` in a directory of its own under target/ (inside the checkout: evaluation is
/// A release directory of `server` 20261105.1, and a gpgv that accepts or refuses every
/// signature.
fn release_fixture(gpgv_ok: bool) -> (TempDir, PathBuf) {
    let tmp = TempDir::new().unwrap();
    let dir = tmp.path().join("release");
    fs::create_dir_all(tmp.path().join("keys/release")).unwrap();
    fs::create_dir_all(&dir).unwrap();
    fs::write(tmp.path().join("keys/release/index.pgp"), "key").unwrap();
    let root = "ab".repeat(32);
    let uuid = |h: &str| {
        format!(
            "{}-{}-{}-{}-{}",
            &h[..8],
            &h[8..12],
            &h[12..16],
            &h[16..20],
            &h[20..32]
        )
    };
    let stem = "server_20261105.1";
    let files = [
        (
            format!("{stem}.usr.{}.raw", uuid(&root[..32])),
            "usr".to_string(),
        ),
        (
            format!("{stem}.usr-verity.{}.raw", uuid(&root[32..])),
            "verity".into(),
        ),
        (
            format!("{stem}.usr-verity-sig.raw"),
            format!(r#"{{"rootHash":"{root}"}}"#),
        ),
        (format!("{stem}.efi"), "uki".into()),
    ];
    let mut index = String::new();
    for (name, body) in &files {
        fs::write(dir.join(name), body).unwrap();
        let digest = sha256(&dir.join(name));
        index += &format!("{digest}  {name}\n");
    }
    fs::write(dir.join("SHA256SUMS"), index).unwrap();
    fs::write(dir.join("SHA256SUMS.gpg"), "sig").unwrap();
    let gpgv = tmp.path().join("gpgv");
    fs::write(
        &gpgv,
        if gpgv_ok {
            "#!/bin/sh\nexit 0\n"
        } else {
            "#!/bin/sh\necho 'BAD signature' >&2\nexit 1\n"
        },
    )
    .unwrap();
    fs::set_permissions(&gpgv, fs::Permissions::from_mode(0o755)).unwrap();
    (tmp, gpgv)
}

fn release_check(tmp: &TempDir, gpgv: &PathBuf, json: bool) -> Output {
    let mut c = Command::new(env!("CARGO_BIN_EXE_golconda"));
    c.env("GOLCONDA_GPGV", gpgv)
        .args(["release", "check"])
        .arg(tmp.path().join("release"))
        .arg("--keys")
        .arg(tmp.path().join("keys"));
    if json {
        c.arg("--json");
    }
    c.output().unwrap()
}

#[test]
fn release_check_says_what_it_checked() {
    let (tmp, gpgv) = release_fixture(true);
    let out = stdout(&release_check(&tmp, &gpgv, false));
    assert_eq!(
        out,
        "server 20261105.1: 4 files match SHA256SUMS, signed by the release key\n"
    );
    let v: serde_json::Value =
        serde_json::from_str(&stdout(&release_check(&tmp, &gpgv, true))).unwrap();
    assert_eq!(v["version"], "20261105.1");
    assert_eq!(v["files"].as_array().unwrap().len(), 4);
    assert_eq!(v["rootHash"], "ab".repeat(32));
}

#[test]
fn release_check_refuses_a_signature_the_release_key_did_not_make() {
    let (tmp, gpgv) = release_fixture(false);
    let o = release_check(&tmp, &gpgv, false);
    assert_eq!(o.status.code(), Some(1));
    let e = String::from_utf8_lossy(&o.stderr);
    assert!(
        e.contains("not a signature by the release key") && e.contains("BAD signature"),
        "{e}"
    );
}

fn golconda_in(tmp: &TempDir, gpgv: &PathBuf, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_golconda"))
        .env("GOLCONDA_GPGV", gpgv)
        .current_dir(tmp.path())
        .args(args)
        .output()
        .unwrap()
}

fn git_in(dir: &Path, args: &[&str]) {
    let ok = Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .status()
        .unwrap()
        .success();
    assert!(ok, "git {args:?}");
}

#[test]
fn release_publish_and_list_through_rclone() {
    let (tmp, gpgv) = release_fixture(true);
    let repo = tmp.path().join("repo");
    fs::create_dir_all(&repo).unwrap();
    git_in(&repo, &["init", "-q", "-b", "main"]);
    git_in(&repo, &["commit", "-q", "--allow-empty", "-m", "start"]);
    let publish = [
        "release", "publish", "release", "--to", "www", "--keys", "keys", "--repo", "repo",
    ];
    let o = golconda_in(&tmp, &gpgv, &publish);
    assert_eq!(o.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&o.stderr).contains("no release commit for server 20261105.1"));
    let mut unrecorded = publish.to_vec();
    unrecorded.push("--unrecorded");
    assert_eq!(
        stdout(&golconda_in(&tmp, &gpgv, &unrecorded)),
        "server 20261105.1 published to www, unrecorded\n"
    );
    let list = ["release", "list", "--to", "www", "--repo", "repo"];
    assert_eq!(
        stdout(&golconda_in(&tmp, &gpgv, &list)),
        "www serves server 20261105.1: no release commit here\n"
    );
    // the release commit build makes: the trailers name the digests in the directory's index
    let index = fs::read_to_string(tmp.path().join("release/SHA256SUMS")).unwrap();
    let mut trailers = vec![
        "Release-Image: server".to_string(),
        "Release-Version: 20261105.1".to_string(),
        format!("Config: sha256:{}", "c".repeat(64)),
    ];
    for (key, line) in ["Usr", "Verity", "Signature", "Uki"]
        .iter()
        .zip(index.lines())
    {
        trailers.push(format!(
            "{key}: sha256:{}",
            line.split_once("  ").unwrap().0
        ));
    }
    trailers.push("Store-Path: /nix/store/x".to_string());
    let trailers = trailers.join("\n");
    git_in(
        &repo,
        &[
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            &format!("release: server 20261105.1\n\n{trailers}"),
        ],
    );
    let listed = stdout(&golconda_in(&tmp, &gpgv, &list));
    assert!(
        listed.starts_with("server 20261105.1  ") && listed.ends_with("  served\n"),
        "{listed}"
    );
    assert_eq!(
        stdout(&golconda_in(&tmp, &gpgv, &publish)),
        "www serves server 20261105.1 already: nothing to upload\n"
    );
}
