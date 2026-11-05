//! Options in a system's JSON Schema (lib/schema.nix): find one by its path, name its type.
//!
//! A module is `properties.<module path>`; an option path walks `properties` (a struct's
//! fields), `additionalProperties` (a map's values) and `$ref`s into `$defs`.

use crate::document::path_name;
use serde_json::Value;

/// An option found in the schema.
#[derive(Debug)]
pub struct OptionSchema<'a> {
    /// the option's own schema, `$ref` not followed
    pub node: &'a Value,
    /// the nearest description on the way: the option's, else its enclosing type's
    pub description: Option<&'a str>,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum LookupError {
    #[error("no module {0}")]
    NoModule(String),
    /// the path that exists ("module option.path"), then the name that does not
    #[error("{0} has no option {1}")]
    NoOption(String, String),
}

/// The `$defs` entry a `$ref` names, or the node itself.
pub fn resolve<'a>(schema: &'a Value, node: &'a Value) -> &'a Value {
    match node["$ref"]
        .as_str()
        .and_then(|r| r.strip_prefix("#/$defs/"))
    {
        Some(name) => resolve(schema, &schema["$defs"][name]),
        None => node,
    }
}

pub fn option<'a>(
    schema: &'a Value,
    module: &str,
    path: &[&str],
) -> Result<OptionSchema<'a>, LookupError> {
    let m = schema["properties"]
        .get(module)
        .ok_or_else(|| LookupError::NoModule(module.to_string()))?;
    let mut node = m;
    let mut description = None;
    for (i, seg) in path.iter().enumerate() {
        let here = resolve(schema, node);
        description = here["description"].as_str().or(description);
        let next = here["properties"]
            .get(*seg)
            .or_else(|| here.get("additionalProperties").filter(|a| a.is_object()));
        node = next
            .ok_or_else(|| LookupError::NoOption(path_name(module, &path[..i]), seg.to_string()))?;
    }
    let own = resolve(schema, node)["description"]
        .as_str()
        .or(node["description"].as_str());
    Ok(OptionSchema {
        node,
        description: own.or(description),
    })
}

/// A short name for a type: `integer`, `list of string`, `map of network`, a definition's
/// name for a `$ref`, `a or b` for a choice.
pub fn type_name(node: &Value) -> String {
    if let Some(name) = node["$ref"]
        .as_str()
        .and_then(|r| r.strip_prefix("#/$defs/"))
    {
        return name.to_string();
    }
    if let Some(kind) = node["x-golconda"].as_str() {
        return kind.to_string();
    }
    if let Some(alts) = node["anyOf"].as_array().or(node["oneOf"].as_array()) {
        return alts.iter().map(type_name).collect::<Vec<_>>().join(" or ");
    }
    if let Some(values) = node["enum"].as_array() {
        let names: Vec<String> = values.iter().map(ToString::to_string).collect();
        return format!("one of {}", names.join(", "));
    }
    let inner = |n: &Value| {
        let t = type_name(n);
        if t.contains(" or ") {
            format!("({t})")
        } else {
            t
        }
    };
    match &node["type"] {
        Value::String(t) if t == "array" => match node.get("items") {
            Some(items) => format!("list of {}", inner(items)),
            None => "list".into(),
        },
        Value::String(t) if t == "object" => match node.get("additionalProperties") {
            Some(a) if a.is_object() => format!("map of {}", inner(a)),
            _ => "table".into(),
        },
        Value::String(t) => t.clone(),
        Value::Array(ts) => ts
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" or "),
        _ => "any".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn schema() -> Value {
        json!({
            "properties": {
                "/services/sshd": { "properties": {
                    "port": { "type": "integer", "description": "Listening port." }
                }},
                "/network": { "properties": {
                    "networks": {
                        "type": "object",
                        "description": "Network configurations, keyed by name.",
                        "additionalProperties": { "$ref": "#/$defs/network" }
                    }
                }}
            },
            "$defs": {
                "network": { "type": "object", "description": "A .network file.", "properties": {
                    "network": { "$ref": "#/$defs/section" }
                }},
                "section": { "type": "object", "description": "One section.", "additionalProperties": {
                    "anyOf": [ { "type": "string" }, { "items": { "type": ["string", "integer"] }, "type": "array" } ]
                }}
            }
        })
    }

    #[test]
    fn a_top_level_option() {
        let s = schema();
        let o = option(&s, "/services/sshd", &["port"]).unwrap();
        assert_eq!(type_name(o.node), "integer");
        assert_eq!(o.description, Some("Listening port."));
    }

    #[test]
    fn through_a_map_and_definitions() {
        let s = schema();
        let lan = option(&s, "/network", &["networks", "lan"]).unwrap();
        assert_eq!(type_name(lan.node), "network");
        assert_eq!(lan.description, Some("A .network file."));
        let dns = option(&s, "/network", &["networks", "lan", "network", "DNS"]).unwrap();
        assert_eq!(type_name(dns.node), "string or list of (string or integer)");
        // the leaf has none: its section's
        assert_eq!(dns.description, Some("One section."));
    }

    #[test]
    fn missing_module_and_option_are_named() {
        let s = schema();
        assert_eq!(
            option(&s, "/nope", &["x"]).unwrap_err().to_string(),
            "no module /nope"
        );
        assert_eq!(
            option(&s, "/services/sshd", &["prot"])
                .unwrap_err()
                .to_string(),
            "/services/sshd has no option prot"
        );
        assert_eq!(
            option(&s, "/network", &["networks", "lan", "bogus"])
                .unwrap_err()
                .to_string(),
            "/network networks.lan has no option bogus"
        );
    }

    #[test]
    fn type_names() {
        assert_eq!(type_name(&json!({"type": "array"})), "list");
        assert_eq!(
            type_name(&json!({"type": "object", "additionalProperties": {"type": "string"}})),
            "map of string"
        );
        assert_eq!(
            type_name(&json!({"type": "object", "properties": {}})),
            "table"
        );
        assert_eq!(
            type_name(&json!({"enum": ["a", "b"]})),
            "one of \"a\", \"b\""
        );
        assert_eq!(
            type_name(&json!({"type": "string", "x-golconda": "path"})),
            "path"
        );
        assert_eq!(type_name(&json!({})), "any");
    }
}
