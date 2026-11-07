//! Jobs through the daemon's routes, against a machine that is a shell script standing in for
//! ssh (core/src/testdata/machine.sh): it answers varlinkctl, sysupdate and bootctl as the image
//! does, and takes what a deploy published from the update source directory. A deploy also
//! builds: nix-build and gpgv are stand-ins, git and rclone are real.

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode, header};
use golconda_core::git::Person;
use golconda_core::machine::Patience;
use golconda_core::vars::Program;
use golcondad::app::{App, Identity, Level, Signin, router};
use golcondad::jobs::{JobConfig, Runner};
use golcondad::write::Writes;
use http_body_util::BodyExt;
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use tempfile::TempDir;
use tower::ServiceExt;

const MACHINE: &str = include_str!("../../core/src/testdata/machine.sh");
const DOC: &str = "[\"/system\"]\nname = \"server\"\nversion = \"20261105.1\"\n";

struct Scene {
    tmp: TempDir,
    repo: PathBuf,
    m: PathBuf,
}

fn sh(dir: &Path, program: &str, args: &[&str]) -> String {
    let out = Command::new(program)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{program} {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn script(path: &Path, body: &str) -> Program {
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    Program::from_env("GOLCONDA_TEST_UNSET", path.to_str().unwrap())
}

/// A configuration repository (a Golconda checkout, as the build wants) with server.toml and
/// machines.toml, web1 running 20261105.1, and a release of `next` prepared for the nix-build
/// stand-in.
fn scene(next: &str) -> Scene {
    let tmp = TempDir::new().unwrap();
    let t = tmp.path();
    let repo = t.join("repo");
    fs::create_dir_all(repo.join("lib")).unwrap();
    fs::write(repo.join("lib/system.nix"), "{ }").unwrap();
    fs::write(repo.join("server.toml"), DOC).unwrap();
    fs::write(
        repo.join("machines.toml"),
        format!(
            "[server]\nupdates = \"{}\"\n[server.machines.web1]\nssh = \"root@web1\"\n",
            t.join("www").display()
        ),
    )
    .unwrap();
    sh(&repo, "git", &["init", "-q", "-b", "main"]);
    sh(&repo, "git", &["add", "."]);
    sh(
        &repo,
        "git",
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "server",
        ],
    );
    // web1: a machine directory beside the ssh stand-in
    let m = t.join("m");
    fs::create_dir_all(&m).unwrap();
    for (f, v) in [
        ("version", "20261105.1"),
        ("boot", "boot-0"),
        ("slots", "20261105.1\n"),
    ] {
        fs::write(m.join(f), v).unwrap();
    }
    fs::write(m.join("source"), t.join("www").to_str().unwrap()).unwrap();
    fs::create_dir_all(t.join("keys/release")).unwrap();
    fs::write(t.join("keys/release/index.pgp"), "key").unwrap();
    release(t, next);
    Scene { tmp, repo, m }
}

/// A build output for `version`: out-<version>/release with four files and an index.
fn release(t: &Path, version: &str) {
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
    let stem = format!("server_{version}");
    let dir = t.join(format!("out-{version}/release"));
    fs::create_dir_all(&dir).unwrap();
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
        let d = golconda_core::release::sha256(&dir.join(name)).unwrap();
        index += &format!("{d}  {name}\n");
    }
    fs::write(dir.join("SHA256SUMS"), index).unwrap();
    fs::write(dir.join("SHA256SUMS.gpg"), "sig").unwrap();
}

impl Scene {
    fn app(&self, who: Identity, keys: bool) -> Router {
        let t = self.tmp.path();
        let w = Writes::open(
            &t.join("state"),
            Person {
                name: "golcondad".into(),
                id: "golcondad@test".into(),
            },
            None,
            None,
            None,
        )
        .unwrap();
        // nix-build: --arg config DOC --argstr keys K --argstr system S --out-link LINK --expr E
        let nix_build = script(
            &t.join("nix-build"),
            &format!(
                "#!/bin/sh\nv=$(sed -n 's/^version = \"\\(.*\\)\"/\\1/p' \"$3\")\n[ -d {t}/out-$v ] || {{ echo \"error: no build for $v\" >&2; exit 1; }}\nln -sfn {t}/out-$v \"${{11}}\"\n",
                t = t.display()
            ),
        );
        let config = JobConfig {
            ssh: script(&t.join("ssh"), MACHINE),
            nix_build,
            gpgv: script(&t.join("gpgv"), "#!/bin/sh\nexit 0\n"),
            rclone: Program::from_env("GOLCONDA_RCLONE", "rclone"),
            release_keys: keys.then(|| t.join("keys")),
            copy_keys: false,
            patience: Patience {
                every: Duration::from_millis(10),
                until: Duration::from_secs(10),
            },
        };
        let r = Runner::open(&t.join("state"), config).unwrap();
        router(
            App::new(
                vec![("server".into(), self.repo.join("server.toml"))],
                Signin::Dev(who),
                false,
            )
            .with_writes(w)
            .with_jobs(r),
        )
    }

    fn audit(&self) -> String {
        let dir = self.tmp.path().join("state/audit");
        let mut all = String::new();
        for day in walk(&dir) {
            all += &fs::read_to_string(day).unwrap();
        }
        all
    }
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.file_name().is_some_and(|n| n == ".git") {
            continue;
        }
        if p.is_dir() {
            out.extend(walk(&p));
        } else if p.extension().is_some_and(|x| x == "jsonl") {
            out.push(p);
        }
    }
    out
}

fn alice() -> Identity {
    Identity {
        id: "dev:alice".into(),
        name: "alice".into(),
        level: Level::Operator,
    }
}

async fn call(app: &Router, method: &str, path: &str, body: Option<Value>) -> (StatusCode, Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header(header::HOST, "127.0.0.1")
        .header(header::ACCEPT, "application/json");
    let body = match body {
        Some(b) => {
            req = req.header(header::CONTENT_TYPE, "application/json");
            Body::from(b.to_string())
        }
        None => Body::empty(),
    };
    let res = app.clone().oneshot(req.body(body).unwrap()).await.unwrap();
    let status = res.status();
    let b = to_bytes(res.into_body(), 1 << 22).await.unwrap();
    (status, serde_json::from_slice(&b).unwrap_or(Value::Null))
}

/// Starts a job and waits for it to end: the job and its lines.
async fn job(app: &Router, kind: &str, machine: Option<&str>) -> Value {
    let (s, v) = call(
        app,
        "POST",
        "/systems/server/jobs",
        Some(json!({ "kind": kind, "machine": machine })),
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{v}");
    let id = v["job"].as_i64().unwrap();
    let start = Instant::now();
    loop {
        let (_, j) = call(app, "GET", &format!("/jobs/{id}"), None).await;
        if !matches!(j["job"]["state"].as_str(), Some("queued" | "running")) {
            return j;
        }
        assert!(
            start.elapsed() < Duration::from_secs(20),
            "job {id} did not end: {j}"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn lines(j: &Value) -> String {
    j["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["line"].as_str().unwrap().to_string() + "\n")
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn the_status_route_reads_each_machine() {
    let s = scene("20261106.1");
    let app = s.app(alice(), false);
    let (st, v) = call(&app, "GET", "/systems/server/machines", None).await;
    assert_eq!(st, StatusCode::OK, "{v}");
    assert_eq!(v["machines"][0]["name"], "web1");
    assert_eq!(v["machines"][0]["status"]["version"], "20261105.1");
    fs::write(s.m.join("down"), "").unwrap();
    let (_, v) = call(&app, "GET", "/systems/server/machines", None).await;
    assert!(
        v["machines"][0]["error"]
            .as_str()
            .unwrap()
            .contains("Connection refused"),
        "{v}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn update_then_reboot_brings_the_machine_to_the_new_version() {
    let s = scene("20261106.1");
    let app = s.app(alice(), false);
    fs::write(s.m.join("available"), "20261106.1").unwrap();
    let j = job(&app, "update", Some("web1")).await;
    assert_eq!(j["job"]["state"], "ok", "{j}");
    assert!(
        lines(&j).contains("Successfully installed update '20261106.1'"),
        "{j}"
    );
    assert_eq!(
        j["job"]["summary"],
        "web1: 20261106.1 is installed for the next boot"
    );
    let j = job(&app, "reboot", Some("web1")).await;
    assert_eq!(j["job"]["state"], "ok", "{j}");
    assert_eq!(j["job"]["summary"], "web1 runs 20261106.1");
    // each job's start and end are audit entries
    let audit = s.audit();
    for want in [
        r#""action":"job.update""#,
        r#""result":"queued""#,
        r#""action":"job.reboot""#,
    ] {
        assert!(audit.contains(want), "{want} missing:\n{audit}");
    }
    let (_, list) = call(&app, "GET", "/jobs", None).await;
    assert_eq!(list.as_array().unwrap().len(), 2);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_job_says_why_and_the_next_still_runs() {
    let s = scene("20261106.1");
    let app = s.app(alice(), false);
    fs::write(s.m.join("inhibited"), "").unwrap();
    let j = job(&app, "reboot", Some("web1")).await;
    assert_eq!(j["job"]["state"], "failed");
    assert!(
        j["job"]["summary"]
            .as_str()
            .unwrap()
            .contains("BlockedByInhibitor"),
        "{j}"
    );
    assert!(s.audit().contains(r#""result":"failed""#));
    fs::remove_file(s.m.join("inhibited")).unwrap();
    assert_eq!(
        job(&app, "reboot", Some("web1")).await["job"]["state"],
        "ok"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_deploy_builds_publishes_and_brings_each_machine_up() {
    let s = scene("20261106.1");
    let app = s.app(alice(), true);
    // today's version comes after the document's; the stand-in builds what the document says
    let want = golconda_core::release::Version::next(
        golconda_core::release::Version::today(),
        &["20261105.1".parse().unwrap()],
    )
    .unwrap()
    .to_string();
    release(s.tmp.path(), &want);
    let j = job(&app, "deploy", None).await;
    assert_eq!(j["job"]["state"], "ok", "{}", lines(&j));
    assert_eq!(
        j["job"]["summary"].as_str().unwrap(),
        format!("server {want} on web1")
    );
    // the release commit is the operator's, the daemon's committer's
    let who = sh(&s.repo, "git", &["log", "-1", "--format=%s|%an|%cn"]);
    assert_eq!(who, format!("release: server {want}|alice|golcondad"));
    assert!(
        fs::read_to_string(s.tmp.path().join("www/SHA256SUMS"))
            .unwrap()
            .contains(&format!("server_{want}.efi"))
    );
    assert_eq!(
        fs::read_to_string(s.m.join("version")).unwrap().trim(),
        want
    );
    let audit = s.audit();
    for want in [
        r#""action":"release.build""#,
        r#""action":"release.publish""#,
        r#""action":"job.deploy""#,
    ] {
        assert!(audit.contains(want), "{want} missing");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_release_its_entry_cannot_record_is_undone_before_the_push() {
    let s = scene("20261106.1");
    let app = s.app(alice(), true);
    let t = s.tmp.path();
    let want = golconda_core::release::Version::next(
        golconda_core::release::Version::today(),
        &["20261105.1".parse().unwrap()],
    )
    .unwrap()
    .to_string();
    release(t, &want);
    // the build goes on, the audit repository goes away under it
    fs::write(
        t.join("nix-build"),
        format!(
            "#!/bin/sh\nrm -rf {t}/state/audit/.git\nv=$(sed -n 's/^version = \"\\(.*\\)\"/\\1/p' \"$3\")\nln -sfn {t}/out-$v \"${{11}}\"\n",
            t = t.display()
        ),
    )
    .unwrap();
    let j = job(&app, "deploy", None).await;
    assert_eq!(j["job"]["state"], "failed");
    assert!(
        j["job"]["summary"]
            .as_str()
            .unwrap()
            .contains("the release commit is undone"),
        "{j}"
    );
    assert_eq!(sh(&s.repo, "git", &["log", "-1", "--format=%s"]), "server");
    assert_eq!(fs::read_to_string(s.repo.join("server.toml")).unwrap(), DOC);
    assert!(!t.join("www/SHA256SUMS").exists(), "nothing published");
}

#[tokio::test(flavor = "multi_thread")]
async fn jobs_are_refused_to_readers_and_for_what_is_not_there() {
    let s = scene("20261106.1");
    let bob = Identity {
        id: "dev:bob".into(),
        name: "bob".into(),
        level: Level::ReadOnly,
    };
    let app = s.app(bob, true);
    let (st, _) = call(
        &app,
        "POST",
        "/systems/server/jobs",
        Some(json!({ "kind": "reboot", "machine": "web1" })),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    assert!(s.audit().contains(r#""result":"denied""#));
    let app = s.app(alice(), false);
    for (body, want) in [
        (
            json!({ "kind": "reboot", "machine": "web9" }),
            "no machine web9",
        ),
        (json!({ "kind": "reboot" }), "needs a machine"),
        (
            json!({ "kind": "format", "machine": "web1" }),
            "no job format",
        ),
        (json!({ "kind": "deploy" }), "--release-keys"),
    ] {
        let (st, v) = call(&app, "POST", "/systems/server/jobs", Some(body)).await;
        assert_eq!(st, StatusCode::BAD_REQUEST, "{v}");
        assert!(v["error"].as_str().unwrap().contains(want), "{v}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_jobs_lines_and_end_go_to_the_systems_stream() {
    let s = scene("20261106.1");
    let app = s.app(alice(), false);
    let req = Request::get("/systems/server/events?page=/jobs/1")
        .header(header::HOST, "127.0.0.1")
        .body(Body::empty())
        .unwrap();
    let mut body = app.clone().oneshot(req).await.unwrap().into_body();
    fs::write(s.m.join("available"), "20261106.1").unwrap();
    job(&app, "update", Some("web1")).await;
    let mut seen = String::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !seen.contains(r#""state":"ok""#) {
        let frame = tokio::time::timeout_at(deadline, body.frame())
            .await
            .unwrap_or_else(|_| panic!("no job end in:\n{seen}"))
            .unwrap()
            .unwrap();
        if let Ok(d) = frame.into_data() {
            seen += &String::from_utf8_lossy(&d);
        }
    }
    assert!(seen.contains("event: job"), "{seen}");
    assert!(seen.contains("Successfully installed update"), "{seen}");
}
