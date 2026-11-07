//! Where the TUI's data comes from: the daemon's JSON routes. A trait, so the tests can stand
//! in for the daemon.

use crate::login;
use serde_json::Value;

pub trait Source {
    /// GET `path` (from the daemon's root): the JSON of a 200, else what the daemon said.
    fn get(&self, path: &str) -> Result<Value, String>;
    /// POST `body` to `path`: the status and the JSON, whatever the status.
    fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String>;
}

/// The daemon over HTTP, with the token `golconda login` keeps for it.
pub struct Daemon {
    url: String,
    agent: ureq::Agent,
    bearer: Option<String>,
}

impl Daemon {
    pub fn new(url: &str) -> Result<Daemon, String> {
        let agent = login::agent().map_err(|e| e.to_string())?;
        let bearer = login::bearer(&agent, url).map_err(|e| e.to_string())?;
        Ok(Daemon {
            url: url.trim_end_matches('/').to_string(),
            agent,
            bearer,
        })
    }

    fn auth(&self) -> String {
        self.bearer
            .as_ref()
            .map(|t| format!("Bearer {t}"))
            .unwrap_or_default()
    }
}

fn json_of(res: ureq::http::Response<ureq::Body>) -> (u16, Value) {
    let status = res.status().as_u16();
    let text = res.into_body().read_to_string().unwrap_or_default();
    (status, serde_json::from_str(&text).unwrap_or(Value::Null))
}

impl Source for Daemon {
    fn get(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{path}", self.url);
        let mut r = self.agent.get(&url).header("Accept", "application/json");
        if self.bearer.is_some() {
            r = r.header("Authorization", &self.auth());
        }
        let res = r.call().map_err(|e| format!("GET {path}: {e}"))?;
        match json_of(res) {
            (200, v) => Ok(v),
            (s, v) => Err(format!(
                "{path}: {s}: {}",
                v["error"].as_str().unwrap_or("no answer")
            )),
        }
    }

    fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.url);
        let mut r = self
            .agent
            .post(&url)
            .header("Accept", "application/json")
            .header("Content-Type", "application/json");
        if self.bearer.is_some() {
            r = r.header("Authorization", &self.auth());
        }
        let res = r
            .send(body.to_string())
            .map_err(|e| format!("POST {path}: {e}"))?;
        Ok(json_of(res))
    }
}
