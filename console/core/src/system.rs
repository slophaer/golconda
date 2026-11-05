//! One system: its document, and what mkSystem says about it (config, schema, module docs).

use crate::document::{key, line_of, option_name, toml_text};
use crate::eval::{self, Arg, Iets};
use crate::schema::{self, LookupError};
use serde_json::{Map, Value, json};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf, absolute};
use std::process::Command;
use tempfile::{Builder, TempPath};

/// What one evaluation returns: the outputs the console reads, nothing that builds.
const EXPR: &str = "{ config, system }: \
    let s = import ./lib/system.nix { inherit config system; }; \
    in { inherit (s) config schema moduleDocs; }";

pub struct System {
    /// the Golconda checkout the document is evaluated with
    pub root: PathBuf,
    /// the document, relative to `root`
    pub document: PathBuf,
    pub text: String,
    /// mkSystem's config: module path -> option -> { value?; explicit; }
    pub config: Value,
    pub schema: Value,
    /// module path -> its #! doc text or null
    pub module_docs: Value,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("cannot read {path}: {1}", path = .0.display())]
    Read(PathBuf, io::Error),
    #[error(
        "{} is in no Golconda checkout (a directory above it with lib/system.nix); \
         pure evaluation reads files under the checkout only",
        .0.display()
    )]
    NoCheckout(PathBuf),
    #[error(transparent)]
    Eval(eval::Error),
    /// git could not give the document at a revision
    #[error("the document at {0}: {1}")]
    Git(String, String),
}

/// A copy of `text` beside `document` for one evaluation (pure evaluation reads under the
/// checkout only, and the document's relative paths must hold). The name is dot-prefixed with
/// `tag` and random; the file is created new (a planted symlink is refused) and readable by its
/// owner only, as the document may hold what others should not. Dropping the result removes it.
pub(crate) fn write_beside(document: &Path, tag: &str, text: &str) -> io::Result<TempPath> {
    let dir = match document.parent() {
        Some(d) if !d.as_os_str().is_empty() => d,
        _ => Path::new("."),
    };
    let name = document.file_name().unwrap_or_default().to_string_lossy();
    let prefix = format!(".{name}.golconda-{tag}-");
    let mut file = Builder::new().prefix(&prefix).tempfile_in(dir)?;
    file.write_all(text.as_bytes())?;
    Ok(file.into_temp_path())
}

/// The nearest directory at or above `path` with lib/system.nix.
pub fn find_root(path: &Path) -> Option<PathBuf> {
    let abs = absolute(path).ok()?;
    abs.ancestors()
        .skip(1)
        .find(|d| d.join("lib/system.nix").is_file())
        .map(Path::to_path_buf)
}

impl System {
    /// Read `document` and evaluate it for `system` (a Nix system double).
    pub fn load(iets: &Iets, document: &Path, system: &str) -> Result<System, Error> {
        let text = fs::read_to_string(document).map_err(|e| Error::Read(document.into(), e))?;
        let root = find_root(document).ok_or_else(|| Error::NoCheckout(document.into()))?;
        let abs = absolute(document).map_err(|e| Error::Read(document.into(), e))?;
        let v = iets
            .eval_json(
                &root,
                EXPR,
                &[Arg::Path("config", &abs), Arg::Str("system", system)],
            )
            .map_err(Error::Eval)?;
        Ok(System {
            document: abs.strip_prefix(&root).unwrap_or(&abs).to_path_buf(),
            root,
            text,
            config: v["config"].clone(),
            schema: v["schema"].clone(),
            module_docs: v["moduleDocs"].clone(),
        })
    }

    /// `text` evaluated as if it were `document`: written beside it (so its relative paths and
    /// pure evaluation's root are the same), loaded, removed. For another revision of it.
    pub fn load_text(
        iets: &Iets,
        document: &Path,
        text: &str,
        system: &str,
    ) -> Result<System, Error> {
        let copy =
            write_beside(document, "old", text).map_err(|e| Error::Read(document.into(), e))?;
        System::load(iets, &copy, system)
    }

    /// The document as git has it at `rev`.
    pub fn git_text(document: &Path, rev: &str) -> Result<String, Error> {
        let dir = match document.parent() {
            Some(d) if !d.as_os_str().is_empty() => d,
            _ => Path::new("."),
        };
        let name = document.file_name().unwrap_or_default().to_string_lossy();
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["show", &format!("{rev}:./{name}")])
            .output()
            .map_err(|e| Error::Read(document.into(), e))?;
        if !out.status.success() {
            let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
            return Err(Error::Git(rev.to_string(), msg));
        }
        String::from_utf8(out.stdout).map_err(|e| {
            Error::Git(
                rev.to_string(),
                format!("{}: not UTF-8: {e}", document.display()),
            )
        })
    }

    /// `path`: the option path in the module, at least one key.
    pub fn explain(&self, module: &str, path: &[&str]) -> Result<Explanation, LookupError> {
        let found = schema::option(&self.schema, module, path)?;
        let entry = &self.config[module][path[0]];
        let value = path[1..]
            .iter()
            .try_fold(&entry["value"], |v, seg| v.get(*seg))
            .filter(|v| !v.is_null())
            .cloned();
        let set_at = line_of(&self.text, module, path);
        let declared = &found.node["x-golconda-declaredIn"];
        Ok(Explanation {
            module: module.to_string(),
            option: option_name(path),
            type_name: schema::type_name(found.node),
            description: found.description.map(str::to_string),
            explicit: entry["explicit"] == true && (path.len() == 1 || set_at.is_some()),
            value,
            default: found.node.get("default").cloned(),
            set_at: set_at.map(|l| (self.document.display().to_string(), l)),
            declared_at: declared["file"]
                .as_str()
                .map(|f| (f.to_string(), declared["line"].as_u64().unwrap_or(0))),
        })
    }

    /// The effective configuration as TOML-like text: every module mkSystem reports, every
    /// option with its value; defaults marked `# default`, an option with neither value nor
    /// default as a comment. `set_only`: what the document sets.
    pub fn show(&self, set_only: bool) -> String {
        let mut out = String::new();
        let empty = Map::new();
        for (module, options) in self.config.as_object().unwrap_or(&empty) {
            let mut lines = String::new();
            for (name, o) in options.as_object().unwrap_or(&empty) {
                let explicit = o["explicit"] == true;
                if set_only && !explicit {
                    continue;
                }
                let key = key(name);
                match o.get("value") {
                    None => lines += &format!("# {key}: no value\n"),
                    // TOML has no null: a comment keeps the text TOML
                    Some(Value::Null) if explicit => lines += &format!("# {key} = null\n"),
                    Some(Value::Null) => lines += &format!("# {key} = null  # default\n"),
                    Some(v) if explicit => lines += &format!("{key} = {}\n", toml_text(v)),
                    Some(v) => lines += &format!("{key} = {}  # default\n", toml_text(v)),
                }
            }
            if lines.is_empty() && set_only {
                continue;
            }
            if !out.is_empty() {
                out.push('\n');
            }
            out += &format!("[{}]\n{lines}", Value::String(module.clone()));
        }
        out
    }
}

/// What `golconda config explain` says about one option.
#[derive(Debug, Clone, PartialEq)]
pub struct Explanation {
    pub module: String,
    /// the option path inside the module, dotted
    pub option: String,
    pub type_name: String,
    pub description: Option<String>,
    /// the effective value; None when there is none
    pub value: Option<Value>,
    /// the document sets it
    pub explicit: bool,
    pub default: Option<Value>,
    /// (document, line) where the document sets it
    pub set_at: Option<(String, usize)>,
    /// (file, line) where the module declares it
    pub declared_at: Option<(String, u64)>,
}

impl Explanation {
    pub fn to_json(&self) -> Value {
        json!({
            "module": self.module,
            "option": self.option,
            "type": self.type_name,
            "description": self.description,
            "value": self.value,
            "explicit": self.explicit,
            "default": self.default,
            "setAt": self.set_at.as_ref().map(|(f, l)| json!({ "file": f, "line": l })),
            "declaredIn": self.declared_at.as_ref().map(|(f, l)| json!({ "file": f, "line": l })),
        })
    }

    pub fn to_text(&self) -> String {
        let mut out = format!("{} {}\n", self.module, self.option);
        if let Some(d) = &self.description {
            out += &format!("\n{}\n\n", wrap(d, 76, "  "));
        }
        out += &format!("type      {}\n", self.type_name);
        let value = match &self.value {
            Some(v) => toml_text(v),
            None => "(none)".into(),
        };
        match &self.set_at {
            Some((f, l)) if self.explicit => {
                out += &format!("value     {value}  (set at {f}:{l})\n");
            }
            _ => out += &format!("value     {value}  (default)\n"),
        }
        if let Some(d) = &self.default {
            out += &format!("default   {}\n", toml_text(d));
        }
        if let Some((f, l)) = &self.declared_at {
            out += &format!("declared  {f}:{l}\n");
        }
        out
    }
}

fn wrap(text: &str, width: usize, indent: &str) -> String {
    let mut lines = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        if !line.is_empty() && indent.len() + line.len() + 1 + word.len() > width {
            lines.push(format!("{indent}{line}"));
            line.clear();
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line += word;
    }
    if !line.is_empty() {
        lines.push(format!("{indent}{line}"));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    fn system() -> System {
        System {
            root: "/c".into(),
            document: "server.toml".into(),
            text: "[\"/services/sshd\"]\nport = 2222\n".into(),
            config: json!({
                "/base": { "ntp": { "explicit": false, "value": ["a"] },
                           "dns": { "explicit": false, "value": null } },
                "/services/sshd": {
                    "port": { "explicit": true, "value": 2222 },
                    "package": { "explicit": false },
                    "principals": { "explicit": false, "value": {} }
                }
            }),
            schema: json!({ "properties": { "/base": { "properties": { "ntp": {} } },
                "/services/sshd": { "properties": {
                "port": { "type": "integer", "default": 22, "description": "Listening port.",
                          "x-golconda-declaredIn": { "file": "modules/services/sshd/default.nix", "line": 50 } },
                "package": { "type": "string", "x-golconda": "package" },
                "principals": { "type": "object", "additionalProperties": { "type": "array", "items": { "type": "string" } } }
            }}}}),
            module_docs: json!({}),
        }
    }

    #[test]
    fn explain_a_set_option() {
        let e = system().explain("/services/sshd", &["port"]).unwrap();
        assert_eq!(
            e.to_text(),
            "/services/sshd port\n\n  Listening port.\n\n\
             type      integer\n\
             value     2222  (set at server.toml:2)\n\
             default   22\n\
             declared  modules/services/sshd/default.nix:50\n"
        );
        assert_eq!(
            e.to_json()["setAt"],
            json!({ "file": "server.toml", "line": 2 })
        );
    }

    #[test]
    fn explain_an_option_with_no_value() {
        let e = system().explain("/services/sshd", &["package"]).unwrap();
        assert_eq!(e.value, None);
        assert!(!e.explicit);
        assert!(
            e.to_text()
                .contains("type      package\nvalue     (none)  (default)\n")
        );
    }

    #[test]
    fn explain_inside_a_map_has_no_value_where_the_map_has_none() {
        let e = system()
            .explain("/services/sshd", &["principals", "root"])
            .unwrap();
        assert_eq!(e.type_name, "list of string");
        assert_eq!(e.value, None);
        assert!(!e.explicit);
    }

    #[test]
    fn explain_a_key_the_document_does_not_set_in_a_map_it_sets() {
        let mut sys = system();
        sys.text += "principals = { root = [\"a@b\"] }\n";
        sys.config["/services/sshd"]["principals"] =
            json!({ "explicit": true, "value": { "root": ["a@b"] } });
        let root = sys
            .explain("/services/sshd", &["principals", "root"])
            .unwrap();
        assert!(root.explicit);
        assert_eq!(root.set_at, Some(("server.toml".into(), 3)));
        let admin = sys
            .explain("/services/sshd", &["principals", "admin"])
            .unwrap();
        assert!(!admin.explicit);
        assert_eq!(admin.set_at, None);
    }

    #[test]
    fn show_marks_defaults_and_missing_values() {
        assert_eq!(
            system().show(false),
            "[\"/base\"]\n# dns = null  # default\nntp = [\"a\"]  # default\n\n\
             [\"/services/sshd\"]\n# package: no value\nport = 2222\nprincipals = {}  # default\n"
        );
        assert_eq!(system().show(true), "[\"/services/sshd\"]\nport = 2222\n");
    }

    #[test]
    fn keys_that_need_quotes() {
        assert_eq!(key("port"), "port");
        assert_eq!(key("a.b"), "\"a.b\"");
        assert_eq!(key(""), "\"\"");
    }

    #[test]
    fn the_checkout_is_found_above_the_document() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        fs::create_dir_all(root.join("lib")).unwrap();
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("lib/system.nix"), "").unwrap();
        // the document's own directory counts, and so does every one above it
        assert_eq!(find_root(&root.join("server.toml")), Some(root.into()));
        assert_eq!(find_root(&root.join("a/b/server.toml")), Some(root.into()));
        assert_eq!(find_root(Path::new("/server.toml")), None);
    }

    #[test]
    fn copies_beside_the_document_have_names_of_their_own() {
        let dir = TempDir::new().unwrap();
        let document = dir.path().join("server.toml");
        let a = write_beside(&document, "old", "a").unwrap();
        let b = write_beside(&document, "old", "b").unwrap();
        assert_ne!(a.to_path_buf(), b.to_path_buf());
        assert_eq!(a.parent(), Some(dir.path()));
        let name = a.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with(".server.toml.golconda-old-"), "{name}");
    }

    #[test]
    fn a_copy_is_new_only_for_its_owner_and_gone_when_dropped() {
        let dir = TempDir::new().unwrap();
        let copy = write_beside(&dir.path().join("server.toml"), "t", "x").unwrap();
        assert_eq!(fs::read_to_string(&copy).unwrap(), "x");
        assert_eq!(
            fs::metadata(&copy).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let path = copy.to_path_buf();
        drop(copy);
        assert!(!path.exists());
    }
}
