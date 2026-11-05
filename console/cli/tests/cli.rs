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
    assert!(
        out.contains("declared  modules/services/sshd/default.nix:52\n"),
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
    assert!(String::from_utf8_lossy(&o.stderr).contains("usage:"));
}

#[test]
fn version_and_help() {
    let v = stdout(&golconda(&["--version"]));
    assert_eq!(v, format!("golconda {}\n", env!("CARGO_PKG_VERSION")));
    assert!(stdout(&golconda(&["--help"])).starts_with("usage:"));
}
