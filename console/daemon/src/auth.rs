//! Sign-in through OpenID Connect: the authorization code flow with PKCE, a session cookie.
//!
//! The daemon is the client. It reads the provider's discovery document and keys at start,
//! sends the browser to the provider with a state, a nonce and a PKCE challenge, takes the
//! code back at /auth/callback, exchanges it for an ID token and checks that token itself:
//! the signature (RS256 or ES256, with `ring`; any other algorithm is refused), the issuer,
//! the audience, the expiry and the nonce. The `groups` claim gives the level. Sessions live
//! in memory: a restart signs everyone out.

use crate::app::{Identity, Level};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{self, UnparsedPublicKey};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// A lock that a panicked holder left behind is still good: every update here is one call.
fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// How long a session lasts, and how long a browser has to come back from the provider.
const SESSION: Duration = Duration::from_hours(12);
const PENDING: Duration = Duration::from_secs(600);
/// Clock difference allowed between the provider and this host.
const LEEWAY: i64 = 60;

pub const COOKIE: &str = "golconda_session";

#[derive(Debug, Clone)]
pub struct OidcConfig {
    pub issuer: String,
    pub client_id: String,
    pub client_secret: Option<String>,
    /// where browsers reach this daemon: the redirect URI and the one Host it answers
    pub public_url: String,
    pub operator_group: String,
    pub read_only_group: String,
    /// PEM certificates the provider's TLS certificate must chain to, such as our own CA's;
    /// None: the public roots built in (webpki-roots)
    pub ca_pem: Option<String>,
}

struct Pending {
    verifier: String,
    nonce: String,
    next: String,
    since: Instant,
}

struct Session {
    who: Identity,
    since: Instant,
}

pub struct Oidc {
    pub config: OidcConfig,
    authorize: String,
    token: String,
    jwks_uri: String,
    keys: RwLock<Vec<Value>>,
    pending: Mutex<HashMap<String, Pending>>,
    sessions: Mutex<HashMap<String, Session>>,
    agent: ureq::Agent,
    rng: SystemRandom,
}

/// Why a sign-in failed.
#[derive(Debug, thiserror::Error)]
pub enum Refused {
    /// the browser's request: an unknown or spent state, a bad token (400)
    #[error("{0}")]
    Bad(String),
    /// a valid identity in neither group (403)
    #[error("{0}")]
    NotAllowed(String),
}

fn bad(m: impl Into<String>) -> Refused {
    Refused::Bad(m.into())
}

/// `s` with everything but the unreserved characters percent-encoded (RFC 3986).
pub fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out += &format!("%{b:02X}");
        }
    }
    out
}

/// The host of a URL, without user, port or path: what a browser sends in Host.
fn host(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let authority = rest.split('/').next().unwrap_or("");
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => authority.split(':').next().unwrap_or(""),
    }
}

pub fn is_loopback(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1")
}

impl Oidc {
    /// Read the provider's discovery document and keys. The issuer must use https, except on
    /// loopback (a provider on this host, as the tests' stub).
    pub fn discover(config: OidcConfig) -> Result<Oidc, String> {
        if !config.issuer.starts_with("https://") && !is_loopback(host(&config.issuer)) {
            return Err(format!("the issuer {} must use https", config.issuer));
        }
        let roots = match &config.ca_pem {
            None => ureq::tls::RootCerts::WebPki,
            Some(pem) => {
                let certs: Vec<_> = ureq::tls::parse_pem(pem.as_bytes())
                    .filter_map(|item| match item {
                        Ok(ureq::tls::PemItem::Certificate(c)) => Some(c),
                        _ => None,
                    })
                    .collect();
                if certs.is_empty() {
                    return Err("the CA file holds no PEM certificate".into());
                }
                ureq::tls::RootCerts::new_with_certs(&certs)
            }
        };
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(10)))
            .max_redirects(0)
            .tls_config(ureq::tls::TlsConfig::builder().root_certs(roots).build())
            .build()
            .into();
        let url = format!(
            "{}/.well-known/openid-configuration",
            config.issuer.trim_end_matches('/')
        );
        let d = get_json(&agent, &url)?;
        if d["issuer"] != config.issuer.as_str() {
            return Err(format!("{url} names the issuer {}", d["issuer"]));
        }
        let field = |k: &str| {
            d[k].as_str()
                .map(str::to_string)
                .ok_or(format!("{url} has no {k}"))
        };
        let oidc = Oidc {
            authorize: field("authorization_endpoint")?,
            token: field("token_endpoint")?,
            jwks_uri: field("jwks_uri")?,
            config,
            keys: RwLock::default(),
            pending: Mutex::default(),
            sessions: Mutex::default(),
            agent,
            rng: SystemRandom::new(),
        };
        oidc.fetch_keys()?;
        Ok(oidc)
    }

    fn fetch_keys(&self) -> Result<(), String> {
        let set = get_json(&self.agent, &self.jwks_uri)?;
        let keys = set["keys"].as_array().cloned().unwrap_or_default();
        *self.keys.write().unwrap() = keys;
        Ok(())
    }

    /// The one Host this daemon answers to.
    pub fn public_host(&self) -> &str {
        host(&self.config.public_url)
    }

    /// The cookie is Secure when browsers reach the daemon over https.
    pub fn secure(&self) -> bool {
        self.config.public_url.starts_with("https://")
    }

    fn random(&self) -> String {
        let mut b = [0u8; 32];
        self.rng.fill(&mut b).expect("the system's random source");
        URL_SAFE_NO_PAD.encode(b)
    }

    fn redirect_uri(&self) -> String {
        format!(
            "{}/auth/callback",
            self.config.public_url.trim_end_matches('/')
        )
    }

    /// Start a sign-in that returns to `next`: the provider's address to send the browser to.
    pub fn begin(&self, next: &str) -> String {
        let (state, nonce, verifier) = (self.random(), self.random(), self.random());
        let challenge = URL_SAFE_NO_PAD.encode(ring::digest::digest(
            &ring::digest::SHA256,
            verifier.as_bytes(),
        ));
        let mut pending = locked(&self.pending);
        pending.retain(|_, p| p.since.elapsed() < PENDING);
        pending.insert(
            state.clone(),
            Pending {
                verifier,
                nonce: nonce.clone(),
                next: next.to_string(),
                since: Instant::now(),
            },
        );
        let sep = if self.authorize.contains('?') {
            '&'
        } else {
            '?'
        };
        format!(
            "{}{sep}response_type=code&client_id={}&redirect_uri={}&scope={}&state={state}\
             &nonce={nonce}&code_challenge={challenge}&code_challenge_method=S256",
            self.authorize,
            encode(&self.config.client_id),
            encode(&self.redirect_uri()),
            encode("openid profile email groups"),
        )
    }

    /// Finish a sign-in: exchange the code, check the ID token, start a session. Blocking.
    /// Returns the session id and where to go next.
    pub fn finish(&self, code: &str, state: &str) -> Result<(String, String), Refused> {
        // a state is good once, and only for a while
        let p = locked(&self.pending)
            .remove(state)
            // shortcut: untested, it needs a clock the tests can move; a state is 32 random
            // bytes and good once, so an old one is no easier to use than a guessed one
            .filter(|p| p.since.elapsed() < PENDING)
            .ok_or_else(|| bad("sign-in expired or unknown: sign in again"))?;
        let mut form = vec![
            ("grant_type", "authorization_code".to_string()),
            ("code", code.to_string()),
            ("redirect_uri", self.redirect_uri()),
            ("client_id", self.config.client_id.clone()),
            ("code_verifier", p.verifier),
        ];
        if let Some(s) = &self.config.client_secret {
            form.push(("client_secret", s.clone()));
        }
        let body: Vec<String> = form
            .iter()
            .map(|(k, v)| format!("{k}={}", encode(v)))
            .collect();
        let res = self
            .agent
            .post(&self.token)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .config()
            .http_status_as_error(false)
            .build()
            .send(body.join("&"))
            .map_err(|e| bad(format!("the token endpoint: {e}")))?;
        let status = res.status();
        let answer: Value = res
            .into_body()
            .read_to_string()
            .ok()
            .and_then(|b| serde_json::from_str(&b).ok())
            .ok_or_else(|| bad("the token endpoint answered no JSON"))?;
        if !status.is_success() {
            return Err(bad(format!(
                "the token endpoint refused the code: {}",
                answer["error"]
            )));
        }
        let token = answer["id_token"]
            .as_str()
            .ok_or_else(|| bad("the token endpoint gave no ID token"))?;
        let claims = match self.verify(token) {
            Err(e) if e.contains("unknown key") => {
                // the provider may have rotated its keys since start
                self.fetch_keys().map_err(bad)?;
                self.verify(token)
            }
            r => r,
        }
        .map_err(|e| bad(format!("the ID token: {e}")))?;
        if claims["nonce"] != p.nonce.as_str() {
            return Err(bad("the ID token: its nonce is not this sign-in's"));
        }
        let who = self.identity(&claims)?;
        let id = self.random();
        let mut sessions = locked(&self.sessions);
        sessions.retain(|_, s| s.since.elapsed() < SESSION);
        sessions.insert(
            id.clone(),
            Session {
                who,
                since: Instant::now(),
            },
        );
        Ok((id, safe_next(&p.next)))
    }

    /// The claims of an ID token whose signature, issuer, audience and expiry check.
    fn verify(&self, token: &str) -> Result<Value, String> {
        let parts: Vec<&str> = token.split('.').collect();
        let [head, body, sig] = parts[..] else {
            return Err("not a signed JWT".into());
        };
        let json = |p: &str| -> Result<Value, String> {
            let b = URL_SAFE_NO_PAD.decode(p).map_err(|e| e.to_string())?;
            serde_json::from_slice(&b).map_err(|e| e.to_string())
        };
        let header = json(head)?;
        // an extension the token says must be understood, and this code does not know any
        if header.get("crit").is_some() {
            return Err("it names critical header extensions".into());
        }
        let alg = header["alg"].as_str().unwrap_or("");
        // the algorithm comes from the key's type, never from the token alone: only these two
        let (kty, scheme): (&str, &dyn signature::VerificationAlgorithm) = match alg {
            "RS256" => ("RSA", &signature::RSA_PKCS1_2048_8192_SHA256),
            "ES256" => ("EC", &signature::ECDSA_P256_SHA256_FIXED),
            a => return Err(format!("the algorithm {a:?} is not RS256 or ES256")),
        };
        let kid = header["kid"].as_str();
        let keys = self.keys.read().unwrap();
        // the keys that may have signed it: its type, not for encryption only, not for another
        // algorithm, its kid when it names one (without, each of them is tried)
        let candidates: Vec<&Value> = keys
            .iter()
            .filter(|k| k["kty"] == kty && k["use"] != "enc")
            .filter(|k| k["alg"].is_null() || k["alg"] == alg)
            .filter(|k| kid.is_none() || k["kid"].as_str() == kid)
            .collect();
        if candidates.is_empty() {
            return Err(format!("unknown key {kid:?}"));
        }
        let sig = URL_SAFE_NO_PAD.decode(sig).map_err(|e| e.to_string())?;
        let signed = format!("{head}.{body}");
        let checks = |key: &Value| -> Result<bool, String> {
            let b64 = |f: &str| {
                key[f]
                    .as_str()
                    .and_then(|s| URL_SAFE_NO_PAD.decode(s).ok())
                    .ok_or(format!("the key has no {f}"))
            };
            Ok(if kty == "RSA" {
                signature::RsaPublicKeyComponents {
                    n: b64("n")?,
                    e: b64("e")?,
                }
                .verify(
                    &signature::RSA_PKCS1_2048_8192_SHA256,
                    signed.as_bytes(),
                    &sig,
                )
                .is_ok()
            } else {
                if key["crv"] != "P-256" {
                    return Ok(false);
                }
                let mut point = vec![4u8];
                point.extend(b64("x")?);
                point.extend(b64("y")?);
                UnparsedPublicKey::new(scheme, point)
                    .verify(signed.as_bytes(), &sig)
                    .is_ok()
            })
        };
        let mut good = false;
        for key in candidates {
            if checks(key)? {
                good = true;
                break;
            }
        }
        if !good {
            return Err("its signature does not check".into());
        }
        self.check_claims(json(body)?)
    }

    /// The claims if they name this issuer and client and are in time.
    fn check_claims(&self, claims: Value) -> Result<Value, String> {
        if claims["iss"] != self.config.issuer.as_str() {
            return Err(format!("issued by {}", claims["iss"]));
        }
        let aud = match &claims["aud"] {
            Value::String(a) => a == &self.config.client_id,
            Value::Array(a) => a.iter().any(|x| x == self.config.client_id.as_str()),
            _ => false,
        };
        if !aud {
            return Err(format!("meant for {}", claims["aud"]));
        }
        // with more than one audience, the party it was issued to must be named, and be us
        let several = claims["aud"].as_array().is_some_and(|a| a.len() > 1);
        match claims.get("azp") {
            Some(azp) if azp != self.config.client_id.as_str() => {
                return Err(format!("issued to {azp}"));
            }
            None if several => return Err("several audiences and no azp".into()),
            _ => {}
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX));
        if claims["nbf"].as_i64().is_some_and(|nbf| nbf - LEEWAY > now) {
            return Err("it is not valid yet".into());
        }
        match claims["exp"].as_i64() {
            Some(exp) if exp + LEEWAY > now => Ok(claims),
            _ => Err("it has expired".into()),
        }
    }

    /// Who the claims name, and at what level their groups put them.
    fn identity(&self, claims: &Value) -> Result<Identity, Refused> {
        let name = ["name", "preferred_username", "email", "sub"]
            .iter()
            .find_map(|k| claims[*k].as_str())
            .unwrap_or("someone")
            .to_string();
        let groups: Vec<&str> = match &claims["groups"] {
            Value::Array(g) => g.iter().filter_map(Value::as_str).collect(),
            Value::String(g) => vec![g.as_str()],
            _ => vec![],
        };
        let c = &self.config;
        let level = if groups.contains(&c.operator_group.as_str()) {
            Level::Operator
        } else if groups.contains(&c.read_only_group.as_str()) {
            Level::ReadOnly
        } else {
            return Err(Refused::NotAllowed(format!(
                "{name} is in neither {} nor {}",
                c.operator_group, c.read_only_group
            )));
        };
        Ok(Identity {
            id: claims["sub"].as_str().unwrap_or("").to_string(),
            name,
            level,
        })
    }

    pub fn session(&self, id: &str) -> Option<Identity> {
        let sessions = locked(&self.sessions);
        let s = sessions.get(id)?;
        (s.since.elapsed() < SESSION).then(|| s.who.clone())
    }

    pub fn end(&self, id: &str) {
        locked(&self.sessions).remove(id);
    }
}

fn get_json(agent: &ureq::Agent, url: &str) -> Result<Value, String> {
    agent
        .get(url)
        .call()
        .map_err(|e| format!("{url}: {e}"))?
        .into_body()
        .read_to_string()
        .map_err(|e| format!("{url}: {e}"))
        .and_then(|b| serde_json::from_str(&b).map_err(|e| format!("{url}: no JSON: {e}")))
}

/// A path on this site to go to after sign-in; anything else (another site, `//host`,
/// `/\host`, which browsers read as one) is `/`.
pub fn safe_next(next: &str) -> String {
    let ok = next.starts_with('/')
        && !next.starts_with("//")
        && !next.starts_with("/\\")
        && !next.contains(['\r', '\n']);
    if ok { next.to_string() } else { "/".into() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hosts_and_encoding() {
        assert_eq!(host("https://console.example.com/x"), "console.example.com");
        assert_eq!(host("http://127.0.0.1:8796"), "127.0.0.1");
        assert_eq!(host("http://[::1]:80/"), "::1");
        assert_eq!(host("https://u@h.example:1/"), "h.example");
        assert_eq!(encode("a b/c?d=é"), "a%20b%2Fc%3Fd%3D%C3%A9");
    }

    #[test]
    fn next_is_a_path_on_this_site() {
        assert_eq!(
            safe_next("/systems/x/config?option=a"),
            "/systems/x/config?option=a"
        );
        for bad in [
            "//evil",
            "/\\evil",
            "https://evil",
            "evil",
            "",
            "/a\r\nSet-Cookie: x",
        ] {
            assert_eq!(safe_next(bad), "/", "{bad:?}");
        }
    }
}
