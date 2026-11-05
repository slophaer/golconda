//! The `golconda` binary against the checkout's own `examples/server.toml`, through iets.
//!
//! They need `iets` on PATH (or `GOLCONDA_IETS`) and the Golconda checkout around this crate,
//! which a package build does not have, so they are ignored there:
//! `cargo test -- --include-ignored` runs them (console/README.md).

use std::path::PathBuf;
use std::process::{Command, Output};

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
    let module = std::fs::read_to_string(checkout().join("modules/services/sshd/default.nix"))
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
    assert!(stdout(&golconda(&["--help"])).contains("Usage: golconda <COMMAND>"));
}

/// `golconda vars` with stand-ins for age and ssh (GOLCONDA_AGE, GOLCONDA_SSH): the wiring of
/// set, push and list. The logic is tested in golconda-core (vars.rs).
#[test]
fn vars_set_push_list() {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("golconda-cli-vars-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
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
            .current_dir(&dir)
            .env("GOLCONDA_AGE", &age)
            .env("GOLCONDA_SSH", &ssh)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
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
    let _ = fs::remove_dir_all(&dir);
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
    let rel = format!("console/target/cli-tests/{test}-{}", std::process::id());
    let dir = checkout().join(&rel);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::copy(checkout().join(doc), dir.join("server.toml")).unwrap();
    format!("{rel}/server.toml")
}

fn read(rel: &str) -> String {
    std::fs::read_to_string(checkout().join(rel)).unwrap()
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
    assert_eq!(std::fs::read_dir(dir).unwrap().count(), 1);
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
    std::fs::write(checkout().join(&f), text).unwrap();
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
    let left: Vec<_> = std::fs::read_dir(checkout().join("examples"))
        .unwrap()
        .filter_map(|e| e.ok())
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
    use std::os::unix::fs::PermissionsExt;
    let f = scratch("mode", DOC);
    let path = checkout().join(&f);
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
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
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // a link to the document stays a link, and the document changes
    let link = path.with_file_name("link.toml");
    std::os::unix::fs::symlink("server.toml", &link).unwrap();
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
        std::fs::symlink_metadata(&link)
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
    // a negative number is a value, not a flag
    stdout(&golconda(&[
        "config",
        "set",
        "-f",
        &f,
        "/services/sshd",
        "port",
        "-1",
    ]));
    assert!(read(&f).contains("\nport = -1\n"));
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
