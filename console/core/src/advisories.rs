//! Known vulnerabilities of an image's packages, from OSV (https://osv.dev).
//!
//! Packages with a purl are asked for in one batch (`POST /v1/querybatch`), each vulnerability
//! found is read once (`GET /v1/vulns/ID`) for its summary and severity. The answers are kept
//! with the time they were asked, in memory and, given a file, on disk: a package is asked about
//! again only when its answer is older than the lifetime. OSV not answering is a report with an
//! error, never a failure; an older answer still shows, marked with its age.

use crate::packages::Package;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tempfile::NamedTempFile;

pub const OSV_URL: &str = "https://api.osv.dev";
/// How long an answer is good: a day. A refresh costs one batch query per 1000 packages and one
/// read per vulnerability not seen before, so the time is about freshness, not load; advisories
/// and upstream releases are acted on daily, and uptrack's datasources are polled no more often.
pub const LIFETIME: Duration = Duration::from_hours(24);
/// After a failure OSV is left alone this long, so a page view does not wait for it again.
const RETRY: Duration = Duration::from_secs(300);
/// Queries in one batch request: OSV's limit. A longer list is sent in several.
const BATCH: usize = 1000;
const TIMEOUT: Duration = Duration::from_secs(15);

/// One vulnerability OSV lists for a package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Advisory {
    pub id: String,
    pub summary: Option<String>,
    /// OSV's own word for it (LOW, MODERATE, HIGH, CRITICAL), when the record has one
    pub severity: Option<String>,
}

/// What was known about a list of packages at one time.
#[derive(Debug, Clone, Default)]
pub struct Report {
    /// Unix time of the oldest answer used; none when nothing is known
    pub checked_at: Option<u64>,
    /// why OSV could not be asked (or asked again), if so
    pub error: Option<String>,
    found: BTreeMap<String, Vec<Advisory>>,
}

/// A query as OSV takes it: a purl, and a version when the purl names none.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Query {
    purl: String,
    version: Option<String>,
}

/// The ids found for one query, and when.
#[derive(Debug, Clone)]
struct Answer {
    at: u64,
    ids: Vec<String>,
}

/// A vulnerability's record, and when it was read.
#[derive(Debug, Clone)]
struct Detail {
    at: u64,
    summary: Option<String>,
    severity: Option<String>,
}

#[derive(Debug, Default)]
struct State {
    answers: BTreeMap<String, Answer>,
    details: BTreeMap<String, Detail>,
    failed: Option<(Instant, String)>,
}

/// OSV's answers, asked for on demand and kept.
pub struct Advisories {
    base: String,
    file: Option<PathBuf>,
    lifetime: Duration,
    agent: ureq::Agent,
    state: Mutex<State>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// The purl types OSV has records for. OSV answers a query for any other type (`github`,
/// `generic`, `gnu`, `gitlab`, `sourceforge`, …) with no vulnerabilities at all, which looks
/// the same as a package that has none; so those are never asked about, and shown as not
/// covered. Each type here was checked against api.osv.dev with a version known to be
/// vulnerable. `apk` is left out: it answered nothing for the Alpine release tried.
const COVERED_TYPES: [&str; 16] = [
    "bitnami", "cargo", "composer", "cran", "deb", "gem", "golang", "hackage", "hex", "maven",
    "npm", "nuget", "pub", "pypi", "rpm", "swift",
];

/// OSV has records for the type of `purl`.
pub fn covers(purl: &str) -> bool {
    let Some(rest) = purl
        .get(..4)
        .filter(|scheme| scheme.eq_ignore_ascii_case("pkg:"))
        .map(|_| &purl[4..])
    else {
        return false;
    };
    let kind = rest.split('/').next().unwrap_or_default();
    rest.contains('/') && COVERED_TYPES.iter().any(|t| kind.eq_ignore_ascii_case(t))
}

/// The package has a purl of a type OSV has records for.
pub fn covered(p: &Package) -> bool {
    p.purl.as_deref().is_some_and(covers)
}

/// "just now", "5 min ago", "3 h ago", "2 days ago" for a time `secs` back.
pub fn ago(secs: u64) -> String {
    match secs {
        0..60 => "just now".into(),
        60..3600 => format!("{} min ago", secs / 60),
        3600..172_800 => format!("{} h ago", secs / 3600),
        _ => format!("{} days ago", secs / 86400),
    }
}

/// How long ago the Unix time `at` was.
pub fn since(at: u64) -> String {
    ago(now().saturating_sub(at))
}

impl Query {
    /// The query for `p`, if OSV can be asked: it needs a purl, and a version from the purl or
    /// the package (a query without one lists every vulnerability the package ever had).
    fn of(p: &Package) -> Option<Query> {
        let purl = p.purl.as_deref().filter(|purl| covers(purl))?;
        let name = purl.split(['?', '#']).next().unwrap_or(purl);
        let (kind, path) = name.strip_prefix("pkg:")?.split_once('/')?;
        if kind.is_empty() || path.is_empty() {
            return None;
        }
        let versioned = path.rsplit('/').next().is_some_and(|n| n.contains('@'));
        if versioned {
            return Some(Query {
                purl: purl.into(),
                version: None,
            });
        }
        (!p.version.is_empty()).then(|| Query {
            purl: purl.into(),
            version: Some(p.version.clone()),
        })
    }

    fn key(&self) -> String {
        match &self.version {
            Some(v) => format!("{}@{v}", self.purl),
            None => self.purl.clone(),
        }
    }

    fn to_json(&self) -> Value {
        let mut q = json!({ "package": { "purl": self.purl } });
        if let Some(v) = &self.version {
            q["version"] = json!(v);
        }
        q
    }
}

impl Advisory {
    pub fn to_json(&self) -> Value {
        json!({ "id": self.id, "summary": self.summary, "severity": self.severity })
    }
}

impl Report {
    /// The vulnerabilities of `p`; none when it was not asked about (no purl, or no answer yet).
    pub fn of(&self, p: &Package) -> Option<&[Advisory]> {
        let key = Query::of(p)?.key();
        self.found.get(&key).map(Vec::as_slice)
    }

    pub fn vulnerable(&self, p: &Package) -> bool {
        self.of(p).is_some_and(|a| !a.is_empty())
    }
}

impl Advisories {
    /// Asks the OSV server at `base`, keeping answers `lifetime` and in `file` when given.
    pub fn open(base: &str, file: Option<PathBuf>, lifetime: Duration) -> Advisories {
        let state = file.as_deref().map(read_cache).unwrap_or_default();
        Advisories {
            base: base.trim_end_matches('/').into(),
            file,
            lifetime,
            agent: ureq::Agent::config_builder()
                .timeout_global(Some(TIMEOUT))
                .tls_config(
                    ureq::tls::TlsConfig::builder()
                        .root_certs(ureq::tls::RootCerts::WebPki)
                        .build(),
                )
                .build()
                .into(),
            state: Mutex::new(state),
        }
    }

    /// Asks again only for what is missing or too old.
    pub fn check(&self, list: &[Package]) -> Report {
        let queries: BTreeMap<String, Query> = list
            .iter()
            .filter_map(Query::of)
            .map(|q| (q.key(), q))
            .collect();
        let mut st = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let t = now();
        let fresh = |a: &Answer| t.saturating_sub(a.at) < self.lifetime.as_secs();
        let stale: Vec<&Query> = queries
            .iter()
            .filter(|(k, _)| !st.answers.get(*k).is_some_and(fresh))
            .map(|(_, q)| q)
            .collect();
        let mut error = None;
        if !stale.is_empty() {
            match st.failed.clone() {
                Some((at, e)) if at.elapsed() < RETRY => error = Some(e),
                _ => match self.refresh(&stale, &mut st.details, t) {
                    Ok(found) => {
                        st.failed = None;
                        st.answers.extend(found);
                        if let Some(f) = &self.file {
                            write_cache(f, &st);
                        }
                    }
                    Err(e) => {
                        st.failed = Some((Instant::now(), e.clone()));
                        error = Some(e);
                    }
                },
            }
        }
        let mut report = Report {
            error,
            ..Report::default()
        };
        for k in queries.keys() {
            let Some(a) = st.answers.get(k) else { continue };
            let list = a
                .ids
                .iter()
                .map(|id| {
                    let d = st.details.get(id);
                    Advisory {
                        id: id.clone(),
                        summary: d.and_then(|d| d.summary.clone()),
                        severity: d.and_then(|d| d.severity.clone()),
                    }
                })
                .collect();
            report.found.insert(k.clone(), list);
            report.checked_at = Some(report.checked_at.map_or(a.at, |c| c.min(a.at)));
        }
        report
    }

    /// Asks OSV for `queries`, and for the records of the ids it names that are missing or old.
    fn refresh(
        &self,
        queries: &[&Query],
        details: &mut BTreeMap<String, Detail>,
        t: u64,
    ) -> Result<BTreeMap<String, Answer>, String> {
        let mut found = BTreeMap::new();
        for chunk in queries.chunks(BATCH) {
            let body = json!({ "queries": chunk.iter().map(|q| q.to_json()).collect::<Vec<_>>() });
            let v = self.post("/v1/querybatch", &body.to_string())?;
            let results = v["results"].as_array().ok_or("OSV: no results")?;
            if results.len() != chunk.len() {
                return Err(format!(
                    "OSV: {} answers for {} queries",
                    results.len(),
                    chunk.len()
                ));
            }
            for (q, r) in chunk.iter().zip(results) {
                let ids = r["vulns"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|v| v["id"].as_str().map(str::to_string))
                    .collect();
                found.insert(q.key(), Answer { at: t, ids });
            }
        }
        let wanted: BTreeSet<&String> = found.values().flat_map(|a| &a.ids).collect();
        for id in wanted {
            let old = details
                .get(id)
                .is_some_and(|d| t.saturating_sub(d.at) < self.lifetime.as_secs());
            if !old && let Ok(v) = self.get(&format!("/v1/vulns/{id}")) {
                details.insert(
                    id.clone(),
                    Detail {
                        at: t,
                        summary: v["summary"].as_str().map(str::to_string),
                        severity: severity(&v),
                    },
                );
            }
        }
        Ok(found)
    }

    fn post(&self, path: &str, body: &str) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        let res = self
            .agent
            .post(&url)
            .header("Content-Type", "application/json")
            .send(body)
            .map_err(|e| format!("{url}: {e}"))?;
        read(&url, res)
    }

    fn get(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        let res = self
            .agent
            .get(&url)
            .call()
            .map_err(|e| format!("{url}: {e}"))?;
        read(&url, res)
    }
}

fn read(url: &str, res: ureq::http::Response<ureq::Body>) -> Result<Value, String> {
    let text = res
        .into_body()
        .read_to_string()
        .map_err(|e| format!("{url}: {e}"))?;
    serde_json::from_str(&text).map_err(|e| format!("{url}: no JSON: {e}"))
}

/// The word OSV's record has for its severity: the database's own, or an affected package's.
fn severity(v: &Value) -> Option<String> {
    let own = v["database_specific"]["severity"].as_str();
    let affected = v["affected"]
        .as_array()
        .into_iter()
        .flatten()
        .find_map(|a| {
            a["ecosystem_specific"]["severity"]
                .as_str()
                .or_else(|| a["database_specific"]["severity"].as_str())
        });
    own.or(affected).map(str::to_string)
}

fn read_cache(file: &Path) -> State {
    let v: Value = fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null);
    let mut st = State::default();
    for (k, a) in v["answers"].as_object().into_iter().flatten() {
        let ids = a["ids"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|i| i.as_str().map(str::to_string))
            .collect();
        if let Some(at) = a["at"].as_u64() {
            st.answers.insert(k.clone(), Answer { at, ids });
        }
    }
    for (id, d) in v["details"].as_object().into_iter().flatten() {
        if let Some(at) = d["at"].as_u64() {
            st.details.insert(
                id.clone(),
                Detail {
                    at,
                    summary: d["summary"].as_str().map(str::to_string),
                    severity: d["severity"].as_str().map(str::to_string),
                },
            );
        }
    }
    st
}

/// Written beside and renamed, so a crash leaves the old file. A failure is not worth failing
/// a page for: the answers are still in memory.
fn write_cache(file: &Path, st: &State) {
    let mut answers = Map::new();
    for (k, a) in &st.answers {
        answers.insert(k.clone(), json!({ "at": a.at, "ids": a.ids }));
    }
    let mut details = Map::new();
    for (id, d) in &st.details {
        details.insert(
            id.clone(),
            json!({ "at": d.at, "summary": d.summary, "severity": d.severity }),
        );
    }
    let doc = json!({ "answers": answers, "details": details });
    let dir = file.parent().unwrap_or(Path::new("."));
    let written = fs::create_dir_all(dir)
        .and_then(|()| NamedTempFile::new_in(dir))
        .and_then(|mut t| {
            t.write_all(doc.to_string().as_bytes())?;
            t.persist(file).map_err(|e| e.error)
        });
    drop(written);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::thread;
    use tempfile::TempDir;

    fn pkg(name: &str, version: &str, purl: Option<&str>, root: bool) -> Package {
        Package {
            name: name.into(),
            version: version.into(),
            origin: None,
            purl: purl.map(str::to_string),
            cpe: None,
            root,
            replaces: vec![],
            pinned: None,
        }
    }

    /// An OSV stand-in: counts the requests, keeps the batch bodies, can be told to fail.
    struct Osv {
        url: String,
        batches: Arc<Mutex<Vec<Value>>>,
        requests: Arc<AtomicUsize>,
        down: Arc<AtomicBool>,
    }

    fn osv() -> Osv {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let stub = Osv {
            url: format!("http://{}", listener.local_addr().unwrap()),
            batches: Arc::default(),
            requests: Arc::default(),
            down: Arc::default(),
        };
        let (batches, requests, down) = (
            stub.batches.clone(),
            stub.requests.clone(),
            stub.down.clone(),
        );
        thread::spawn(move || {
            for conn in listener.incoming() {
                let mut conn = conn.unwrap();
                let mut input = BufReader::new(conn.try_clone().unwrap());
                let mut line = String::new();
                input.read_line(&mut line).unwrap();
                let mut len = 0;
                loop {
                    let mut h = String::new();
                    input.read_line(&mut h).unwrap();
                    if h == "\r\n" || h.is_empty() {
                        break;
                    }
                    if let Some(v) = h.to_lowercase().strip_prefix("content-length:") {
                        len = v.trim().parse().unwrap();
                    }
                }
                let mut raw = vec![0; len];
                input.read_exact(&mut raw).unwrap();
                requests.fetch_add(1, Ordering::SeqCst);
                let path = line.split(' ').nth(1).unwrap().to_string();
                let (status, body) = if down.load(Ordering::SeqCst) {
                    (503, "{}".to_string())
                } else if path == "/v1/querybatch" {
                    let q: Value = serde_json::from_slice(&raw).unwrap();
                    let results: Vec<Value> = q["queries"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|q| {
                            let purl = q["package"]["purl"].as_str().unwrap();
                            if purl.contains("gone") {
                                json!({ "vulns": [{ "id": "GHSA-404", "modified": "x" }] })
                            } else if purl.contains("time@") || purl.contains("django") {
                                json!({ "vulns": [{ "id": "GHSA-1", "modified": "x" }] })
                            } else {
                                json!({})
                            }
                        })
                        .collect();
                    batches.lock().unwrap().push(q);
                    (200, json!({ "results": results }).to_string())
                } else if path == "/v1/vulns/GHSA-1" {
                    let record = json!({ "id": "GHSA-1", "summary": "XSS in time",
                        "database_specific": { "severity": "MODERATE" } });
                    (200, record.to_string())
                } else {
                    (404, json!({ "code": 5 }).to_string())
                };
                write!(conn, "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
        });
        stub
    }

    fn image() -> Vec<Package> {
        vec![
            pkg("acl", "2.4.0", Some("pkg:gem/acl@2.4.0"), false),
            pkg("time", "0.1.40", Some("pkg:cargo/time@0.1.40"), false),
            pkg("django", "3.0", Some("pkg:pypi/django"), true),
            pkg("musl", "1.2", None, false),
        ]
    }

    fn open(o: &Osv, file: Option<PathBuf>, lifetime: Duration) -> Advisories {
        Advisories::open(&o.url, file, lifetime)
    }

    #[test]
    fn ages_read_in_the_largest_unit() {
        assert_eq!(ago(5), "just now");
        assert_eq!(ago(60), "1 min ago");
        assert_eq!(ago(3599), "59 min ago");
        assert_eq!(ago(3 * 3600 + 5), "3 h ago");
        assert_eq!(ago(47 * 3600), "47 h ago");
        assert_eq!(ago(3 * 86400), "3 days ago");
    }

    #[test]
    fn more_packages_than_osv_takes_at_once_are_asked_in_several_batches() {
        let o = osv();
        let list: Vec<Package> = (0..1500)
            .map(|i| {
                pkg(
                    &format!("p{i}"),
                    "1",
                    Some(&format!("pkg:cargo/p{i}@1")),
                    false,
                )
            })
            .collect();
        let r = open(&o, None, LIFETIME).check(&list);
        assert_eq!(r.error, None);
        let sizes: Vec<usize> = o
            .batches
            .lock()
            .unwrap()
            .iter()
            .map(|b| b["queries"].as_array().unwrap().len())
            .collect();
        // OSV's limit is 1000 queries a request
        assert_eq!(sizes, [1000, 500]);
    }

    #[test]
    fn asks_osv_by_purl_and_reads_each_vulnerability() {
        let o = osv();
        let list = image();
        let r = open(&o, None, LIFETIME).check(&list);
        assert_eq!(r.error, None);
        let batch = o.batches.lock().unwrap();
        // one batch, in the order of the keys; a purl with a version is sent as it is, one
        // without gets "version"; the package with no purl is not asked about
        assert_eq!(batch.len(), 1);
        assert_eq!(
            batch[0],
            json!({ "queries": [
                { "package": { "purl": "pkg:cargo/time@0.1.40" } },
                { "package": { "purl": "pkg:gem/acl@2.4.0" } },
                { "package": { "purl": "pkg:pypi/django" }, "version": "3.0" },
            ] })
        );
        let time = r.of(&list[1]).unwrap();
        assert_eq!(
            time,
            [Advisory {
                id: "GHSA-1".into(),
                summary: Some("XSS in time".into()),
                severity: Some("MODERATE".into())
            }]
        );
        assert_eq!(r.of(&list[0]).unwrap(), []);
        assert_eq!(r.of(&list[2]).unwrap().len(), 1);
        assert!(r.of(&list[3]).is_none());
        assert!(r.checked_at.is_some());
        assert_eq!(time[0].to_json()["severity"], "MODERATE");
    }

    #[test]
    fn only_the_purl_types_osv_indexes_are_covered() {
        for covered in [
            "pkg:pypi/django@3.0",
            "pkg:cargo/time",
            "pkg:npm/%40scope/name@1",
            "pkg:golang/github.com/x/y@1",
            "pkg:deb/debian/openssl@1.0.1",
            "PKG:PyPI/django",
        ] {
            assert!(covers(covered), "{covered}");
        }
        for not in [
            "pkg:github/systemd/systemd@v262.1",
            "pkg:generic/openssl@3.0.1",
            "pkg:gnu/bash",
            "pkg:gitlab/a/b",
            "pkg:sourceforge/e2fsprogs",
            "pkg:luarocks/lpeg",
            "bogus",
            "pkg:",
        ] {
            assert!(!covers(not), "{not}");
        }
        let with = |purl: &str| pkg("p", "1", Some(purl), false);
        assert!(covered(&with("pkg:pypi/p")));
        assert!(!covered(&with("pkg:github/p/p")));
        assert!(!covered(&pkg("p", "1", None, false)));
    }

    #[test]
    fn a_purl_type_osv_does_not_index_is_not_asked_about() {
        let o = osv();
        let list = [
            pkg(
                "systemd",
                "262.1",
                Some("pkg:github/systemd/systemd@v262.1"),
                true,
            ),
            pkg("zlib", "1.3", Some("pkg:generic/zlib@1.3"), false),
            pkg("bash", "5", Some("pkg:gnu/bash"), false),
            pkg("time", "0.1.40", Some("pkg:cargo/time@0.1.40"), false),
        ];
        let r = open(&o, None, LIFETIME).check(&list);
        assert_eq!(r.error, None);
        let batch = o.batches.lock().unwrap();
        let asked: Vec<&str> = batch[0]["queries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|q| q["package"]["purl"].as_str().unwrap())
            .collect();
        assert_eq!(asked, ["pkg:cargo/time@0.1.40"]);
        assert!(
            list[..3]
                .iter()
                .all(|p| r.of(p).is_none() && !r.vulnerable(p))
        );
        assert!(r.vulnerable(&list[3]));
        // nothing but uncovered packages: OSV is not called at all
        let before = o.requests.load(Ordering::SeqCst);
        let r = open(&o, None, LIFETIME).check(&list[..3]);
        assert_eq!(o.requests.load(Ordering::SeqCst), before);
        assert_eq!(r.error, None);
    }

    #[test]
    fn a_purl_osv_would_refuse_is_not_sent() {
        let o = osv();
        let list = [
            pkg("a", "1", Some("bogus"), false),
            pkg("b", "", Some("pkg:pypi/b"), false),
            pkg("time", "0.1.40", Some("pkg:cargo/time@0.1.40"), false),
        ];
        let r = open(&o, None, LIFETIME).check(&list);
        assert_eq!(r.error, None);
        let batch = o.batches.lock().unwrap();
        assert_eq!(batch[0]["queries"].as_array().unwrap().len(), 1);
        assert!(r.of(&list[0]).is_none() && r.of(&list[1]).is_none());
        assert!(r.vulnerable(&list[2]));
    }

    #[test]
    fn a_second_check_within_the_lifetime_asks_nothing() {
        let o = osv();
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("advisories.json");
        let list = image();
        let first = open(&o, Some(file.clone()), LIFETIME);
        first.check(&list);
        let n = o.requests.load(Ordering::SeqCst);
        assert_eq!(n, 2, "one batch, one vulnerability");
        let r = first.check(&list);
        assert_eq!(o.requests.load(Ordering::SeqCst), n);
        assert!(r.vulnerable(&list[1]));
        // a restarted daemon reads the file
        let r = open(&o, Some(file), LIFETIME).check(&list);
        assert_eq!(o.requests.load(Ordering::SeqCst), n);
        assert!(r.vulnerable(&list[1]) && r.error.is_none());
        assert!(r.checked_at.is_some());
    }

    #[test]
    fn only_what_is_missing_is_asked_for() {
        let o = osv();
        let list = image();
        let a = open(&o, None, LIFETIME);
        a.check(&list[..2]);
        a.check(&list);
        let batch = o.batches.lock().unwrap();
        assert_eq!(batch.len(), 2);
        assert_eq!(
            batch[1]["queries"].as_array().unwrap().len(),
            1,
            "{:?}",
            batch[1]
        );
        // the second batch found GHSA-1 again: its record was kept, not read a second time
        assert_eq!(o.requests.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn an_answer_older_than_the_lifetime_is_asked_for_again() {
        let o = osv();
        let list = image();
        let a = open(&o, None, Duration::ZERO);
        a.check(&list);
        a.check(&list);
        assert_eq!(o.batches.lock().unwrap().len(), 2);
    }

    #[test]
    fn osv_not_answering_is_a_report_not_a_failure() {
        let o = osv();
        o.down.store(true, Ordering::SeqCst);
        let list = image();
        let r = open(&o, None, LIFETIME).check(&list);
        assert!(
            r.error.as_deref().is_some_and(|e| e.contains("503")),
            "{r:?}"
        );
        assert!(r.of(&list[1]).is_none() && !r.vulnerable(&list[1]));
        assert_eq!(r.checked_at, None);
        // nothing listens at all
        let gone = Advisories::open("http://127.0.0.1:1", None, LIFETIME).check(&list);
        assert!(gone.error.is_some() && gone.checked_at.is_none());
    }

    #[test]
    fn a_failure_is_not_tried_again_at_once() {
        let o = osv();
        o.down.store(true, Ordering::SeqCst);
        let list = image();
        let a = open(&o, None, LIFETIME);
        a.check(&list);
        let r = a.check(&list);
        assert_eq!(o.requests.load(Ordering::SeqCst), 1);
        assert!(r.error.is_some());
    }

    #[test]
    fn an_old_answer_shows_when_asking_again_fails() {
        let o = osv();
        let list = image();
        let a = open(&o, None, Duration::ZERO);
        a.check(&list);
        o.down.store(true, Ordering::SeqCst);
        let r = a.check(&list);
        assert!(r.error.is_some());
        assert!(r.vulnerable(&list[1]), "{r:?}");
        assert!(r.checked_at.is_some());
    }

    #[test]
    fn a_vulnerability_that_cannot_be_read_is_still_listed() {
        let o = osv();
        let list = [pkg("gone", "1", Some("pkg:cargo/gone@1"), false)];
        let r = open(&o, None, LIFETIME).check(&list);
        assert_eq!(r.error, None);
        let a = &r.of(&list[0]).unwrap()[0];
        assert_eq!(
            (a.id.as_str(), &a.summary, &a.severity),
            ("GHSA-404", &None, &None)
        );
    }

    #[test]
    fn a_damaged_file_is_ignored() {
        let o = osv();
        let dir = TempDir::new().unwrap();
        let file = dir.path().join("advisories.json");
        fs::write(&file, "{ not json").unwrap();
        let list = image();
        let r = open(&o, Some(file.clone()), LIFETIME).check(&list);
        assert!(r.vulnerable(&list[1]));
        let again: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        assert!(again.is_object());
    }
}
