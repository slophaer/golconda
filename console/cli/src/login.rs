//! Signing the CLI in to a golcondad through OIDC's device flow (RFC 8628).
//!
//! The daemon names the provider and the CLI's public client (`/auth/device`). The CLI asks
//! the provider for a code, the operator confirms it in a browser, and the CLI polls for the
//! tokens. It keeps the ID token and the refresh token per daemon in
//! `$XDG_STATE_HOME/golconda/tokens.json` (mode 0600) and sends the ID token as a bearer; the
//! daemon checks it. A token about to expire is renewed with the refresh token.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::{Map, Value, json};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, error, result};
use tempfile::NamedTempFile;

type Result<T> = result::Result<T, Box<dyn error::Error>>;

/// A token this close to its expiry is renewed first.
const MARGIN: u64 = 60;
const DEVICE_GRANT: &str = "urn:ietf:params:oauth:grant-type:device_code";

/// The HTTP client: no redirects, statuses as answers, and with `GOLCONDA_CA_FILE` the
/// certificates of our own CA as the only roots.
pub fn agent() -> Result<ureq::Agent> {
    let roots = match env::var_os("GOLCONDA_CA_FILE") {
        None => ureq::tls::RootCerts::WebPki,
        Some(f) => {
            let pem = fs::read(&f)
                .map_err(|e| format!("GOLCONDA_CA_FILE {}: {e}", f.to_string_lossy()))?;
            let certs: Vec<_> = ureq::tls::parse_pem(&pem)
                .filter_map(|i| match i {
                    Ok(ureq::tls::PemItem::Certificate(c)) => Some(c),
                    _ => None,
                })
                .collect();
            if certs.is_empty() {
                return Err("GOLCONDA_CA_FILE holds no PEM certificate".into());
            }
            ureq::tls::RootCerts::new_with_certs(&certs)
        }
    };
    Ok(ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .timeout_global(Some(Duration::from_secs(30)))
        .tls_config(ureq::tls::TlsConfig::builder().root_certs(roots).build())
        .build()
        .into())
}

fn json_of(res: ureq::http::Response<ureq::Body>) -> (u16, Value) {
    let status = res.status().as_u16();
    let text = res.into_body().read_to_string().unwrap_or_default();
    (status, serde_json::from_str(&text).unwrap_or(Value::Null))
}

fn get(agent: &ureq::Agent, url: &str) -> Result<Value> {
    let res = agent
        .get(url)
        .header("Accept", "application/json")
        .call()
        .map_err(|e| format!("GET {url}: {e}"))?;
    match json_of(res) {
        (200, v) => Ok(v),
        (s, v) => Err(format!(
            "GET {url}: {s}: {}",
            v["error"].as_str().unwrap_or("no answer")
        )
        .into()),
    }
}

fn post_form(agent: &ureq::Agent, url: &str, form: &[(&str, &str)]) -> Result<(u16, Value)> {
    let body: Vec<String> = form
        .iter()
        .map(|(k, v)| format!("{k}={}", encode(v)))
        .collect();
    let res = agent
        .post(url)
        .header("Accept", "application/json")
        .header("Content-Type", "application/x-www-form-urlencoded")
        .send(body.join("&"))
        .map_err(|e| format!("POST {url}: {e}"))?;
    Ok(json_of(res))
}

/// `s` with everything but the unreserved characters percent-encoded (RFC 3986).
fn encode(s: &str) -> String {
    s.bytes().fold(String::new(), |mut out, b| {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(char::from(b));
        } else {
            out += &format!("%{b:02X}");
        }
        out
    })
}

/// A provider on this host may use plain http (the tests' stub); any other must use https.
fn is_loopback(url: &str) -> bool {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let authority = rest.split('/').next().unwrap_or("");
    let host = match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => authority.split(':').next().unwrap_or(""),
    };
    matches!(host, "localhost" | "127.0.0.1" | "::1")
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// The claims of a JWT, unchecked: the daemon checks the token, the CLI only reads when it
/// expires and whom it names.
fn claims(token: &str) -> Option<Value> {
    let body = token.split('.').nth(1)?;
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(body).ok()?).ok()
}

/// The tokens file: one entry per daemon URL.
fn store_path() -> Result<PathBuf> {
    let base = env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .ok_or("neither XDG_STATE_HOME nor HOME is set")?;
    Ok(base.join("golconda/tokens.json"))
}

fn key(server: &str) -> String {
    server.trim_end_matches('/').to_string()
}

fn load() -> Result<Map<String, Value>> {
    let path = store_path()?;
    match fs::read(&path) {
        Ok(b) => Ok(serde_json::from_slice::<Value>(&b)
            .map_err(|e| format!("{}: {e}", path.display()))?
            .as_object()
            .cloned()
            .unwrap_or_default()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Map::new()),
        Err(e) => Err(format!("{}: {e}", path.display()).into()),
    }
}

/// Writes the tokens: a new file in the same directory (0700), 0600 from the start, renamed
/// over the old one.
fn save(all: &Map<String, Value>) -> Result<()> {
    let path = store_path()?;
    let dir = path.parent().ok_or("the tokens file has no directory")?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?;
    let mut f = NamedTempFile::new_in(dir)?;
    f.as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    f.write_all(format!("{:#}\n", Value::Object(all.clone())).as_bytes())?;
    f.as_file().sync_all()?;
    f.persist(&path)
        .map_err(|e| format!("{}: {}", path.display(), e.error))?;
    Ok(())
}

/// Signs in to `server`: prints the code and where to enter it on `tell`, polls until the
/// operator has confirmed it, keeps the tokens. Returns who the daemon says that is.
pub fn login(server: &str, tell: &mut dyn Write) -> Result<String> {
    let agent = agent()?;
    let base = key(server);
    let flow = get(&agent, &format!("{base}/auth/device"))?;
    let (Some(issuer), Some(client)) = (flow["issuer"].as_str(), flow["clientId"].as_str()) else {
        return Err(format!("{base}/auth/device names no issuer and client").into());
    };
    if !issuer.starts_with("https://") && !is_loopback(issuer) {
        return Err(format!("the issuer {issuer} must use https").into());
    }
    let scope = flow["scope"].as_str().unwrap_or("openid");
    let discovery = format!(
        "{}/.well-known/openid-configuration",
        issuer.trim_end_matches('/')
    );
    let d = get(&agent, &discovery)?;
    if d["issuer"] != issuer {
        return Err(format!("{discovery} names the issuer {}", d["issuer"]).into());
    }
    let (Some(device), Some(token)) = (
        d["device_authorization_endpoint"].as_str(),
        d["token_endpoint"].as_str(),
    ) else {
        return Err(format!("{issuer} offers no device flow").into());
    };
    let (status, code) = post_form(&agent, device, &[("client_id", client), ("scope", scope)])?;
    let (Some(device_code), Some(user_code), Some(uri)) = (
        code["device_code"].as_str(),
        code["user_code"].as_str(),
        code["verification_uri"].as_str(),
    ) else {
        return Err(format!("{device}: {status}: {}", code["error"]).into());
    };
    match code["verification_uri_complete"].as_str() {
        Some(full) => writeln!(tell, "Open {full}\n(or {uri} and enter {user_code})")?,
        None => writeln!(tell, "Open {uri} and enter {user_code}")?,
    }
    let mut interval = code["interval"].as_u64().unwrap_or(5);
    let deadline = Instant::now() + Duration::from_secs(code["expires_in"].as_u64().unwrap_or(600));
    let tokens = loop {
        if Instant::now() > deadline {
            return Err("the code expired: run golconda login again".into());
        }
        thread::sleep(Duration::from_secs(interval));
        let (status, v) = post_form(
            &agent,
            token,
            &[
                ("grant_type", DEVICE_GRANT),
                ("device_code", device_code),
                ("client_id", client),
            ],
        )?;
        match (status, v["error"].as_str()) {
            (200, _) => break v,
            (_, Some("authorization_pending")) => {}
            (_, Some("slow_down")) => interval += 5,
            (_, Some("access_denied")) => return Err("the sign-in was refused".into()),
            (_, Some("expired_token")) => {
                return Err("the code expired: run golconda login again".into());
            }
            (s, e) => return Err(format!("{token}: {s}: {}", e.unwrap_or("no answer")).into()),
        }
    };
    let id_token = tokens["id_token"]
        .as_str()
        .ok_or("the provider gave no ID token (is openid in the scope?)")?;
    let mut all = load()?;
    all.insert(
        base.clone(),
        json!({
            "idToken": id_token,
            "refreshToken": tokens["refresh_token"],
            "tokenEndpoint": token,
            "clientId": client,
        }),
    );
    save(&all)?;
    let me = whoami(&agent, &base, id_token)?;
    Ok(format!(
        "signed in to {base} as {} ({})\n",
        me["name"].as_str().unwrap_or("?"),
        me["level"].as_str().unwrap_or("?")
    ))
}

fn whoami(agent: &ureq::Agent, base: &str, token: &str) -> Result<Value> {
    let url = format!("{base}/auth/me");
    let res = agent
        .get(&url)
        .header("Accept", "application/json")
        .header("Authorization", &format!("Bearer {token}"))
        .call()
        .map_err(|e| format!("GET {url}: {e}"))?;
    match json_of(res) {
        (200, v) => Ok(v),
        (s, v) => Err(format!(
            "{base} refused the token: {s}: {}",
            v["error"].as_str().unwrap_or("")
        )
        .into()),
    }
}

/// The token to send to `server`, renewed first when it is about to expire; None when this
/// CLI never signed in there (a development daemon needs none).
pub fn bearer(agent: &ureq::Agent, server: &str) -> Result<Option<String>> {
    let base = key(server);
    let mut all = load()?;
    let Some(entry) = all.get(&base).cloned() else {
        return Ok(None);
    };
    let id_token = entry["idToken"].as_str().unwrap_or("");
    let exp = claims(id_token)
        .and_then(|c| c["exp"].as_u64())
        .unwrap_or(0);
    if exp > now() + MARGIN {
        return Ok(Some(id_token.to_string()));
    }
    let again = || format!("the sign-in to {base} has expired: run golconda login --server {base}");
    let (Some(refresh), Some(token), Some(client)) = (
        entry["refreshToken"].as_str(),
        entry["tokenEndpoint"].as_str(),
        entry["clientId"].as_str(),
    ) else {
        return Err(again().into());
    };
    let (status, v) = post_form(
        agent,
        token,
        &[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", client),
        ],
    )?;
    let Some(fresh) = v["id_token"].as_str().filter(|_| status == 200) else {
        return Err(again().into());
    };
    let mut renewed = entry.clone();
    renewed["idToken"] = fresh.into();
    if let Some(r) = v["refresh_token"].as_str() {
        renewed["refreshToken"] = r.into();
    }
    all.insert(base, renewed);
    save(&all)?;
    Ok(Some(fresh.to_string()))
}

/// Forgets the tokens for `server`; whether there were any.
pub fn logout(server: &str) -> Result<bool> {
    let mut all = load()?;
    let had = all.remove(&key(server)).is_some();
    if had {
        save(&all)?;
    }
    Ok(had)
}
