//! The candidate: one per system, the committed document plus the operations not yet
//! committed. Operations live in a journal, an SQLite database, so a
//! restart keeps them; the document file changes only at commit.
//!
//! Each operation gets the system's next revision. An operation names the revision it was
//! made on (its base) and is refused when an operation after that base touched the same
//! path, a path inside it or a path that contains it: edits to different options never
//! conflict. It is checked against the schema before it is recorded; evaluation comes at
//! commit.
//!
//! Writers are serialised by SQLite (`BEGIN IMMEDIATE`, a busy timeout), so two daemons, or
//! two threads with a connection each, on one journal do not race.

use crate::check::{Problem, schema_problems};
use crate::diff;
use crate::document::{self, EditError, parse_value, path_name};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Who made an operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Operator {
    /// the OIDC subject; `outside` for a change the daemon did not make
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Edit {
    /// the value as TOML text
    Set(String),
    Delete,
}

/// An operation asked for.
#[derive(Debug, Clone)]
pub struct Request {
    /// the revision the operator saw
    pub base: u64,
    pub module: String,
    /// the option path in the module; empty for the module's whole table
    pub path: Vec<String>,
    pub edit: Edit,
    pub by: Operator,
    /// where it came from: web, cli, tui
    pub via: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Open,
    Committed,
    Discarded,
}

/// An operation in the journal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Op {
    pub rev: u64,
    pub base: u64,
    pub module: String,
    pub path: Vec<String>,
    pub edit: Edit,
    pub by: Operator,
    pub via: String,
    /// UTC, RFC 3339
    pub at: String,
    pub state: State,
    /// the git commit it is in, once committed
    pub commit: Option<String>,
}

impl Op {
    /// `set /services/sshd port 2222`, `delete /network`
    pub fn summary(&self) -> String {
        let p: Vec<&str> = self.path.iter().map(String::as_str).collect();
        match &self.edit {
            Edit::Set(v) => format!("set {} {v}", path_name(&self.module, &p)),
            Edit::Delete => format!("delete {}", path_name(&self.module, &p)),
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "rev": self.rev, "base": self.base, "module": self.module, "path": self.path,
            "op": match self.edit { Edit::Set(_) => "set", Edit::Delete => "delete" },
            "value": match &self.edit { Edit::Set(v) => Value::String(v.clone()), Edit::Delete => Value::Null },
            "by": { "id": self.by.id, "name": self.by.name }, "via": self.via, "at": self.at,
            "state": match self.state { State::Open => "open", State::Committed => "committed", State::Discarded => "discarded" },
            "commit": self.commit,
        })
    }

    /// The document with this operation applied.
    fn apply_to(&self, text: &str) -> Result<String, EditError> {
        let p: Vec<&str> = self.path.iter().map(String::as_str).collect();
        match &self.edit {
            Edit::Set(v) => document::set(text, &self.module, &p, parse_value(v)),
            Edit::Delete => document::delete(text, &self.module, &p),
        }
    }
}

/// Two paths touch each other: the same module, and one path is the other or inside it.
pub fn overlaps(a_module: &str, a: &[String], b_module: &str, b: &[String]) -> bool {
    a_module == b_module && (a.starts_with(b) || b.starts_with(a))
}

/// Why an operation was not recorded.
#[derive(Debug, thiserror::Error)]
pub enum Refused {
    /// operations after the base touched this path: theirs, in order
    #[error("conflict: {}", .0.iter().map(|o| format!("{} by {} (rev {})", o.summary(), o.by.name, o.rev)).collect::<Vec<_>>().join("; "))]
    Conflict(Vec<Op>),
    /// the schema's problems this operation would add
    #[error("{}", .0.iter().map(|p| format!("{}: {}", p.path, p.message)).collect::<Vec<_>>().join("; "))]
    Invalid(Vec<Problem>),
    #[error(transparent)]
    Edit(EditError),
    #[error("base revision {base} is ahead of the candidate's revision {revision}")]
    Base { base: u64, revision: u64 },
    #[error("the journal: {0}")]
    Journal(#[from] rusqlite::Error),
    /// the record of it (the audit entry) could not be written, so it was not made
    #[error("not recorded: {0}")]
    Record(String),
}

/// The operation journal of every system.
pub struct Journal {
    conn: Connection,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS ops (
    system TEXT NOT NULL,
    rev INTEGER NOT NULL,
    base INTEGER NOT NULL,
    module TEXT NOT NULL,
    path TEXT NOT NULL,           -- JSON array
    edit TEXT NOT NULL CHECK (edit IN ('set', 'delete')),
    value TEXT,                   -- TOML, for set
    operator_id TEXT NOT NULL,
    operator_name TEXT NOT NULL,
    via TEXT NOT NULL,
    at TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'committed', 'discarded')),
    commit_id TEXT,               -- the git commit, once committed
    PRIMARY KEY (system, rev)
);";

impl Journal {
    pub fn open(path: &Path) -> rusqlite::Result<Journal> {
        Journal::setup(Connection::open(path)?)
    }

    pub fn in_memory() -> rusqlite::Result<Journal> {
        Journal::setup(Connection::open_in_memory()?)
    }

    fn setup(conn: Connection) -> rusqlite::Result<Journal> {
        conn.busy_timeout(Duration::from_secs(10))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Journal { conn })
    }

    /// The system's revision: the last operation's, 0 before any.
    pub fn revision(&self, system: &str) -> rusqlite::Result<u64> {
        revision(&self.conn, system)
    }

    /// The operations not yet committed or discarded, in order.
    pub fn open_ops(&self, system: &str) -> rusqlite::Result<Vec<Op>> {
        ops(&self.conn, system, "state = 'open'", 0)
    }

    /// Every operation after `rev`, whatever its state.
    pub fn since(&self, system: &str, rev: u64) -> rusqlite::Result<Vec<Op>> {
        ops(&self.conn, system, "1", rev)
    }

    /// The candidate's document: `committed` with the open operations applied.
    pub fn candidate(&self, system: &str, committed: &str) -> Result<String, Refused> {
        candidate(&self.open_ops(system)?, committed)
    }

    /// Record an operation on the candidate of `system`, whose committed document is
    /// `committed`, if it conflicts with nothing after its base and adds no problem the
    /// `schema` finds. The recorded operation.
    pub fn apply(
        &mut self,
        system: &str,
        committed: &str,
        schema: &Value,
        r: Request,
    ) -> Result<Op, Refused> {
        self.apply_with(system, committed, schema, r, |_| Ok(()))
    }

    /// `apply`, with `record` run on the operation before it is committed to the journal: the
    /// audit entry, written before the operation exists. If it fails, nothing is recorded.
    pub fn apply_with(
        &mut self,
        system: &str,
        committed: &str,
        schema: &Value,
        r: Request,
        record: impl FnOnce(&Op) -> Result<(), String>,
    ) -> Result<Op, Refused> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let revision = revision(&tx, system)?;
        if r.base > revision {
            return Err(Refused::Base {
                base: r.base,
                revision,
            });
        }
        let theirs: Vec<Op> = ops(&tx, system, "1", r.base)?
            .into_iter()
            .filter(|o| overlaps(&o.module, &o.path, &r.module, &r.path))
            .collect();
        if !theirs.is_empty() {
            return Err(Refused::Conflict(theirs));
        }
        // the value as TOML writes it: what the journal and the commit message show
        let edit = match r.edit {
            Edit::Set(v) => Edit::Set(parse_value(&v).to_string().trim().to_string()),
            Edit::Delete => Edit::Delete,
        };
        let op = Op {
            rev: revision + 1,
            base: r.base,
            module: r.module,
            path: r.path,
            edit,
            by: r.by,
            via: r.via,
            at: now(),
            state: State::Open,
            commit: None,
        };
        let before = candidate(&ops(&tx, system, "state = 'open'", 0)?, committed)?;
        let after = op.apply_to(&before).map_err(Refused::Edit)?;
        let had = schema_problems(schema, &before, &before).map_err(Refused::Edit)?;
        let new: Vec<Problem> = schema_problems(schema, &after, &before)
            .map_err(Refused::Edit)?
            .into_iter()
            .filter(|p| {
                !had.iter()
                    .any(|h| h.path == p.path && h.message == p.message)
            })
            .collect();
        if !new.is_empty() {
            return Err(Refused::Invalid(new));
        }
        insert(&tx, system, &op)?;
        record(&op).map_err(Refused::Record)?;
        tx.commit()?;
        Ok(op)
    }

    /// Drop the open operations; the journal keeps them, discarded. Those it dropped.
    pub fn discard(&mut self, system: &str) -> rusqlite::Result<Vec<Op>> {
        self.close(system, "discarded", None)
    }

    /// The open operations are in the git commit `id` now. Those it marked.
    pub fn committed(&mut self, system: &str, id: &str) -> rusqlite::Result<Vec<Op>> {
        self.close(system, "committed", Some(id))
    }

    /// The commit `id` was undone: its operations are open again.
    pub fn reopen(&mut self, system: &str, id: &str) -> rusqlite::Result<()> {
        self.conn.execute(
            "UPDATE ops SET state = 'open', commit_id = NULL WHERE system = ?1 AND commit_id = ?2",
            params![system, id],
        )?;
        Ok(())
    }

    fn close(&mut self, system: &str, state: &str, id: Option<&str>) -> rusqlite::Result<Vec<Op>> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let open = ops(&tx, system, "state = 'open'", 0)?;
        tx.execute(
            "UPDATE ops SET state = ?2, commit_id = ?3 WHERE system = ?1 AND state = 'open'",
            params![system, state, id],
        )?;
        tx.commit()?;
        Ok(open)
    }

    /// A change the daemon did not make (a commit someone pushed): one operation per path the
    /// semantic diff names, by `by` (the operator `outside` with the commit's author), already
    /// committed in `commit`. They take revisions like any other, so the conflict rule
    /// counts them.
    pub fn record_outside(
        &mut self,
        system: &str,
        changes: &[diff::Change],
        by: &Operator,
        commit: &str,
    ) -> rusqlite::Result<Vec<Op>> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let base = revision(&tx, system)?;
        let mut recorded = Vec::new();
        for (rev, c) in (base + 1..).zip(changes) {
            let edit = match (&c.after.value, c.after.explicit) {
                (Some(v), true) => Edit::Set(document::toml_text(v)),
                _ => Edit::Delete,
            };
            let op = Op {
                rev,
                base,
                module: c.module.clone(),
                path: c.path.clone(),
                edit,
                by: by.clone(),
                via: "outside".into(),
                at: now(),
                state: State::Committed,
                commit: Some(commit.to_string()),
            };
            insert(&tx, system, &op)?;
            recorded.push(op);
        }
        tx.commit()?;
        Ok(recorded)
    }
}

fn insert(conn: &Connection, system: &str, op: &Op) -> rusqlite::Result<()> {
    let value = match &op.edit {
        Edit::Set(v) => Some(v.as_str()),
        Edit::Delete => None,
    };
    let state = match op.state {
        State::Open => "open",
        State::Committed => "committed",
        State::Discarded => "discarded",
    };
    conn.execute(
        "INSERT INTO ops (system, rev, base, module, path, edit, value, operator_id,
         operator_name, via, at, state, commit_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
        params![
            system,
            sql(op.rev),
            sql(op.base),
            op.module,
            Value::from(op.path.clone()).to_string(),
            if value.is_some() { "set" } else { "delete" },
            value,
            op.by.id,
            op.by.name,
            op.via,
            op.at,
            state,
            op.commit,
        ],
    )?;
    Ok(())
}

/// A revision as SQLite stores it: its integers are signed, revisions never come near the end.
fn sql(rev: u64) -> i64 {
    i64::try_from(rev).unwrap_or(i64::MAX)
}

fn revision_of(n: i64) -> u64 {
    u64::try_from(n).unwrap_or(0)
}

fn revision(conn: &Connection, system: &str) -> rusqlite::Result<u64> {
    conn.query_row(
        "SELECT max(rev) FROM ops WHERE system = ?1",
        [system],
        |r| r.get::<_, Option<i64>>(0),
    )
    .optional()
    .map(|r| r.flatten().map_or(0, revision_of))
}

fn ops(conn: &Connection, system: &str, filter: &str, after: u64) -> rusqlite::Result<Vec<Op>> {
    let mut q = conn.prepare(&format!(
        "SELECT rev, base, module, path, edit, value, operator_id, operator_name, via, at, state,
         commit_id FROM ops WHERE system = ?1 AND rev > ?2 AND {filter} ORDER BY rev"
    ))?;
    let rows = q.query_map(params![system, sql(after)], |r| {
        let path: String = r.get(3)?;
        let edit: String = r.get(4)?;
        let state: String = r.get(10)?;
        Ok(Op {
            rev: revision_of(r.get(0)?),
            base: revision_of(r.get(1)?),
            module: r.get(2)?,
            path: serde_json::from_str(&path).unwrap_or_default(),
            edit: if edit == "set" {
                Edit::Set(r.get(5)?)
            } else {
                Edit::Delete
            },
            by: Operator {
                id: r.get(6)?,
                name: r.get(7)?,
            },
            via: r.get(8)?,
            at: r.get(9)?,
            state: match state.as_str() {
                "committed" => State::Committed,
                "discarded" => State::Discarded,
                _ => State::Open,
            },
            commit: r.get(11)?,
        })
    })?;
    rows.collect()
}

fn candidate(open: &[Op], committed: &str) -> Result<String, Refused> {
    open.iter().try_fold(committed.to_string(), |text, op| {
        op.apply_to(&text).map_err(Refused::Edit)
    })
}

/// Now, UTC, as RFC 3339 to the second.
pub fn now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    rfc3339(secs)
}

/// Seconds since 1970 as `YYYY-MM-DDTHH:MM:SSZ` (the days-to-civil algorithm, proleptic
/// Gregorian).
pub fn rfc3339(secs: u64) -> String {
    let (days, rest) = (
        i64::try_from(secs / 86400).unwrap_or(i64::MAX),
        secs % 86400,
    );
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::thread;
    use tempfile::TempDir;

    const DOC: &str = "[\"/system\"]\nname = \"s\"\n\n[\"/services/sshd\"]\nport = 22\n";

    fn schema() -> Value {
        json!({ "type": "object", "additionalProperties": false, "properties": {
            "/system": { "type": "object" },
            "/network": { "type": "object", "properties": {
                "networks": { "type": "object" }, "defaultDhcp": { "type": "boolean" } } },
            "/services/sshd": { "type": "object", "additionalProperties": false, "properties": {
                "port": { "type": "integer", "minimum": 1 },
                "authorizedKeys": { "type": "array" }
            }}
        }})
    }

    fn who(n: &str) -> Operator {
        Operator {
            id: format!("id-{n}"),
            name: n.into(),
        }
    }

    fn req(base: u64, module: &str, path: &str, edit: Edit, by: &str) -> Request {
        Request {
            base,
            module: module.into(),
            path: if path.is_empty() {
                vec![]
            } else {
                path.split('.').map(str::to_string).collect()
            },
            edit,
            by: who(by),
            via: "web".into(),
        }
    }

    fn set(v: &str) -> Edit {
        Edit::Set(v.into())
    }

    #[test]
    fn an_operation_gets_the_next_revision_and_changes_the_candidate_only() {
        let mut j = Journal::in_memory().unwrap();
        assert_eq!(j.revision("s").unwrap(), 0);
        let op = j
            .apply(
                "s",
                DOC,
                &schema(),
                req(0, "/services/sshd", "port", set("2222"), "alice"),
            )
            .unwrap();
        assert_eq!((op.rev, op.base, op.state), (1, 0, State::Open));
        assert_eq!(op.summary(), "set /services/sshd port 2222");
        assert_eq!(j.revision("s").unwrap(), 1);
        assert_eq!(
            j.candidate("s", DOC).unwrap(),
            DOC.replace("port = 22", "port = 2222")
        );
        // another system has its own revisions
        assert_eq!(j.revision("t").unwrap(), 0);
    }

    #[test]
    fn edits_to_different_options_never_conflict() {
        let mut j = Journal::in_memory().unwrap();
        j.apply(
            "s",
            DOC,
            &schema(),
            req(0, "/services/sshd", "port", set("2222"), "alice"),
        )
        .unwrap();
        // bob saw revision 0 too
        let op = j
            .apply(
                "s",
                DOC,
                &schema(),
                req(0, "/services/sshd", "authorizedKeys", set("[]"), "bob"),
            )
            .unwrap();
        assert_eq!(op.rev, 2);
        let text = j.candidate("s", DOC).unwrap();
        assert!(
            text.contains("port = 2222\nauthorizedKeys = []\n"),
            "{text}"
        );
    }

    #[test]
    fn the_same_path_inside_it_or_containing_it_conflicts() {
        let cases = [
            ("/services/sshd", "port", "/services/sshd", "port"),
            ("/network", "networks", "/network", "networks.lan"),
            ("/network", "networks.lan", "/network", "networks"),
            ("/services/sshd", "", "/services/sshd", "port"),
            ("/services/sshd", "port", "/services/sshd", ""),
        ];
        for (m1, p1, m2, p2) in cases {
            let mut j = Journal::in_memory().unwrap();
            let first = if p1.is_empty() {
                Edit::Delete
            } else if p1 == "port" {
                set("2222")
            } else {
                set("{}")
            };
            j.apply("s", DOC, &json!({}), req(0, m1, p1, first, "alice"))
                .unwrap();
            let second = if p2.is_empty() {
                Edit::Delete
            } else if p2 == "port" {
                set("2200")
            } else {
                set("{}")
            };
            match j.apply("s", DOC, &json!({}), req(0, m2, p2, second.clone(), "bob")) {
                Err(Refused::Conflict(theirs)) => {
                    assert_eq!(theirs.len(), 1);
                    assert_eq!(theirs[0].by.name, "alice");
                }
                other => panic!("{m1} {p1} / {m2} {p2}: {other:?}"),
            }
            // on top of alice's revision it goes in
            assert!(
                j.apply("s", DOC, &json!({}), req(1, m2, p2, second, "bob"))
                    .is_ok(),
                "{m2} {p2}"
            );
        }
        // another module, or a sibling path: no conflict
        assert!(!overlaps("/a", &["x".into()], "/b", &["x".into()]));
        assert!(!overlaps(
            "/a",
            &["x".into(), "y".into()],
            "/a",
            &["x".into(), "z".into()]
        ));
        assert!(!overlaps("/a", &["xy".into()], "/a", &["x".into()]));
    }

    #[test]
    fn a_conflict_counts_committed_and_discarded_operations_too() {
        let mut j = Journal::in_memory().unwrap();
        j.apply(
            "s",
            DOC,
            &schema(),
            req(0, "/services/sshd", "port", set("2222"), "alice"),
        )
        .unwrap();
        j.committed("s", "c1").unwrap();
        let e = j.apply(
            "s",
            DOC,
            &schema(),
            req(0, "/services/sshd", "port", set("2200"), "bob"),
        );
        assert!(matches!(e, Err(Refused::Conflict(_))), "{e:?}");
    }

    #[test]
    fn a_base_ahead_of_the_candidate_is_refused() {
        let mut j = Journal::in_memory().unwrap();
        let e = j.apply(
            "s",
            DOC,
            &schema(),
            req(3, "/services/sshd", "port", set("1"), "alice"),
        );
        assert!(
            matches!(
                e,
                Err(Refused::Base {
                    base: 3,
                    revision: 0
                })
            ),
            "{e:?}"
        );
    }

    #[test]
    fn an_operation_the_schema_refuses_is_not_recorded() {
        let mut j = Journal::in_memory().unwrap();
        let e = j.apply(
            "s",
            DOC,
            &schema(),
            req(0, "/services/sshd", "port", set("0"), "alice"),
        );
        match e {
            Err(Refused::Invalid(p)) => assert_eq!(p[0].message, "0 is less than 1"),
            other => panic!("{other:?}"),
        }
        let e = j.apply(
            "s",
            DOC,
            &schema(),
            req(0, "/services/sshd", "prot", set("1"), "alice"),
        );
        assert!(matches!(e, Err(Refused::Invalid(_))), "{e:?}");
        assert_eq!(j.revision("s").unwrap(), 0);
        // a problem the document had already does not stop another edit
        let broken = DOC.replace("port = 22", "port = 0");
        assert!(
            j.apply(
                "s",
                &broken,
                &schema(),
                req(0, "/services/sshd", "authorizedKeys", set("[]"), "alice")
            )
            .is_ok()
        );
    }

    #[test]
    fn discard_and_commit_close_the_open_operations_and_revisions_go_on() {
        let mut j = Journal::in_memory().unwrap();
        j.apply(
            "s",
            DOC,
            &schema(),
            req(0, "/services/sshd", "port", set("2222"), "alice"),
        )
        .unwrap();
        let dropped = j.discard("s").unwrap();
        assert_eq!(dropped.len(), 1);
        assert_eq!(j.candidate("s", DOC).unwrap(), DOC);
        assert_eq!(j.open_ops("s").unwrap(), Vec::<Op>::new());
        let op = j
            .apply(
                "s",
                DOC,
                &schema(),
                req(1, "/services/sshd", "port", set("2200"), "alice"),
            )
            .unwrap();
        assert_eq!(op.rev, 2);
        assert_eq!(j.committed("s", "c1").unwrap().len(), 1);
        let states: Vec<State> = j.since("s", 0).unwrap().iter().map(|o| o.state).collect();
        assert_eq!(states, vec![State::Discarded, State::Committed]);
    }

    #[test]
    fn an_operation_whose_record_fails_is_not_recorded() {
        let mut j = Journal::in_memory().unwrap();
        let r = req(0, "/services/sshd", "port", set("2222"), "alice");
        let e = j.apply_with("s", DOC, &schema(), r.clone(), |op| {
            assert_eq!(op.rev, 1);
            Err("the audit log is full".into())
        });
        assert!(
            matches!(e, Err(Refused::Record(ref m)) if m == "the audit log is full"),
            "{e:?}"
        );
        assert_eq!(j.revision("s").unwrap(), 0);
        // the hook sees the operation it is about, and it goes in when the hook says yes
        let op = j.apply_with("s", DOC, &schema(), r, |_| Ok(())).unwrap();
        assert_eq!(op.rev, 1);
    }

    #[test]
    fn a_restart_keeps_the_journal() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        let path = dir.join("journal.db");
        {
            let mut j = Journal::open(&path).unwrap();
            j.apply(
                "s",
                DOC,
                &schema(),
                req(0, "/services/sshd", "port", set("2222"), "alice"),
            )
            .unwrap();
        }
        let j = Journal::open(&path).unwrap();
        assert_eq!(j.revision("s").unwrap(), 1);
        assert_eq!(j.open_ops("s").unwrap()[0].by.name, "alice");
    }

    #[test]
    fn writers_at_the_same_time_get_one_revision_each_and_one_wins_a_conflict() {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        let path = dir.join("journal.db");
        Journal::open(&path).unwrap();
        let run = |options: Vec<&'static str>| {
            let handles: Vec<_> = options
                .into_iter()
                .enumerate()
                .map(|(i, option)| {
                    let path = path.clone();
                    thread::spawn(move || {
                        // a connection each, as two daemons would have
                        let mut j = Journal::open(&path).unwrap();
                        let module = "/network";
                        j.apply(
                            "s",
                            DOC,
                            &json!({}),
                            req(0, module, option, set(&format!("\"{i}\"")), "x"),
                        )
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().unwrap())
                .collect::<Vec<_>>()
        };
        // eight different options, all on base 0: all go in, revisions 1 to 8
        let done = run((0..8)
            .map(|i| ["a", "b", "c", "d", "e", "f", "g", "h"][i])
            .collect());
        let mut revs: Vec<u64> = done.iter().map(|r| r.as_ref().unwrap().rev).collect();
        revs.sort_unstable();
        assert_eq!(revs, (1..=8).collect::<Vec<_>>());
        // eight writers of one option on base 0 (after the first eight: a fresh system)
        let done: Vec<_> = {
            let handles: Vec<_> = (0..8)
                .map(|i| {
                    let path = path.clone();
                    thread::spawn(move || {
                        let mut j = Journal::open(&path).unwrap();
                        j.apply(
                            "t",
                            DOC,
                            &json!({}),
                            req(0, "/network", "same", set(&format!("\"{i}\"")), "x"),
                        )
                    })
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        };
        assert_eq!(done.iter().filter(|r| r.is_ok()).count(), 1);
        assert_eq!(
            done.iter()
                .filter(|r| matches!(r, Err(Refused::Conflict(_))))
                .count(),
            7
        );
    }

    #[test]
    fn rfc3339_dates() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(1_793_908_800 + 3661), "2026-11-05T21:01:01Z");
        assert_eq!(rfc3339(4_107_542_399), "2100-02-28T23:59:59Z");
    }
}
