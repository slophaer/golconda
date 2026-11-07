//! The write routes on a scratch clone of this checkout, with a bare remote, a state
//! directory and a signing key of their own: operations, conflicts, refusals, commit, discard,
//! and the audit entry of each. Evaluation needs iets and the checkout, so most are ignored
//! in the package build.

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode, header};
use golconda_core::audit::Entry;
use golconda_core::candidate::Operator;
use golconda_core::git::Person;
use golcondad::app::{App, Identity, Level, Signin, router};
use golcondad::write::Writes;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;
use tempfile::TempDir;
use tower::ServiceExt;

struct Scene {
    _tmp: TempDir,
    dir: PathBuf,
    work: PathBuf,
    state: PathBuf,
    key: PathBuf,
    allowed: PathBuf,
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// A clone of this checkout at its HEAD, on branch main, with a bare remote as origin.
fn scene() -> Scene {
    let checkout = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let head = git(&checkout, &["rev-parse", "HEAD"]);
    let tmp = TempDir::new().unwrap();
    let dir = tmp.path().to_path_buf();
    git(
        &dir,
        &[
            "clone",
            "-q",
            "--shared",
            "--no-checkout",
            checkout.to_str().unwrap(),
            "work",
        ],
    );
    let work = dir.join("work");
    git(&work, &["checkout", "-q", "-b", "main", &head]);
    git(&dir, &["clone", "-q", "--bare", "work", "remote.git"]);
    git(
        &work,
        &[
            "remote",
            "set-url",
            "origin",
            dir.join("remote.git").to_str().unwrap(),
        ],
    );
    git(&work, &["fetch", "-q", "origin"]);
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
    Scene {
        _tmp: tmp,
        state: dir.join("state"),
        work,
        key,
        allowed,
        dir,
    }
}

/// A scene with no Golconda checkout: a repository holding just the document, for what
/// needs no evaluation (refusals, forms, the audit log), so it runs in the package build.
fn small_scene() -> Scene {
    let tmp = TempDir::new().unwrap();
    let dir = tmp.path().to_path_buf();
    let work = dir.join("work");
    fs::create_dir_all(work.join("examples")).unwrap();
    fs::write(
        work.join("examples/server.toml"),
        "[\"/system\"]\nname = \"s\"\n",
    )
    .unwrap();
    git(&work, &["init", "-q", "-b", "main"]);
    git(&work, &["add", "."]);
    git(
        &work,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@x",
            "commit",
            "-qm",
            "seed",
        ],
    );
    let key = dir.join("key");
    assert!(
        Command::new("ssh-keygen")
            .args(["-q", "-t", "ed25519", "-N", "", "-C", "golcondad", "-f"])
            .arg(&key)
            .status()
            .unwrap()
            .success()
    );
    Scene {
        _tmp: tmp,
        state: dir.join("state"),
        work,
        key,
        allowed: dir.join("allowed_signers"),
        dir,
    }
}

fn app(s: &Scene, level: Level) -> axum::Router {
    app_and_token(s, level).0
}

/// The daemon, and the CSRF token its development identity's forms carry.
fn app_and_token(s: &Scene, level: Level) -> (axum::Router, String) {
    let committer = Person {
        name: "golcondad".into(),
        id: "golcondad@test".into(),
    };
    let writes = Writes::open(
        &s.state,
        committer,
        Some(s.key.clone()),
        Some("origin".into()),
        None,
    )
    .unwrap();
    let who = Identity {
        id: "alice@example.com".into(),
        name: "Alice".into(),
        level,
    };
    let doc = s.work.join("examples/server.toml");
    let app = App::new(vec![("server".into(), doc)], Signin::Dev(who), false).with_writes(writes);
    let token = app.csrf.clone();
    (router(app), token)
}

async fn post(app: &axum::Router, path: &str, body: Value) -> (StatusCode, Value) {
    let req = Request::post(path)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::ACCEPT, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let b = to_bytes(res.into_body(), 1 << 22).await.unwrap();
    (status, serde_json::from_slice(&b).unwrap_or(Value::Null))
}

async fn get(app: &axum::Router, path: &str) -> Value {
    let req = Request::get(path)
        .header(header::ACCEPT, "application/json")
        .body(Body::empty())
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    serde_json::from_slice(&to_bytes(res.into_body(), 1 << 22).await.unwrap()).unwrap()
}

/// The audit log's entries, oldest first.
fn audit(s: &Scene) -> Vec<Value> {
    let mut files: Vec<PathBuf> = Vec::new();
    let mut stack = vec![s.state.join("audit")];
    while let Some(d) = stack.pop() {
        for e in fs::read_dir(d).unwrap().flatten() {
            let p = e.path();
            if p.file_name().is_some_and(|n| n == ".git") {
                continue;
            }
            if p.is_dir() {
                stack.push(p);
            } else {
                files.push(p);
            }
        }
    }
    files.sort();
    files
        .iter()
        .flat_map(|f| {
            fs::read_to_string(f)
                .unwrap()
                .lines()
                .map(|l| serde_json::from_str(l).unwrap())
                .collect::<Vec<Value>>()
        })
        .collect()
}

fn set(base: u64, option: &str, value: &str) -> Value {
    json!({ "base": base, "module": "/services/sshd", "option": option, "op": "set", "value": value })
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn an_operation_changes_the_candidate_and_is_audited() {
    let s = scene();
    let a = app(&s, Level::Operator);
    let (st, op) = post(&a, "/systems/server/ops", set(0, "port", "2222")).await;
    assert_eq!(st, StatusCode::OK, "{op}");
    assert_eq!(op["rev"], 1);
    let c = get(&a, "/systems/server/candidate").await;
    assert_eq!(c["revision"], 1);
    assert_eq!(c["ops"][0]["value"], "2222");
    // the document itself changes only at commit
    let doc = fs::read_to_string(s.work.join("examples/server.toml")).unwrap();
    assert!(doc.contains("\nport = 22\n"), "{doc}");
    let e = audit(&s);
    assert_eq!(e.len(), 1);
    assert_eq!(e[0]["action"], "config.set");
    assert_eq!(
        (&e[0]["before"], &e[0]["after"], &e[0]["rev"]),
        (&json!(22), &json!(2222), &json!(1))
    );
    assert_eq!(
        e[0]["operator"],
        json!({ "id": "alice@example.com", "name": "Alice", "via": "cli" })
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn a_conflict_and_a_problem_are_refused_and_audited() {
    let s = scene();
    let a = app(&s, Level::Operator);
    post(&a, "/systems/server/ops", set(0, "port", "2222")).await;
    let (st, v) = post(&a, "/systems/server/ops", set(0, "port", "2200")).await;
    assert_eq!(st, StatusCode::CONFLICT, "{v}");
    assert_eq!(v["theirs"][0]["by"]["name"], "Alice");
    assert_eq!(v["yours"]["value"], 2200);
    let (st, v) = post(&a, "/systems/server/ops", set(1, "port", "0")).await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY, "{v}");
    assert_eq!(v["problems"][0]["message"], "0 is less than 1");
    let results: Vec<String> = audit(&s)
        .iter()
        .map(|e| e["result"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(results, ["ok", "refused", "refused"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reader_may_not_write_and_that_is_audited_too() {
    let s = small_scene();
    let a = app(&s, Level::ReadOnly);
    let (st, v) = post(&a, "/systems/server/ops", set(0, "port", "2222")).await;
    assert_eq!(st, StatusCode::FORBIDDEN, "{v}");
    let (st, _) = post(&a, "/systems/server/commit", json!({ "message": "x" })).await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    let e = audit(&s);
    assert_eq!(
        e.iter()
            .map(|e| (e["action"].as_str().unwrap(), e["result"].as_str().unwrap()))
            .collect::<Vec<_>>(),
        [("config.set", "denied"), ("config.commit", "denied")]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_daemon_without_state_only_reads() {
    let who = Identity {
        id: "dev:a".into(),
        name: "a".into(),
        level: Level::Operator,
    };
    let a = router(App::new(
        vec![("server".into(), PathBuf::from("x.toml"))],
        Signin::Dev(who),
        false,
    ));
    let (st, v) = post(&a, "/systems/server/ops", set(0, "port", "1")).await;
    assert_eq!(st, StatusCode::SERVICE_UNAVAILABLE, "{v}");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn commit_writes_signs_pushes_and_names_the_commit_in_the_audit_log() {
    let s = scene();
    let a = app(&s, Level::Operator);
    post(&a, "/systems/server/ops", set(0, "port", "2222")).await;
    let (st, c) = post(
        &a,
        "/systems/server/commit",
        json!({ "message": "sshd on 2222" }),
    )
    .await;
    assert_eq!(st, StatusCode::OK, "{c}");
    assert_eq!(c["pushed"], true);
    let id = c["commit"].as_str().unwrap();
    let doc = fs::read_to_string(s.work.join("examples/server.toml")).unwrap();
    assert!(doc.contains("\nport = 2222\n"), "{doc}");
    assert_eq!(git(&s.dir.join("remote.git"), &["rev-parse", "main"]), id);
    let allowed = format!("gpg.ssh.allowedSignersFile={}", s.allowed.display());
    git(&s.work, &["-c", &allowed, "verify-commit", id]);
    let last = audit(&s).pop().unwrap();
    assert_eq!(
        (&last["action"], &last["configCommit"]),
        (&json!("config.commit"), &json!(id))
    );
    assert_eq!(get(&a, "/systems/server/candidate").await["ops"], json!([]));
    // and the audit log checks
    let audit_git = golconda_core::git::Git {
        dir: s.state.join("audit"),
        committer: Person {
            name: "x".into(),
            id: "x".into(),
        },
        signing_key: None,
    };
    assert_eq!(
        golconda_core::audit::Audit { git: &audit_git }
            .verify(&s.allowed)
            .unwrap(),
        2
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn discard_drops_the_open_operations() {
    let s = scene();
    let a = app(&s, Level::Operator);
    post(&a, "/systems/server/ops", set(0, "port", "2222")).await;
    let (st, v) = post(&a, "/systems/server/discard", json!({})).await;
    assert_eq!(st, StatusCode::OK, "{v}");
    assert_eq!(v["discarded"].as_array().unwrap().len(), 1);
    assert_eq!(get(&a, "/systems/server/candidate").await["ops"], json!([]));
    assert_eq!(audit(&s).pop().unwrap()["action"], "config.discard");
    let (st, _) = post(&a, "/systems/server/discard", json!({})).await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
}

/// A browser's form POST: urlencoded fields, from this daemon's page (Origin = Host).
async fn form(
    app: &axum::Router,
    path: &str,
    fields: &[(&str, &str)],
    origin: &str,
) -> (StatusCode, Option<String>, String) {
    let body = serde_urlencoded::to_string(fields).unwrap();
    let req = Request::post(path)
        .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
        .header(header::HOST, "127.0.0.1:8796")
        .header(header::ORIGIN, origin)
        .body(Body::from(body))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let location = res
        .headers()
        .get(header::LOCATION)
        .map(|l| l.to_str().unwrap().to_string());
    let b = to_bytes(res.into_body(), 1 << 22).await.unwrap();
    (status, location, String::from_utf8_lossy(&b).into_owned())
}

const HERE: &str = "http://127.0.0.1:8796";
const BACK: &str = "/systems/server/config/services/sshd?option=port";

fn port_form<'a>(token: &'a str, base: &'a str, value: &'a str) -> Vec<(&'a str, &'a str)> {
    vec![
        ("csrf", token),
        ("base", base),
        ("module", "/services/sshd"),
        ("option", "port"),
        ("op", "set"),
        ("kind", "toml"),
        ("value", value),
        ("return", BACK),
    ]
}

#[tokio::test(flavor = "multi_thread")]
async fn a_form_needs_this_sessions_token_and_this_origin() {
    let s = small_scene();
    let (a, token) = app_and_token(&s, Level::Operator);
    let (st, _, body) = form(
        &a,
        "/systems/server/ops",
        &port_form("forged", "0", "2222"),
        HERE,
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN, "{body}");
    assert!(body.contains("not from this console"), "{body}");
    // the right token, from a page elsewhere
    let (st, _, _) = form(
        &a,
        "/systems/server/ops",
        &port_form(&token, "0", "2222"),
        "https://evil.example",
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    let (st, _, _) = form(
        &a,
        "/systems/server/commit",
        &[("csrf", "forged"), ("message", "x")],
        HERE,
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    let (st, _, _) = form(&a, "/systems/server/discard", &[("csrf", "")], HERE).await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    // nothing reached the journal
    assert_eq!(audit(&s), Vec::<Value>::new());
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn a_form_saves_to_the_candidate_and_goes_back_and_a_conflict_offers_three_ways() {
    let s = scene();
    let (a, token) = app_and_token(&s, Level::Operator);
    let (st, location, body) = form(
        &a,
        "/systems/server/ops",
        &port_form(&token, "0", "2222"),
        HERE,
    )
    .await;
    assert_eq!(st, StatusCode::SEE_OTHER, "{body}");
    assert_eq!(location.as_deref(), Some(BACK));
    assert_eq!(audit(&s)[0]["operator"]["via"], "web");
    // a string control's text is quoted for TOML
    let fields = [
        ("csrf", token.as_str()),
        ("base", "1"),
        ("module", "/factory"),
        ("option", "timezone"),
        ("op", "set"),
        ("kind", "string"),
        ("value", "Europe/Berlin"),
        ("return", "/"),
    ];
    let (st, _, body) = form(&a, "/systems/server/ops", &fields, HERE).await;
    assert_eq!(st, StatusCode::SEE_OTHER, "{body}");
    assert_eq!(
        get(&a, "/systems/server/candidate").await["ops"][1]["value"],
        "\"Europe/Berlin\""
    );
    // a list control: one key per line becomes a TOML array
    let keys = "ssh-ed25519 AAAA a@x\nssh-ed25519 BBBB b@x\n";
    let fields = [
        ("csrf", token.as_str()),
        ("base", "2"),
        ("module", "/services/sshd"),
        ("option", "authorizedKeys"),
        ("op", "set"),
        ("kind", "lines"),
        ("value", keys),
        ("return", "/"),
    ];
    let (st, _, body) = form(&a, "/systems/server/ops", &fields, HERE).await;
    assert_eq!(st, StatusCode::SEE_OTHER, "{body}");
    let ops = get(&a, "/systems/server/candidate").await;
    assert_eq!(
        ops["ops"][2]["value"],
        r#"["ssh-ed25519 AAAA a@x", "ssh-ed25519 BBBB b@x"]"#
    );
    // the same option from a page of revision 0: the conflict page
    let (st, _, page) = form(
        &a,
        "/systems/server/ops",
        &port_form(&token, "0", "2200"),
        HERE,
    )
    .await;
    assert_eq!(st, StatusCode::CONFLICT);
    assert!(
        page.contains("Apply mine on top") && page.contains(r#"name="base" value="3""#),
        "{page}"
    );
    // the page shows the form, with this revision and the amber row
    let req = Request::get(BACK).body(Body::empty()).unwrap();
    let res = a.clone().oneshot(req).await.unwrap();
    let page =
        String::from_utf8_lossy(&to_bytes(res.into_body(), 1 << 22).await.unwrap()).into_owned();
    assert!(
        page.contains(&format!(r#"name="csrf" value="{token}""#)),
        "{page}"
    );
    assert!(page.contains(r#"<span class="v chg">2222"#), "{page}");
    // a value the schema refuses: a page with the problem and the way back
    let (st, _, page) = form(
        &a,
        "/systems/server/ops",
        &port_form(&token, "3", "0"),
        HERE,
    )
    .await;
    assert_eq!(st, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        page.contains("0 is less than 1") && page.contains("Back to the form"),
        "{page}"
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn someone_who_may_only_read_gets_no_form() {
    let s = scene();
    let a = app(&s, Level::ReadOnly);
    let res = a
        .oneshot(Request::get(BACK).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let page =
        String::from_utf8_lossy(&to_bytes(res.into_body(), 1 << 22).await.unwrap()).into_owned();
    assert!(page.contains("Listening port."), "{page}");
    assert!(!page.contains("<form"), "{page}");
}

async fn page(app: &axum::Router, path: &str) -> String {
    let res = app
        .clone()
        .oneshot(Request::get(path).body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "{path}");
    String::from_utf8_lossy(&to_bytes(res.into_body(), 1 << 22).await.unwrap()).into_owned()
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn the_changes_page_shows_the_candidate_and_commits_it() {
    let s = scene();
    let (a, token) = app_and_token(&s, Level::Operator);
    let (st, _, body) = form(
        &a,
        "/systems/server/ops",
        &port_form(&token, "0", "2222"),
        HERE,
    )
    .await;
    assert_eq!(st, StatusCode::SEE_OTHER, "{body}");
    let p = page(&a, "/systems/server/changes").await;
    assert!(p.contains("set /services/sshd port 2222"), "{p}");
    assert!(p.contains(r#"<span class="del">- port = 22</span>"#), "{p}");
    assert!(
        p.contains(r#"<span class="add">+ port = 2222</span>"#),
        "{p}"
    );
    // the rail counts the open operations
    assert!(p.contains("Changes<small>1</small>"), "{p}");
    let fields = [
        ("csrf", token.as_str()),
        ("message", "sshd on 2222"),
        ("return", "/systems/server/changes"),
    ];
    let (st, location, body) = form(&a, "/systems/server/commit", &fields, HERE).await;
    assert_eq!(st, StatusCode::SEE_OTHER, "{body}");
    assert_eq!(location.as_deref(), Some("/systems/server/changes"));
    let doc = fs::read_to_string(s.work.join("examples/server.toml")).unwrap();
    assert!(doc.contains("\nport = 2222\n"), "{doc}");
    assert_eq!(
        git(
            &s.dir.join("remote.git"),
            &["log", "-1", "--format=%s", "main"]
        ),
        "sshd on 2222"
    );
    let p = page(&a, "/systems/server/changes").await;
    assert!(
        p.contains("No changes in the candidate.") && !p.contains("Changes<small>"),
        "{p}"
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn an_audit_log_that_is_not_pushed_says_so_on_every_page() {
    let s = scene();
    let committer = Person {
        name: "golcondad".into(),
        id: "golcondad@test".into(),
    };
    // an audit remote that does not exist: every push fails
    let writes = Writes::open(
        &s.state,
        committer,
        Some(s.key.clone()),
        None,
        Some("nowhere".into()),
    )
    .unwrap();
    let who = Identity {
        id: "alice@example.com".into(),
        name: "Alice".into(),
        level: Level::Operator,
    };
    let app = App::new(
        vec![("server".into(), s.work.join("examples/server.toml"))],
        Signin::Dev(who),
        false,
    )
    .with_writes(writes);
    let a = router(app);
    let p = page(&a, "/systems/server/config").await;
    assert!(!p.contains("audit log has entries"), "{p}");
    post(&a, "/systems/server/ops", set(0, "port", "2222")).await;
    let p = page(&a, "/systems/server/config").await;
    assert!(
        p.contains("The audit log has entries its remote does not have yet"),
        "{p}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_audit_log_page_lists_entries_newest_first_and_filters_them() {
    let s = small_scene();
    let committer = Person {
        name: "golcondad".into(),
        id: "golcondad@test".into(),
    };
    let writes = Writes::open(&s.state, committer, Some(s.key.clone()), None, None).unwrap();
    let alice = Operator {
        id: "alice@example.com".into(),
        name: "Alice".into(),
    };
    let bob = Operator {
        id: "bob@example.com".into(),
        name: "Bob".into(),
    };
    for (who, time, action, result) in [
        (&alice, "2026-11-04T09:00:00Z", "config.set", "ok"),
        (&bob, "2026-11-05T10:00:00Z", "config.set", "denied"),
        (&alice, "2026-11-05T11:00:00Z", "config.commit", "ok"),
    ] {
        writes
            .record(&Entry {
                time: time.into(),
                system: Some("server".into()),
                target: Some("/services/sshd port".into()),
                after: Some(json!(2222)),
                ..Entry::new(who, "web", action, result)
            })
            .unwrap();
    }
    // someone who may only read sees it too
    let reader = Identity {
        id: "carol@example.com".into(),
        name: "Carol".into(),
        level: Level::ReadOnly,
    };
    let a = router(
        App::new(
            vec![("server".into(), s.work.join("examples/server.toml"))],
            Signin::Dev(reader),
            false,
        )
        .with_writes(writes),
    );
    let all = get(&a, "/audit").await;
    let times: Vec<&str> = all
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["time"].as_str().unwrap())
        .collect();
    assert_eq!(
        times,
        [
            "2026-11-05T11:00:00Z",
            "2026-11-05T10:00:00Z",
            "2026-11-04T09:00:00Z"
        ]
    );
    assert_eq!(
        get(&a, "/audit?operator=Bob")
            .await
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        get(&a, "/audit?action=config.commit")
            .await
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        get(&a, "/audit?day=2026-11-05&operator=alice")
            .await
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let p = page(&a, "/audit?operator=Bob").await;
    assert!(
        p.contains(r#"<span class="pill p-red">denied</span>"#),
        "{p}"
    );
    assert!(
        p.contains(r#"<input type="text" name="operator" value="Bob">"#),
        "{p}"
    );
    assert!(!p.contains("config.commit"), "{p}");
}

/// The daemon as `name` (id `name@example.com`), an operator.
fn app_as(s: &Scene, name: &str) -> axum::Router {
    let writes = Writes::open(
        &s.state,
        Person {
            name: "golcondad".into(),
            id: "golcondad@test".into(),
        },
        Some(s.key.clone()),
        Some("origin".into()),
        None,
    )
    .unwrap();
    let who = Identity {
        id: format!("{}@example.com", name.to_lowercase()),
        name: name.into(),
        level: Level::Operator,
    };
    let doc = s.work.join("examples/server.toml");
    router(App::new(vec![("server".into(), doc)], Signin::Dev(who), false).with_writes(writes))
}

#[tokio::test(flavor = "multi_thread")]
async fn a_lock_keeps_others_out_and_breaking_it_needs_a_reason() {
    let s = small_scene();
    let (alice, bob) = (app_as(&s, "Alice"), app_as(&s, "Bob"));
    let (st, v) = post(&alice, "/systems/server/lock", json!({ "minutes": 10 })).await;
    assert_eq!(st, StatusCode::OK, "{v}");
    assert_eq!(v["lock"]["by"]["name"], "Alice");
    for path in [
        "/systems/server/lock",
        "/systems/server/unlock",
        "/systems/server/discard",
        "/systems/server/commit",
    ] {
        let (st, v) = post(&bob, path, json!({ "message": "x" })).await;
        assert_eq!(st, StatusCode::LOCKED, "{path}: {v}");
        assert_eq!(v["lock"]["by"]["name"], "Alice", "{path}");
    }
    let (st, v) = post(&bob, "/systems/server/lock/break", json!({})).await;
    assert_eq!(st, StatusCode::BAD_REQUEST, "{v}");
    let (st, v) = post(
        &bob,
        "/systems/server/lock/break",
        json!({ "reason": "Alice is on leave" }),
    )
    .await;
    assert_eq!(st, StatusCode::OK, "{v}");
    assert_eq!(v["broken"]["by"]["name"], "Alice");
    let (st, _) = post(&alice, "/systems/server/unlock", json!({})).await;
    assert_eq!(st, StatusCode::BAD_REQUEST, "nothing left to unlock");
    let unlocks = audit(&s)
        .iter()
        .filter(|e| e["action"] == "config.unlock" && e["result"] == "ok")
        .count();
    assert_eq!(unlocks, 0, "an unlock that did nothing is no entry");
    let entries = audit(&s);
    let actions: Vec<(&str, &str)> = entries
        .iter()
        .map(|e| (e["action"].as_str().unwrap(), e["result"].as_str().unwrap()))
        .collect();
    assert!(actions.contains(&("config.lock", "ok")), "{actions:?}");
    assert!(
        actions.contains(&("config.discard", "refused")),
        "{actions:?}"
    );
    assert!(
        actions.contains(&("config.commit", "refused")),
        "{actions:?}"
    );
    let broke = entries
        .iter()
        .find(|e| e["action"] == "config.lock.break")
        .unwrap();
    assert_eq!(broke["target"], "Alice's lock: Alice is on leave");
    assert_eq!(broke["operator"]["name"], "Bob");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn an_operation_under_someone_elses_lock_is_refused() {
    let s = scene();
    let (alice, bob) = (app_as(&s, "Alice"), app_as(&s, "Bob"));
    post(&alice, "/systems/server/lock", json!({})).await;
    let op = json!({ "base": 0, "module": "/services/sshd", "option": "port", "op": "set", "value": "2222" });
    let (st, v) = post(&bob, "/systems/server/ops", op.clone()).await;
    assert_eq!(st, StatusCode::LOCKED, "{v}");
    let (st, v) = post(&alice, "/systems/server/ops", op).await;
    assert_eq!(st, StatusCode::OK, "{v}");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_audit_index_is_made_again_at_start() {
    let s = small_scene();
    let alice = app_as(&s, "Alice");
    post(&alice, "/systems/server/lock", json!({})).await;
    post(&alice, "/systems/server/unlock", json!({})).await;
    // the index file thrown away: the next start makes it from the repository
    fs::remove_file(s.state.join("audit-index.db")).unwrap();
    let again = app_as(&s, "Bob");
    let entries = get(&again, "/audit?operator=Alice").await;
    let actions: Vec<&str> = entries
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["action"].as_str().unwrap())
        .collect();
    assert_eq!(actions, ["config.unlock", "config.lock"]);
}

/// Reads the event stream until `want` is in it (or fails after 5 s).
async fn until(body: &mut Body, want: &str) -> String {
    let mut seen = String::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !seen.contains(want) {
        let frame = tokio::time::timeout_at(deadline, body.frame())
            .await
            .unwrap_or_else(|_| panic!("no {want:?} in:\n{seen}"))
            .expect("the stream ended")
            .unwrap();
        if let Ok(data) = frame.into_data() {
            seen += &String::from_utf8_lossy(&data);
        }
    }
    seen
}

async fn stream(app: &axum::Router, page: &str) -> Body {
    let req = Request::get(format!("/systems/server/events?page={page}"))
        .body(Body::empty())
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.headers()[header::CONTENT_TYPE], "text/event-stream");
    res.into_body()
}

#[tokio::test(flavor = "multi_thread")]
async fn the_event_stream_carries_presence_and_the_lock() {
    let s = small_scene();
    let alice = app_as(&s, "Alice");
    let mut watch = stream(&alice, "/systems/server/changes").await;
    let first = until(&mut watch, "event: presence").await;
    assert!(
        first.contains(r#"{"name":"Alice","page":"/systems/server/changes"}"#),
        "{first}"
    );
    // a second page of the same person, then gone again
    let other = stream(&alice, "/systems/server/config").await;
    until(&mut watch, r#""page":"/systems/server/config""#).await;
    drop(other);
    let left = until(&mut watch, "event: presence").await;
    assert!(
        !left
            .rsplit("event: presence")
            .next()
            .unwrap()
            .contains("/config"),
        "{left}"
    );
    post(&alice, "/systems/server/lock", json!({ "minutes": 5 })).await;
    let lock = until(&mut watch, "event: lock").await;
    assert!(lock.contains(r#""name":"Alice""#), "{lock}");
}
