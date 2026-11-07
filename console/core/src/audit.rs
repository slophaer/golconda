//! The audit log: a git repository of its own, one entry per commit.
//!
//! An entry adds one JSON line to the file of its day, `YYYY/MM/DD.jsonl`, so `git show` of a
//! commit is exactly its entry. The author is the operator; the committer is the daemon, which
//! signs every commit with its SSH key. The message is a one-line summary with trailers
//! (`Operator:`, `Action:`, `System:`, `Result:`, `Config-Commit:`), for `git log --grep` and
//! `%(trailers)`. Git's chain of commits is the hash chain; the protection against a rewrite
//! is the remote the daemon pushes to, which refuses force-pushes.
//!
//! `verify` checks the whole history: every commit signed by an allowed key, and each adding
//! exactly one line, a JSON entry, and removing none.

use crate::candidate::{Operator, now};
use crate::document;
use crate::git::{self, Git, Person};
use serde_json::{Map, Value, json};
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// One action, as the log keeps it.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// UTC, RFC 3339
    pub time: String,
    pub operator: Operator,
    /// web, cli, tui, or daemon
    pub via: String,
    /// config.set, config.commit, config.discard, config.refused, signin, …
    pub action: String,
    pub system: Option<String>,
    pub rev: Option<u64>,
    /// what it acted on: `/services/sshd port`
    pub target: Option<String>,
    pub before: Option<Value>,
    pub after: Option<Value>,
    /// ok, refused, denied, failed
    pub result: String,
    pub config_commit: Option<String>,
}

impl Entry {
    /// An entry for now, with the rest left empty.
    pub fn new(operator: &Operator, via: &str, action: &str, result: &str) -> Entry {
        Entry {
            time: now(),
            operator: operator.clone(),
            via: via.into(),
            action: action.into(),
            system: None,
            rev: None,
            target: None,
            before: None,
            after: None,
            result: result.into(),
            config_commit: None,
        }
    }

    /// The line in the day's file: only the fields that are there.
    pub fn to_json(&self) -> Value {
        let mut o = Map::new();
        o.insert("time".into(), self.time.clone().into());
        o.insert(
            "operator".into(),
            json!({ "id": self.operator.id, "name": self.operator.name, "via": self.via }),
        );
        o.insert("action".into(), self.action.clone().into());
        o.insert("result".into(), self.result.clone().into());
        let optional = [
            ("system", self.system.clone().map(Value::from)),
            ("rev", self.rev.map(Value::from)),
            ("target", self.target.clone().map(Value::from)),
            ("before", self.before.clone()),
            ("after", self.after.clone()),
            ("configCommit", self.config_commit.clone().map(Value::from)),
        ];
        for (k, v) in optional {
            if let Some(v) = v {
                o.insert(k.into(), v);
            }
        }
        Value::Object(o)
    }

    /// `config.set server /services/sshd port: 22 → 2222`
    pub fn summary(&self) -> String {
        let mut s = self.action.clone();
        if let Some(sys) = &self.system {
            s += &format!(" {sys}");
        }
        if let Some(t) = &self.target {
            s += &format!(" {t}");
        }
        match (&self.before, &self.after) {
            (Some(b), Some(a)) => s += &format!(": {} → {}", short(b), short(a)),
            (None, Some(a)) => s += &format!(": {}", short(a)),
            (Some(b), None) => s += &format!(": {} → none", short(b)),
            (None, None) => {}
        }
        if self.result != "ok" {
            s += &format!(" ({})", self.result);
        }
        s
    }

    fn message(&self) -> String {
        let mut m = format!(
            "{}\n\nOperator: {} <{}>\nAction: {}\n",
            self.summary(),
            self.operator.name,
            self.operator.id,
            self.action
        );
        if let Some(sys) = &self.system {
            m += &format!("System: {sys}\n");
        }
        m += &format!("Result: {}\n", self.result);
        if let Some(c) = &self.config_commit {
            m += &format!("Config-Commit: {c}\n");
        }
        m
    }
}

fn short(v: &Value) -> String {
    let t = document::toml_text(v);
    if t.chars().count() > 60 {
        format!("{}…", t.chars().take(59).collect::<String>())
    } else {
        t
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Git(#[from] git::Error),
    #[error("the audit file: {0}")]
    Io(#[from] io::Error),
    /// a commit that is not one signed entry
    #[error("commit {commit}: {why}")]
    Bad { commit: String, why: String },
    #[error("the audit index: {0}")]
    Index(#[from] rusqlite::Error),
}

/// The audit repository.
pub struct Audit<'a> {
    pub git: &'a Git,
}

impl Audit<'_> {
    /// A repository at the git's directory, made if there is none.
    pub fn open(git: &Git) -> Result<Audit<'_>, Error> {
        fs::create_dir_all(&git.dir)?;
        if !git.dir.join(".git").exists() {
            git.run(&["init", "--quiet", "-b", "main"])?;
        }
        Ok(Audit { git })
    }

    /// Write the entry and commit it, synced to disk before it returns: an action is
    /// answered only after its entry is. The commit's id.
    pub fn record(&self, e: &Entry) -> Result<String, Error> {
        let day = day_file(&e.time);
        let path = self.git.dir.join(&day);
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;
        let length = f.metadata()?.len();
        writeln!(f, "{}", e.to_json())?;
        // shortcut: untested, it would take a crash; the entry is on disk before the commit
        f.sync_all()?;
        let author = Person {
            name: e.operator.name.clone(),
            id: e.operator.id.clone(),
        };
        match self.git.commit(&day, &author, &e.message()) {
            Ok(id) => Ok(id),
            Err(err) => {
                // the entry is not written: no line of it stays to ride along with the next (the
                // next commit's `git add` stages the file as it is then)
                f.set_len(length)?;
                f.sync_all()?;
                Err(err.into())
            }
        }
    }

    /// Check every commit: signed by a key in `allowed_signers`, adding exactly one line, a
    /// JSON entry, to one day's file, and removing nothing. The number of entries.
    pub fn verify(&self, allowed_signers: &Path) -> Result<usize, Error> {
        let git = self.git;
        let list = git.run(&["rev-list", "--reverse", "HEAD"])?;
        let allowed = format!("gpg.ssh.allowedSignersFile={}", allowed_signers.display());
        let mut n = 0;
        for c in list.lines() {
            let bad = |why: String| Error::Bad {
                commit: c.to_string(),
                why,
            };
            git.run(&["-c", &allowed, "verify-commit", c])
                .map_err(|e| bad(format!("signature: {}", e.message)))?;
            let stat = git.run(&["show", "--numstat", "--format=", c])?;
            let files: Vec<&str> = stat.lines().collect();
            let [one] = files[..] else {
                return Err(bad(format!("changes {} files", files.len())));
            };
            let parts: Vec<&str> = one.split('\t').collect();
            if parts.len() != 3 || parts[0] != "1" || parts[1] != "0" || !is_day_file(parts[2]) {
                return Err(bad(format!("is not one line added to a day's file: {one}")));
            }
            let added = git.run(&["show", "--format=", "--unified=0", c])?;
            let line = added
                .lines()
                .find(|l| l.starts_with('+') && !l.starts_with("+++"))
                .unwrap_or("")
                .trim_start_matches('+');
            serde_json::from_str::<Value>(line)
                .ok()
                .filter(|v| v["action"].is_string() && v["operator"]["id"].is_string())
                .ok_or_else(|| bad("its line is not an entry".into()))?;
            n += 1;
        }
        Ok(n)
    }
}

/// `2026/11/05.jsonl` for a time of that day.
fn day_file(time: &str) -> PathBuf {
    let d = time.get(..10).unwrap_or("0000-00-00");
    PathBuf::from(format!("{}/{}/{}.jsonl", &d[..4], &d[5..7], &d[8..10]))
}

/// What the audit page asks for: each one given must be part of its field (the operator's id or
/// name, the system, the action, the time, so a day is `2026-11-05`).
#[derive(Debug, Default, Clone)]
pub struct Filter {
    pub operator: Option<String>,
    pub system: Option<String>,
    pub action: Option<String>,
    pub day: Option<String>,
}

/// The audit page's index: the entries in SQLite, rebuilt from the repository's day files at
/// start and added to with each new entry. The repository is the record; the index can be
/// thrown away.
pub struct Index {
    conn: rusqlite::Connection,
}

/// The day files under `dir` (YYYY/MM/DD.jsonl), oldest first.
fn day_files(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let mut days = Vec::new();
    let sorted = |d: &Path| -> io::Result<Vec<PathBuf>> {
        let mut v: Vec<PathBuf> = fs::read_dir(d)?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.file_name().is_some_and(|n| n != ".git"))
            .collect();
        v.sort();
        Ok(v)
    };
    for year in sorted(dir)?.into_iter().filter(|p| p.is_dir()) {
        for month in sorted(&year)?.into_iter().filter(|p| p.is_dir()) {
            days.extend(
                sorted(&month)?
                    .into_iter()
                    .filter(|p| p.extension().is_some_and(|e| e == "jsonl")),
            );
        }
    }
    Ok(days)
}

impl Index {
    /// The index at `path`, made again from the repository at `repo`.
    pub fn rebuild(path: &Path, repo: &Path) -> Result<Index, Error> {
        let conn = rusqlite::Connection::open(path)?;
        conn.execute_batch(
            "DROP TABLE IF EXISTS entries;
             CREATE TABLE entries (
               seq INTEGER PRIMARY KEY AUTOINCREMENT, time TEXT, operator_id TEXT,
               operator_name TEXT, system TEXT, action TEXT, json TEXT NOT NULL);",
        )?;
        let index = Index { conn };
        let tx = index.conn.unchecked_transaction()?;
        for day in day_files(repo)? {
            for line in fs::read_to_string(&day)?.lines() {
                if let Ok(v) = serde_json::from_str::<Value>(line) {
                    index.add(&v)?;
                }
            }
        }
        tx.commit()?;
        Ok(index)
    }

    /// Adds an entry (its JSON line) as the newest.
    pub fn add(&self, v: &Value) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO entries (time, operator_id, operator_name, system, action, json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                v["time"].as_str(),
                v["operator"]["id"].as_str(),
                v["operator"]["name"].as_str(),
                v["system"].as_str(),
                v["action"].as_str(),
                v.to_string()
            ],
        )?;
        Ok(())
    }

    /// The entries `f` keeps, newest first, at most `limit`.
    pub fn query(&self, f: &Filter, limit: usize) -> rusqlite::Result<Vec<Value>> {
        let mut q = self.conn.prepare(
            "SELECT json FROM entries WHERE
               (?1 IS NULL OR instr(operator_id, ?1) > 0 OR instr(operator_name, ?1) > 0)
               AND (?2 IS NULL OR instr(system, ?2) > 0)
               AND (?3 IS NULL OR instr(action, ?3) > 0)
               AND (?4 IS NULL OR instr(time, ?4) > 0)
             ORDER BY seq DESC LIMIT ?5",
        )?;
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = q.query_map(
            rusqlite::params![f.operator, f.system, f.action, f.day, limit],
            |r| r.get::<_, String>(0),
        )?;
        Ok(rows
            .filter_map(|r| r.ok().and_then(|t| serde_json::from_str(&t).ok()))
            .collect())
    }
}

fn is_day_file(p: &str) -> bool {
    let b = p.as_bytes();
    p.len() == 16
        && Path::new(p).extension() == Some(OsStr::new("jsonl"))
        && b[4] == b'/'
        && b[7] == b'/'
        && [0, 1, 2, 3, 5, 6, 8, 9]
            .iter()
            .all(|&i| b[i].is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs;
    use std::process::Command;
    use tempfile::TempDir;

    struct Scene {
        _tmp: TempDir,
        dir: PathBuf,
        git: Git,
        allowed: PathBuf,
    }

    fn scene() -> Scene {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
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
            git: Git {
                dir: dir.join("audit"),
                committer: Person {
                    name: "golcondad".into(),
                    id: "golcondad@test".into(),
                },
                signing_key: Some(key),
            },
            allowed,
            dir,
        }
    }

    fn alice() -> Operator {
        Operator {
            id: "alice@example.com".into(),
            name: "Alice".into(),
        }
    }

    fn set_port() -> Entry {
        Entry {
            time: "2026-11-03T14:02:11Z".into(),
            system: Some("server".into()),
            rev: Some(57),
            target: Some("/services/sshd port".into()),
            before: Some(json!(22)),
            after: Some(json!(2222)),
            ..Entry::new(&alice(), "web", "config.set", "ok")
        }
    }

    #[test]
    fn an_entry_is_one_line_in_its_day_file_and_one_signed_commit() {
        let s = scene();
        let a = Audit::open(&s.git).unwrap();
        a.record(&set_port()).unwrap();
        let e2 = Entry {
            time: "2026-11-03T14:05:31Z".into(),
            config_commit: Some("e90c417".into()),
            ..Entry::new(&alice(), "web", "config.commit", "ok")
        };
        a.record(&e2).unwrap();
        let day = fs::read_to_string(s.git.dir.join("2026/11/03.jsonl")).unwrap();
        let lines: Vec<Value> = day
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(
            lines[0],
            json!({ "time": "2026-11-03T14:02:11Z",
                    "operator": { "id": "alice@example.com", "name": "Alice", "via": "web" },
                    "action": "config.set", "system": "server", "rev": 57,
                    "target": "/services/sshd port", "before": 22, "after": 2222, "result": "ok" })
        );
        let log = s.git.run(&["log", "--format=%an|%cn|%B%x00"]).unwrap();
        let first = log
            .split('\0')
            .map(str::trim)
            .rfind(|x| !x.is_empty())
            .unwrap();
        assert_eq!(
            first,
            "Alice|golcondad|config.set server /services/sshd port: 22 → 2222\n\n\
             Operator: Alice <alice@example.com>\nAction: config.set\nSystem: server\nResult: ok"
        );
        assert!(log.contains("Config-Commit: e90c417"), "{log}");
        assert_eq!(a.verify(&s.allowed).unwrap(), 2);
    }

    #[test]
    fn verify_refuses_an_unsigned_commit_and_one_that_is_not_one_entry() {
        // an unsigned commit
        let s = scene();
        let a = Audit::open(&s.git).unwrap();
        a.record(&set_port()).unwrap();
        let unsigned = Git {
            dir: s.git.dir.clone(),
            committer: s.git.committer.clone(),
            signing_key: None,
        };
        Audit { git: &unsigned }.record(&set_port()).unwrap();
        let e = a.verify(&s.allowed).unwrap_err().to_string();
        assert!(e.contains("signature"), "{e}");
        // a commit that changes an entry
        let s = scene();
        let a = Audit::open(&s.git).unwrap();
        a.record(&set_port()).unwrap();
        let p = s.git.dir.join("2026/11/03.jsonl");
        let text = fs::read_to_string(&p).unwrap().replace("2222", "2200");
        fs::write(&p, text).unwrap();
        s.git
            .commit(Path::new("2026/11/03.jsonl"), &s.git.committer, "fix")
            .unwrap();
        let e = a.verify(&s.allowed).unwrap_err().to_string();
        assert!(e.contains("is not one line added"), "{e}");
        // a signed commit whose line is no entry
        let s = scene();
        let a = Audit::open(&s.git).unwrap();
        let p = s.git.dir.join("2026/11/03.jsonl");
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, "not json\n").unwrap();
        s.git
            .commit(Path::new("2026/11/03.jsonl"), &s.git.committer, "junk")
            .unwrap();
        let e = a.verify(&s.allowed).unwrap_err().to_string();
        assert!(e.contains("not an entry"), "{e}");
        // and a key that is not allowed
        let s = scene();
        let a = Audit::open(&s.git).unwrap();
        a.record(&set_port()).unwrap();
        fs::write(
            &s.allowed,
            "someone@else namespaces=\"git\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample\n",
        )
        .unwrap();
        assert!(a.verify(&s.allowed).is_err());
    }

    #[test]
    fn an_entry_that_could_not_be_committed_leaves_no_line_behind() {
        let s = scene();
        let a = Audit::open(&s.git).unwrap();
        a.record(&set_port()).unwrap();
        let day = s.git.dir.join("2026/11/03.jsonl");
        let before = fs::read_to_string(&day).unwrap();
        // a key that is not there: the commit fails, so the entry is not written
        let broken = Git {
            dir: s.git.dir.clone(),
            committer: s.git.committer.clone(),
            signing_key: Some(s.dir.join("no-such-key")),
        };
        assert!(Audit { git: &broken }.record(&set_port()).is_err());
        assert_eq!(std::fs::read_to_string(&day).unwrap(), before);
        // and the next entry is one line in one commit, as every other
        a.record(&set_port()).unwrap();
        assert_eq!(a.verify(&s.allowed).unwrap(), 2);
    }

    #[test]
    fn summaries() {
        assert_eq!(
            set_port().summary(),
            "config.set server /services/sshd port: 22 → 2222"
        );
        let refused = Entry {
            system: Some("server".into()),
            target: Some("/network".into()),
            after: Some(json!({ "x": 1 })),
            ..Entry::new(&alice(), "web", "config.set", "denied")
        };
        assert_eq!(
            refused.summary(),
            "config.set server /network: { x = 1 } (denied)"
        );
        assert_eq!(
            day_file("2026-11-03T14:02:11Z"),
            PathBuf::from("2026/11/03.jsonl")
        );
        assert!(is_day_file("2026/11/03.jsonl"));
        assert!(!is_day_file("2026/11/03.json") && !is_day_file("x/11/03.jsonl"));
    }

    #[test]
    fn the_index_is_the_day_files_newest_first_and_filters_them() {
        let tmp = TempDir::new().unwrap();
        let repo = tmp.path().join("audit");
        let line = |time: &str, name: &str, action: &str| {
            json!({ "time": time, "operator": { "id": format!("{name}@x"), "name": name, "via": "web" },
                    "action": action, "system": "server", "result": "ok" })
            .to_string()
        };
        fs::create_dir_all(repo.join("2026/11")).unwrap();
        fs::create_dir_all(repo.join(".git")).unwrap();
        fs::write(
            repo.join("2026/11/04.jsonl"),
            format!(
                "{}\n{}\n",
                line("2026-11-04T10:00:00Z", "Alice", "config.set"),
                line("2026-11-04T11:00:00Z", "Bob", "config.commit")
            ),
        )
        .unwrap();
        fs::write(
            repo.join("2026/11/05.jsonl"),
            line("2026-11-05T09:00:00Z", "Alice", "job.deploy") + "\n",
        )
        .unwrap();
        let path = tmp.path().join("index.db");
        let index = Index::rebuild(&path, &repo).unwrap();
        let times = |v: Vec<Value>| -> Vec<String> {
            v.iter()
                .map(|e| e["time"].as_str().unwrap()[..13].to_string())
                .collect()
        };
        assert_eq!(
            times(index.query(&Filter::default(), 10).unwrap()),
            ["2026-11-05T09", "2026-11-04T11", "2026-11-04T10"]
        );
        let alice = Filter {
            operator: Some("lic".into()),
            ..Filter::default()
        };
        assert_eq!(index.query(&alice, 10).unwrap().len(), 2);
        let day = Filter {
            day: Some("2026-11-04".into()),
            action: Some("commit".into()),
            ..Filter::default()
        };
        assert_eq!(times(index.query(&day, 10).unwrap()), ["2026-11-04T11"]);
        assert_eq!(index.query(&Filter::default(), 1).unwrap().len(), 1);
        // a new entry is the newest; a rebuild forgets what the repository does not hold
        let new: Value =
            serde_json::from_str(&line("2026-11-05T10:00:00Z", "Carol", "config.lock")).unwrap();
        index.add(&new).unwrap();
        assert_eq!(
            index.query(&Filter::default(), 1).unwrap()[0]["operator"]["name"],
            "Carol"
        );
        drop(index);
        let again = Index::rebuild(&path, &repo).unwrap();
        assert_eq!(again.query(&Filter::default(), 10).unwrap().len(), 3);
    }
}
