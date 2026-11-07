//! Live updates: one stream of Server-Sent Events per system, for the optional script.
//!
//! Events: `rev` (an operation, a commit, a discard), `lock` (taken, given up, broken), `job`
//! (a line of a job's output, or its end) and `presence` (who has which page of the system
//! open). Presence comes from the open streams: each one names the page it shows. The pages
//! work without any of it; the stream only carries news one way.

use crate::app::Identity;
use crate::locked;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub struct Event {
    pub system: String,
    pub kind: &'static str,
    pub data: Value,
}

struct Viewer {
    system: String,
    name: String,
    page: String,
}

pub struct Hub {
    tx: broadcast::Sender<Event>,
    viewers: Mutex<HashMap<u64, Viewer>>,
    next: AtomicU64,
}

impl Default for Hub {
    fn default() -> Self {
        Hub {
            tx: broadcast::channel(1024).0,
            viewers: Mutex::default(),
            next: AtomicU64::new(1),
        }
    }
}

impl Hub {
    /// Tells everyone who watches `system`; nobody watching is no error.
    pub fn send(&self, system: &str, kind: &'static str, data: Value) {
        let _ = self.tx.send(Event {
            system: system.into(),
            kind,
            data,
        });
    }

    /// Who has which page of `system` open: one entry per person and page.
    fn presence(&self, system: &str) -> Value {
        let mut seen: Vec<(String, String)> = locked(&self.viewers)
            .values()
            .filter(|v| v.system == system)
            .map(|v| (v.name.clone(), v.page.clone()))
            .collect();
        seen.sort();
        seen.dedup();
        Value::Array(
            seen.into_iter()
                .map(|(name, page)| json!({ "name": name, "page": page }))
                .collect(),
        )
    }

    /// A stream opens: its id (for `leave`) and its events, the presence first.
    pub fn join(
        &self,
        system: &str,
        who: &Identity,
        page: &str,
    ) -> (u64, broadcast::Receiver<Event>) {
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let rx = self.tx.subscribe();
        locked(&self.viewers).insert(
            id,
            Viewer {
                system: system.into(),
                name: who.name.clone(),
                page: page.into(),
            },
        );
        self.send(system, "presence", self.presence(system));
        (id, rx)
    }

    /// A stream closed.
    pub fn leave(&self, id: u64) {
        let gone = locked(&self.viewers).remove(&id);
        if let Some(v) = gone {
            self.send(&v.system, "presence", self.presence(&v.system));
        }
    }
}
