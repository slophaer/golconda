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

/// The SBOM, the image's own packages, and each component's pin date: `[pin] date` of the
/// sources.toml beside its package, for the packages that have one. The date is the console's
/// to read; the SBOM (and so the image) stays as the generator writes it.
const EXPR: &str = "{ config, system }: \
    let \
      s = import ./lib/system.nix { inherit config system; }; \
      dateOf = p: \
        if p ? dir && builtins.pathExists (p.dir + \"/sources.toml\") \
        then (builtins.fromTOML (builtins.readFile (p.dir + \"/sources.toml\"))).pin.date or null \
        else null; \
    in { \
      bom = s.sbom.bom; \
      roots = map (p: p.pname or p.name) s.composed.packages; \
      dates = builtins.listToAttrs (map (c: { name = c.name; value = dateOf (s.pkgs.${c.name} or { }); }) \
        s.sbom.bom.components); \
    }";

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
    /// the release date (`YYYY-MM-DD`) of the pinned version, from its sources.toml's
    /// `[pin] date`, when that has one
    pub pinned: Option<String>,
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
            "pinned": self.pinned,
        })
    }

    /// Days from the release of the pinned version to the Unix time `now`; none when the
    /// package has no pin date (or one in the future).
    pub fn age_days(&self, now: u64) -> Option<u64> {
        let (y, m, d) = civil(self.pinned.as_deref()?)?;
        let released = days_from_civil(y, m, d);
        u64::try_from(i64::try_from(now / 86400).ok()?.checked_sub(released)?).ok()
    }
}

/// The packages in the order to show them: the vulnerable ones first, then the outdated ones,
/// then the ones the image names itself, then the rest; each group in the order of `list`.
pub fn order(
    list: &[Package],
    vulnerable: impl Fn(&Package) -> bool,
    outdated: impl Fn(&Package) -> bool,
) -> Vec<&Package> {
    let mut shown: Vec<&Package> = list.iter().collect();
    shown.sort_by_key(|p| (!vulnerable(p), !outdated(p), !p.root));
    shown
}

/// The value of the component's property `name`.
fn property(component: &Value, name: &str) -> Option<String> {
    component["properties"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| p["name"] == name)
        .and_then(|p| p["value"].as_str())
        .map(str::to_string)
}

/// `YYYY-MM-DD` as year, month, day; none for anything else or a day that does not exist.
fn civil(date: &str) -> Option<(i64, i64, i64)> {
    let mut parts = date.splitn(3, '-');
    let (y, m, d) = (parts.next()?, parts.next()?, parts.next()?);
    if y.len() != 4 || m.len() != 2 || d.len() != 2 {
        return None;
    }
    let (y, m, d): (i64, i64, i64) = (y.parse().ok()?, m.parse().ok()?, d.parse().ok()?);
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let last = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => 28 + i64::from(leap),
        _ => return None,
    };
    (1..=last).contains(&d).then_some((y, m, d))
}

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The components of `bom`, with `roots` the names the image takes directly and `dates` the
/// pin date of each (name -> `YYYY-MM-DD` or null); sorted by name.
pub fn parse(bom: &Value, roots: &[String], dates: &Value) -> Vec<Package> {
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
                origin: property(c, "golconda:origin"),
                purl: s("purl"),
                cpe: s("cpe"),
                pinned: dates[name.as_str()]
                    .as_str()
                    .filter(|d| civil(d).is_some())
                    .map(str::to_string),
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
        list: parse(&v["bom"], &roots, &v["dates"]),
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
        let list = parse(&bom, &["systemd".into(), "openssh".into()], &Value::Null);
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

    #[test]
    fn the_pin_date_is_read_when_it_is_a_date() {
        let components: Vec<Value> = ["a", "b", "c", "d"]
            .iter()
            .map(|n| json!({ "name": n, "version": "1" }))
            .collect();
        let bom = json!({ "components": components });
        let dates = json!({ "a": "2026-10-31", "b": "last week", "c": "2026-02-30", "d": null });
        let list = parse(&bom, &[], &dates);
        let pinned: Vec<Option<&str>> = list.iter().map(|p| p.pinned.as_deref()).collect();
        assert_eq!(pinned, [Some("2026-10-31"), None, None, None]);
        assert_eq!(list[0].to_json()["pinned"], "2026-10-31");
    }

    #[test]
    fn age_is_counted_in_days_from_the_release() {
        let on = |date: Option<&str>, now: u64| {
            let bom = json!({ "components": [{ "name": "p", "version": "1" }] });
            parse(&bom, &[], &json!({ "p": date }))[0].age_days(now)
        };
        // 2026-11-07, 13:00 UTC
        let now = 1_794_056_400;
        assert_eq!(on(Some("2025-05-18"), now), Some(538));
        assert_eq!(on(Some("2026-11-07"), now), Some(0));
        assert_eq!(on(Some("2026-11-08"), now), None, "released tomorrow");
        assert_eq!(on(None, now), None);
        // the leap day counts
        assert_eq!(on(Some("2024-02-29"), 1_772_323_200), Some(731));
    }

    #[test]
    fn vulnerable_come_first_then_outdated_then_the_image_s_own() {
        let components: Vec<Value> = ["a", "b", "c", "d", "e", "f"]
            .iter()
            .map(|n| json!({ "name": n, "version": "1" }))
            .collect();
        let list = parse(
            &json!({ "components": components }),
            &["b".into(), "f".into()],
            &Value::Null,
        );
        let names =
            |shown: Vec<&Package>| -> String { shown.iter().map(|p| p.name.as_str()).collect() };
        let by = |set: &'static str| move |p: &Package| set.contains(p.name.as_str());
        // d is vulnerable, e outdated, c both; b and f are the image's own
        assert_eq!(names(order(&list, by("cd"), by("ce"))), "cdebfa");
        assert_eq!(names(order(&list, by(""), by(""))), "bfacde");
    }
}
