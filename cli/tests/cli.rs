//! The `golconda` binary: `vars` against stand-ins for age and ssh, `release` against a release
//! directory in a scratch directory with a stand-in for gpgv, and rclone and git as they are.
//! `release build` needs a Golconda checkout and nix-build, so its pieces are unit tests
//! (src/release.rs).

use ring::digest;
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
