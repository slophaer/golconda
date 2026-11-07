//! The `golconda` binary against the checkout's own `examples/server.toml`, through iets.
//!
//! They need `iets` on PATH (or `GOLCONDA_IETS`) and the Golconda checkout around this crate,
//! which a package build does not have, so they are ignored there:
//! `cargo test -- --include-ignored` runs them (console/README.md).

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use golconda_core::audit::{Audit, Entry};
use golconda_core::candidate::Operator;
use golconda_core::git::{Git, Person};
use golconda_core::release;
use golconda_core::vars::Program;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync;
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::{Builder, TempDir};

fn checkout() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn golconda(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_golconda"))
        .args(args)
        .current_dir(checkout())
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

const DOC: &str = "examples/server.toml";
const NET: &str = "console/cli/tests/fixtures/network.toml";

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn show_lists_every_option_and_marks_defaults() {
    let out = stdout(&golconda(&["config", "show", "-f", DOC]));
    assert!(out.contains("[\"/services/sshd\"]\n"), "{out}");
    assert!(out.contains("\nport = 22\n"), "{out}");
    assert!(
        out.contains("\nhostCertificate = false  # default\n"),
        "{out}"
    );
    // an option with neither a value nor a default
    assert!(out.contains("\n# package: no value\n"), "{out}");
    // a module the document does not name, present with its defaults
    assert!(out.contains("[\"/base\"]\n"), "{out}");
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn show_set_lists_what_the_document_sets() {
    let out = stdout(&golconda(&["config", "show", "--set", "-f", DOC]));
    assert!(out.contains("\nport = 22\n"), "{out}");
    assert!(!out.contains("# default"), "{out}");
    assert!(!out.contains("[\"/base\"]"), "{out}");
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn show_json_is_mksystem_config() {
    let out = stdout(&golconda(&["config", "show", "--json", "-f", DOC]));
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(
        v["/services/sshd"]["port"],
        serde_json::json!({ "explicit": true, "value": 22 })
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn explain_says_what_an_option_is_and_where_it_is_set() {
    let out = stdout(&golconda(&[
        "config",
        "explain",
        "-f",
        DOC,
        "/services/sshd",
        "port",
    ]));
    assert!(out.starts_with("/services/sshd port\n"), "{out}");
    assert!(out.contains("Listening port."), "{out}");
    assert!(out.contains("type      integer\n"), "{out}");
    assert!(
        out.contains("value     22  (set at examples/server.toml:11)\n"),
        "{out}"
    );
    assert!(out.contains("default   22\n"), "{out}");
    // the line of `port = {` in the module, found rather than written down
    let module = fs::read_to_string(checkout().join("modules/services/sshd/default.nix"))
        .expect("the sshd module");
    let line = module
        .lines()
        .position(|l| l == "    port = {")
        .expect("a port option")
        + 1;
    assert!(
        out.contains(&format!(
            "declared  modules/services/sshd/default.nix:{line}\n"
        )),
        "{out}"
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn explain_a_nested_option_through_a_map_and_definitions() {
    let explain = |option: &str| {
        let out = stdout(&golconda(&[
            "config", "explain", "--json", "-f", NET, "/network", option,
        ]));
        serde_json::from_str::<serde_json::Value>(&out).unwrap()
    };
    let lan = explain("networks.lan");
    assert_eq!(lan["type"], "network");
    assert_eq!(lan["explicit"], true);
    assert_eq!(lan["value"]["match"]["Name"], "en*");
    let dns = explain("networks.lan.network.DNS");
    assert_eq!(dns["module"], "/network");
    assert_eq!(dns["option"], "networks.lan.network.DNS");
    assert_eq!(dns["value"], serde_json::json!(["192.0.2.53"]));
    assert_eq!(dns["setAt"], serde_json::json!({ "file": NET, "line": 8 }));
    assert!(
        dns["description"]
            .as_str()
            .unwrap()
            .starts_with("One section of a .network file")
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn explain_an_unknown_option_fails_and_names_it() {
    let o = golconda(&["config", "explain", "-f", DOC, "/services/sshd", "prot"]);
    assert_eq!(o.status.code(), Some(1));
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(err.contains("/services/sshd has no option prot"), "{err}");
}

#[test]
fn usage_errors_exit_2() {
    let o = golconda(&["config", "frobnicate"]);
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).contains("Usage: golconda config"));
}

#[test]
fn version_and_help() {
    let v = stdout(&golconda(&["--version"]));
    assert_eq!(v, format!("golconda {}\n", env!("CARGO_PKG_VERSION")));
    assert!(stdout(&golconda(&["--help"])).contains("Usage: golconda [OPTIONS] <COMMAND>"));
}

/// `golconda vars` with stand-ins for age and ssh (GOLCONDA_AGE, GOLCONDA_SSH): the wiring of
/// set, push and list. The logic is tested in golconda-core (vars.rs).
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
/// pure), and its path relative to the checkout.
fn scratch(test: &str, doc: &str) -> String {
    let parent = checkout().join("console/target/cli-tests");
    fs::create_dir_all(&parent).unwrap();
    let dir = Builder::new()
        .prefix(&format!("{test}-"))
        .tempdir_in(&parent)
        .unwrap()
        .keep();
    fs::copy(checkout().join(doc), dir.join("server.toml")).unwrap();
    let rel = dir.strip_prefix(checkout()).unwrap();
    format!("{}/server.toml", rel.display())
}

fn read(rel: &str) -> String {
    fs::read_to_string(checkout().join(rel)).unwrap()
}

fn fails(o: &Output) -> String {
    assert_eq!(
        o.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&o.stdout)
    );
    String::from_utf8(o.stderr.clone()).unwrap()
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn set_changes_one_line_and_keeps_the_rest() {
    let f = scratch("set-port", DOC);
    let before = read(&f);
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/services/sshd",
        "port",
        "2222",
    ]));
    let after = read(&f);
    assert_eq!(after, before.replace("\nport = 22\n", "\nport = 2222\n"));
    let out = stdout(&golconda(&[
        "config",
        "explain",
        "-f",
        &f,
        "/services/sshd",
        "port",
    ]));
    assert!(
        out.contains(&format!("value     2222  (set at {f}:11)\n")),
        "{out}"
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn set_adds_a_module_and_options_inside_it() {
    let f = scratch("set-network", DOC);
    let before = read(&f);
    // a network needs its match section: the schema says so before anything is written
    let err = fails(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/network",
        "networks.lan.network.DNS",
        r#"["192.0.2.53"]"#,
    ]));
    assert!(
        err.contains("/network networks.lan: missing match"),
        "{err}"
    );
    assert_eq!(read(&f), before);
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/network",
        "networks.lan",
        r#"{ match = { Name = "en*" } }"#,
    ]));
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/network",
        "networks.lan.network.DNS",
        r#"["192.0.2.53"]"#,
    ]));
    let after = read(&f);
    assert!(after.starts_with(&before), "{after}");
    assert_eq!(
        &after[before.len()..],
        "\n[\"/network\"]\nnetworks.lan = { match = { Name = \"en*\" }, network = { DNS = [\"192.0.2.53\"] } }\n"
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn set_refuses_a_value_of_the_wrong_type_and_names_the_line() {
    let f = scratch("set-type", DOC);
    let before = read(&f);
    // a VALUE that is not TOML is a string
    let err = fails(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/services/sshd",
        "port",
        "x",
    ]));
    assert!(
        err.contains(&format!(
            "{f}:11: /services/sshd port: expected integer, got \"x\""
        )),
        "{err}"
    );
    assert_eq!(read(&f), before);
    let err = fails(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/services/sshd",
        "prot",
        "1",
    ]));
    assert!(err.contains("/services/sshd prot: no such option"), "{err}");
    assert_eq!(read(&f), before);
    // a port out of range: the schema refuses it, with its line, before any evaluation
    let err = fails(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/services/sshd",
        "port",
        "0",
    ]));
    assert!(
        err.contains(&format!("{f}:11: /services/sshd port: 0 is less than 1")),
        "{err}"
    );
    assert_eq!(read(&f), before);
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn set_refuses_what_only_evaluation_catches() {
    let f = scratch("set-eval", DOC);
    let before = read(&f);
    let err = fails(&golconda(&[
        "config", "set", "-f", &f, "golconda", "modules", "nope",
    ]));
    assert!(
        err.contains("golconda.modules names 'nope', which does not exist"),
        "{err}"
    );
    // Golconda's file by its path in the checkout
    assert!(err.contains(": lib/config.nix:"), "{err}");
    assert_eq!(read(&f), before);
    // nothing left beside the document
    let dir = checkout().join(&f).parent().unwrap().to_path_buf();
    assert_eq!(fs::read_dir(dir).unwrap().count(), 1);
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn delete_removes_an_option_and_then_says_it_is_not_set() {
    let f = scratch("delete", DOC);
    let before = read(&f);
    stdout(&golconda(&[
        "config",
        "delete",
        "-f",
        &f,
        "/services/sshd",
        "port",
    ]));
    assert_eq!(read(&f), before.replace("\nport = 22\n", "\n"));
    let err = fails(&golconda(&[
        "config",
        "delete",
        "-f",
        &f,
        "/services/sshd",
        "port",
    ]));
    assert!(
        err.contains("/services/sshd port is not set in the document"),
        "{err}"
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn validate_checks_schema_then_evaluation() {
    assert_eq!(
        stdout(&golconda(&["config", "validate", "-f", DOC])),
        format!("{DOC}: valid\n")
    );
    let f = scratch("validate", DOC);
    let text = read(&f).replace("\nport = 22\n", "\nport = \"22\"\n");
    fs::write(checkout().join(&f), text).unwrap();
    let err = fails(&golconda(&["config", "validate", "-f", &f]));
    assert!(
        err.contains(&format!("{f}:11: /services/sshd port: expected integer")),
        "{err}"
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn diff_lists_operations_between_effective_configurations() {
    let f = scratch("diff", DOC);
    let set = |args: &[&str]| {
        let mut a = vec!["config", "set", "-f", &f];
        a.extend_from_slice(args);
        stdout(&golconda(&a));
    };
    set(&["/services/sshd", "port", "2222"]);
    set(&[
        "/network",
        "networks.lan",
        r#"{ match = { Name = "en*" } }"#,
    ]);
    set(&["/factory", "timezone", "Europe/Berlin"]);
    stdout(&golconda(&[
        "config",
        "delete",
        "-f",
        &f,
        "/services/sshd",
        "authorizedKeys",
    ]));
    let out = stdout(&golconda(&["diff", "-f", &f, "--from", DOC]));
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(
        lines,
        vec![
            r#"set /factory timezone "Europe/Berlin" (was "UTC", the default)"#,
            // networks was the default: the change is the whole table, not its new key
            r#"set /network networks { lan = { match = { Name = "en*" } } } (was {}, the default)"#,
            r#"delete /services/sshd authorizedKeys (was ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample admin@example.com"]; now [], the default)"#,
            "set /services/sshd port 2222 (was 22)",
        ],
        "{out}"
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn diff_goes_down_to_the_key_that_changed() {
    let f = scratch("diff-key", NET);
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/network",
        "networks.lan.network.DNS",
        r#"["192.0.2.54"]"#,
    ]));
    let out = stdout(&golconda(&["diff", "--json", "-f", &f, "--from", NET]));
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(
        v,
        serde_json::json!([{
            "op": "set",
            "module": "/network",
            "path": ["networks", "lan", "network", "DNS"],
            "before": { "explicit": true, "value": ["192.0.2.53"] },
            "after": { "explicit": true, "value": ["192.0.2.54"] },
        }])
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn diff_against_a_git_revision() {
    // the working tree's examples/server.toml is HEAD's
    assert_eq!(stdout(&golconda(&["diff", "-f", DOC])), "");
    assert_eq!(stdout(&golconda(&["diff", "-f", DOC, "HEAD"])), "");
    let err = fails(&golconda(&["diff", "-f", DOC, "no-such-rev"]));
    assert!(err.contains("no-such-rev"), "{err}");
    // the old revision was evaluated from a copy beside the document, now gone
    let left: Vec<_> = fs::read_dir(checkout().join("examples"))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().contains(".golconda-"))
        .collect();
    assert!(left.is_empty(), "{left:?}");
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn a_key_with_a_dot_is_quoted() {
    let f = scratch("dotted", NET);
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/network",
        r#"networks."lan.1""#,
        r#"{ match = { Name = "eth1" } }"#,
    ]));
    let out = stdout(&golconda(&[
        "config",
        "explain",
        "--json",
        "-f",
        &f,
        "/network",
        r#"networks."lan.1".match"#,
    ]));
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["value"]["Name"], "eth1");
    assert_eq!(v["option"], r#"networks."lan.1".match"#);
    let out = stdout(&golconda(&["diff", "-f", &f, "--from", NET]));
    assert!(
        out.contains(r#"set /network networks."lan.1" { match = { Name = "eth1" } } (was none)"#),
        "{out}"
    );
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn an_edit_keeps_the_mode_and_a_symlink() {
    let f = scratch("mode", DOC);
    let path = checkout().join(&f);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/services/sshd",
        "port",
        "2222",
    ]));
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // a link to the document stays a link, and the document changes
    let link = path.with_file_name("link.toml");
    symlink("server.toml", &link).unwrap();
    let lf = format!("{}/link.toml", f.rsplit_once('/').unwrap().0);
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &lf,
        "/services/sshd",
        "port",
        "2200",
    ]));
    assert!(
        fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert!(read(&f).contains("\nport = 2200\n"));
}

#[test]
#[ignore = "needs iets and the Golconda checkout"]
fn values_that_start_with_a_dash() {
    let f = scratch("dash", DOC);
    // a negative number is a value, not a flag: the schema, not the parser, refuses it
    let err = fails(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/services/sshd",
        "port",
        "-1",
    ]));
    assert!(err.contains("port: -1 is less than 1"), "{err}");
    // after --, everything is an operand
    let err = fails(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "--",
        "/services/sshd",
        "port",
        "--x",
    ]));
    assert!(err.contains("expected integer"), "{err}");
}

#[test]
fn audit_verify_checks_every_entry() {
    let tmp = TempDir::new().unwrap();
    let dir = tmp.path().to_path_buf();
    let key = dir.join("key");
    assert!(
        Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "golcondad", "-f"])
            .arg(&key)
            .status()
            .unwrap()
            .success()
    );
    let public = fs::read_to_string(key.with_extension("pub")).unwrap();
    let allowed = dir.join("allowed_signers");
    fs::write(
        &allowed,
        format!("golcondad@test namespaces=\"git\" {public}"),
    )
    .unwrap();
    let git = Git {
        dir: dir.join("audit"),
        committer: Person {
            name: "golcondad".into(),
            id: "golcondad@test".into(),
        },
        signing_key: Some(key),
    };
    let audit = Audit::open(&git).unwrap();
    let alice = Operator {
        id: "alice@example.com".into(),
        name: "Alice".into(),
    };
    for action in ["signin", "config.set"] {
        audit
            .record(&Entry::new(&alice, "web", action, "ok"))
            .unwrap();
    }
    let verify = || {
        golconda(&[
            "audit",
            "verify",
            "--repo",
            git.dir.to_str().unwrap(),
            "--allowed-signers",
            allowed.to_str().unwrap(),
        ])
    };
    assert_eq!(stdout(&verify()), "2 entries, each one signed line\n");
    // relative paths, from the directory they are relative to
    let o = Command::new(env!("CARGO_BIN_EXE_golconda"))
        .args([
            "audit",
            "verify",
            "--repo",
            "audit",
            "--allowed-signers",
            "allowed_signers",
        ])
        .current_dir(&dir)
        .output()
        .unwrap();
    assert_eq!(stdout(&o), "2 entries, each one signed line\n");
    // an unsigned entry
    let unsigned = Git {
        signing_key: None,
        dir: git.dir.clone(),
        committer: git.committer.clone(),
    };
    Audit::open(&unsigned)
        .unwrap()
        .record(&Entry::new(&alice, "web", "x", "ok"))
        .unwrap();
    let err = fails(&verify());
    assert!(err.contains("signature"), "{err}");
}

/// A daemon stand-in: answers each request in turn with the given status and JSON, and keeps
/// what it was sent (request line, then body).
fn stub(answers: Vec<(u16, &'static str)>) -> (String, sync::Arc<sync::Mutex<Vec<String>>>) {
    let listener = net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let seen = sync::Arc::new(sync::Mutex::new(Vec::new()));
    let log = seen.clone();
    thread::spawn(move || {
        for (status, body) in answers {
            let (mut s, _) = listener.accept().unwrap();
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            r.read_line(&mut line).unwrap();
            let mut len = 0;
            loop {
                let mut h = String::new();
                r.read_line(&mut h).unwrap();
                if h == "\r\n" || h.is_empty() {
                    break;
                }
                if let Some(v) = h.to_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap();
                }
            }
            let mut b = vec![0; len];
            r.read_exact(&mut b).unwrap();
            log.lock().unwrap().push(format!(
                "{}{}",
                line.trim(),
                if len > 0 {
                    format!(" {}", String::from_utf8_lossy(&b))
                } else {
                    String::new()
                }
            ));
            write!(s, "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        }
    });
    (url, seen)
}

#[test]
fn with_a_server_set_is_an_operation_on_the_revision_it_reads() {
    let (url, seen) = stub(vec![
        (200, r#"{"revision":4,"ops":[]}"#),
        (
            200,
            r#"{"rev":5,"base":4,"module":"/services/sshd","path":["port"],"op":"set","value":"2222","by":{"id":"a","name":"Alice"},"via":"cli","at":"t","state":"open","commit":null}"#,
        ),
    ]);
    let out = stdout(&golconda(&[
        "--server",
        &url,
        "--name",
        "server",
        "config",
        "set",
        "/services/sshd",
        "port",
        "2222",
    ]));
    assert_eq!(out, "rev 5: set /services/sshd port 2222\n");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0], "GET /systems/server/candidate HTTP/1.1");
    let body = seen[1]
        .strip_prefix("POST /systems/server/ops HTTP/1.1 ")
        .expect("an operation posted");
    let body: serde_json::Value = serde_json::from_str(body).unwrap();
    assert_eq!(
        body,
        serde_json::json!({ "base": 4, "module": "/services/sshd", "option": "port", "op": "set", "value": "2222" })
    );
}

#[test]
fn with_a_server_a_conflict_and_problems_are_said_plainly() {
    let (url, _) = stub(vec![(
        409,
        r#"{"error":"conflict","yours":{"target":"/services/sshd port","value":2200},"theirs":[{"rev":5,"base":4,"module":"/services/sshd","path":["port"],"op":"set","value":"2222","by":{"id":"a","name":"Alice"},"via":"web","at":"2026-11-05T20:00:00Z","state":"open","commit":null}]}"#,
    )]);
    let err = fails(&golconda(&[
        "--server",
        &url,
        "--name",
        "server",
        "config",
        "set",
        "--base",
        "4",
        "/services/sshd",
        "port",
        "2200",
    ]));
    assert!(
        err.contains(
            "conflict: rev 5 set /services/sshd port 2222 by Alice at 2026-11-05T20:00:00Z"
        ),
        "{err}"
    );
    let (url, _) = stub(vec![(
        422,
        r#"{"error":"invalid","problems":[{"line":11,"path":"/services/sshd port","message":"0 is less than 1"}]}"#,
    )]);
    let err = fails(&golconda(&[
        "--server",
        &url,
        "--name",
        "server",
        "config",
        "set",
        "--base",
        "4",
        "/services/sshd",
        "port",
        "0",
    ]));
    assert!(
        err.contains("/services/sshd port: 0 is less than 1"),
        "{err}"
    );
}

#[test]
fn with_a_server_commit_discard_and_the_candidate() {
    let (url, seen) = stub(vec![
        (
            200,
            r#"{"revision":6,"ops":[{"rev":6,"base":5,"module":"/network","path":[],"op":"delete","value":null,"by":{"id":"b","name":"Bob"},"via":"web","at":"t","state":"open","commit":null}]}"#,
        ),
        (
            200,
            r#"{"commit":"abc123","pushed":false,"ops":[],"outside":[]}"#,
        ),
        (200, r#"{"discarded":[]}"#),
    ]);
    let srv = ["--server", url.as_str(), "--name", "server"];
    let run = |rest: &[&str]| golconda(&[&srv[..], rest].concat());
    assert_eq!(
        stdout(&run(&["config", "candidate"])),
        "revision 6\n  6 delete /network (Bob)\n"
    );
    assert_eq!(
        stdout(&run(&["config", "commit", "-m", "drop the network"])),
        "committed abc123, not pushed yet\n"
    );
    assert_eq!(
        stdout(&run(&["config", "discard"])),
        "discarded 0 operations\n"
    );
    let seen = seen.lock().unwrap();
    assert!(
        seen[1].starts_with("POST /systems/server/commit HTTP/1.1"),
        "{seen:?}"
    );
    assert!(
        seen[1].ends_with(r#"{"message":"drop the network"}"#),
        "{seen:?}"
    );
}

#[test]
fn candidate_commit_and_discard_need_a_server() {
    let o = golconda(&["config", "commit", "-m", "x"]);
    assert_eq!(
        o.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
}

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
        let digest = release::sha256(&dir.join(name)).unwrap();
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
    // the release commit build makes, from the directory's own index
    let r = release::check(
        &tmp.path().join("release"),
        &release::keyring(&tmp.path().join("keys")),
        &Program::from_env("GOLCONDA_TEST_UNSET", gpgv.to_str().unwrap()),
    )
    .unwrap();
    let rec = release::Record {
        commit: String::new(),
        id: "server".into(),
        version: r.index.version,
        config: format!("sha256:{}", "c".repeat(64)),
        digests: r
            .index
            .files
            .clone()
            .map(|f| format!("sha256:{}", f.digest)),
        store_path: "/nix/store/x".into(),
    };
    git_in(
        &repo,
        &[
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            &format!("release: server 20261105.1\n\n{}", rec.trailers()),
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

/// One request a routing stub saw: the request line, the Authorization header, the body.
#[derive(Clone, Debug)]
struct Seen {
    line: String,
    auth: String,
    body: String,
}

type Handler = dyn Fn(&str, &Seen) -> (u16, String) + Send + Sync;

/// A stub HTTP server that answers each request with `handler(its own URL, the request)`,
/// for as long as the test runs: daemon and provider in one.
fn routes(handler: Box<Handler>) -> (String, sync::Arc<sync::Mutex<Vec<Seen>>>) {
    let listener = net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let seen = sync::Arc::new(sync::Mutex::new(Vec::new()));
    let (log, me) = (seen.clone(), url.clone());
    thread::spawn(move || {
        for s in listener.incoming() {
            let mut s = s.unwrap();
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            r.read_line(&mut line).unwrap();
            let (mut len, mut auth) = (0, String::new());
            loop {
                let mut h = String::new();
                r.read_line(&mut h).unwrap();
                if h == "\r\n" || h.is_empty() {
                    break;
                }
                let lower = h.to_lowercase();
                if let Some(v) = lower.strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap();
                }
                if lower.starts_with("authorization:") {
                    auth = h["authorization:".len()..].trim().to_string();
                }
            }
            let mut b = vec![0; len];
            r.read_exact(&mut b).unwrap();
            let req = Seen {
                line: line.trim().to_string(),
                auth,
                body: String::from_utf8_lossy(&b).into_owned(),
            };
            let (status, body) = handler(&me, &req);
            log.lock().unwrap().push(req);
            write!(s, "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
        }
    });
    (url, seen)
}

/// An ID token as the CLI sees it: unchecked, it only reads exp (the daemon checks it).
fn jwt(name: &str, exp: i64) -> String {
    let b = |v: serde_json::Value| URL_SAFE_NO_PAD.encode(v.to_string());
    format!(
        "{}.{}.sig",
        b(serde_json::json!({ "alg": "ES256" })),
        b(serde_json::json!({ "aud": "golconda-cli", "name": name, "exp": exp }))
    )
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        .cast_signed()
}

/// A daemon with OIDC and its provider: the device flow gives `first` after one
/// authorization_pending, a refresh with r1 gives `second`, and the daemon takes either.
fn oidc_stub(first: String, second: String) -> (String, sync::Arc<sync::Mutex<Vec<Seen>>>) {
    let polls = sync::Arc::new(sync::Mutex::new(0));
    routes(Box::new(move |me, req| {
        let path = req.line.split(' ').nth(1).unwrap_or("");
        let ok = |v: serde_json::Value| (200, v.to_string());
        match path {
            "/auth/device" => ok(
                serde_json::json!({ "issuer": me, "clientId": "golconda-cli", "scope": "openid groups offline_access" }),
            ),
            "/.well-known/openid-configuration" => ok(serde_json::json!({
                "issuer": me, "device_authorization_endpoint": format!("{me}/device"),
                "token_endpoint": format!("{me}/token"),
            })),
            "/device" if req.body.contains("client_id=golconda-cli") => ok(serde_json::json!({
                "device_code": "dc1", "user_code": "WDJB-MJHT", "verification_uri": format!("{me}/verify"),
                "verification_uri_complete": format!("{me}/verify?code=WDJB-MJHT"), "interval": 0, "expires_in": 60,
            })),
            "/token" if req.body.contains("device_code=dc1") => {
                let mut n = polls.lock().unwrap();
                *n += 1;
                if *n == 1 {
                    (400, r#"{"error":"authorization_pending"}"#.into())
                } else {
                    ok(
                        serde_json::json!({ "id_token": first, "refresh_token": "r1", "token_type": "Bearer" }),
                    )
                }
            }
            "/token"
                if req.body.contains("grant_type=refresh_token")
                    && req.body.contains("refresh_token=r1") =>
            {
                ok(serde_json::json!({ "id_token": second, "refresh_token": "r2" }))
            }
            "/token" => (400, r#"{"error":"invalid_grant"}"#.into()),
            "/auth/me" | "/systems/server/candidate"
                if req.auth == format!("Bearer {first}")
                    || req.auth == format!("Bearer {second}") =>
            {
                ok(
                    serde_json::json!({ "name": "Alice", "level": "operator", "revision": 0, "ops": [] }),
                )
            }
            _ => (401, r#"{"error":"sign in first"}"#.into()),
        }
    }))
}

fn golconda_state(state: &TempDir, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_golconda"))
        .env("XDG_STATE_HOME", state.path())
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn login_signs_in_through_the_device_flow_and_keeps_the_token_private() {
    let state = TempDir::new().unwrap();
    let token = jwt("Alice", unix_now() + 3600);
    let (url, seen) = oidc_stub(token.clone(), jwt("Alice", unix_now() + 7200));
    let o = golconda_state(&state, &["--server", &url, "login"]);
    assert_eq!(
        stdout(&o),
        format!("signed in to {url} as Alice (operator)\n")
    );
    let told = String::from_utf8_lossy(&o.stderr);
    assert!(
        told.contains(&format!("Open {url}/verify?code=WDJB-MJHT")),
        "{told}"
    );
    assert!(told.contains("enter WDJB-MJHT"), "{told}");
    let file = state.path().join("golconda/tokens.json");
    let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!((mode(&file), mode(file.parent().unwrap())), (0o600, 0o700));
    // the daemon's calls carry it
    let o = golconda_state(&state, &["--server", &url, "config", "candidate"]);
    stdout(&o);
    let last = seen.lock().unwrap().last().cloned().unwrap();
    assert_eq!(last.line, "GET /systems/server/candidate HTTP/1.1");
    assert_eq!(last.auth, format!("Bearer {token}"));
    assert_eq!(
        stdout(&golconda_state(&state, &["--server", &url, "logout"])),
        format!("signed out of {url}\n")
    );
    assert_eq!(
        stdout(&golconda_state(&state, &["--server", &url, "logout"])),
        format!("not signed in to {url}\n")
    );
    let o = golconda_state(&state, &["--server", &url, "config", "candidate"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&o.stderr).contains("golconda login --server"));
}

#[test]
fn an_expired_token_is_renewed_with_the_refresh_token() {
    let state = TempDir::new().unwrap();
    let (old, fresh) = (
        jwt("Alice", unix_now() - 10),
        jwt("Alice", unix_now() + 3600),
    );
    let (url, seen) = oidc_stub(old.clone(), fresh.clone());
    stdout(&golconda_state(&state, &["--server", &url, "login"]));
    stdout(&golconda_state(
        &state,
        &["--server", &url, "config", "candidate"],
    ));
    let seen = seen.lock().unwrap();
    let refresh = seen
        .iter()
        .find(|s| s.body.contains("grant_type=refresh_token"))
        .expect("a refresh");
    assert!(refresh.body.contains("refresh_token=r1"), "{refresh:?}");
    assert_eq!(seen.last().unwrap().auth, format!("Bearer {fresh}"));
    let kept = fs::read_to_string(state.path().join("golconda/tokens.json")).unwrap();
    assert!(kept.contains(&fresh) && kept.contains("\"r2\""), "{kept}");
}

#[test]
fn a_refresh_the_provider_refuses_asks_for_login_again() {
    let state = TempDir::new().unwrap();
    let (url, _) = oidc_stub(jwt("Alice", unix_now() - 10), String::new());
    stdout(&golconda_state(&state, &["--server", &url, "login"]));
    // a refresh token the provider no longer takes
    let file = state.path().join("golconda/tokens.json");
    let text = fs::read_to_string(&file)
        .unwrap()
        .replace("\"r1\"", "\"revoked\"");
    fs::write(&file, text).unwrap();
    let o = golconda_state(&state, &["--server", &url, "config", "candidate"]);
    assert_eq!(o.status.code(), Some(1));
    let e = String::from_utf8_lossy(&o.stderr);
    assert!(
        e.contains("has expired: run golconda login --server"),
        "{e}"
    );
}

#[test]
fn login_needs_a_server() {
    let state = TempDir::new().unwrap();
    assert_eq!(golconda_state(&state, &["login"]).status.code(), Some(2));
}

#[test]
fn login_refuses_a_provider_without_https() {
    let state = TempDir::new().unwrap();
    let (url, seen) = routes(Box::new(|_, _| {
        (
            200,
            r#"{"issuer":"http://idp.example.com","clientId":"golconda-cli"}"#.into(),
        )
    }));
    let o = golconda_state(&state, &["--server", &url, "login"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&o.stderr).contains("must use https"));
    assert_eq!(
        seen.lock().unwrap().len(),
        1,
        "nothing asked of the provider"
    );
}

/// A daemon with one machine and a job 7 that runs once and then ends `end`.
fn jobs_stub(end: &'static str) -> (String, sync::Arc<sync::Mutex<Vec<Seen>>>) {
    let polls = sync::Arc::new(sync::Mutex::new(0));
    routes(Box::new(move |_, req| {
        let path = req.line.split(' ').nth(1).unwrap_or("");
        let job = |state: &str| serde_json::json!({ "id": 7, "kind": "update", "machine": "web1", "by": { "name": "Alice" }, "state": state, "summary": if state == "running" { None } else { Some("web1: 20261106.1 is installed for the next boot") } });
        let v = match path {
            "/systems/server/machines" => serde_json::json!({ "updates": "www", "machines": [
                { "name": "web1", "status": { "version": "20261105.1", "available": "20261106.1", "entries": [
                    { "version": "20261105.1", "selected": true, "default": true },
                    { "id": "auto", "selected": false } ] } },
                { "name": "web2", "error": "web2: ssh: Connection refused" } ] }),
            "/systems/server/jobs" => serde_json::json!({ "job": 7 }),
            "/jobs?system=server" => serde_json::json!([job("ok")]),
            "/jobs/7?after=0" => {
                let mut n = polls.lock().unwrap();
                *n += 1;
                if *n == 1 {
                    serde_json::json!({ "job": job("running"), "lines": [{ "n": 1, "at": "t", "line": "Selected update '20261106.1' for install." }] })
                } else {
                    serde_json::json!({ "job": job(end), "lines": [] })
                }
            }
            "/jobs/7?after=1" => {
                serde_json::json!({ "job": job(end), "lines": [{ "n": 2, "at": "t", "line": "done" }] })
            }
            _ => return (404, r#"{"error":"no"}"#.into()),
        };
        (200, v.to_string())
    }))
}

#[test]
fn machines_and_jobs_through_a_daemon() {
    let state = TempDir::new().unwrap();
    let (url, seen) = jobs_stub("ok");
    let out = stdout(&golconda_state(&state, &["--server", &url, "machines"]));
    assert_eq!(
        out,
        "web1  20261105.1  slots: 20261105.1 (booted)  20261106.1 available\nweb2  unreachable: web2: ssh: Connection refused\n"
    );
    let o = golconda_state(
        &state,
        &["--server", &url, "job", "start", "update", "web1", "--wait"],
    );
    assert_eq!(
        stdout(&o),
        "Selected update '20261106.1' for install.\ndone\n"
    );
    let posted = seen
        .lock()
        .unwrap()
        .iter()
        .find(|s| s.line.starts_with("POST"))
        .cloned()
        .unwrap();
    let body: serde_json::Value = serde_json::from_str(&posted.body).unwrap();
    assert_eq!(
        body,
        serde_json::json!({ "kind": "update", "machine": "web1" })
    );
    let list = stdout(&golconda_state(&state, &["--server", &url, "job", "list"]));
    assert_eq!(
        list,
        "7  update  web1  Alice  ok  web1: 20261106.1 is installed for the next boot\n"
    );
}

#[test]
fn a_failed_job_makes_wait_exit_1() {
    let state = TempDir::new().unwrap();
    let (url, _) = jobs_stub("failed");
    let o = golconda_state(
        &state,
        &["--server", &url, "job", "start", "update", "web1", "--wait"],
    );
    assert_eq!(o.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&o.stderr).contains("job 7 failed"));
}

#[test]
#[ignore = "needs iets and the checkout"]
fn packages_lists_the_sbom_with_what_the_image_names_itself() {
    let out = stdout(&golconda(&["packages", "-f", "examples/server.toml"]));
    let systemd = out
        .lines()
        .find(|l| l.starts_with("systemd  "))
        .expect(&out);
    assert!(systemd.ends_with("golconda  in the image"), "{systemd}");
    let acl = out.lines().find(|l| l.starts_with("acl  ")).expect(&out);
    assert!(acl.ends_with("repkgs"), "{acl}");
    let bom: serde_json::Value = serde_json::from_str(&stdout(&golconda(&[
        "packages",
        "-f",
        "examples/server.toml",
        "--sbom",
    ])))
    .unwrap();
    assert_eq!(bom["bomFormat"], "CycloneDX");
}

/// A checkout with a made-up SBOM (a stand-in for iets) of three packages, one of them
/// vulnerable at the OSV stub; `golconda packages` run in it with a cache of its own.
struct Image {
    tmp: TempDir,
}

impl Image {
    fn new() -> Image {
        let tmp = TempDir::new().unwrap();
        let t = tmp.path();
        fs::create_dir_all(t.join("lib")).unwrap();
        fs::write(t.join("lib/system.nix"), "{ }").unwrap();
        fs::write(t.join("server.toml"), "").unwrap();
        let sbom = r#"{"roots":["systemd"],"bom":{"components":[
            {"name":"acl","version":"2.4.0","purl":"pkg:generic/acl@2.4.0"},
            {"name":"openssl","version":"3.0.1","purl":"pkg:generic/openssl@3.0.1"},
            {"name":"systemd","version":"262.1"}]}}"#;
        fs::write(t.join("sbom.json"), sbom).unwrap();
        let iets = t.join("iets");
        fs::write(&iets, "#!/bin/sh\ncat \"$(dirname \"$0\")/sbom.json\"\n").unwrap();
        fs::set_permissions(&iets, fs::Permissions::from_mode(0o755)).unwrap();
        Image { tmp }
    }

    fn packages(&self, args: &[&str]) -> Output {
        let t = self.tmp.path();
        Command::new(env!("CARGO_BIN_EXE_golconda"))
            .args(["packages", "-f"])
            .arg(t.join("server.toml"))
            .args(args)
            .env("GOLCONDA_IETS", t.join("iets"))
            .env("XDG_CACHE_HOME", t.join("cache"))
            .output()
            .unwrap()
    }
}

fn osv_with_one_vulnerability() -> (String, sync::Arc<sync::Mutex<Vec<Seen>>>) {
    routes(Box::new(|_, req| {
        if req.line.contains("/v1/querybatch") {
            let q: serde_json::Value = serde_json::from_str(&req.body).unwrap();
            let results: Vec<serde_json::Value> = q["queries"]
                .as_array()
                .unwrap()
                .iter()
                .map(|q| {
                    if q["package"]["purl"].as_str().unwrap().contains("openssl") {
                        serde_json::json!({ "vulns": [{ "id": "CVE-2022-0778" }] })
                    } else {
                        serde_json::json!({})
                    }
                })
                .collect();
            (200, serde_json::json!({ "results": results }).to_string())
        } else {
            (
                200,
                r#"{"id":"CVE-2022-0778","summary":"Infinite loop in BN_mod_sqrt()","database_specific":{"severity":"HIGH"}}"#
                    .into(),
            )
        }
    }))
}

#[test]
fn packages_with_advisories_lists_the_vulnerable_first_and_asks_once() {
    let image = Image::new();
    let (osv, seen) = osv_with_one_vulnerability();
    let out = stdout(&image.packages(&["--advisories", "--osv-url", &osv]));
    let lines: Vec<&str> = out.lines().collect();
    assert!(lines[0].starts_with("openssl  3.0.1"), "{out}");
    assert_eq!(
        lines[1].trim(),
        "CVE-2022-0778  HIGH  Infinite loop in BN_mod_sqrt()",
        "{out}"
    );
    assert!(lines[2].starts_with("systemd  262.1"), "{out}");
    assert!(lines[3].starts_with("acl  2.4.0"), "{out}");
    assert!(out.contains("checked just now"), "{out}");
    // the next run, a process later, reads the cache
    let n = seen.lock().unwrap().len();
    assert_eq!(n, 2);
    let again = stdout(&image.packages(&["--advisories", "--osv-url", &osv]));
    assert_eq!(seen.lock().unwrap().len(), n);
    assert_eq!(again, out);
    // without the flag nothing is asked and the list is as before
    let plain = stdout(&image.packages(&[]));
    assert!(plain.starts_with("acl  2.4.0"), "{plain}");
    assert!(!plain.contains("CVE-"), "{plain}");
    assert_eq!(seen.lock().unwrap().len(), n);
}

#[test]
fn packages_with_advisories_still_lists_when_osv_cannot_be_reached() {
    let image = Image::new();
    let o = image.packages(&["--advisories", "--osv-url", "http://127.0.0.1:1"]);
    let out = stdout(&o);
    assert!(out.starts_with("systemd  262.1"), "{out}");
    assert!(out.contains("could not check"), "{out}");
    assert!(!String::from_utf8_lossy(&o.stderr).contains("panicked"));
}

#[test]
fn lock_unlock_and_a_lock_that_refuses() {
    let (url, seen) = stub(vec![
        (
            200,
            r#"{"lock":{"by":{"name":"Alice"},"until":"2026-11-07T12:30:00Z"}}"#,
        ),
        (
            423,
            r#"{"error":"locked","lock":{"by":{"name":"Bob"},"until":"2026-11-07T13:00:00Z"}}"#,
        ),
        (200, r#"{"broken":{"by":{"name":"Bob"}}}"#),
    ]);
    let s = |args: &[&str]| {
        let mut a = vec!["--server", url.as_str(), "config"];
        a.extend(args);
        golconda(&a)
    };
    assert_eq!(
        stdout(&s(&["lock", "--minutes", "90"])),
        "locked until 2026-11-07T12:30:00Z\n"
    );
    let o = s(&["unlock"]);
    assert_eq!(o.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&o.stderr)
            .contains("Bob holds the lock on this system until 2026-11-07T13:00:00Z")
    );
    assert_eq!(
        stdout(&s(&["break-lock", "--reason", "Bob left"])),
        "broke Bob's lock\n"
    );
    let seen = seen.lock().unwrap();
    assert_eq!(
        seen[0],
        r#"POST /systems/server/lock HTTP/1.1 {"minutes":90}"#
    );
    assert_eq!(
        seen[2],
        r#"POST /systems/server/lock/break HTTP/1.1 {"reason":"Bob left"}"#
    );
    // without a daemon there is no lock
    assert_eq!(golconda(&["config", "lock"]).status.code(), Some(2));
}
