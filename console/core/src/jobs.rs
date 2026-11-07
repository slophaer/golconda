//! Jobs: what the daemon does to machines (update, reboot, confirm, roll back, deploy), with
//! their state and output kept in SQLite (`jobs.db` in its state directory), so a job's log stays
//! readable after it ends and after a restart.
//!
//! A job is queued, runs, and ends ok or failed. A restart finds the jobs that had not ended and
//! marks them interrupted: nothing resumes a half-done job behind the operator's back.

use crate::candidate::{Operator, rfc3339};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("the job store: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("no job {0}")]
    NoJob(i64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Queued,
    Running,
    Ok,
    Failed,
    /// the daemon stopped while it ran or waited
    Interrupted,
}

impl State {
    pub fn name(self) -> &'static str {
        match self {
            State::Queued => "queued",
            State::Running => "running",
            State::Ok => "ok",
            State::Failed => "failed",
            State::Interrupted => "interrupted",
        }
    }

    fn parse(s: &str) -> State {
        match s {
            "queued" => State::Queued,
            "running" => State::Running,
            "ok" => State::Ok,
            "failed" => State::Failed,
            _ => State::Interrupted,
        }
    }

    pub fn ended(self) -> bool {
        matches!(self, State::Ok | State::Failed | State::Interrupted)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    pub id: i64,
    /// update, reboot, confirm, rollback, deploy
    pub kind: String,
    pub system: String,
    /// None: the whole system (deploy)
    pub machine: Option<String>,
    pub by: Operator,
    pub state: State,
    pub created: String,
    pub started: Option<String>,
    pub ended: Option<String>,
    /// one line: what came of it
    pub summary: Option<String>,
}

impl Job {
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id, "kind": self.kind, "system": self.system, "machine": self.machine,
            "by": { "id": self.by.id, "name": self.by.name }, "state": self.state.name(),
            "created": self.created, "started": self.started, "ended": self.ended,
            "summary": self.summary,
        })
    }
}

fn now() -> String {
    rfc3339(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs()),
    )
}

pub struct Jobs {
    conn: Connection,
}

const COLUMNS: &str = "id, kind, system, machine, operator_id, operator_name, state, created, started, ended, summary";

fn job_of(r: &rusqlite::Row<'_>) -> rusqlite::Result<Job> {
    Ok(Job {
        id: r.get(0)?,
        kind: r.get(1)?,
        system: r.get(2)?,
        machine: r.get(3)?,
        by: Operator {
            id: r.get(4)?,
            name: r.get(5)?,
        },
        state: State::parse(&r.get::<_, String>(6)?),
        created: r.get(7)?,
        started: r.get(8)?,
        ended: r.get(9)?,
        summary: r.get(10)?,
    })
}

impl Jobs {
    /// Opens (or creates) the store; the jobs a previous run left unended become interrupted.
    pub fn open(path: &Path) -> Result<Jobs, Error> {
        let conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS jobs (
               id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, system TEXT NOT NULL,
               machine TEXT, operator_id TEXT NOT NULL, operator_name TEXT NOT NULL,
               state TEXT NOT NULL, created TEXT NOT NULL, started TEXT, ended TEXT, summary TEXT);
             CREATE TABLE IF NOT EXISTS lines (
               job INTEGER NOT NULL REFERENCES jobs(id), n INTEGER NOT NULL, at TEXT NOT NULL,
               line TEXT NOT NULL, PRIMARY KEY (job, n));",
        )?;
        conn.execute(
            "UPDATE jobs SET state = 'interrupted', ended = ?1,
               summary = 'the daemon stopped before it ended'
             WHERE state IN ('queued', 'running')",
            [now()],
        )?;
        Ok(Jobs { conn })
    }

    /// A new queued job; its id.
    pub fn create(
        &self,
        kind: &str,
        system: &str,
        machine: Option<&str>,
        by: &Operator,
    ) -> Result<i64, Error> {
        self.conn.execute(
            "INSERT INTO jobs (kind, system, machine, operator_id, operator_name, state, created)
             VALUES (?1, ?2, ?3, ?4, ?5, 'queued', ?6)",
            params![kind, system, machine, by.id, by.name, now()],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn start(&self, id: i64) -> Result<(), Error> {
        self.set(
            "UPDATE jobs SET state = 'running', started = ?2 WHERE id = ?1 AND state = 'queued'",
            id,
            &now(),
        )
    }

    /// Ends a job ok or failed, with one line of what came of it.
    pub fn end(&self, id: i64, ok: bool, summary: &str) -> Result<(), Error> {
        let n = self.conn.execute(
            "UPDATE jobs SET state = ?2, ended = ?3, summary = ?4 WHERE id = ?1",
            params![id, if ok { "ok" } else { "failed" }, now(), summary],
        )?;
        if n == 0 {
            return Err(Error::NoJob(id));
        }
        Ok(())
    }

    fn set(&self, sql: &str, id: i64, at: &str) -> Result<(), Error> {
        if self.conn.execute(sql, params![id, at])? == 0 {
            return Err(Error::NoJob(id));
        }
        Ok(())
    }

    /// Appends one line of output.
    pub fn log(&self, id: i64, line: &str) -> Result<(), Error> {
        self.conn.execute(
            "INSERT INTO lines (job, n, at, line)
             VALUES (?1, (SELECT COALESCE(MAX(n), 0) + 1 FROM lines WHERE job = ?1), ?2, ?3)",
            params![id, now(), line],
        )?;
        Ok(())
    }

    pub fn get(&self, id: i64) -> Result<Job, Error> {
        self.conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM jobs WHERE id = ?1"),
                [id],
                job_of,
            )
            .optional()?
            .ok_or(Error::NoJob(id))
    }

    /// A job's output lines after line `after` (0: all): (n, at, line).
    pub fn lines(&self, id: i64, after: i64) -> Result<Vec<(i64, String, String)>, Error> {
        let mut q = self
            .conn
            .prepare("SELECT n, at, line FROM lines WHERE job = ?1 AND n > ?2 ORDER BY n")?;
        let rows = q.query_map(params![id, after], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// The newest jobs first, at most `limit`, of `system` when given.
    pub fn list(&self, system: Option<&str>, limit: i64) -> Result<Vec<Job>, Error> {
        let mut q = self.conn.prepare(&format!(
            "SELECT {COLUMNS} FROM jobs WHERE ?1 IS NULL OR system = ?1 ORDER BY id DESC LIMIT ?2"
        ))?;
        let rows = q.query_map(params![system, limit], job_of)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn alice() -> Operator {
        Operator {
            id: "id-alice".into(),
            name: "Alice".into(),
        }
    }

    #[test]
    fn a_job_runs_logs_and_ends() {
        let tmp = TempDir::new().unwrap();
        let j = Jobs::open(&tmp.path().join("jobs.db")).unwrap();
        let id = j
            .create("update", "server", Some("web1"), &alice())
            .unwrap();
        assert_eq!(j.get(id).unwrap().state, State::Queued);
        j.start(id).unwrap();
        j.log(id, "fetching 20261107.1").unwrap();
        j.log(id, "installed").unwrap();
        j.end(id, true, "20261107.1 installed").unwrap();
        let job = j.get(id).unwrap();
        assert_eq!(
            (job.state, job.summary.as_deref()),
            (State::Ok, Some("20261107.1 installed"))
        );
        assert!(job.started.is_some() && job.ended.is_some());
        let lines: Vec<String> = j.lines(id, 0).unwrap().into_iter().map(|l| l.2).collect();
        assert_eq!(lines, ["fetching 20261107.1", "installed"]);
        assert_eq!(j.lines(id, 1).unwrap().len(), 1, "only what came after");
        assert_eq!(j.get(id).unwrap().to_json()["machine"], "web1");
    }

    #[test]
    fn a_restart_marks_unended_jobs_interrupted() {
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("jobs.db");
        let (done, running, queued) = {
            let j = Jobs::open(&path).unwrap();
            let a = j
                .create("reboot", "server", Some("web1"), &alice())
                .unwrap();
            j.start(a).unwrap();
            j.end(a, false, "unreachable").unwrap();
            let b = j
                .create("update", "server", Some("web1"), &alice())
                .unwrap();
            j.start(b).unwrap();
            let c = j.create("deploy", "server", None, &alice()).unwrap();
            (a, b, c)
        };
        let j = Jobs::open(&path).unwrap();
        assert_eq!(j.get(done).unwrap().state, State::Failed);
        for id in [running, queued] {
            assert_eq!(j.get(id).unwrap().state, State::Interrupted);
        }
        let all = j.list(None, 10).unwrap();
        assert_eq!(
            all.iter().map(|x| x.id).collect::<Vec<_>>(),
            [queued, running, done]
        );
        assert_eq!(j.list(Some("edge"), 10).unwrap(), []);
        assert!(matches!(j.get(99), Err(Error::NoJob(99))));
    }
}
