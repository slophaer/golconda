//! The TOML document as written: where it sets a path, and values printed as TOML.

use serde_json::Value;
use toml_edit::{Array, Document, InlineTable, Item, TableLike};

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
}
