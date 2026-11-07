//! Sign-in through OIDC against a stub provider: a real HTTP server on a random port, which
//! signs ID tokens with the test keys in fixtures/ and checks the PKCE verifier. Each test
//! walks the browser's way: a page, the daemon's /auth/login, the provider's /authorize, the
//! daemon's /auth/callback, the page again with the session cookie.
//!
//! The pages need evaluation (iets), so the tests that open one are ignored in the package
//! build; the sign-in itself, its refusals and the cookie need none.

use axum::Router;
use axum::body::{Body, to_bytes};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, Request, StatusCode, header};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use golcondad::app::{App, router};
use golcondad::auth::{Oidc, OidcConfig};
use ring::signature;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};
use tower::ServiceExt;

const PUBLIC: &str = "http://console.test";

#[derive(Clone, Copy, PartialEq, Debug)]
enum Mode {
    Good,
    Rs256,
    WrongAudience,
    WrongIssuer,
    Expired,
    WrongNonce,
    UnknownKey,
    AlgNone,
    AlgHs256,
    /// signed with the ES256 key, but the header says ES384: only the allow-list refuses it
    AlgMislabeled,
    /// nbf ten minutes ahead
    NotYetValid,
    /// two audiences and no azp, or an azp that is another client
    TwoAudiencesNoAzp,
    TwoAudiencesOtherAzp,
    /// two audiences, azp this client: good
    TwoAudiencesAzp,
    /// a crit header the daemon does not know
    Crit,
    /// kid of the same key published for encryption only
    EncryptionKey,
    /// kid of the same key published as an ES384 key
    KeyForAnotherAlg,
    /// no kid: the daemon tries every ES256 key, the right one is second
    NoKid,
}

struct Grant {
    user: String,
    /// the client the token is meant for
    aud: String,
    nonce: String,
    challenge: String,
    redirect_uri: String,
}

struct Stub {
    issuer: String,
    mode: Mutex<Mode>,
    grants: Mutex<HashMap<String, Grant>>,
}

fn der(pem: &str) -> Vec<u8> {
    let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
    STANDARD.decode(body).unwrap()
}

fn jwk(file: &str, kid: &str, alg: &str) -> Value {
    let mut k: Value = serde_json::from_str(file).unwrap();
    k["kid"] = kid.into();
    k["alg"] = alg.into();
    k["use"] = "sig".into();
    k
}

impl Stub {
    fn token(&self, g: &Grant) -> String {
        let mode = *self.mode.lock().unwrap();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            .cast_signed();
        let groups: Vec<&str> = match g.user.as_str() {
            "alice" => vec!["golconda-operators", "staff"],
            "bob" => vec!["golconda-readers"],
            _ => vec!["staff"],
        };
        let mut claims = json!({
            "iss": self.issuer, "aud": g.aud, "sub": format!("id-{}", g.user),
            "name": g.user[..1].to_uppercase() + &g.user[1..], "groups": groups,
            "nonce": g.nonce, "iat": now, "exp": now + 300,
        });
        match mode {
            Mode::WrongAudience => claims["aud"] = "another-client".into(),
            Mode::WrongIssuer => claims["iss"] = "http://127.0.0.1:1".into(),
            Mode::Expired => claims["exp"] = (now - 600).into(),
            Mode::WrongNonce => claims["nonce"] = "not-the-nonce".into(),
            Mode::NotYetValid => claims["nbf"] = (now + 600).into(),
            Mode::TwoAudiencesNoAzp => claims["aud"] = json!(["console", "another-client"]),
            Mode::TwoAudiencesOtherAzp | Mode::TwoAudiencesAzp => {
                claims["aud"] = json!(["console", "another-client"]);
                claims["azp"] = if mode == Mode::TwoAudiencesAzp {
                    "console"
                } else {
                    "another-client"
                }
                .into();
            }
            _ => {}
        }
        let (alg, kid) = match mode {
            Mode::Rs256 => ("RS256", "rsa1"),
            Mode::AlgNone => ("none", "ec1"),
            Mode::AlgHs256 => ("HS256", "ec1"),
            Mode::AlgMislabeled => ("ES384", "ec1"),
            Mode::EncryptionKey => ("ES256", "enc1"),
            Mode::KeyForAnotherAlg => ("ES256", "es384"),
            _ => ("ES256", "ec1"),
        };
        let b64 = |v: &Value| URL_SAFE_NO_PAD.encode(v.to_string());
        let mut header = json!({ "alg": alg, "kid": kid, "typ": "JWT" });
        match mode {
            Mode::NoKid => {
                header.as_object_mut().unwrap().remove("kid");
            }
            Mode::Crit => header["crit"] = json!(["exp"]),
            _ => {}
        }
        let input = format!("{}.{}", b64(&header), b64(&claims));
        let rng = ring::rand::SystemRandom::new();
        let sig = match mode {
            Mode::AlgNone => Vec::new(),
            // HMAC with the public key as the secret: the old algorithm-confusion attack
            Mode::AlgHs256 => {
                let k = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, input.as_bytes());
                ring::hmac::sign(&k, input.as_bytes()).as_ref().to_vec()
            }
            Mode::Rs256 => {
                let key =
                    signature::RsaKeyPair::from_pkcs8(&der(include_str!("fixtures/oidc-rsa.pem")))
                        .unwrap();
                let mut sig = vec![0; key.public().modulus_len()];
                key.sign(
                    &signature::RSA_PKCS1_SHA256,
                    &rng,
                    input.as_bytes(),
                    &mut sig,
                )
                .unwrap();
                sig
            }
            _ => {
                let pem = if mode == Mode::UnknownKey {
                    include_str!("fixtures/oidc-other.pem")
                } else {
                    include_str!("fixtures/oidc-stub.pem")
                };
                let key = signature::EcdsaKeyPair::from_pkcs8(
                    &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
                    &der(pem),
                    &rng,
                )
                .unwrap();
                key.sign(&rng, input.as_bytes()).unwrap().as_ref().to_vec()
            }
        };
        format!("{input}.{}", URL_SAFE_NO_PAD.encode(sig))
    }
}

async fn discovery(State(s): State<Arc<Stub>>) -> axum::Json<Value> {
    axum::Json(json!({
        "issuer": s.issuer,
        "authorization_endpoint": format!("{}/authorize", s.issuer),
        "token_endpoint": format!("{}/token", s.issuer),
        "jwks_uri": format!("{}/jwks", s.issuer),
        "device_authorization_endpoint": format!("{}/device", s.issuer),
    }))
}

async fn jwks() -> axum::Json<Value> {
    // oidc-other's key is not here: what it signs must be refused. The stub's own key is
    // here three times: for encryption only, as an ES384 key, and as the signing key ec1;
    // before them a key that signs nothing, so a token without kid must try more than one.
    let mut enc = jwk(include_str!("fixtures/oidc-stub.jwk.json"), "enc1", "ES256");
    enc["use"] = "enc".into();
    axum::Json(json!({ "keys": [
        jwk(include_str!("fixtures/oidc-extra.jwk.json"), "ec0", "ES256"),
        enc,
        jwk(include_str!("fixtures/oidc-stub.jwk.json"), "es384", "ES384"),
        jwk(include_str!("fixtures/oidc-stub.jwk.json"), "ec1", "ES256"),
        jwk(include_str!("fixtures/oidc-rsa.jwk.json"), "rsa1", "RS256"),
    ]}))
}

async fn authorize(
    State(s): State<Arc<Stub>>,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    for (k, v) in [
        ("response_type", "code"),
        ("client_id", "console"),
        ("code_challenge_method", "S256"),
    ] {
        if q.get(k).map(String::as_str) != Some(v) {
            return (StatusCode::BAD_REQUEST, format!("{k} must be {v}")).into_response();
        }
    }
    let scope = q.get("scope").cloned().unwrap_or_default();
    if !scope.split(' ').any(|s| s == "openid") {
        return (StatusCode::BAD_REQUEST, "scope needs openid").into_response();
    }
    let code = format!("code-{}", s.grants.lock().unwrap().len());
    s.grants.lock().unwrap().insert(
        code.clone(),
        Grant {
            user: q["login_hint"].clone(),
            aud: "console".into(),
            nonce: q["nonce"].clone(),
            challenge: q["code_challenge"].clone(),
            redirect_uri: q["redirect_uri"].clone(),
        },
    );
    Redirect::to(&format!(
        "{}?code={code}&state={}",
        q["redirect_uri"], q["state"]
    ))
    .into_response()
}

async fn token(State(s): State<Arc<Stub>>, body: String) -> Response {
    let f: HashMap<String, String> = body
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (k.to_string(), percent_decode(v)))
        .collect();
    let Some(g) = f
        .get("code")
        .and_then(|c| s.grants.lock().unwrap().remove(c))
    else {
        return (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({ "error": "invalid_grant" })),
        )
            .into_response();
    };
    let verifier = f.get("code_verifier").cloned().unwrap_or_default();
    let challenge = URL_SAFE_NO_PAD.encode(ring::digest::digest(
        &ring::digest::SHA256,
        verifier.as_bytes(),
    ));
    if challenge != g.challenge
        || f.get("redirect_uri") != Some(&g.redirect_uri)
        || f.get("grant_type").map(String::as_str) != Some("authorization_code")
        || f.get("client_id").map(String::as_str) != Some("console")
    {
        return (
            StatusCode::BAD_REQUEST,
            axum::Json(json!({ "error": "invalid_grant" })),
        )
            .into_response();
    }
    axum::Json(json!({ "access_token": "x", "token_type": "Bearer", "id_token": s.token(&g) }))
        .into_response()
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8(out).unwrap()
}

/// The stub, serving on 127.0.0.1, and a daemon that signs in through it.
async fn setup(mode: Mode) -> (Arc<Stub>, Router) {
    setup_cli(mode, Some("golconda-cli")).await
}

/// The same, with `cli` as the daemon's CLI client.
async fn setup_cli(mode: Mode, cli: Option<&str>) -> (Arc<Stub>, Router) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let issuer = format!("http://{}", listener.local_addr().unwrap());
    let stub = Arc::new(Stub {
        issuer: issuer.clone(),
        mode: Mutex::new(mode),
        grants: Mutex::default(),
    });
    let app = Router::new()
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/jwks", get(jwks))
        .route("/authorize", get(authorize))
        .route("/token", post(token))
        .with_state(stub.clone());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let cfg = OidcConfig {
        issuer,
        client_id: "console".into(),
        client_secret: None,
        public_url: PUBLIC.into(),
        operator_group: "golconda-operators".into(),
        read_only_group: "golconda-readers".into(),
        ca_pem: None,
        cli_client_id: cli.map(str::to_string),
    };
    let oidc = tokio::task::spawn_blocking(move || Oidc::discover(cfg))
        .await
        .unwrap()
        .unwrap();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let daemon = router(App::new(
        vec![("server".into(), root.join("examples/server.toml"))],
        golcondad::app::Signin::Oidc(Box::new(oidc)),
        false,
    ));
    (stub, daemon)
}

async fn send(app: &Router, req: Request<Body>) -> (StatusCode, HeaderMap, String) {
    let res = app.clone().oneshot(req).await.unwrap();
    let (status, headers) = (res.status(), res.headers().clone());
    let body = to_bytes(res.into_body(), 1 << 22).await.unwrap();
    (status, headers, String::from_utf8_lossy(&body).into_owned())
}

fn location(h: &HeaderMap) -> String {
    h[header::LOCATION].to_str().unwrap().to_string()
}

/// The browser's way to a signed-in session for `user`: the callback's answer.
async fn sign_in(app: &Router, user: &str) -> (StatusCode, HeaderMap, String) {
    let (s, h, _) = send(
        app,
        Request::get("/systems/server/config")
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(s, StatusCode::SEE_OTHER);
    assert_eq!(
        location(&h),
        "/auth/login?next=%2Fsystems%2Fserver%2Fconfig"
    );
    let (s, h, _) = send(app, Request::get(location(&h)).body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::SEE_OTHER);
    let authorize = format!("{}&login_hint={user}", location(&h));
    assert!(
        authorize.contains("redirect_uri=http%3A%2F%2Fconsole.test%2Fauth%2Fcallback"),
        "{authorize}"
    );
    assert!(
        authorize.contains("code_challenge_method=S256"),
        "{authorize}"
    );
    // the provider: answers with a redirect to the callback, which the test follows by hand
    let callback = tokio::task::spawn_blocking(move || {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .max_redirects(0)
            .build()
            .into();
        let res = agent.get(&authorize).call().unwrap();
        res.headers()["location"].to_str().unwrap().to_string()
    })
    .await
    .unwrap();
    let path = callback
        .strip_prefix(PUBLIC)
        .expect("back to the daemon's public address")
        .to_string();
    send(app, Request::get(path).body(Body::empty()).unwrap()).await
}

fn cookie(h: &HeaderMap) -> String {
    h[header::SET_COOKIE]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_string()
}

#[tokio::test(flavor = "multi_thread")]
async fn an_operator_signs_in_and_gets_a_session_cookie() {
    let (_, app) = setup(Mode::Good).await;
    let (s, h, body) = sign_in(&app, "alice").await;
    assert_eq!(s, StatusCode::SEE_OTHER, "{body}");
    assert_eq!(location(&h), "/systems/server/config");
    let set = h[header::SET_COOKIE].to_str().unwrap();
    assert!(set.starts_with("golconda_session="), "{set}");
    assert!(
        set.contains("HttpOnly") && set.contains("SameSite=Lax") && set.contains("Path=/"),
        "{set}"
    );
    // http in the public address: no Secure (a browser would drop the cookie)
    assert!(!set.contains("Secure"), "{set}");
    // the session names who and at what level, as JSON
    let req = Request::get("/auth/me")
        .header(header::COOKIE, cookie(&h))
        .body(Body::empty())
        .unwrap();
    let (s, _, me) = send(&app, req).await;
    assert_eq!(s, StatusCode::OK, "{me}");
    let me: Value = serde_json::from_str(&me).unwrap();
    assert_eq!(
        me,
        json!({ "id": "id-alice", "name": "Alice", "level": "operator" })
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reader_gets_read_only_and_rs256_works() {
    let (_, app) = setup(Mode::Rs256).await;
    let (s, h, body) = sign_in(&app, "bob").await;
    assert_eq!(s, StatusCode::SEE_OTHER, "{body}");
    let req = Request::get("/auth/me")
        .header(header::COOKIE, cookie(&h))
        .body(Body::empty())
        .unwrap();
    let (_, _, me) = send(&app, req).await;
    assert!(me.contains(r#""level":"read-only""#), "{me}");
}

#[tokio::test(flavor = "multi_thread")]
async fn someone_in_neither_group_is_refused() {
    let (_, app) = setup(Mode::Good).await;
    let (s, h, body) = sign_in(&app, "carol").await;
    assert_eq!(s, StatusCode::FORBIDDEN, "{body}");
    assert!(
        body.contains("Carol is in neither golconda-operators nor golconda-readers"),
        "{body}"
    );
    assert!(h.get(header::SET_COOKIE).is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn tokens_that_do_not_check_are_refused() {
    for mode in [
        Mode::WrongAudience,
        Mode::WrongIssuer,
        Mode::Expired,
        Mode::WrongNonce,
        Mode::UnknownKey,
        Mode::AlgNone,
        Mode::AlgHs256,
        Mode::AlgMislabeled,
        Mode::NotYetValid,
        Mode::TwoAudiencesNoAzp,
        Mode::TwoAudiencesOtherAzp,
        Mode::Crit,
        Mode::EncryptionKey,
        Mode::KeyForAnotherAlg,
    ] {
        let (_, app) = setup(mode).await;
        let (s, h, body) = sign_in(&app, "alice").await;
        assert_eq!(s, StatusCode::BAD_REQUEST, "{mode:?}: {body}");
        assert!(h.get(header::SET_COOKIE).is_none(), "{mode:?}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn tokens_that_check_in_other_ways_are_taken() {
    for mode in [Mode::TwoAudiencesAzp, Mode::NoKid] {
        let (_, app) = setup(mode).await;
        let (s, _, body) = sign_in(&app, "alice").await;
        assert_eq!(s, StatusCode::SEE_OTHER, "{mode:?}: {body}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_state_is_good_once_and_only_from_this_daemon() {
    let (_, app) = setup(Mode::Good).await;
    let (_, h, _) = send(
        &app,
        Request::get("/auth/login").body(Body::empty()).unwrap(),
    )
    .await;
    let authorize = location(&h);
    let state = authorize
        .split("state=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap()
        .to_string();
    // a state this daemon never gave out
    let (s, _, _) = send(
        &app,
        Request::get("/auth/callback?code=c&state=forged")
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    // the real one, once with a code the provider never gave: the state is spent all the same
    let uri = format!("/auth/callback?code=nope&state={state}");
    let (s, _, _) = send(&app, Request::get(&uri).body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    let (s, _, body) = send(&app, Request::get(&uri).body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::BAD_REQUEST);
    assert!(body.contains("sign-in expired or unknown"), "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn next_stays_on_this_site() {
    let (_, app) = setup(Mode::Good).await;
    for next in [
        "//evil.example/x",
        "https://evil.example/",
        "%2F%2Fevil.example",
        "/\\evil.example",
    ] {
        let (_, h, _) = send(
            &app,
            Request::get(format!("/auth/login?next={next}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await;
        let authorize = location(&h);
        // finish the sign-in and see where it lands
        let callback = tokio::task::spawn_blocking(move || {
            let agent: ureq::Agent = ureq::Agent::config_builder()
                .max_redirects(0)
                .build()
                .into();
            let res = agent
                .get(&format!("{authorize}&login_hint=alice"))
                .call()
                .unwrap();
            res.headers()["location"].to_str().unwrap().to_string()
        })
        .await
        .unwrap();
        let (s, h, _) = send(
            &app,
            Request::get(callback.strip_prefix(PUBLIC).unwrap())
                .body(Body::empty())
                .unwrap(),
        )
        .await;
        assert_eq!(s, StatusCode::SEE_OTHER);
        assert_eq!(location(&h), "/", "{next}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_session_json_gets_401_and_sign_out_ends_it() {
    let (_, app) = setup(Mode::Good).await;
    let req = Request::get("/systems/server/config")
        .header(header::ACCEPT, "application/json")
        .body(Body::empty())
        .unwrap();
    let (s, _, _) = send(&app, req).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // a cookie the daemon never gave out is no session
    let req = Request::get("/auth/me")
        .header(header::COOKIE, "golconda_session=forged")
        .body(Body::empty())
        .unwrap();
    assert_eq!(send(&app, req).await.0, StatusCode::UNAUTHORIZED);
    let (_, h, _) = sign_in(&app, "alice").await;
    let c = cookie(&h);
    let req = Request::post("/auth/logout")
        .header(header::COOKIE, &c)
        .body(Body::empty())
        .unwrap();
    let (s, h, _) = send(&app, req).await;
    assert_eq!(s, StatusCode::SEE_OTHER);
    assert!(
        h[header::SET_COOKIE]
            .to_str()
            .unwrap()
            .contains("Max-Age=0")
    );
    let req = Request::get("/auth/me")
        .header(header::COOKIE, &c)
        .body(Body::empty())
        .unwrap();
    assert_eq!(send(&app, req).await.0, StatusCode::UNAUTHORIZED);
}

#[tokio::test(flavor = "multi_thread")]
async fn only_the_public_host_is_served() {
    let (_, app) = setup(Mode::Good).await;
    let status = |host: &'static str| {
        let app = app.clone();
        async move {
            let req = Request::get(golcondad::pages::stylesheet()).header(header::HOST, host);
            app.oneshot(req.body(Body::empty()).unwrap())
                .await
                .unwrap()
                .status()
        }
    };
    assert_eq!(status("console.test").await, StatusCode::OK);
    assert_eq!(
        status("127.0.0.1:8796").await,
        StatusCode::MISDIRECTED_REQUEST
    );
    assert_eq!(
        status("evil.example").await,
        StatusCode::MISDIRECTED_REQUEST
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs iets and the Golconda checkout"]
async fn a_signed_in_page_names_who_and_offers_sign_out() {
    let (_, app) = setup(Mode::Good).await;
    let (_, h, _) = sign_in(&app, "alice").await;
    let req = Request::get("/systems/server/config")
        .header(header::COOKIE, cookie(&h))
        .body(Body::empty())
        .unwrap();
    let (s, _, body) = send(&app, req).await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(body.contains("Alice · operator"), "{body}");
    assert!(
        body.contains(r#"<form method="post" action="/auth/logout">"#),
        "{body}"
    );
}

#[tokio::test]
async fn the_issuer_must_use_https_except_on_loopback() {
    let cfg = |issuer: &str| OidcConfig {
        issuer: issuer.into(),
        client_id: "console".into(),
        client_secret: None,
        public_url: PUBLIC.into(),
        operator_group: "o".into(),
        read_only_group: "r".into(),
        ca_pem: None,
        cli_client_id: None,
    };
    let e = tokio::task::spawn_blocking(move || Oidc::discover(cfg("http://idp.example")).err())
        .await
        .unwrap();
    assert!(e.unwrap().contains("https"));
}

/// The stub's discovery document and keys over https, with a certificate from the test CA,
/// on a thread of its own: the daemon trusts it only with that CA.
fn https_stub() -> String {
    let certs =
        vec![CertificateDer::from_pem_slice(include_bytes!("fixtures/tls-server.pem")).unwrap()];
    let key = PrivateKeyDer::from_pem_slice(include_bytes!("fixtures/tls-server.key")).unwrap();
    let config = Arc::new(
        rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .unwrap(),
    );
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let issuer = format!("https://{}", listener.local_addr().unwrap());
    let doc = json!({
        "issuer": issuer,
        "authorization_endpoint": format!("{issuer}/authorize"),
        "token_endpoint": format!("{issuer}/token"),
        "jwks_uri": format!("{issuer}/jwks"),
    });
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let conn = rustls::ServerConnection::new(config.clone()).unwrap();
            let mut tls = rustls::StreamOwned::new(conn, stream);
            let mut req = Vec::new();
            let mut buf = [0u8; 1024];
            while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                match tls.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => req.extend_from_slice(&buf[..n]),
                }
            }
            let path = String::from_utf8_lossy(&req)
                .split(' ')
                .nth(1)
                .unwrap_or("")
                .to_string();
            let body = if path == "/jwks" {
                json!({ "keys": [] })
            } else {
                doc.clone()
            }
            .to_string();
            let _ = write!(
                tls,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = tls.flush();
        }
    });
    issuer
}

#[tokio::test]
async fn a_provider_behind_our_own_ca_is_trusted_with_the_ca_file_only() {
    let issuer = https_stub();
    let cfg = |ca: Option<&str>| OidcConfig {
        issuer: issuer.clone(),
        client_id: "console".into(),
        client_secret: None,
        public_url: PUBLIC.into(),
        operator_group: "o".into(),
        read_only_group: "r".into(),
        ca_pem: ca.map(str::to_string),
        cli_client_id: None,
    };
    let (without, with) = (cfg(None), cfg(Some(include_str!("fixtures/tls-ca.pem"))));
    let e = tokio::task::spawn_blocking(move || Oidc::discover(without).err())
        .await
        .unwrap();
    assert!(
        e.expect("refused without the CA")
            .to_lowercase()
            .contains("certificate")
    );
    let ok = tokio::task::spawn_blocking(move || Oidc::discover(with).map(drop))
        .await
        .unwrap();
    assert!(ok.is_ok(), "{ok:?}");
}

impl Stub {
    /// An ID token for `user`, meant for `aud`, as the device flow gives the CLI.
    fn mint(&self, user: &str, aud: &str) -> String {
        self.token(&Grant {
            user: user.into(),
            aud: aud.into(),
            nonce: String::new(),
            challenge: String::new(),
            redirect_uri: String::new(),
        })
    }
}

async fn with_bearer(app: &Router, token: &str) -> (StatusCode, String) {
    let (s, _, body) = send(
        app,
        Request::get("/auth/me")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .body(Body::empty())
            .unwrap(),
    )
    .await;
    (s, body)
}

#[tokio::test(flavor = "multi_thread")]
async fn the_cli_learns_where_to_sign_in() {
    let (stub, app) = setup(Mode::Good).await;
    let (s, _, body) = send(
        &app,
        Request::get("/auth/device").body(Body::empty()).unwrap(),
    )
    .await;
    assert_eq!(s, StatusCode::OK);
    let v: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["issuer"], stub.issuer.as_str());
    assert_eq!(v["clientId"], "golconda-cli");
    assert!(
        v["scope"]
            .as_str()
            .unwrap()
            .split(' ')
            .any(|s| s == "openid")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bearer_token_for_the_cli_client_signs_in() {
    let (stub, app) = setup(Mode::Good).await;
    let (s, body) = with_bearer(&app, &stub.mint("alice", "golconda-cli")).await;
    assert_eq!(s, StatusCode::OK, "{body}");
    let v: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(
        (v["id"].as_str(), v["level"].as_str()),
        (Some("id-alice"), Some("operator"))
    );
    let (s, body) = with_bearer(&app, &stub.mint("bob", "golconda-cli")).await;
    assert_eq!(s, StatusCode::OK, "{body}");
    assert!(body.contains("read-only"), "{body}");
    let (s, body) = with_bearer(&app, &stub.mint("carol", "golconda-cli")).await;
    assert_eq!(s, StatusCode::FORBIDDEN, "{body}");
}

#[tokio::test(flavor = "multi_thread")]
async fn bearer_tokens_that_do_not_check_are_refused() {
    let (stub, app) = setup(Mode::Good).await;
    // the web client's token is not the CLI's
    let (s, body) = with_bearer(&app, &stub.mint("alice", "console")).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    assert!(body.contains("meant for"), "{body}");
    for mode in [
        Mode::Expired,
        Mode::UnknownKey,
        Mode::WrongIssuer,
        Mode::AlgNone,
    ] {
        *stub.mode.lock().unwrap() = mode;
        let (s, body) = with_bearer(&app, &stub.mint("alice", "golconda-cli")).await;
        assert_eq!(s, StatusCode::UNAUTHORIZED, "{mode:?}: {body}");
    }
    let (s, _) = with_bearer(&app, "not.a-token").await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_cli_client_there_is_no_bearer_and_no_device_flow() {
    let (stub, app) = setup_cli(Mode::Good, None).await;
    let (s, _, _) = send(
        &app,
        Request::get("/auth/device").body(Body::empty()).unwrap(),
    )
    .await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    let (s, body) = with_bearer(&app, &stub.mint("alice", "golconda-cli")).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    assert!(body.contains("no bearer"), "{body}");
}
