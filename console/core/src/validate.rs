//! JSON Schema validation, for the keywords Golconda's schema uses (lib/schema.nix): `$ref`,
//! `type`, `const`, `enum`, `minimum`, `maximum`, `minLength`, `pattern`, `not`, `anyOf`, `oneOf`, `properties`,
//! `additionalProperties`, `required`, `propertyNames`, `items`, `prefixItems`, `minItems`,
//! `maxItems`. A schema with any other keyword, or a pattern the regex engine cannot read, would
//! be checked only in part: [`unsupported`] lists them, and a system with such a schema does not
//! load. Each violation has the path of the value it is about, so the caller can find it in the
//! document.

use crate::schema::{resolve, type_name};
use regex::Regex;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Violation {
    /// object keys and array indexes, from the document's top
    pub path: Vec<String>,
    pub message: String,
}

pub struct Validator<'a> {
    schema: &'a Value,
    regexes: RefCell<HashMap<String, Option<Regex>>>,
}

impl<'a> Validator<'a> {
    pub fn new(schema: &'a Value) -> Self {
        Validator {
            schema,
            regexes: RefCell::new(HashMap::new()),
        }
    }

    /// Every violation of `instance` against the whole schema.
    pub fn validate(&self, instance: &Value) -> Vec<Violation> {
        let mut out = Vec::new();
        self.check(self.schema, instance, &mut Vec::new(), &mut out);
        out
    }

    fn matches(&self, pattern: &str, s: &str) -> bool {
        let mut cache = self.regexes.borrow_mut();
        let re = cache
            .entry(pattern.to_string())
            .or_insert_with(|| Regex::new(pattern).ok());
        // a pattern this engine cannot read checks nothing: `unsupported` refuses such a schema
        re.as_ref().is_none_or(|re| re.is_match(s))
    }

    fn valid(&self, node: &Value, v: &Value) -> bool {
        let mut out = Vec::new();
        self.check(node, v, &mut Vec::new(), &mut out);
        out.is_empty()
    }

    fn check(&self, node: &Value, v: &Value, path: &mut Vec<String>, out: &mut Vec<Violation>) {
        let mut fail = |path: &Vec<String>, message: String| {
            out.push(Violation {
                path: path.clone(),
                message,
            });
        };
        if node.get("$ref").is_some() {
            return self.check(resolve(self.schema, node), v, path, out);
        }
        if let Some(t) = node.get("type")
            && !has_type(t, v)
        {
            return fail(
                path,
                format!("expected {}, got {}", type_name(node), shown(v)),
            );
        }
        if let Some(c) = node.get("const")
            && c != v
        {
            return fail(path, format!("expected {c}, got {}", shown(v)));
        }
        if let Some(values) = node["enum"].as_array()
            && !values.contains(v)
        {
            return fail(
                path,
                format!("expected {}, got {}", type_name(node), shown(v)),
            );
        }
        if let Value::String(s) = v {
            if let Some(n) = node["minLength"].as_u64()
                && (s.chars().count() as u64) < n
            {
                fail(path, format!("must be at least {n} characters"));
            }
            if let Some(p) = node["pattern"].as_str()
                && !self.matches(p, s)
            {
                fail(path, format!("{} does not match {p}", shown(v)));
            }
        }
        if let Some(x) = v.as_f64() {
            if node["minimum"].as_f64().is_some_and(|m| x < m) {
                fail(path, format!("{v} is less than {}", node["minimum"]));
            }
            if node["maximum"].as_f64().is_some_and(|m| x > m) {
                fail(path, format!("{v} is more than {}", node["maximum"]));
            }
        }
        if let Some(n) = node.get("not")
            && self.valid(n, v)
        {
            let what = n["pattern"]
                .as_str()
                .map_or_else(|| format!("be {}", type_name(n)), |p| format!("match {p}"));
            fail(path, format!("{} must not {what}", shown(v)));
        }
        for (key, one) in [("anyOf", false), ("oneOf", true)] {
            let Some(alts) = node[key].as_array() else {
                continue;
            };
            let passing = alts.iter().filter(|a| self.valid(a, v)).count();
            if passing == 0 {
                // the one alternative of the value's own type explains best
                let same: Vec<&Value> = alts
                    .iter()
                    .filter(|a| {
                        let a = resolve(self.schema, a);
                        a.get("type").is_some_and(|t| has_type(t, v))
                    })
                    .collect();
                match same.as_slice() {
                    [a] => self.check(a, v, path, out),
                    _ => fail(
                        path,
                        format!("expected {}, got {}", type_name(node), shown(v)),
                    ),
                }
                return;
            }
            if one && passing > 1 {
                return fail(path, format!("{} matches more than one of {key}", shown(v)));
            }
        }
        match v {
            Value::Object(m) => self.object(node, m, path, out),
            Value::Array(xs) => self.array(node, xs, path, out),
            _ => {}
        }
    }

    fn object(
        &self,
        node: &Value,
        m: &serde_json::Map<String, Value>,
        path: &mut Vec<String>,
        out: &mut Vec<Violation>,
    ) {
        let props = node["properties"].as_object();
        for r in node["required"].as_array().into_iter().flatten() {
            if let Some(r) = r.as_str().filter(|r| !m.contains_key(*r)) {
                out.push(Violation {
                    path: path.clone(),
                    message: format!("missing {r}"),
                });
            }
        }
        for (k, x) in m {
            path.push(k.clone());
            if let Some(names) = node.get("propertyNames") {
                self.check(names, &Value::String(k.clone()), path, out);
            }
            match (
                props.and_then(|p| p.get(k)),
                node.get("additionalProperties"),
            ) {
                (Some(s), _) => self.check(s, x, path, out),
                (None, Some(Value::Bool(false))) => out.push(Violation {
                    path: path.clone(),
                    // the top's keys are modules, a module's are options
                    message: match path.len() {
                        1 => "no such module".into(),
                        2 => "no such option".into(),
                        _ => "no such key".into(),
                    },
                }),
                (None, Some(s)) if s.is_object() => self.check(s, x, path, out),
                _ => {}
            }
            path.pop();
        }
    }

    fn array(&self, node: &Value, xs: &[Value], path: &mut Vec<String>, out: &mut Vec<Violation>) {
        let prefix = node["prefixItems"].as_array();
        let fail = |out: &mut Vec<Violation>, message: String| {
            out.push(Violation {
                path: path.clone(),
                message,
            });
        };
        if let Some(n) = node["minItems"].as_u64().filter(|n| (xs.len() as u64) < *n) {
            fail(
                out,
                format!("expected at least {n} items, got {}", xs.len()),
            );
        }
        if let Some(n) = node["maxItems"].as_u64().filter(|n| (xs.len() as u64) > *n) {
            fail(out, format!("expected at most {n} items, got {}", xs.len()));
        }
        for (i, x) in xs.iter().enumerate() {
            let s = prefix.and_then(|p| p.get(i)).or(node.get("items"));
            if let Some(s) = s.filter(|s| s.is_object()) {
                path.push(i.to_string());
                self.check(s, x, path, out);
                path.pop();
            }
        }
    }
}

/// The keywords `Validator` checks, and those whose value is a schema or a list or map of them.
const CHECKED: &[&str] = &[
    "$ref",
    "type",
    "const",
    "enum",
    "minimum",
    "maximum",
    "minLength",
    "pattern",
    "not",
    "anyOf",
    "oneOf",
    "properties",
    "additionalProperties",
    "required",
    "propertyNames",
    "items",
    "prefixItems",
    "minItems",
    "maxItems",
];
/// Keywords that check nothing (annotations, the schema's identity, `$defs` reached by `$ref`);
/// `x-` keywords are Golconda's own annotations.
const ANNOTATIONS: &[&str] = &[
    "$schema",
    "$id",
    "$defs",
    "$comment",
    "title",
    "description",
    "default",
    "examples",
];

/// What in `schema` the validator would not check, as "JSON pointer: why", sorted: a keyword it
/// does not know, or a pattern its regex engine cannot read. Empty for a schema it checks fully.
pub fn unsupported(schema: &Value) -> Vec<String> {
    // a JSON pointer's segment escapes ~ and /
    fn seg(k: &str) -> String {
        k.replace('~', "~0").replace('/', "~1")
    }
    fn walk(node: &Value, at: &str, out: &mut Vec<String>) {
        let Some(m) = node.as_object() else {
            return; // `true`, `false`: nothing to check
        };
        for (k, v) in m {
            let here = format!("{at}/{}", seg(k));
            match k.as_str() {
                "properties" | "$defs" => {
                    for (name, sub) in v.as_object().into_iter().flatten() {
                        walk(sub, &format!("{here}/{}", seg(name)), out);
                    }
                }
                "anyOf" | "oneOf" | "prefixItems" => {
                    for (i, sub) in v.as_array().into_iter().flatten().enumerate() {
                        walk(sub, &format!("{here}/{i}"), out);
                    }
                }
                "not" | "items" | "additionalProperties" | "propertyNames" => walk(v, &here, out),
                "pattern" => {
                    let p = v.as_str().unwrap_or_default();
                    if let Err(e) = Regex::new(p) {
                        // the engine's message ends with a line `error: why`
                        let why = e.to_string();
                        let why = why.lines().last().unwrap_or_default();
                        let why = why.strip_prefix("error: ").unwrap_or(why);
                        out.push(format!("{at}: pattern {p} cannot be read: {why}"));
                    }
                }
                k if CHECKED.contains(&k) || ANNOTATIONS.contains(&k) || k.starts_with("x-") => {}
                k => out.push(format!("{at}: {k} is not a keyword this validator checks")),
            }
        }
    }
    let mut out = Vec::new();
    walk(schema, "", &mut out);
    out.sort();
    out
}

fn has_type(t: &Value, v: &Value) -> bool {
    let one = |t: &str| match t {
        "integer" => v.is_i64() || v.is_u64(),
        "number" => v.is_number(),
        "string" => v.is_string(),
        "boolean" => v.is_boolean(),
        "null" => v.is_null(),
        "array" => v.is_array(),
        "object" => v.is_object(),
        _ => true,
    };
    match t {
        Value::String(t) => one(t),
        Value::Array(ts) => ts.iter().filter_map(Value::as_str).any(one),
        _ => true,
    }
}

/// A value in a message: scalars as they are, containers by kind.
fn shown(v: &Value) -> String {
    match v {
        Value::Array(_) => "a list".into(),
        Value::Object(_) => "a table".into(),
        v => v.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn schema() -> Value {
        json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["/system"],
            "properties": {
                "/system": { "type": "object", "additionalProperties": false, "properties": {
                    "name": { "type": "string", "minLength": 1, "pattern": "^[a-z]+$" },
                    "kind": { "enum": ["a", "b"] },
                    "v": { "const": 1 }
                }},
                "/services/sshd": { "type": "object", "additionalProperties": false, "properties": {
                    "port": { "type": "integer" },
                    "keys": { "type": "array", "items": { "$ref": "#/$defs/line" } },
                    "pair": { "type": "array", "prefixItems": [ {"type": "string"}, {"type": "integer"} ],
                              "minItems": 2, "maxItems": 2 },
                    "principals": { "type": "object", "propertyNames": { "pattern": "^[a-z]+$" },
                                    "additionalProperties": { "type": "array" } }
                }},
                "/network": { "type": "object", "properties": {
                    "networks": { "type": "object", "additionalProperties": { "$ref": "#/$defs/network" } }
                }}
            },
            "$defs": {
                "line": { "type": "string", "not": { "pattern": "[\\u0000-\\u001f]" } },
                "network": { "type": "object", "required": ["match"], "additionalProperties": false,
                    "properties": {
                        "match": { "type": "object" },
                        "network": { "type": "object", "additionalProperties": { "anyOf": [
                            { "type": "string" }, { "type": "boolean" },
                            { "type": "array", "items": { "type": ["string", "integer"] } }
                        ]}}
                    }},
                "either": { "oneOf": [ { "type": "integer" }, { "type": "number" } ] }
            }
        })
    }

    fn errors(instance: &Value) -> Vec<(String, String)> {
        let s = schema();
        Validator::new(&s)
            .validate(instance)
            .into_iter()
            .map(|v| (v.path.join(" "), v.message))
            .collect()
    }

    fn e(path: &str, message: &str) -> (String, String) {
        (path.to_string(), message.to_string())
    }

    #[test]
    fn a_valid_document() {
        let ok = json!({
            "/system": { "name": "server", "kind": "a", "v": 1 },
            "/services/sshd": { "port": 22, "keys": ["k"], "pair": ["a", 1], "principals": { "root": [] } },
            "/network": { "networks": { "lan": { "match": {}, "network": { "DNS": ["x", 1], "DHCP": true } } } }
        });
        assert_eq!(errors(&ok), vec![]);
    }

    #[test]
    fn modules_and_options() {
        assert_eq!(
            errors(&json!({ "/nope": {}, "/services/sshd": { "prot": 1 } })),
            vec![
                e("", "missing /system"),
                e("/nope", "no such module"),
                e("/services/sshd prot", "no such option")
            ]
        );
    }

    #[test]
    fn scalars() {
        assert_eq!(
            errors(
                &json!({ "/system": { "name": "", "kind": "c", "v": 2 }, "/services/sshd": { "port": 1.5 } })
            ),
            vec![
                e("/services/sshd port", "expected integer, got 1.5"),
                e("/system kind", "expected one of \"a\", \"b\", got \"c\""),
                e("/system name", "must be at least 1 characters"),
                e("/system name", "\"\" does not match ^[a-z]+$"),
                e("/system v", "expected 1, got 2"),
            ]
        );
        assert_eq!(
            errors(&json!({ "/system": { "name": 3 } })),
            vec![e("/system name", "expected string, got 3")]
        );
    }

    #[test]
    fn lists_maps_and_refs() {
        assert_eq!(
            errors(&json!({ "/system": {}, "/services/sshd": {
                "keys": ["ok", "a\nb", 7],
                "pair": ["a"],
                "principals": { "Root": [] , "x": "y" }
            }})),
            vec![
                e(
                    "/services/sshd keys 1",
                    "\"a\\nb\" must not match [\\u0000-\\u001f]"
                ),
                e("/services/sshd keys 2", "expected string, got 7"),
                e("/services/sshd pair", "expected at least 2 items, got 1"),
                e(
                    "/services/sshd principals Root",
                    "\"Root\" does not match ^[a-z]+$"
                ),
                e("/services/sshd principals x", "expected list, got \"y\""),
            ]
        );
    }

    #[test]
    fn required_inside_a_map_and_choices() {
        assert_eq!(
            errors(&json!({ "/system": {}, "/network": { "networks": {
                "lan": { "network": { "DNS": [true], "DHCP": 1 } }
            }}})),
            vec![
                e("/network networks lan", "missing match"),
                // DHCP fits no alternative's type: all are named
                e(
                    "/network networks lan network DHCP",
                    "expected string or boolean or list of (string or integer), got 1"
                ),
                // a list: the list alternative says what is wrong inside it
                e(
                    "/network networks lan network DNS 0",
                    "expected string or integer, got true"
                ),
            ]
        );
    }

    #[test]
    fn numbers_within_bounds() {
        let s =
            json!({ "properties": { "p": { "type": "integer", "minimum": 1, "maximum": 65535 } } });
        let errors = |v: Value| -> Vec<String> {
            Validator::new(&s)
                .validate(&json!({ "p": v }))
                .into_iter()
                .map(|v| v.message)
                .collect()
        };
        assert_eq!(errors(json!(1)), Vec::<String>::new());
        assert_eq!(errors(json!(65535)), Vec::<String>::new());
        assert_eq!(errors(json!(0)), vec!["0 is less than 1"]);
        assert_eq!(errors(json!(-1)), vec!["-1 is less than 1"]);
        assert_eq!(errors(json!(65536)), vec!["65536 is more than 65535"]);
    }

    #[test]
    fn one_of_wants_exactly_one() {
        let s = schema();
        let v = Validator::new(&s);
        let either = &s["$defs"]["either"];
        let mut out = Vec::new();
        v.check(either, &json!(1), &mut Vec::new(), &mut out);
        assert_eq!(out[0].message, "1 matches more than one of oneOf");
        assert!(v.valid(either, &json!(1.5)));
    }

    #[test]
    fn the_test_schema_is_supported() {
        assert_eq!(unsupported(&schema()), Vec::<String>::new());
    }

    #[test]
    fn unknown_keywords_and_unreadable_patterns_are_unsupported() {
        let s = json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema", "title": "t",
            "x-golconda": { "anything": 1 },
            "properties": {
                "a": { "type": "string", "format": "email", "description": "d", "default": { "maxLength": 1 } },
                "b": { "type": "array", "items": { "uniqueItems": true } },
                "c": { "type": "string", "pattern": "(?=x)" }
            },
            "$defs": { "d": { "anyOf": [{ "type": "string" }, { "dependentRequired": {} }] } }
        });
        assert_eq!(
            unsupported(&s),
            vec![
                "/$defs/d/anyOf/1: dependentRequired is not a keyword this validator checks",
                "/properties/a: format is not a keyword this validator checks",
                "/properties/b/items: uniqueItems is not a keyword this validator checks",
                "/properties/c: pattern (?=x) cannot be read: look-around, including look-ahead and look-behind, is not supported",
            ]
        );
    }
}
