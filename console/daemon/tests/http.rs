//! golcondad's routes against the checkout's own examples/server.toml, through iets, in
//! process. Ignored in the package build, which has neither (console/README.md).

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode, header};
use golcondad::app::{App, Identity, Level, Signin, router};
use std::fs;
use std::path::PathBuf;
use tower::ServiceExt;

fn checkout() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn app(read_only: bool) -> axum::Router {
    let root = checkout();
    router(App::new(
        vec![("server".into(), root.join("examples/server.toml"))],
        Signin::Dev(Identity {
            id: "dev:alice".into(),
            name: "alice".into(),
            level: Level::Operator,
        }),
        read_only,
    ))
}

async fn get(app: axum::Router, uri: &str, json: bool) -> (StatusCode, String, String) {
    let mut req = Request::get(uri);
    if json {
        req = req.header(header::ACCEPT, "application/json");
    }
    let res = app.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
    let status = res.status();
    let ctype = res
        .headers()
        .get(header::CONTENT_TYPE)
        .map(|v| v.to_str().unwrap().to_string())
        .unwrap_or_default();
    let body = to_bytes(res.into_body(), 1 << 22).await.unwrap();
    (status, ctype, String::from_utf8_lossy(&body).into_owned())
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn a_module_page_shows_its_options_and_the_selected_one() {
    let (s, ctype, body) = get(
        app(false),
        "/systems/server/config/services/sshd?option=port",
        false,
    )
    .await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(ctype.starts_with("text/html"), "{ctype}");
    // the strip: system, image version, who
    assert!(
        body.contains(r#"<span class="host">server</span>"#),
        "{body}"
    );
    assert!(body.contains("image 20261031.1"), "{body}");
    assert!(body.contains("alice · operator"), "{body}");
    // the module's doc text and its option rows, set ones marked
    assert!(body.contains("OpenSSH daemon as a service"), "{body}");
    assert!(body.contains(r#"<span class="v set">22</span>"#), "{body}");
    assert!(
        body.contains(r#"<span class="v def">false</span>"#),
        "{body}"
    );
    // the selected option's detail
    assert!(body.contains("<h4>/services/sshd port</h4>"), "{body}");
    assert!(body.contains("<dd>examples/server.toml:11</dd>"), "{body}");
    // the line of `port = {` in the module, found rather than written down
    let module = fs::read_to_string(checkout().join("modules/services/sshd/default.nix"))
        .expect("the sshd module");
    let line = module
        .lines()
        .position(|l| l == "    port = {")
        .expect("a port option")
        + 1;
    assert!(
        body.contains(&format!(
            "<dd>modules/services/sshd/default.nix:{line}</dd>"
        )),
        "{body}"
    );
    // one script, the optional one from this daemon, nothing inline, no request elsewhere
    assert_eq!(body.matches("<script").count(), 1, "{body}");
    assert!(
        body.contains(r#"<script src="/assets/live.js?v="#),
        "{body}"
    );
    assert!(
        !body.contains("http://") && !body.contains("https://"),
        "{body}"
    );
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn the_same_route_answers_json() {
    let (s, ctype, body) = get(app(false), "/systems/server/config/services/sshd", true).await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(ctype.starts_with("application/json"), "{ctype}");
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["module"], "/services/sshd");
    let port = v["options"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["option"] == "port")
        .unwrap();
    assert_eq!(port["value"], 22);
    assert_eq!(port["setAt"]["line"], 11);
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn the_config_page_lists_every_module() {
    let (s, _, body) = get(app(false), "/systems/server/config", false).await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(
        body.contains(r#"href="/systems/server/config/services/sshd""#),
        "{body}"
    );
    assert!(
        body.contains(r#"href="/systems/server/config/base""#),
        "{body}"
    );
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn changes_against_git() {
    // the working tree's examples/server.toml is HEAD's
    let (s, _, body) = get(app(false), "/systems/server/changes", false).await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(body.contains("No changes against HEAD."), "{body}");
    let (_, _, json) = get(app(false), "/systems/server/changes", true).await;
    assert_eq!(json.trim(), "[]");
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn unknown_systems_modules_and_options_are_404() {
    for uri in [
        "/systems/nope/config",
        "/systems/server/config/no/such",
        "/systems/server/config/services/sshd?option=prot",
    ] {
        let (s, _, body) = get(app(false), uri, false).await;
        assert_eq!(s, StatusCode::NOT_FOUND, "{uri}: {body}");
    }
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn a_read_only_daemon_says_so_on_every_page() {
    let (_, _, body) = get(app(true), "/systems/server/config", false).await;
    assert!(body.contains("This console is read-only"), "{body}");
}

#[tokio::test]
async fn assets_and_headers_need_no_evaluation() {
    let res = app(false)
        .oneshot(
            Request::get(golcondad::pages::stylesheet())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let h = res.headers();
    assert_eq!(h[header::CONTENT_TYPE], "text/css; charset=utf-8");
    let csp = h[header::CONTENT_SECURITY_POLICY].to_str().unwrap();
    assert!(csp.starts_with("default-src 'self'"), "{csp}");
    assert!(csp.contains("frame-ancestors 'none'"), "{csp}");
    assert_eq!(h[header::X_CONTENT_TYPE_OPTIONS], "nosniff");
    let (s, _, _) = get(app(false), "/assets/fonts/nope.woff2", false).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    // built with the fonts (GOLCONDA_FONTS), each is served as WOFF2
    for (file, bytes) in golcondad::FONTS {
        let res = app(false)
            .oneshot(
                Request::get(format!("/assets/fonts/{file}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.headers()[header::CONTENT_TYPE], "font/woff2");
        assert_eq!(
            to_bytes(res.into_body(), 1 << 20).await.unwrap().len(),
            bytes.len()
        );
    }
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn a_module_without_options_has_a_page() {
    for m in ["vars", "security"] {
        let (s, _, body) = get(app(false), &format!("/systems/server/config/{m}"), false).await;
        assert_eq!(s, StatusCode::OK, "{m}: {body}");
        assert!(body.contains("This module has no options."), "{m}: {body}");
    }
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn module_docs_and_descriptions_are_markdown() {
    let (_, _, body) = get(app(false), "/systems/server/config/services/sshd", false).await;
    // `sshd.service` in the module's text, `openssh` in package's description
    assert!(body.contains("<code>sshd.service</code>"), "{body}");
    assert!(body.contains("<code>openssh</code>"), "{body}");
    assert!(!body.contains('`'), "{body}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs iets and the Golconda checkout"]
async fn changes_pages_at_the_same_time() {
    let a = app(false);
    let pages = (0..4).map(|_| tokio::spawn(get(a.clone(), "/systems/server/changes", false)));
    for p in pages {
        let (s, _, body) = p.await.unwrap();
        assert_eq!(s, StatusCode::OK, "{body}");
    }
}

#[tokio::test]
async fn only_a_loopback_host_is_served() {
    // a page elsewhere whose name resolves to 127.0.0.1 (DNS rebinding) sends its own Host
    let status = |host: &'static str| async move {
        let req = Request::get(golcondad::pages::stylesheet()).header(header::HOST, host);
        app(false)
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap()
            .status()
    };
    assert_eq!(
        status("evil.example:8796").await,
        StatusCode::MISDIRECTED_REQUEST
    );
    assert_eq!(
        status("127.0.0.1.evil.example").await,
        StatusCode::MISDIRECTED_REQUEST
    );
    for ok in [
        "127.0.0.1:8796",
        "localhost:8796",
        "[::1]:8796",
        "localhost",
    ] {
        assert_eq!(status(ok).await, StatusCode::OK, "{ok}");
    }
}

#[tokio::test]
#[ignore = "needs iets and the Golconda checkout"]
async fn the_packages_page_lists_the_sbom() {
    let (status, _, body) = get(app(false), "/systems/server/packages", true).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let list: serde_json::Value = serde_json::from_str(&body).unwrap();
    let systemd = list
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["name"] == "systemd")
        .unwrap();
    assert_eq!(
        (systemd["root"].as_bool(), systemd["origin"].as_str()),
        (Some(true), Some("golconda"))
    );
    let (_, _, page) = get(app(false), "/systems/server/packages", false).await;
    assert!(
        page.contains("systemd")
            && page.contains("in the image")
            && page.contains("/systems/server/sbom.json"),
        "{page}"
    );
    let (status, _, bom) = get(app(false), "/systems/server/sbom.json", false).await;
    assert_eq!(status, StatusCode::OK);
    assert!(bom.contains("\"bomFormat\":\"CycloneDX\""), "{bom}");
}
