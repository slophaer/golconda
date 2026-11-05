//! Checking a document, and changing it only once the change checks: the schema first (its
//! problems name lines of the document), then evaluation (what only the modules know).

use crate::document::{EditError, line_of, path_name, to_json};
use crate::eval::{self, Arg, Iets};
use crate::system::{self, System, beside};
use crate::validate::Validator;
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Every check the modules make, without building: the /usr tree's derivation.
const CHECK_EXPR: &str = "{ config, system }: \
    (import ./lib/system.nix { inherit config system; }).usrTree.drvPath";

/// A schema violation, placed in the document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Problem {
    /// the line of the value, or of the nearest key above it the document has
    pub line: Option<usize>,
    /// "module option.path", or "" for the document as a whole
    pub path: String,
    pub message: String,
}

/// The schema's problems with `text`, at lines of `lines_of`: the document as it is on disk,
/// which for a refused edit is not `text`. A path it lacks gets the line of the nearest key
/// above it that it has.
pub fn schema_problems(
    schema: &Value,
    text: &str,
    lines_of: &str,
) -> Result<Vec<Problem>, EditError> {
    let doc = to_json(text)?;
    Ok(Validator::new(schema)
        .validate(&doc)
        .into_iter()
        .map(|v| {
            let segs: Vec<&str> = v.path.iter().map(String::as_str).collect();
            let line = (1..=segs.len())
                .rev()
                .find_map(|n| line_of(lines_of, segs[0], &segs[1..n]));
            let path = match segs.split_first() {
                Some((m, rest)) => path_name(m, rest),
                None => String::new(),
            };
            Problem {
                line,
                path,
                message: v.message,
            }
        })
        .collect())
}

/// Evaluate `document` (inside `root`) as far as every module's checks go.
pub fn evaluate(
    iets: &Iets,
    root: &Path,
    document: &Path,
    system: &str,
) -> Result<(), eval::Error> {
    let abs = std::path::absolute(document).unwrap_or_else(|_| document.to_path_buf());
    iets.eval_json(
        root,
        CHECK_EXPR,
        &[Arg::Path("config", &abs), Arg::Str("system", system)],
    )
    .map(drop)
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Load(system::Error),
    #[error(transparent)]
    Edit(EditError),
    /// the schema's problems, and the document they are in
    #[error("{}", problems(.0, .1))]
    Invalid(PathBuf, Vec<Problem>),
    #[error(transparent)]
    Eval(eval::Error),
    #[error("cannot write {path}: {1}", path = .0.display())]
    Write(PathBuf, std::io::Error),
}

/// One line per problem: `doc:line: module option: message`.
fn problems(doc: &Path, problems: &[Problem]) -> String {
    let lines: Vec<String> = problems
        .iter()
        .map(|p| {
            let at = p.line.map_or(String::new(), |l| format!(":{l}"));
            let path = if p.path.is_empty() {
                String::new()
            } else {
                format!("{}: ", p.path)
            };
            format!("{}{at}: {path}{}", doc.display(), p.message)
        })
        .collect();
    lines.join("\n")
}

/// Check the document as it is: the schema, then evaluation.
pub fn validate(iets: &Iets, document: &Path, system: &str) -> Result<(), Error> {
    let sys = System::load(iets, document, system).map_err(Error::Load)?;
    let problems = schema_problems(&sys.schema, &sys.text, &sys.text).map_err(Error::Edit)?;
    if !problems.is_empty() {
        return Err(Error::Invalid(sys.document, problems));
    }
    evaluate(iets, &sys.root, document, system).map_err(Error::Eval)
}

/// Change the document with `edit`, and write it only once the new text checks. The check
/// evaluates a copy beside the document (pure evaluation reads under the checkout only),
/// which then replaces it; a failed check removes the copy and leaves the document as it was.
pub fn apply(
    iets: &Iets,
    document: &Path,
    system: &str,
    edit: impl FnOnce(&str) -> Result<String, EditError>,
) -> Result<(), Error> {
    let sys = System::load(iets, document, system).map_err(Error::Load)?;
    let text = edit(&sys.text).map_err(Error::Edit)?;
    let problems = schema_problems(&sys.schema, &text, &sys.text).map_err(Error::Edit)?;
    if !problems.is_empty() {
        return Err(Error::Invalid(sys.document, problems));
    }
    let copy = beside(document, "new");
    std::fs::write(&copy, &text).map_err(|e| Error::Write(copy.clone(), e))?;
    let checked = evaluate(iets, &sys.root, &copy, system).map_err(Error::Eval);
    // the document's mode stays; through a symlink, its target changes, the link stays
    let target = std::fs::canonicalize(document).unwrap_or_else(|_| document.to_path_buf());
    let write = |e| Error::Write(target.clone(), e);
    let done = checked.and_then(|()| {
        let mode = std::fs::metadata(&target).map_err(write)?.permissions();
        std::fs::set_permissions(&copy, mode).map_err(write)?;
        std::fs::rename(&copy, &target).map_err(write)
    });
    if done.is_err() {
        let _ = std::fs::remove_file(&copy);
    }
    done
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn schema() -> Value {
        json!({ "type": "object", "additionalProperties": false, "required": ["/system"], "properties": {
            "/system": { "type": "object" },
            "/services/sshd": { "type": "object", "additionalProperties": false, "properties": {
                "port": { "type": "integer" },
                "keys": { "type": "array", "items": { "type": "string" } }
            }}
        }})
    }

    const DOC: &str = "[\"/system\"]\n\n[\"/services/sshd\"]\nport = \"x\"\nprot = 1\nkeys = [\n  \"a\",\n  2,\n]\n";

    #[test]
    fn problems_name_their_lines() {
        let p = schema_problems(&schema(), DOC, DOC).unwrap();
        let shown: Vec<(Option<usize>, &str, &str)> = p
            .iter()
            .map(|p| (p.line, p.path.as_str(), p.message.as_str()))
            .collect();
        assert_eq!(
            shown,
            vec![
                // an array item: the line of its key
                (Some(6), "/services/sshd keys.1", "expected string, got 2"),
                (
                    Some(4),
                    "/services/sshd port",
                    "expected integer, got \"x\""
                ),
                (Some(5), "/services/sshd prot", "no such option"),
            ]
        );
    }

    #[test]
    fn a_problem_of_the_whole_document_has_no_line() {
        let p = schema_problems(&schema(), "", "").unwrap();
        assert_eq!(
            p,
            vec![Problem {
                line: None,
                path: String::new(),
                message: "missing /system".into()
            }]
        );
        let shown = Error::Invalid("s.toml".into(), p).to_string();
        assert_eq!(shown, "s.toml: missing /system");
    }

    #[test]
    fn a_refused_edit_names_lines_of_the_document_on_disk() {
        let on_disk = "[\"/system\"]\n\n[\"/services/sshd\"]\nport = 22\n";
        let edited = format!("{on_disk}prot = 1\n");
        let p = schema_problems(&schema(), &edited, on_disk).unwrap();
        // not on disk yet: its table's header
        assert_eq!(
            (p[0].line, p[0].path.as_str()),
            (Some(3), "/services/sshd prot")
        );
        let p = schema_problems(&schema(), "[\"/system\"]\n[\"/x\"]\n", "[\"/system\"]\n").unwrap();
        assert_eq!((p[0].line, p[0].path.as_str()), (None, "/x"));
    }

    #[test]
    fn invalid_lists_each_problem_on_its_line() {
        let p = schema_problems(&schema(), DOC, DOC).unwrap();
        assert_eq!(
            Error::Invalid("s.toml".into(), p).to_string(),
            "s.toml:6: /services/sshd keys.1: expected string, got 2\n\
             s.toml:4: /services/sshd port: expected integer, got \"x\"\n\
             s.toml:5: /services/sshd prot: no such option"
        );
    }
}
