//! What changes something: operations on a candidate, commit, discard. Each
//! answers JSON for the CLI and, for a browser's form, a redirect or a page.
//!
//! Every action, and every refusal (a conflict, a problem the schema finds, a write in
//! read-only), is an entry in the audit log, written before the answer: an operation's in
//! the journal's transaction, a commit's after the git commit and before the push. An entry
//! that cannot be written refuses the action. Each entry goes to the systemd journal too, and
//! the audit repository is pushed in the background.

use crate::app::{App, Identity, Level};
use crate::locked;
use golconda_core::audit::{Audit, Entry};
use golconda_core::candidate::{Edit, Journal, Op, Operator, Refused, Request};
use golconda_core::check::Problem;
use golconda_core::commit::{self, Repo};
use golconda_core::document::toml_text;
use golconda_core::document::{option_name, parse_path, to_json};
use golconda_core::git::{Git, Person};
use golconda_core::system::System;
use serde_json::{Value, json};
use std::fs;
use std::os;
use std::path::{self, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

/// What a daemon that writes has: the journal, the audit repository, its signing key.
pub struct Writes {
    /// the state directory: journal.db, jobs.db, audit/, releases/
    pub state: PathBuf,
    pub journal: Mutex<Journal>,
    /// held while something writes a system's checkout (a commit, a fetch, a release build),
    /// which takes minutes for a build: edits need the journal only
    pub checkout: Mutex<()>,
    /// the audit repository; its lock also orders the entries
    pub audit: Mutex<Git>,
    /// the remote the audit repository is pushed to
    pub audit_push: Option<String>,
    /// the audit repository has entries its remote lacks
    pub audit_unpushed: Arc<AtomicBool>,
    /// the daemon, as committer, and its SSH key
    pub committer: Person,
    pub signing_key: Option<PathBuf>,
    /// the remote each system's checkout fetches from and pushes to (its current branch)
    pub push: Option<String>,
    /// systemd's journal socket; none: not there (tests)
    pub journal_socket: Option<PathBuf>,
}

impl Writes {
    /// `<state>/journal.db` and `<state>/audit`.
    pub fn open(
        state: &Path,
        committer: Person,
        signing_key: Option<PathBuf>,
        push: Option<String>,
        audit_push: Option<String>,
    ) -> Result<Writes, String> {
        fs::create_dir_all(state).map_err(|e| format!("{}: {e}", state.display()))?;
        // git signs in the audit repository's directory: a relative key would not be found
        let signing_key = signing_key
            .map(|k| path::absolute(&k).map_err(|e| format!("{}: {e}", k.display())))
            .transpose()?;
        let journal = Journal::open(&state.join("journal.db")).map_err(|e| e.to_string())?;
        let git = Git {
            dir: state.join("audit"),
            committer: committer.clone(),
            signing_key: signing_key.clone(),
        };
        Audit::open(&git).map_err(|e| e.to_string())?;
        let socket = PathBuf::from("/run/systemd/journal/socket");
        Ok(Writes {
            state: state.to_path_buf(),
            journal: Mutex::new(journal),
            checkout: Mutex::new(()),
            audit: Mutex::new(git),
            audit_push,
            audit_unpushed: Arc::default(),
            committer,
            signing_key,
            push,
            journal_socket: socket.exists().then_some(socket),
        })
    }

    /// Write `e` to the audit log (and the systemd journal), then push the log in the
    /// background. An error: the entry is not written.
    pub fn record(&self, e: &Entry) -> Result<(), String> {
        {
            let git = locked(&self.audit);
            Audit { git: &git }.record(e).map_err(|e| e.to_string())?;
        }
        if let Some(socket) = &self.journal_socket {
            send_journal(socket, e);
        }
        if let Some(remote) = self.audit_push.clone() {
            self.audit_unpushed.store(true, Ordering::SeqCst);
            let dir = locked(&self.audit).dir.clone();
            let committer = self.committer.clone();
            let unpushed = self.audit_unpushed.clone();
            // the push may lag; the pages say so until one succeeds
            thread::spawn(move || {
                let git = Git {
                    dir,
                    committer,
                    signing_key: None,
                };
                if git.push(&remote, "main").is_ok() {
                    unpushed.store(false, Ordering::SeqCst);
                }
            });
        }
        Ok(())
    }

    /// Push the audit repository now; whether it worked.
    pub fn push_audit(&self) -> bool {
        let Some(remote) = &self.audit_push else {
            return true;
        };
        let ok = locked(&self.audit).push(remote, "main").is_ok();
        self.audit_unpushed.store(!ok, Ordering::SeqCst);
        ok
    }
}

impl Writes {
    /// The audit log's entries, newest first, those that `keep` keeps, at most `limit`.
    /// shortcut: it reads the day files, newest first, instead of an index (SQLite, rebuilt from
    /// the repository); that is quick for months of entries, not for years.
    pub fn entries(&self, limit: usize, keep: impl Fn(&Value) -> bool) -> Vec<Value> {
        let dir = locked(&self.audit).dir.clone();
        let mut days: Vec<PathBuf> = Vec::new();
        let sub = |d: &Path| -> Vec<PathBuf> {
            let mut v: Vec<PathBuf> = fs::read_dir(d)
                .into_iter()
                .flatten()
                .flatten()
                .map(|e| e.path())
                .filter(|p| !p.ends_with(".git"))
                .collect();
            v.sort();
            v.reverse();
            v
        };
        for year in sub(&dir) {
            for month in sub(&year) {
                days.extend(
                    sub(&month)
                        .into_iter()
                        .filter(|p| p.extension().is_some_and(|e| e == "jsonl")),
                );
            }
        }
        let mut out = Vec::new();
        for day in days {
            let text = fs::read_to_string(&day).unwrap_or_default();
            for line in text.lines().rev() {
                if let Ok(v) = serde_json::from_str::<Value>(line)
                    && keep(&v)
                {
                    out.push(v);
                    if out.len() == limit {
                        return out;
                    }
                }
            }
        }
        out
    }
}

/// An entry in systemd's journal, in its native datagram protocol: KEY=value lines.
fn send_journal(socket: &Path, e: &Entry) {
    let one = |s: &str| s.replace('\n', " ");
    let mut m = format!(
        "SYSLOG_IDENTIFIER=golcondad\nPRIORITY=6\nMESSAGE={}\nGOLCONDA_ACTION={}\nGOLCONDA_OPERATOR={}\nGOLCONDA_RESULT={}\n",
        one(&e.summary()),
        one(&e.action),
        one(&e.operator.id),
        one(&e.result)
    );
    if let Some(s) = &e.system {
        m += &format!("GOLCONDA_SYSTEM={}\n", one(s));
    }
    if let Ok(sock) = os::unix::net::UnixDatagram::unbound() {
        let _ = sock.send_to(m.as_bytes(), socket);
    }
}

/// A form's value as TOML, by the control it came from (`kind`): `string` is text to quote,
/// `lines` one string per line, anything else TOML as typed.
pub fn form_value(kind: &str, raw: &str) -> String {
    match kind {
        "string" => toml_text(&Value::String(raw.to_string())),
        "lines" => toml_text(&Value::Array(
            raw.lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .map(|l| Value::String(l.to_string()))
                .collect(),
        )),
        _ => raw.to_string(),
    }
}

/// The operator an identity is.
pub fn operator(who: &Identity) -> Operator {
    Operator {
        id: who.id.clone(),
        name: who.name.clone(),
    }
}

/// The value at `module` `path` in a document, as JSON; null when it has none.
fn value_at(text: &str, module: &str, path: &[String]) -> Value {
    let doc = to_json(text).unwrap_or(Value::Null);
    path.iter()
        .fold(&doc[module], |v, k| &v[k.as_str()])
        .clone()
}

fn toml_json(v: &str) -> Value {
    let doc = format!("x = {v}");
    to_json(&doc).map_or(Value::Null, |d| d["x"].clone())
}

/// Why a write did not happen, as the answer says it.
#[derive(Debug)]
pub enum Outcome {
    /// done: what to say (JSON)
    Done(Value),
    /// 403: read-only
    Denied(String),
    /// 409: what an operation after the base changed
    Conflict { yours: Value, theirs: Vec<Op> },
    /// 422: the schema's problems
    Invalid(Vec<Problem>),
    /// 400: a request that makes no sense
    Bad(String),
    /// 500: the evaluation, git, the journal or the audit log failed
    Failed(String),
}

/// A write is allowed: the daemon is not read-only and the person is an operator. If not,
/// the refusal is an audit entry too.
pub fn may_write(
    app: &App,
    w: &Writes,
    who: &Identity,
    via: &str,
    action: &str,
    system: &str,
) -> Option<Outcome> {
    let why = if app.read_only {
        "this console is read-only"
    } else if who.level == Level::ReadOnly {
        "you may only read"
    } else {
        return None;
    };
    let e = Entry {
        system: Some(system.into()),
        ..Entry::new(&operator(who), via, action, "denied")
    };
    if let Err(err) = w.record(&e) {
        eprintln!("golcondad: the audit entry of a denied write: {err}");
    }
    Some(Outcome::Denied(why.into()))
}

/// One operation, asked for in `body` (JSON or a form's fields): base, module, option
/// (a TOML dotted key, empty for the whole module), op (set or delete), value (TOML).
pub fn operation(
    app: &App,
    w: &Writes,
    who: &Identity,
    via: &str,
    system: &str,
    doc: &Path,
    body: &Value,
) -> Outcome {
    let action = match body["op"].as_str() {
        Some("set") => "config.set",
        Some("delete") => "config.delete",
        _ => return Outcome::Bad("op is set or delete".into()),
    };
    if let Some(o) = may_write(app, w, who, via, action, system) {
        return o;
    }
    let base = match &body["base"] {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        _ => None,
    };
    let Some(base) = base else {
        return Outcome::Bad("base is the revision the change was made on".into());
    };
    let Some(module) = body["module"]
        .as_str()
        .filter(|m| m.starts_with('/') || *m == "golconda")
    else {
        return Outcome::Bad("module is a module path".into());
    };
    let option = body["option"].as_str().unwrap_or("");
    let path = if option.is_empty() {
        Vec::new()
    } else {
        match parse_path(option) {
            Ok(p) => p,
            Err(e) => return Outcome::Bad(e.to_string()),
        }
    };
    let edit = if action == "config.set" {
        let Some(v) = body["value"].as_str() else {
            return Outcome::Bad("set needs a value (TOML)".into());
        };
        Edit::Set(v.to_string())
    } else {
        Edit::Delete
    };
    let sys = match System::load(&app.iets, doc, &app.platform) {
        Ok(s) => s,
        Err(e) => return Outcome::Failed(e.to_string()),
    };
    let p: Vec<&str> = path.iter().map(String::as_str).collect();
    let target = if p.is_empty() {
        module.to_string()
    } else {
        format!("{module} {}", option_name(&p))
    };
    let r = Request {
        base,
        module: module.to_string(),
        path: path.clone(),
        edit: edit.clone(),
        by: operator(who),
        via: via.into(),
    };
    let mut journal = locked(&w.journal);
    let before = journal
        .candidate(system, &sys.text)
        .map_or(Value::Null, |t| value_at(&t, module, &path));
    let after = match &edit {
        Edit::Set(v) => toml_json(v),
        Edit::Delete => Value::Null,
    };
    let entry = |result: &str, rev: Option<u64>| Entry {
        system: Some(system.into()),
        rev,
        target: Some(target.clone()),
        before: (!before.is_null()).then(|| before.clone()),
        after: (!after.is_null()).then(|| after.clone()),
        ..Entry::new(&operator(who), via, action, result)
    };
    let done = journal.apply_with(system, &sys.text, &sys.schema, r, |op| {
        w.record(&entry("ok", Some(op.rev)))
    });
    let refusal = |o: Outcome| {
        if let Err(e) = w.record(&entry("refused", None)) {
            eprintln!("golcondad: the audit entry of a refusal: {e}");
        }
        o
    };
    match done {
        Ok(op) => Outcome::Done(op.to_json()),
        Err(Refused::Conflict(theirs)) => refusal(Outcome::Conflict {
            yours: json!({ "target": target, "value": after }),
            theirs,
        }),
        Err(Refused::Invalid(p)) => refusal(Outcome::Invalid(p)),
        Err(Refused::Base { .. }) => {
            Outcome::Bad("the base revision is ahead of the candidate".into())
        }
        Err(Refused::Edit(e)) => refusal(Outcome::Bad(e.to_string())),
        Err(e) => Outcome::Failed(e.to_string()),
    }
}

/// The checkout a system's document is in, and the branch it is on.
/// The checkout around `doc` as the daemon commits in it, the document's path in it, and its
/// current branch.
pub(crate) fn repo_of(w: &Writes, doc: &Path) -> Result<(Git, PathBuf, String), String> {
    let dir = doc
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let probe = Git {
        dir: dir.to_path_buf(),
        committer: w.committer.clone(),
        signing_key: None,
    };
    let top = PathBuf::from(
        probe
            .run(&["rev-parse", "--show-toplevel"])
            .map_err(|e| e.to_string())?,
    );
    let branch = probe
        .run(&["rev-parse", "--abbrev-ref", "HEAD"])
        .map_err(|e| e.to_string())?;
    let abs = path::absolute(doc).map_err(|e| e.to_string())?;
    let rel = abs
        .strip_prefix(&top)
        .map_err(|_| format!("{} is not in {}", doc.display(), top.display()))?
        .to_path_buf();
    Ok((
        Git {
            dir: top,
            committer: w.committer.clone(),
            signing_key: w.signing_key.clone(),
        },
        rel,
        branch,
    ))
}

/// Record the outside changes a fetch found, one entry for them all.
fn record_outside(w: &Writes, system: &str, outside: &[Op]) {
    let Some(first) = outside.first() else { return };
    let e = Entry {
        system: Some(system.into()),
        rev: outside.last().map(|o| o.rev),
        target: Some(
            outside
                .iter()
                .map(Op::summary)
                .collect::<Vec<_>>()
                .join("; "),
        ),
        config_commit: first.commit.clone(),
        ..Entry::new(&first.by, "outside", "config.outside", "recorded")
    };
    if let Err(err) = w.record(&e) {
        eprintln!("golcondad: the audit entry of an outside change: {err}");
    }
}

/// Commit the candidate of `system`, with `message`.
pub fn commit(
    app: &App,
    w: &Writes,
    who: &Identity,
    via: &str,
    system: &str,
    doc: &Path,
    message: &str,
) -> Outcome {
    if let Some(o) = may_write(app, w, who, via, "config.commit", system) {
        return o;
    }
    let (git, rel, branch) = match repo_of(w, doc) {
        Ok(r) => r,
        Err(e) => return Outcome::Failed(e),
    };
    let repo = Repo {
        git: &git,
        document: &rel,
        remote: w.push.as_deref().map(|r| (r, branch.as_str())),
    };
    let eval = commit::Iets {
        iets: &app.iets,
        platform: &app.platform,
    };
    let by = operator(who);
    let _checkout = locked(&w.checkout);
    let mut journal = locked(&w.journal);
    let done = commit::commit_with(&mut journal, &repo, &eval, system, &by, message, |c| {
        record_outside(w, system, &c.outside);
        w.record(&Entry {
            system: Some(system.into()),
            rev: c.ops.last().map(|o| o.rev),
            target: Some(c.ops.iter().map(Op::summary).collect::<Vec<_>>().join("; ")),
            config_commit: Some(c.id.clone()),
            ..Entry::new(&by, via, "config.commit", "ok")
        })
    });
    match done {
        Ok(c) => Outcome::Done(json!({
            "commit": c.id, "pushed": c.pushed,
            "ops": c.ops.iter().map(Op::to_json).collect::<Vec<_>>(),
            "outside": c.outside.iter().map(Op::to_json).collect::<Vec<_>>(),
        })),
        Err(commit::Error::Conflict { outside, yours }) => {
            record_outside(w, system, &outside);
            let _ = w.record(&Entry {
                system: Some(system.into()),
                target: Some(yours.iter().map(Op::summary).collect::<Vec<_>>().join("; ")),
                ..Entry::new(&by, via, "config.commit", "refused")
            });
            Outcome::Conflict {
                yours: Value::Array(yours.iter().map(Op::to_json).collect()),
                theirs: outside,
            }
        }
        Err(commit::Error::Nothing) => Outcome::Bad("nothing to commit".into()),
        Err(commit::Error::Invalid(e)) => {
            let _ = w.record(&Entry {
                system: Some(system.into()),
                ..Entry::new(&by, via, "config.commit", "refused")
            });
            Outcome::Invalid(vec![Problem {
                line: None,
                path: String::new(),
                message: e,
            }])
        }
        Err(e) => Outcome::Failed(e.to_string()),
    }
}

/// Drop the candidate's open operations.
pub fn discard(app: &App, w: &Writes, who: &Identity, via: &str, system: &str) -> Outcome {
    if let Some(o) = may_write(app, w, who, via, "config.discard", system) {
        return o;
    }
    let mut journal = locked(&w.journal);
    let open = match journal.open_ops(system) {
        Ok(o) => o,
        Err(e) => return Outcome::Failed(e.to_string()),
    };
    if open.is_empty() {
        return Outcome::Bad("nothing to discard".into());
    }
    let e = Entry {
        system: Some(system.into()),
        rev: open.last().map(|o| o.rev),
        target: Some(open.iter().map(Op::summary).collect::<Vec<_>>().join("; ")),
        ..Entry::new(&operator(who), via, "config.discard", "ok")
    };
    if let Err(err) = w.record(&e) {
        return Outcome::Failed(format!("not recorded, so not discarded: {err}"));
    }
    match journal.discard(system) {
        Ok(ops) => {
            Outcome::Done(json!({ "discarded": ops.iter().map(Op::to_json).collect::<Vec<_>>() }))
        }
        Err(e) => Outcome::Failed(e.to_string()),
    }
}

/// Fetch every system's remote and record what is new: the timer's work.
pub fn fetch_all(app: &App, w: &Writes) {
    for (system, doc) in &app.systems {
        let Ok((git, rel, branch)) = repo_of(w, doc) else {
            continue;
        };
        let Some(remote) = w.push.as_deref() else {
            return;
        };
        let repo = Repo {
            git: &git,
            document: &rel,
            remote: Some((remote, branch.as_str())),
        };
        let eval = commit::Iets {
            iets: &app.iets,
            platform: &app.platform,
        };
        let _checkout = locked(&w.checkout);
        let mut journal = locked(&w.journal);
        match commit::fetch(&mut journal, &repo, &eval, system) {
            Ok(outside) => record_outside(w, system, &outside),
            Err(e) => eprintln!("golcondad: fetching {system}: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::os;
    use tempfile::TempDir;

    #[test]
    fn an_entry_reaches_the_journal_as_fields() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("journal.sock");
        let sock = os::unix::net::UnixDatagram::bind(&path).unwrap();
        let who = Operator {
            id: "alice@example.com".into(),
            name: "Alice".into(),
        };
        let e = Entry {
            system: Some("server".into()),
            target: Some("/services/sshd port".into()),
            after: Some(json!(2222)),
            ..Entry::new(&who, "web", "config.set", "ok")
        };
        send_journal(&path, &e);
        let mut buf = [0u8; 4096];
        let n = sock.recv(&mut buf).unwrap();
        let got = String::from_utf8_lossy(&buf[..n]).into_owned();
        for field in [
            "SYSLOG_IDENTIFIER=golcondad\n",
            "MESSAGE=config.set server /services/sshd port: 2222\n",
            "GOLCONDA_ACTION=config.set\n",
            "GOLCONDA_OPERATOR=alice@example.com\n",
            "GOLCONDA_RESULT=ok\n",
            "GOLCONDA_SYSTEM=server\n",
        ] {
            assert!(got.contains(field), "{field:?} in {got:?}");
        }
    }

    #[test]
    fn form_values_become_toml() {
        assert_eq!(form_value("string", "Europe/Berlin"), "\"Europe/Berlin\"");
        assert_eq!(form_value("string", "a\"b"), "'a\"b'");
        assert_eq!(
            form_value("lines", "ssh-ed25519 A x\r\n\n  ssh-ed25519 B y  \n"),
            "[\"ssh-ed25519 A x\", \"ssh-ed25519 B y\"]"
        );
        assert_eq!(form_value("lines", ""), "[]");
        assert_eq!(form_value("toml", "2222"), "2222");
        assert_eq!(form_value("", "{ a = 1 }"), "{ a = 1 }");
    }
}
