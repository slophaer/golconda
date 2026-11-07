//! checks.schema-parity (tests/schema): the console's validator and Nix agree on every fixture.
//! `schema-parity SCHEMA.json FIXTURES.json`: SCHEMA is lib/schema.nix's schema, FIXTURES the
//! rows of tests/schema/default.nix (`name`, `value`, `accepted`, `nixAccepted`, and
//! `definition` for a row checked against one `$defs` entry). Each row's schema verdict and Nix
//! verdict must both be the expected one, and the schema must be one the validator checks fully.

use golconda_core::validate::{Validator, unsupported};
use serde_json::{Value, json};
use std::process::ExitCode;
use std::{env, fs};

fn read(path: &str) -> Result<Value, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let [schema, fixtures] = args.as_slice() else {
        eprintln!("usage: schema-parity SCHEMA.json FIXTURES.json");
        return ExitCode::from(2);
    };
    let (schema, fixtures) = match (read(schema), read(fixtures)) {
        (Ok(s), Ok(f)) => (s, f),
        (Err(e), _) | (_, Err(e)) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    let mut failures = 0;
    for problem in unsupported(&schema) {
        eprintln!("FAIL the schema: {problem}");
        failures += 1;
    }
    let rows = fixtures.as_array().map_or(&[][..], Vec::as_slice);
    for row in rows {
        let target = match row["definition"].as_str() {
            Some(d) => json!({ "$ref": format!("#/$defs/{d}"), "$defs": schema["$defs"] }),
            None => schema.clone(),
        };
        let violations = Validator::new(&target).validate(&row["value"]);
        let expected = &row["accepted"];
        let ours = Value::Bool(violations.is_empty());
        let nix = &row["nixAccepted"];
        if &ours != expected || nix != expected {
            failures += 1;
            eprintln!(
                "FAIL {}: expected={expected}, schema={ours}, nix={nix}",
                row["name"]
            );
            for v in violations {
                eprintln!("  /{}: {}", v.path.join("/"), v.message);
            }
        }
    }
    println!("{} schema/Nix fixtures, {failures} failures", rows.len());
    if failures == 0 && !rows.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
