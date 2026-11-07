//! The Packages page and its JSON with advisories from OSV, against a stand-in for iets (the
//! SBOM it prints is made up) and a stub OSV server.

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::extract::State;
use axum::http::{Request, StatusCode, header};
use axum::routing::{get, post};
use golconda_core::advisories::Advisories;
use golconda_core::eval::Iets;
use golcondad::app::{App, Identity, Level, Signin, router};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tempfile::TempDir;
use tower::ServiceExt;

const IETS: &str = r#"#!/bin/sh
case "$*" in
*sbom*) cat "$(dirname "$0")/sbom-eval.json" ;;
*) echo '{"config":{},"schema":{"properties":{}},"moduleDocs":{}}' ;;
esac
"#;

/// Four packages: systemd (the image's own), openssl (vulnerable), zlib, and acl, which has no
/// purl.
fn sbom() -> Value {
    json!({ "roots": ["systemd"], "bom": { "components": [
        { "name": "acl", "version": "2.4.0" },
        { "name": "openssl", "version": "3.0.1", "purl": "pkg:generic/openssl@3.0.1" },
        { "name": "systemd", "version": "262.1", "purl": "pkg:github/systemd/systemd@v262.1" },
        { "name": "zlib", "version": "1.3", "purl": "pkg:generic/zlib@1.3" },
    ] } })
}

struct Scene {
    dir: TempDir,
    queries: Arc<AtomicUsize>,
    osv: String,
}

/// An OSV stub that knows one vulnerability, for openssl; `None` for no server at all.
async fn stub(queries: Arc<AtomicUsize>) -> String {
    async fn batch(State(n): State<Arc<AtomicUsize>>, body: String) -> axum::Json<Value> {
        n.fetch_add(1, Ordering::SeqCst);
        let q: Value = serde_json::from_str(&body).unwrap();
        let results: Vec<Value> = q["queries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|q| {
                if q["package"]["purl"].as_str().unwrap().contains("openssl") {
                    json!({ "vulns": [{ "id": "CVE-2022-0778", "modified": "x" }] })
                } else {
                    json!({})
                }
            })
            .collect();
        axum::Json(json!({ "results": results }))
    }
    async fn vuln() -> axum::Json<Value> {
        axum::Json(
            json!({ "id": "CVE-2022-0778", "summary": "Infinite loop in BN_mod_sqrt()",
            "database_specific": { "severity": "HIGH" } }),
        )
    }
    let app = Router::new()
        .route("/v1/querybatch", post(batch))
        .route("/v1/vulns/{id}", get(vuln))
        .with_state(queries);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    url
}

async fn scene() -> Scene {
    let dir = TempDir::new().unwrap();
    fs::create_dir_all(dir.path().join("lib")).unwrap();
    fs::write(dir.path().join("lib/system.nix"), "{ }").unwrap();
    fs::write(dir.path().join("server.toml"), "").unwrap();
    fs::write(dir.path().join("sbom-eval.json"), sbom().to_string()).unwrap();
    let iets = dir.path().join("iets");
    fs::write(&iets, IETS).unwrap();
    fs::set_permissions(&iets, fs::Permissions::from_mode(0o755)).unwrap();
    let queries = Arc::new(AtomicUsize::new(0));
    let osv = stub(queries.clone()).await;
    Scene { dir, queries, osv }
}

impl Scene {
    /// The daemon, asking OSV at `osv` (none: it does not ask).
    fn app(&self, osv: Option<&str>) -> Router {
        let mut app = App::new(
            vec![("server".into(), self.dir.path().join("server.toml"))],
            Signin::Dev(Identity {
                id: "dev:alice".into(),
                name: "alice".into(),
                level: Level::Operator,
            }),
            false,
        );
        app.iets = Iets::new(self.dir.path().join("iets"));
        if let Some(url) = osv {
            let file = self.dir.path().join("advisories.json");
            app = app.with_advisories(Advisories::open(url, Some(file), Duration::from_hours(6)));
        }
        router(app)
    }
}

async fn get_page(app: &Router, uri: &str, json: bool) -> (StatusCode, String) {
    let mut req = Request::get(uri);
    if json {
        req = req.header(header::ACCEPT, "application/json");
    }
    let res = app
        .clone()
        .oneshot(req.body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = res.status();
    let body = to_bytes(res.into_body(), 1 << 22).await.unwrap();
    (status, String::from_utf8_lossy(&body).into_owned())
}

fn names(v: &Value) -> Vec<&str> {
    v["packages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["name"].as_str().unwrap())
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn the_json_lists_vulnerable_packages_first_with_their_advisories() {
    let s = scene().await;
    let app = s.app(Some(&s.osv));
    let (status, body) = get_page(&app, "/systems/server/packages", true).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let v: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(names(&v), ["openssl", "systemd", "acl", "zlib"]);
    let p = &v["packages"];
    assert_eq!(
        p[0]["advisories"],
        json!([{ "id": "CVE-2022-0778", "summary": "Infinite loop in BN_mod_sqrt()", "severity": "HIGH" }])
    );
    assert_eq!(p[1]["advisories"], json!([]), "asked, nothing found");
    assert_eq!(p[2]["advisories"], Value::Null, "no purl, not asked");
    assert_eq!(v["advisories"]["error"], Value::Null);
    assert!(v["advisories"]["checkedAt"].as_u64().is_some(), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_page_shows_the_advisory_when_it_was_checked_and_can_show_only_those() {
    let s = scene().await;
    let app = s.app(Some(&s.osv));
    let (status, page) = get_page(&app, "/systems/server/packages", false).await;
    assert_eq!(status, StatusCode::OK, "{page}");
    assert!(page.contains("CVE-2022-0778"), "{page}");
    assert!(page.contains("Infinite loop in BN_mod_sqrt()"), "{page}");
    assert!(page.contains("HIGH"), "{page}");
    assert!(page.contains("checked just now"), "{page}");
    let (open, shut) = (page.find("openssl").unwrap(), page.find("systemd").unwrap());
    assert!(open < shut, "vulnerable first");
    let (_, only) = get_page(&app, "/systems/server/packages?show=vulnerable", false).await;
    assert!(only.contains("openssl") && !only.contains("zlib"), "{only}");
}

#[tokio::test(flavor = "multi_thread")]
async fn osv_is_not_asked_on_every_view() {
    let s = scene().await;
    let app = s.app(Some(&s.osv));
    for _ in 0..3 {
        get_page(&app, "/systems/server/packages", false).await;
        get_page(&app, "/systems/server/packages", true).await;
    }
    assert_eq!(s.queries.load(Ordering::SeqCst), 1);
    // a daemon started later reads the state directory's file
    let app = s.app(Some(&s.osv));
    let (_, body) = get_page(&app, "/systems/server/packages", true).await;
    assert_eq!(s.queries.load(Ordering::SeqCst), 1);
    assert!(body.contains("CVE-2022-0778"), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn without_osv_the_page_still_shows_and_says_it_could_not_check() {
    let s = scene().await;
    let app = s.app(Some("http://127.0.0.1:1"));
    let (status, page) = get_page(&app, "/systems/server/packages", false).await;
    assert_eq!(status, StatusCode::OK, "{page}");
    assert!(page.contains("could not check"), "{page}");
    assert!(
        page.contains("openssl") && page.contains("systemd"),
        "{page}"
    );
    let (status, body) = get_page(&app, "/systems/server/packages", true).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let v: Value = serde_json::from_str(&body).unwrap();
    assert!(v["advisories"]["error"].is_string(), "{body}");
    assert_eq!(v["advisories"]["checkedAt"], Value::Null);
    assert_eq!(v["packages"][0]["advisories"], Value::Null);
    // the usual order: the image's own first
    assert_eq!(names(&v), ["systemd", "acl", "openssl", "zlib"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_daemon_that_does_not_check_says_so() {
    let s = scene().await;
    let app = s.app(None);
    let (_, page) = get_page(&app, "/systems/server/packages", false).await;
    assert!(page.contains("not checked"), "{page}");
    let (_, body) = get_page(&app, "/systems/server/packages", true).await;
    let v: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["advisories"], Value::Null);
    assert_eq!(v["packages"][0]["advisories"], Value::Null);
    assert_eq!(s.queries.load(Ordering::SeqCst), 0);
}
