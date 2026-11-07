//! The packages of a system's image: its SBOM (CycloneDX) as mkSystem makes it, evaluated
//! without building anything, and the packages the image names directly.
//!
//! Every component carries `golconda:origin` (golconda, repkgs or the downstream repository's
//! name), a purl, and a cpe when its sources.toml has one; a downstream replacement names what
//! it replaced in `pedigree.ancestors`.

use crate::eval::{Arg, Iets};
use crate::system::{Error, find_root};
use serde_json::Value;
use std::fs;
use std::path::{self, Path};

const EXPR: &str = "{ config, system }: \
    let s = import ./lib/system.nix { inherit config system; }; \
    in { bom = s.sbom.bom; roots = map (p: p.pname or p.name) s.composed.packages; }";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Package {
    pub name: String,
    pub version: String,
    /// golconda, repkgs, or the downstream repository that adds it
    pub origin: Option<String>,
    pub purl: Option<String>,
    pub cpe: Option<String>,
    /// the image names it itself (a module's package), not only as a dependency
    pub root: bool,
    /// the packages it stands in for (a downstream replacement)
    pub replaces: Vec<String>,
}

/// A system's SBOM and its components.
#[derive(Debug, Clone)]
pub struct Packages {
    /// the CycloneDX document
    pub bom: Value,
    /// by name
    pub list: Vec<Package>,
}

impl Package {
    pub fn to_json(&self) -> Value {
        serde_json::json!({
            "name": self.name, "version": self.version, "origin": self.origin,
            "purl": self.purl, "cpe": self.cpe, "root": self.root, "replaces": self.replaces,
        })
    }
}

/// The components of `bom`, with `roots` the names the image takes directly; sorted by name.
pub fn parse(bom: &Value, roots: &[String]) -> Vec<Package> {
    let mut list: Vec<Package> = bom["components"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|c| {
            let s = |k: &str| c[k].as_str().map(str::to_string);
            let name = s("name").unwrap_or_default();
            Package {
                root: roots.contains(&name),
                version: s("version").unwrap_or_default(),
                origin: c["properties"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|p| p["name"] == "golconda:origin")
                    .and_then(|p| p["value"].as_str())
                    .map(str::to_string),
                purl: s("purl"),
                cpe: s("cpe"),
                replaces: c["pedigree"]["ancestors"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|a| a["name"].as_str().map(str::to_string))
                    .collect(),
                name,
            }
        })
        .collect();
    list.sort_by(|a, b| a.name.cmp(&b.name).then(a.version.cmp(&b.version)));
    list
}

/// Evaluates `document`'s SBOM for `system` (a Nix system double).
pub fn load(iets: &Iets, document: &Path, system: &str) -> Result<Packages, Error> {
    fs::metadata(document).map_err(|e| Error::Read(document.into(), e))?;
    let root = find_root(document).ok_or_else(|| Error::NoCheckout(document.into()))?;
    let abs = path::absolute(document).map_err(|e| Error::Read(document.into(), e))?;
    let v = iets
        .eval_json(
            &root,
            EXPR,
            &[Arg::Path("config", &abs), Arg::Str("system", system)],
        )
        .map_err(Error::Eval)?;
    let roots: Vec<String> = v["roots"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| r.as_str().map(str::to_string))
        .collect();
    Ok(Packages {
        list: parse(&v["bom"], &roots),
        bom: v["bom"].clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn components_say_origin_purl_and_what_they_replace() {
        let bom = json!({ "components": [
            { "name": "systemd", "version": "262.1", "purl": "pkg:github/systemd/systemd@v262.1",
              "properties": [{ "name": "golconda:origin", "value": "golconda" }] },
            { "name": "acl", "version": "2.4.0", "purl": "pkg:generic/acl@2.4.0",
              "properties": [{ "name": "repkgs:approximation", "value": "x" }, { "name": "golconda:origin", "value": "repkgs" }] },
            { "name": "openssh", "version": "10.2p1", "cpe": "cpe:2.3:a:openbsd:openssh:10.2:p1:*:*:*:*:*:*",
              "properties": [{ "name": "golconda:origin", "value": "acme" }],
              "pedigree": { "ancestors": [{ "name": "openssh", "version": "10.2p1" }] } },
        ]});
        let list = parse(&bom, &["systemd".into(), "openssh".into()]);
        let names: Vec<&str> = list.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["acl", "openssh", "systemd"]);
        assert_eq!(list[0].origin.as_deref(), Some("repkgs"));
        assert!(!list[0].root && list[1].root && list[2].root);
        assert_eq!(list[1].replaces, ["openssh"]);
        assert!(
            list[1]
                .cpe
                .as_deref()
                .is_some_and(|c| c.starts_with("cpe:2.3:a:openbsd"))
        );
        assert_eq!(list[1].purl, None);
        assert_eq!(list[2].to_json()["origin"], "golconda");
    }
}
