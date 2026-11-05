//! The semantic diff: what changed between two effective configurations (mkSystem's `config`,
//! defaults included), as the operations that make one into the other.
//!
//! A change is a `set` (the new side has an explicit value) or a `delete` (it has none, so the
//! default applies again). Where both sides set a table, the diff goes down to the keys that
//! differ, so two changes to different keys have different paths (the console's conflict rule
//! compares paths). A module that only one side has is one change with an empty path.

use crate::document::{path_name, toml_text};
use serde_json::{Map, Value, json};

/// One side of a change.
#[derive(Debug, Clone, PartialEq)]
pub struct Side {
    /// None: no value (no module, no key, or an option with neither value nor default)
    pub value: Option<Value>,
    /// the document sets it
    pub explicit: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Change {
    pub module: String,
    /// the option path in the module; empty for the module itself
    pub path: Vec<String>,
    pub before: Side,
    pub after: Side,
}

impl Change {
    pub fn op(&self) -> &'static str {
        if self.after.explicit { "set" } else { "delete" }
    }

    pub fn to_json(&self) -> Value {
        let side = |s: &Side| match &s.value {
            Some(v) => json!({ "explicit": s.explicit, "value": v }),
            None => json!({ "explicit": s.explicit }),
        };
        json!({
            "op": self.op(),
            "module": self.module,
            "path": self.path,
            "before": side(&self.before),
            "after": side(&self.after),
        })
    }

    /// `set /services/sshd port 2222 (was 22)`
    pub fn to_text(&self) -> String {
        let path: Vec<&str> = self.path.iter().map(String::as_str).collect();
        let at = path_name(&self.module, &path);
        let shown = |s: &Side| s.value.as_ref().map_or("none".into(), toml_text);
        let was = match (&self.before.value, self.before.explicit) {
            (None, _) => "none".to_string(),
            (Some(v), true) => toml_text(v),
            (Some(v), false) => format!("{}, the default", toml_text(v)),
        };
        if self.after.explicit {
            format!("set {at} {} (was {was})", shown(&self.after))
        } else {
            match &self.after.value {
                Some(v) => format!("delete {at} (was {was}; now {}, the default)", toml_text(v)),
                None => format!("delete {at} (was {was})"),
            }
        }
    }
}

/// The changes from `before` to `after`, each a config: module -> option -> { value?; explicit; }.
/// In module, then path order.
pub fn diff(before: &Value, after: &Value) -> Vec<Change> {
    let empty = Map::new();
    let b = before.as_object().unwrap_or(&empty);
    let a = after.as_object().unwrap_or(&empty);
    let mut out = Vec::new();
    for module in keys(b, a) {
        match (b.get(module), a.get(module)) {
            (Some(bo), Some(ao)) => options(module, bo, ao, &mut out),
            (bo, ao) => out.push(Change {
                module: module.clone(),
                path: vec![],
                before: module_side(bo),
                after: module_side(ao),
            }),
        }
    }
    out
}

/// A module as one value: the options its document sets.
fn module_side(options: Option<&Value>) -> Side {
    match options.and_then(Value::as_object) {
        None => Side {
            value: None,
            explicit: false,
        },
        Some(o) => Side {
            value: Some(Value::Object(
                o.iter()
                    .filter(|(_, e)| e["explicit"] == true)
                    .filter_map(|(k, e)| e.get("value").map(|v| (k.clone(), v.clone())))
                    .collect(),
            )),
            explicit: true,
        },
    }
}

fn options(module: &str, before: &Value, after: &Value, out: &mut Vec<Change>) {
    let empty = Map::new();
    let b = before.as_object().unwrap_or(&empty);
    let a = after.as_object().unwrap_or(&empty);
    for name in keys(b, a) {
        let side = |e: Option<&Value>| Side {
            value: e.and_then(|e| e.get("value")).cloned(),
            explicit: e.is_some_and(|e| e["explicit"] == true),
        };
        let (bs, as_) = (side(b.get(name)), side(a.get(name)));
        values(module, vec![name.clone()], bs, as_, out);
    }
}

/// Both sides of one path: nothing, one change, or (two set tables) the changes of their keys.
fn values(module: &str, path: Vec<String>, before: Side, after: Side, out: &mut Vec<Change>) {
    if before == after {
        return;
    }
    if before.explicit
        && after.explicit
        && let (Some(Value::Object(b)), Some(Value::Object(a))) = (&before.value, &after.value)
    {
        for k in keys(b, a) {
            let side = |m: &Map<String, Value>| Side {
                explicit: m.contains_key(k),
                value: m.get(k).cloned(),
            };
            let mut p = path.clone();
            p.push(k.clone());
            values(module, p, side(b), side(a), out);
        }
        return;
    }
    out.push(Change {
        module: module.to_string(),
        path,
        before,
        after,
    });
}

fn keys<'a>(a: &'a Map<String, Value>, b: &'a Map<String, Value>) -> Vec<&'a String> {
    let mut k: Vec<&String> = a.keys().chain(b.keys()).collect();
    k.sort();
    k.dedup();
    k
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(before: Value, after: Value) -> Vec<String> {
        diff(&before, &after).iter().map(Change::to_text).collect()
    }

    #[test]
    fn nothing_changed() {
        let c = json!({ "/a": { "x": { "explicit": true, "value": 1 } } });
        assert_eq!(texts(c.clone(), c), Vec::<String>::new());
    }

    #[test]
    fn set_over_a_value_and_over_a_default() {
        assert_eq!(
            texts(
                json!({ "/a": { "x": { "explicit": true, "value": 1 }, "y": { "explicit": false, "value": "d" } } }),
                json!({ "/a": { "x": { "explicit": true, "value": 2 }, "y": { "explicit": true, "value": "e" } } })
            ),
            vec![
                "set /a x 2 (was 1)",
                "set /a y \"e\" (was \"d\", the default)"
            ]
        );
    }

    #[test]
    fn delete_back_to_the_default_or_to_nothing() {
        assert_eq!(
            texts(
                json!({ "/a": { "x": { "explicit": true, "value": 2 }, "p": { "explicit": true, "value": "q" } } }),
                json!({ "/a": { "x": { "explicit": false, "value": 1 }, "p": { "explicit": false } } })
            ),
            vec![
                "delete /a p (was \"q\")",
                "delete /a x (was 2; now 1, the default)"
            ]
        );
    }

    #[test]
    fn the_same_value_set_where_it_was_the_default_is_a_change() {
        // the document now says it: a later default change no longer applies
        assert_eq!(
            texts(
                json!({ "/a": { "x": { "explicit": false, "value": 1 } } }),
                json!({ "/a": { "x": { "explicit": true, "value": 1 } } })
            ),
            vec!["set /a x 1 (was 1, the default)"]
        );
    }

    #[test]
    fn into_tables_both_sides_set() {
        let before = json!({ "/n": { "networks": { "explicit": true, "value": {
            "lan": { "match": { "Name": "en*" }, "network": { "DNS": ["a"] } },
            "old": { "match": {} }
        }}}});
        let after = json!({ "/n": { "networks": { "explicit": true, "value": {
            "lan": { "match": { "Name": "en*" }, "network": { "DNS": ["b"], "DHCP": "yes" } },
            "wan": { "match": {} }
        }}}});
        assert_eq!(
            texts(before, after),
            vec![
                "set /n networks.lan.network.DHCP \"yes\" (was none)",
                // a list is one value
                "set /n networks.lan.network.DNS [\"b\"] (was [\"a\"])",
                "delete /n networks.old (was { match = {} })",
                "set /n networks.wan { match = {} } (was none)",
            ]
        );
    }

    #[test]
    fn a_table_set_where_there_was_a_default_is_one_change() {
        assert_eq!(
            texts(
                json!({ "/n": { "networks": { "explicit": false, "value": {} } } }),
                json!({ "/n": { "networks": { "explicit": true, "value": { "lan": { "match": {} } } } } })
            ),
            vec!["set /n networks { lan = { match = {} } } (was {}, the default)"]
        );
    }

    #[test]
    fn modules_added_and_removed() {
        let c = diff(
            &json!({ "/old": { "x": { "explicit": true, "value": 1 } } }),
            &json!({ "/new": { "y": { "explicit": true, "value": 2 }, "z": { "explicit": false, "value": 3 } } }),
        );
        let t: Vec<String> = c.iter().map(Change::to_text).collect();
        assert_eq!(
            t,
            vec![
                "set /new { y = 2 } (was none)",
                "delete /old (was { x = 1 })"
            ]
        );
        assert_eq!(
            c[0].to_json(),
            json!({ "op": "set", "module": "/new", "path": [],
                    "before": { "explicit": false }, "after": { "explicit": true, "value": { "y": 2 } } })
        );
    }
}
