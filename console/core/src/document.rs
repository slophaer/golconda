//! The TOML document as written: where it sets a path, and values printed as TOML.

use serde_json::Value;
use toml_edit::{Array, Document, DocumentMut, InlineTable, Item, Table, TableLike};

/// The 1-based line where the document sets `module` `path`: the key's line, or the header's
/// for a table with one. None when the document does not set it (or does not parse).
pub fn line_of(text: &str, module: &str, path: &[&str]) -> Option<usize> {
    let doc = Document::parse(text.to_string()).ok()?;
    let segs: Vec<&str> = std::iter::once(module)
        .chain(path.iter().copied())
        .collect();
    let mut table: &dyn TableLike = doc.as_table();
    let mut start = None;
    for (i, seg) in segs.iter().enumerate() {
        let (key, item) = table.get_key_value(seg)?;
        let header = match item {
            Item::Table(t) if !t.is_implicit() => t.span(),
            _ => None,
        };
        start = header.or_else(|| key.span()).map(|s| s.start).or(start);
        if i + 1 < segs.len() {
            table = item.as_table_like()?;
        }
    }
    Some(text[..start?].matches('\n').count() + 1)
}

/// A JSON value as a TOML value; None for null, which TOML has no word for.
pub fn toml_value(v: &Value) -> Option<toml_edit::Value> {
    Some(match v {
        Value::Null => return None,
        Value::Bool(b) => (*b).into(),
        Value::Number(n) => match n.as_i64() {
            Some(i) => i.into(),
            None => n.as_f64()?.into(),
        },
        Value::String(s) => s.as_str().into(),
        Value::Array(xs) => {
            let mut a = Array::new();
            for x in xs {
                a.push(toml_value(x)?);
            }
            a.into()
        }
        Value::Object(m) => {
            let mut t = InlineTable::new();
            for (k, x) in m {
                if let Some(x) = toml_value(x) {
                    t.insert(k, x);
                }
            }
            t.into()
        }
    })
}

/// `toml_value` as text, `null` for null.
pub fn toml_text(v: &Value) -> String {
    match toml_value(v) {
        Some(t) => t.to_string().trim().to_string(),
        None => "null".into(),
    }
}

/// What `set` or `delete` cannot do.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum EditError {
    #[error("the document is not TOML: {0}")]
    Parse(String),
    /// delete: the document does not set this (module, option path)
    #[error("{0} is not set in the document")]
    NotSet(String),
    /// a key on the way is a value, not a table
    #[error("{0} is a value in the document, not a table")]
    NotATable(String),
    /// the text is not an option path (a TOML dotted key)
    #[error("{0:?} is not an option path: {1}")]
    Path(String, String),
}

/// A key as TOML writes it: bare when it can be, else quoted.
pub fn key(k: &str) -> String {
    if !k.is_empty()
        && k.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        k.to_string()
    } else {
        Value::String(k.to_string()).to_string()
    }
}

/// An option path as a TOML dotted key, `networks."lan.1".dns`: what `parse_path` reads.
pub fn option_name(path: &[&str]) -> String {
    path.iter().map(|k| key(k)).collect::<Vec<_>>().join(".")
}

/// "module option.path", as messages and the diff name a path.
pub fn path_name(module: &str, path: &[&str]) -> String {
    if path.is_empty() {
        module.to_string()
    } else {
        format!("{module} {}", option_name(path))
    }
}

/// An option path, written as a TOML dotted key: `networks.lan.dns`, `networks."lan.1".dns`.
pub fn parse_path(s: &str) -> Result<Vec<String>, EditError> {
    let bad = |e: String| EditError::Path(s.to_string(), e);
    let keys = toml_edit::Key::parse(s).map_err(|e| bad(e.to_string()))?;
    if keys.is_empty() {
        return Err(bad("it is empty".into()));
    }
    Ok(keys.iter().map(|k| k.get().to_string()).collect())
}

/// A value as the command line gives it: TOML, or else the text as a string. `nan` and `inf`
/// are text too: no option takes a number that is not finite, and JSON has none.
pub fn parse_value(s: &str) -> toml_edit::Value {
    match s.parse::<toml_edit::Value>() {
        Ok(v) if v.as_float().is_none_or(f64::is_finite) => v,
        _ => s.into(),
    }
}

/// The document as JSON, as fromTOML reads it (a date or time becomes its TOML text).
pub fn to_json(text: &str) -> Result<Value, EditError> {
    let doc = Document::parse(text.to_string()).map_err(|e| EditError::Parse(e.to_string()))?;
    Ok(table_json(doc.as_table()))
}

fn table_json(t: &dyn TableLike) -> Value {
    Value::Object(
        t.iter()
            .filter_map(|(k, item)| item_json(item).map(|v| (k.to_string(), v)))
            .collect(),
    )
}

fn item_json(item: &Item) -> Option<Value> {
    match item {
        Item::None => None,
        Item::Value(v) => Some(value_json(v)),
        Item::Table(t) => Some(table_json(t)),
        Item::ArrayOfTables(a) => Some(Value::Array(a.iter().map(|t| table_json(t)).collect())),
    }
}

fn value_json(v: &toml_edit::Value) -> Value {
    use toml_edit::Value as T;
    match v {
        T::String(s) => Value::String(s.value().clone()),
        T::Integer(i) => (*i.value()).into(),
        T::Float(f) => serde_json::Number::from_f64(*f.value()).map_or(Value::Null, Value::Number),
        T::Boolean(b) => (*b.value()).into(),
        T::Datetime(d) => Value::String(d.value().to_string()),
        T::Array(a) => Value::Array(a.iter().map(value_json).collect()),
        T::InlineTable(t) => table_json(t),
    }
}

/// The document with `module` `path` set to `value`, everything else as it was written.
///
/// A missing module becomes a table at the end; a missing key goes after its table's last
/// key. Missing tables on the way become dotted keys (`networks.lan = …`), or nested inline
/// tables inside an inline table. A value replaced keeps its spacing and comment. `path`
/// empty sets the module's whole table (a table value).
pub fn set(
    text: &str,
    module: &str,
    path: &[&str],
    mut value: toml_edit::Value,
) -> Result<String, EditError> {
    let mut doc: DocumentMut = text
        .parse()
        .map_err(|e: toml_edit::TomlError| EditError::Parse(e.to_string()))?;
    value.decor_mut().clear();
    if !doc.contains_key(module) {
        let mut t = Table::new();
        // after everything, the comments at the end included
        let trailing = doc.trailing().as_str().unwrap_or("").to_string();
        doc.set_trailing("");
        let sep = if doc.is_empty() && trailing.is_empty() {
            ""
        } else {
            "\n"
        };
        t.decor_mut().set_prefix(format!("{trailing}{sep}"));
        doc.insert(module, Item::Table(t));
    }
    let Some(Item::Table(table)) = doc.get_mut(module) else {
        return Err(EditError::NotATable(module.to_string()));
    };
    if path.is_empty() {
        let toml_edit::Value::InlineTable(inline) = value else {
            return Err(EditError::NotATable(module.to_string()));
        };
        replace_table(table, inline);
    } else {
        set_in(table, false, module, path, 0, value)?;
    }
    Ok(doc.to_string())
}

/// A header table's keys replaced by an inline table's, its header and comments kept.
fn replace_table(table: &mut Table, inline: InlineTable) {
    table.clear();
    for (k, mut v) in inline {
        v.decor_mut().clear();
        table.insert(&k, Item::Value(v));
    }
}

fn set_in(
    t: &mut dyn TableLike,
    inline: bool,
    module: &str,
    path: &[&str],
    i: usize,
    value: toml_edit::Value,
) -> Result<(), EditError> {
    let seg = path[i];
    if i + 1 == path.len() {
        match t.get_mut(seg) {
            Some(Item::Value(old)) => {
                let decor = old.decor().clone();
                *old = value;
                *old.decor_mut() = decor;
            }
            Some(Item::Table(old)) => match value {
                toml_edit::Value::InlineTable(v) if !old.is_dotted() => replace_table(old, v),
                v => {
                    t.insert(seg, Item::Value(v));
                }
            },
            _ => {
                t.insert(seg, Item::Value(value));
                // a key added to an inline table: its spacing as written would put it after a
                // trailing space (`{ a = 1 } , b = 2`); the table is one line, format it
                if inline {
                    t.fmt();
                }
            }
        }
        return Ok(());
    }
    if t.get(seg).is_none() {
        let fresh = if inline {
            Item::Value(InlineTable::new().into())
        } else {
            let mut d = Table::new();
            d.set_dotted(true);
            d.set_implicit(true);
            Item::Table(d)
        };
        t.insert(seg, fresh);
        if inline {
            t.fmt();
        }
    }
    match t.get_mut(seg) {
        Some(Item::Table(sub)) => set_in(sub, false, module, path, i + 1, value),
        Some(Item::Value(toml_edit::Value::InlineTable(sub))) => {
            set_in(sub, true, module, path, i + 1, value)
        }
        _ => Err(EditError::NotATable(path_name(module, &path[..=i]))),
    }
}

/// The document without `module` `path` (`path` empty: without the module). A table below
/// the module that the deletion leaves empty goes too, whether it was written as a header, a
/// dotted key or inline: otherwise it would still set an empty map. The module's own table
/// stays, as it includes the component.
pub fn delete(text: &str, module: &str, path: &[&str]) -> Result<String, EditError> {
    let mut doc: DocumentMut = text
        .parse()
        .map_err(|e: toml_edit::TomlError| EditError::Parse(e.to_string()))?;
    let not_set = || EditError::NotSet(path_name(module, path));
    if path.is_empty() {
        doc.remove(module).ok_or_else(not_set)?;
    } else {
        let t = doc
            .get_mut(module)
            .and_then(Item::as_table_like_mut)
            .ok_or_else(not_set)?;
        delete_in(t, path).ok_or_else(not_set)?;
    }
    Ok(doc.to_string())
}

/// Some(()) once removed; None when the path is not there.
fn delete_in(t: &mut dyn TableLike, path: &[&str]) -> Option<()> {
    let seg = path[0];
    if path.len() == 1 {
        return t.remove(seg).map(drop);
    }
    let sub = t.get_mut(seg)?;
    delete_in(sub.as_table_like_mut()?, &path[1..])?;
    if sub.as_table_like().is_some_and(|s| s.is_empty()) {
        t.remove(seg);
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const DOC: &str = r#"# a comment
["/system"]
name = "server"

["/services/sshd"]
port = 22
principals = { root = ["a@b"] }

["/network".networks.lan]
match = { Name = "en*" }
network = { DNS = ["192.0.2.53"] }
"#;

    #[test]
    fn a_key_line() {
        assert_eq!(line_of(DOC, "/services/sshd", &["port"]), Some(6));
        assert_eq!(line_of(DOC, "/system", &["name"]), Some(3));
    }

    #[test]
    fn inside_an_inline_table() {
        assert_eq!(
            line_of(DOC, "/services/sshd", &["principals", "root"]),
            Some(7)
        );
        assert_eq!(
            line_of(DOC, "/network", &["networks", "lan", "network", "DNS"]),
            Some(11)
        );
    }

    #[test]
    fn a_table_is_its_header() {
        assert_eq!(line_of(DOC, "/services/sshd", &[]), Some(5));
        assert_eq!(line_of(DOC, "/network", &["networks", "lan"]), Some(9));
    }

    #[test]
    fn not_set_is_none() {
        assert_eq!(line_of(DOC, "/services/sshd", &["hostCertificate"]), None);
        assert_eq!(line_of(DOC, "/base", &["ntp"]), None);
        // below a scalar
        assert_eq!(line_of(DOC, "/services/sshd", &["port", "x"]), None);
        assert_eq!(line_of("not = [toml", "/x", &[]), None);
    }

    #[test]
    fn values_as_toml() {
        assert_eq!(toml_text(&json!(22)), "22");
        assert_eq!(toml_text(&json!("a\"b")), r#"'a"b'"#);
        assert_eq!(toml_text(&json!(["x", 1, true])), r#"["x", 1, true]"#);
        assert_eq!(toml_text(&json!({"a": {"b": []}})), "{ a = { b = [] } }");
        assert_eq!(toml_text(&json!(null)), "null");
        assert_eq!(toml_text(&json!(1.5)), "1.5");
    }

    const EX: &str = "# top\n[\"/system\"]\nname = \"server\"  # the host\n\n[\"/services/sshd\"]\nport = 22\n\n# later:\n# x = 1\n";

    fn v(s: &str) -> toml_edit::Value {
        parse_value(s)
    }

    #[test]
    fn set_replaces_a_value_and_keeps_its_comment() {
        assert_eq!(
            set(EX, "/system", &["name"], v("\"web\"")).unwrap(),
            EX.replace(
                "name = \"server\"  # the host",
                "name = \"web\"  # the host"
            )
        );
    }

    #[test]
    fn set_adds_a_key_after_its_tables_last() {
        assert_eq!(
            set(EX, "/services/sshd", &["revokedKeys"], v("true")).unwrap(),
            EX.replace("port = 22\n", "port = 22\nrevokedKeys = true\n")
        );
    }

    #[test]
    fn set_adds_a_module_after_the_comments_at_the_end() {
        assert_eq!(
            set(EX, "/base", &["ntp"], v("[\"a\"]")).unwrap(),
            format!("{EX}\n[\"/base\"]\nntp = [\"a\"]\n")
        );
        assert_eq!(
            set("", "/base", &["ntp"], v("[]")).unwrap(),
            "[\"/base\"]\nntp = []\n"
        );
    }

    #[test]
    fn set_makes_dotted_keys_and_fills_inline_tables() {
        let a = set(
            EX,
            "/services/sshd",
            &["principals", "root"],
            v("[\"a@b\"]"),
        )
        .unwrap();
        assert!(
            a.contains("port = 22\nprincipals.root = [\"a@b\"]\n"),
            "{a}"
        );
        let b = set(&a, "/services/sshd", &["principals", "admin"], v("[]")).unwrap();
        assert!(
            b.contains("principals.root = [\"a@b\"]\nprincipals.admin = []\n"),
            "{b}"
        );
        let c = set(
            EX,
            "/network",
            &["networks", "lan"],
            v("{ match = { Name = \"en*\" } }"),
        )
        .unwrap();
        let d = set(
            &c,
            "/network",
            &["networks", "lan", "network", "DNS"],
            v("[\"x\"]"),
        )
        .unwrap();
        assert!(
            d.ends_with(
                "networks.lan = { match = { Name = \"en*\" }, network = { DNS = [\"x\"] } }\n"
            ),
            "{d}"
        );
    }

    #[test]
    fn set_adds_a_key_to_an_inline_table_as_written() {
        assert_eq!(
            set("[\"/a\"]\nx = { a = 1 }\n", "/a", &["x", "b"], v("2")).unwrap(),
            "[\"/a\"]\nx = { a = 1, b = 2 }\n"
        );
    }

    #[test]
    fn set_a_whole_table() {
        let doc = "[\"/services/sshd\"]  # ssh\nport = 22\n";
        assert_eq!(
            set(
                doc,
                "/services/sshd",
                &[],
                v("{ port = 2, revokedKeys = true }")
            )
            .unwrap(),
            "[\"/services/sshd\"]  # ssh\nport = 2\nrevokedKeys = true\n"
        );
        let doc = "[\"/network\".networks.lan]\nmatch = {}\n";
        assert_eq!(
            set(
                doc,
                "/network",
                &["networks", "lan"],
                v("{ match = { Name = \"e\" } }")
            )
            .unwrap(),
            "[\"/network\".networks.lan]\nmatch = { Name = \"e\" }\n"
        );
    }

    #[test]
    fn set_below_a_value_is_refused() {
        assert_eq!(
            set(EX, "/services/sshd", &["port", "x"], v("1")),
            Err(EditError::NotATable("/services/sshd port".into()))
        );
        assert!(matches!(
            set("x = [", "/a", &["b"], v("1")),
            Err(EditError::Parse(_))
        ));
    }

    #[test]
    fn delete_a_key_a_dotted_table_and_a_module() {
        assert_eq!(
            delete(EX, "/services/sshd", &["port"]).unwrap(),
            EX.replace("port = 22\n", "")
        );
        let a = set(EX, "/services/sshd", &["principals", "root"], v("[]")).unwrap();
        let b = delete(&a, "/services/sshd", &["principals", "root"]).unwrap();
        assert_eq!(b, EX);
        // not left behind as an empty map, which would set principals = {}
        assert_eq!(
            to_json(&b).unwrap()["/services/sshd"].get("principals"),
            None
        );
        let doc = "[\"/system\"]\nname = \"s\"\n\n[\"/network\".networks.lan]\nmatch = {}\n";
        assert_eq!(
            delete(doc, "/network", &[]).unwrap(),
            "[\"/system\"]\nname = \"s\"\n"
        );
        assert_eq!(
            delete(EX, "/services/sshd", &["nope"]),
            Err(EditError::NotSet("/services/sshd nope".into()))
        );
        assert_eq!(
            delete(EX, "/base", &[]),
            Err(EditError::NotSet("/base".into()))
        );
    }

    #[test]
    fn values_from_the_command_line() {
        assert_eq!(parse_value("22").as_integer(), Some(22));
        assert_eq!(parse_value("\"22\"").as_str(), Some("22"));
        assert_eq!(parse_value("en*").as_str(), Some("en*"));
        assert_eq!(parse_value("true").as_bool(), Some(true));
    }

    #[test]
    fn the_document_as_json() {
        assert_eq!(
            to_json("[\"/a\".b]\nc = [1, \"x\"]\nd = 1979-05-27\ne = { f = true }\n").unwrap(),
            json!({ "/a": { "b": { "c": [1, "x"], "d": "1979-05-27", "e": { "f": true } } } })
        );
    }

    #[test]
    fn option_paths_are_toml_dotted_keys() {
        assert_eq!(parse_path("port").unwrap(), vec!["port"]);
        assert_eq!(
            parse_path("networks.lan.dns").unwrap(),
            vec!["networks", "lan", "dns"]
        );
        assert_eq!(
            parse_path(r#"networks."lan.1".dns"#).unwrap(),
            vec!["networks", "lan.1", "dns"]
        );
        assert!(parse_path("a..b").is_err());
        // written back so that parse_path reads it again
        assert_eq!(
            path_name("/n", &["networks", "lan.1", "dns"]),
            r#"/n networks."lan.1".dns"#
        );
        assert_eq!(path_name("/n", &["networks", "lan"]), "/n networks.lan");
        assert_eq!(path_name("/n", &[]), "/n");
    }

    #[test]
    fn tables_that_get_a_header_get_a_blank_line() {
        let doc = "[\"/system\"]\nname = \"s\"\n\n[\"/network\".networks.lan]\nmatch = {}\n";
        assert_eq!(
            set(doc, "/network", &["networks", "wan", "match"], v("{}")).unwrap(),
            "[\"/system\"]\nname = \"s\"\n\n[\"/network\".networks]\nwan.match = {}\n\n[\"/network\".networks.lan]\nmatch = {}\n"
        );
        assert_eq!(
            set(doc, "/network", &["defaultDhcp"], v("false")).unwrap(),
            "[\"/system\"]\nname = \"s\"\n\n[\"/network\"]\ndefaultDhcp = false\n\n[\"/network\".networks.lan]\nmatch = {}\n"
        );
    }

    #[test]
    fn delete_removes_sub_tables_it_leaves_empty_but_not_the_module() {
        let doc = "[\"/services/sshd\"]\nport = 22\n\n[\"/services/sshd\".principals]\nroot = [\"a@b\"]\n";
        let out = delete(doc, "/services/sshd", &["principals", "root"]).unwrap();
        assert_eq!(out, "[\"/services/sshd\"]\nport = 22\n");
        // an empty module table still includes the component
        assert_eq!(
            delete(&out, "/services/sshd", &["port"]).unwrap(),
            "[\"/services/sshd\"]\n"
        );
    }

    #[test]
    fn text_that_is_no_finite_number_stays_text() {
        assert_eq!(parse_value("nan").as_str(), Some("nan"));
        assert_eq!(parse_value("inf").as_str(), Some("inf"));
        assert_eq!(parse_value("-inf").as_str(), Some("-inf"));
        assert_eq!(parse_value("1.5").as_float(), Some(1.5));
    }
}
