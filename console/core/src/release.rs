//! Releases: the directory an image build writes (`release/`, docs/design/releases.md), checked
//! before anything serves it.
//!
//! A release is four files, the index `SHA256SUMS` that lists them in a fixed order with their
//! digests, and `SHA256SUMS.gpg`, a detached OpenPGP signature of the index by the key set's
//! release key. Machines install only what that key signed, so [`check`] verifies the signature
//! against `release/index.pgp` of the key set, the public half the image carries.
//!
//! `gpgv` is a program, as `age` and `ssh` are for vars: `GOLCONDA_GPGV` names it.

use crate::candidate::rfc3339;
use crate::vars::Program;
use ring::digest::{Context, SHA256};
use serde_json::Value;
use std::cmp::Ordering;
use std::fmt::{self, Write as _};
use std::fs;
use std::io::{self, Read};
use std::ops::Range;
use std::path::{self, Path, PathBuf};
use std::result;
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct Error(pub String);

pub type Result<T> = result::Result<T, Error>;

fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

/// The last revision whose timestamp is still inside its date (lib/version.nix).
const MAX_REVISION: u32 = 86_399;

/// A release version, `YYYYMMDD.N`, with lib/version.nix's grammar: a real date from 1970 on,
/// and a revision from 0 to 86399 without a leading zero. Versions order as sysupdate orders
/// them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub year: u32,
    pub month: u32,
    pub day: u32,
    pub revision: u32,
}

fn is_leap(y: u32) -> bool {
    y.is_multiple_of(4) && (!y.is_multiple_of(100) || y.is_multiple_of(400))
}

fn days_in(y: u32, m: u32) -> u32 {
    match m {
        2 if is_leap(y) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

impl FromStr for Version {
    type Err = Error;

    fn from_str(s: &str) -> Result<Version> {
        let bad = |why: &str| {
            err(format!(
                "'{s}' is not a release version (YYYYMMDD.N): {why}"
            ))
        };
        let Some((date, rev)) = s.split_once('.') else {
            return bad("no '.'");
        };
        let digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
        if date.len() != 8 || !digits(date) || !digits(rev) {
            return bad("eight digits, a dot, digits");
        }
        if rev.len() > 1 && rev.starts_with('0') {
            return bad("the revision has a leading zero");
        }
        let n = |t: &str| t.parse::<u32>().map_err(|e| Error(e.to_string()));
        let (year, month, day) = (n(&date[..4])?, n(&date[4..6])?, n(&date[6..])?);
        let Ok(revision) = rev.parse::<u32>() else {
            return bad("the revision is too large");
        };
        if year < 1970 {
            return bad("the year is before 1970");
        }
        if !(1..=12).contains(&month) || day < 1 || day > days_in(year, month) {
            return bad("not a real date");
        }
        if revision > MAX_REVISION {
            return bad("the revision is above 86399");
        }
        Ok(Version {
            year,
            month,
            day,
            revision,
        })
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{:04}{:02}{:02}.{}",
            self.year, self.month, self.day, self.revision
        )
    }
}

impl Version {
    /// Today's date (UTC) with revision 0.
    pub fn today() -> Version {
        let secs = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let t = rfc3339(secs);
        let n = |r: Range<usize>| t[r].parse().unwrap_or(1);
        Version {
            year: n(0..4),
            month: n(5..7),
            day: n(8..10),
            revision: 0,
        }
    }

    /// The version `--version auto` picks: `today`'s date, with the revision after the newest of
    /// `seen` when that one has the same date.
    ///
    /// # Errors
    ///
    /// When a version in `seen` has a later date than `today` (a clock behind, or a version
    /// given by hand), or today's revisions are used up.
    pub fn next(today: Version, seen: &[Version]) -> Result<Version> {
        let day = Version {
            revision: 0,
            ..today
        };
        let Some(newest) = seen.iter().max() else {
            return Ok(day);
        };
        match (newest.year, newest.month, newest.day).cmp(&(day.year, day.month, day.day)) {
            Ordering::Less => Ok(day),
            Ordering::Greater => err(format!(
                "{newest} is from a later day than today ({day}): give --version"
            )),
            Ordering::Equal if newest.revision >= MAX_REVISION => {
                err(format!("{newest}: no revision left today"))
            }
            Ordering::Equal => Ok(Version {
                revision: newest.revision + 1,
                ..day
            }),
        }
    }

    /// `self` must be newer than every version in `seen`.
    ///
    /// # Errors
    ///
    /// Names the newest one it does not pass.
    pub fn newer_than(&self, seen: &[Version], what: &str) -> Result<()> {
        match seen.iter().max() {
            Some(newest) if newest >= self => err(format!(
                "{self} is not newer than {newest} ({what}): sysupdate would install nothing"
            )),
            _ => Ok(()),
        }
    }
}

/// One line of the index: the digest (lower-case hex) and the file name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct File {
    pub digest: String,
    pub name: String,
}

/// What the four lines of `SHA256SUMS` say.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Index {
    pub id: String,
    pub version: Version,
    /// usr, verity, signature, UKI: the fixed order
    pub files: [File; 4],
    /// the UUIDs in the usr and verity names
    pub usr_uuid: String,
    pub verity_uuid: String,
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn is_uuid(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    parts.len() == 5
        && parts
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(p, len)| is_hex(p, len))
}

/// The image id grammar (modules/lib/grammar.nix `imageName`).
fn is_image_id(s: &str) -> bool {
    let mut b = s.bytes();
    b.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && b.all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}

/// A UUID (8-4-4-4-12) from 32 hex digits, as lib/image/disk.nu writes it.
fn uuid_of(hex: &str) -> String {
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Reads `SHA256SUMS`: four lines in the fixed order, each `<digest>  <name>`, the names
/// `<id>_<version>` with the suffixes of docs/design/releases.md.
///
/// # Errors
///
/// Says which line is wrong and how.
pub fn read_index(text: &str) -> Result<Index> {
    let lines: Vec<&str> = text.lines().collect();
    if lines.len() != 4 || !text.ends_with('\n') {
        return err(format!(
            "SHA256SUMS has {} lines: it must have 4 (usr, verity, signature, UKI), each ending in a newline",
            lines.len()
        ));
    }
    let mut files = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let Some((digest, name)) = line.split_once("  ") else {
            return err(format!("SHA256SUMS line {}: not '<sha256>  <name>'", i + 1));
        };
        if !is_hex(digest, 64) {
            return err(format!(
                "SHA256SUMS line {}: '{digest}' is not a lower-case SHA-256 digest",
                i + 1
            ));
        }
        if name.is_empty() || name.contains('/') || name.contains(char::is_whitespace) {
            return err(format!(
                "SHA256SUMS line {}: '{name}' is not a file name",
                i + 1
            ));
        }
        files.push(File {
            digest: digest.into(),
            name: name.into(),
        });
    }
    // the UKI line holds the stem alone: <id>_<version>.efi
    let uki = files[3].name.clone();
    let Some(stem) = uki.strip_suffix(".efi") else {
        return err(format!(
            "SHA256SUMS line 4: '{}' is not the UKI (<id>_<version>.efi)",
            files[3].name
        ));
    };
    let Some((id, version)) = stem.rsplit_once('_') else {
        return err(format!(
            "SHA256SUMS line 4: '{}' has no '_' between image id and version",
            files[3].name
        ));
    };
    if !is_image_id(id) {
        return err(format!(
            "SHA256SUMS line 4: '{id}' is not an image id (letters, digits and _ . -)"
        ));
    }
    let version: Version = version.parse()?;
    let with_uuid = |n: usize, part: &str| -> Result<String> {
        let name = &files[n].name;
        name.strip_prefix(&format!("{stem}.{part}."))
            .and_then(|r| r.strip_suffix(".raw"))
            .filter(|u| is_uuid(u))
            .map(str::to_string)
            .ok_or_else(|| {
                Error(format!(
                    "SHA256SUMS line {}: '{name}' is not {stem}.{part}.<uuid>.raw",
                    n + 1
                ))
            })
    };
    let usr_uuid = with_uuid(0, "usr")?;
    let verity_uuid = with_uuid(1, "usr-verity")?;
    if files[2].name != format!("{stem}.usr-verity-sig.raw") {
        return err(format!(
            "SHA256SUMS line 3: '{}' is not {stem}.usr-verity-sig.raw",
            files[2].name
        ));
    }
    let files: [File; 4] = files.try_into().map_err(|_| Error("four lines".into()))?;
    Ok(Index {
        id: id.into(),
        version,
        files,
        usr_uuid,
        verity_uuid,
    })
}

/// The SHA-256 of a file, in lower-case hex, read in blocks (a `/usr` image is gigabytes).
///
/// # Errors
///
/// When the file cannot be read.
pub fn sha256(path: &Path) -> io::Result<String> {
    let mut f = fs::File::open(path)?;
    let mut ctx = Context::new(&SHA256);
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
    }
    Ok(ctx
        .finish()
        .as_ref()
        .iter()
        .fold(String::new(), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        }))
}

/// A checked release directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub dir: PathBuf,
    pub index: Index,
    /// the verity root hash the signature file names
    pub root_hash: String,
}

/// The public release key of a key set: `<keys>/release/index.pgp`.
pub fn keyring(keys: &Path) -> PathBuf {
    keys.join("release/index.pgp")
}

/// Checks a release directory: the index's grammar, every file's digest, the UUIDs in the names
/// against the root hash the verity signature names, and the index's signature against
/// `keyring` (a binary OpenPGP public key, the key set's `release/index.pgp`).
///
/// # Errors
///
/// The first thing that is wrong, naming the file.
pub fn check(dir: &Path, keyring: &Path, gpgv: &Program) -> Result<Release> {
    let read = |name: &str| {
        fs::read(dir.join(name)).map_err(|e| Error(format!("{}: {e}", dir.join(name).display())))
    };
    let text = String::from_utf8(read("SHA256SUMS")?)
        .map_err(|_| Error("SHA256SUMS is not UTF-8".into()))?;
    let index = read_index(&text)?;
    for f in &index.files {
        let path = dir.join(&f.name);
        let got = sha256(&path).map_err(|e| Error(format!("{}: {e}", path.display())))?;
        if got != f.digest {
            return err(format!(
                "{}: its digest is {got}, SHA256SUMS says {}",
                f.name, f.digest
            ));
        }
    }
    // the signature partition is JSON padded with NUL bytes to 4096 (lib/image/verity.nu)
    let raw = read(&index.files[2].name)?;
    let end = raw.iter().rposition(|&b| b != 0).map_or(0, |i| i + 1);
    let sig: Value = serde_json::from_slice(&raw[..end])
        .map_err(|e| Error(format!("{}: not JSON: {e}", index.files[2].name)))?;
    let Some(root_hash) = sig["rootHash"].as_str().filter(|h| is_hex(h, 64)) else {
        return err(format!(
            "{}: no rootHash of 64 hex digits",
            index.files[2].name
        ));
    };
    for (uuid, hex, what) in [
        (&index.usr_uuid, &root_hash[..32], "first"),
        (&index.verity_uuid, &root_hash[32..], "last"),
    ] {
        if *uuid != uuid_of(hex) {
            return err(format!(
                "{uuid} is not the {what} 128 bits of the root hash {root_hash}"
            ));
        }
    }
    verify_signature(dir, keyring, gpgv)?;
    Ok(Release {
        dir: dir.to_path_buf(),
        index,
        root_hash: root_hash.into(),
    })
}

/// `gpgv` with the one keyring, in a home of its own: the user's keys play no part.
fn verify_signature(dir: &Path, keyring: &Path, gpgv: &Program) -> Result<()> {
    if !keyring.is_file() {
        return err(format!("{}: no release key there", keyring.display()));
    }
    let keyring = path::absolute(keyring).map_err(|e| Error(e.to_string()))?;
    let home = TempDir::new().map_err(|e| Error(e.to_string()))?;
    let (sig, index) = (dir.join("SHA256SUMS.gpg"), dir.join("SHA256SUMS"));
    if !sig.is_file() {
        return err(format!("{}: no signature", sig.display()));
    }
    gpgv.run(
        &[
            "--homedir".as_ref(),
            home.path().as_os_str(),
            "--keyring".as_ref(),
            keyring.as_os_str(),
            sig.as_os_str(),
            index.as_os_str(),
        ],
        None,
    )
    .map(|_| ())
    .map_err(|e| {
        Error(format!(
            "SHA256SUMS.gpg is not a signature by the release key {}: {e}",
            keyring.display()
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;

    const ROOT: &str = "0123456789abcdef0123456789abcdef89abcdef0123456789abcdef01234567";

    struct Fixture {
        tmp: TempDir,
        dir: PathBuf,
        keys: PathBuf,
        gpgv: Program,
    }

    impl Fixture {
        fn log(&self) -> String {
            fs::read_to_string(self.tmp.path().join("gpgv.log")).unwrap_or_default()
        }

        fn check(&self) -> Result<Release> {
            check(&self.dir, &keyring(&self.keys), &self.gpgv)
        }

        /// SHA256SUMS from `lines` (name and content), the files written
        fn index(&self, lines: &[(&str, &[u8])]) {
            let mut text = String::new();
            for (name, body) in lines {
                fs::write(self.dir.join(name), body).unwrap();
                text += &format!("{}  {name}\n", sha256(&self.dir.join(name)).unwrap());
            }
            fs::write(self.dir.join("SHA256SUMS"), text).unwrap();
        }
    }

    fn names(stem: &str) -> [String; 4] {
        [
            format!("{stem}.usr.{}.raw", uuid_of(&ROOT[..32])),
            format!("{stem}.usr-verity.{}.raw", uuid_of(&ROOT[32..])),
            format!("{stem}.usr-verity-sig.raw"),
            format!("{stem}.efi"),
        ]
    }

    /// A release of `server` 20261105.1 with a signature the stand-in gpgv accepts.
    fn fixture() -> Fixture {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().join("release");
        let keys = tmp.path().join("keys");
        fs::create_dir_all(&dir).unwrap();
        fs::create_dir_all(keys.join("release")).unwrap();
        fs::write(keys.join("release/index.pgp"), "key").unwrap();
        let gpgv = tmp.path().join("gpgv");
        // --homedir H --keyring K SIG INDEX: accept a signature that reads "good"
        fs::write(
            &gpgv,
            format!(
                "#!/bin/sh\necho \"$@\" > {}/gpgv.log\n[ \"$(cat \"$5\")\" = good ] || {{ echo 'BAD signature' >&2; exit 1; }}\n",
                tmp.path().display()
            ),
        )
        .unwrap();
        fs::set_permissions(&gpgv, fs::Permissions::from_mode(0o755)).unwrap();
        let f = Fixture {
            gpgv: Program::from_env("GOLCONDA_TEST_UNSET_GPGV", gpgv.to_str().unwrap()),
            tmp,
            dir,
            keys,
        };
        let n = names("server_20261105.1");
        // padded with NUL bytes to 4096, as lib/image/verity.nu writes it
        let mut sig = format!(r#"{{"rootHash":"{ROOT}","signature":"x"}}"#).into_bytes();
        sig.resize(4096, 0);
        f.index(&[
            (&n[0], b"usr"),
            (&n[1], b"verity"),
            (&n[2], &sig),
            (&n[3], b"uki"),
        ]);
        fs::write(f.dir.join("SHA256SUMS.gpg"), "good").unwrap();
        f
    }

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    #[test]
    fn versions_follow_the_grammar_of_lib_version_nix() {
        for good in ["19700101.0", "20240229.1", "20261031.86399", "20261231.10"] {
            assert_eq!(v(good).to_string(), good);
        }
        for bad in [
            "20250229.1",
            "20261031.01",
            "20261031.86400",
            "19691231.1",
            "20261301.1",
            "20261100.1",
            "2026103.1",
            "20261031",
            "20261031.",
            "20261031.1a",
            "20261031.99999999999",
        ] {
            assert!(bad.parse::<Version>().is_err(), "{bad} was accepted");
        }
    }

    #[test]
    fn versions_order_by_date_then_revision() {
        assert!(v("20261031.10") > v("20261031.9"));
        assert!(v("20261101.0") > v("20261031.86399"));
        assert!(v("20270101.0") > v("20261231.5"));
    }

    #[test]
    fn auto_takes_today_and_the_next_revision_of_today() {
        let today = v("20261106.0");
        assert_eq!(Version::next(today, &[]).unwrap(), v("20261106.0"));
        assert_eq!(
            Version::next(today, &[v("20261105.4")]).unwrap(),
            v("20261106.0")
        );
        assert_eq!(
            Version::next(today, &[v("20261105.4"), v("20261106.2")]).unwrap(),
            v("20261106.3")
        );
        let e = Version::next(today, &[v("20261107.0")]).unwrap_err();
        assert!(e.0.contains("later day"), "{e}");
        assert!(Version::next(today, &[v("20261106.86399")]).is_err());
    }

    #[test]
    fn a_version_must_be_newer_than_all_seen() {
        let seen = [v("20261105.1"), v("20261106.0")];
        assert!(v("20261106.1").newer_than(&seen, "x").is_ok());
        let e = v("20261106.0")
            .newer_than(&seen, "the destination")
            .unwrap_err();
        assert!(e.0.contains("20261106.0 (the destination)"), "{e}");
        assert!(v("20261105.9").newer_than(&seen, "x").is_err());
    }

    #[test]
    fn a_good_release_passes_and_says_what_it_is() {
        let f = fixture();
        let r = f.check().unwrap();
        assert_eq!(r.index.id, "server");
        assert_eq!(r.index.version, v("20261105.1"));
        assert_eq!(r.root_hash, ROOT);
        // gpgv got the key set's keyring, absolute, and a home of its own
        let log = f.log();
        let args: Vec<&str> = log.split_whitespace().collect();
        assert_eq!(args[0], "--homedir");
        assert_ne!(args[1], f.tmp.path().to_str().unwrap());
        assert_eq!(
            &args[2..4],
            &["--keyring", keyring(&f.keys).to_str().unwrap()]
        );
        assert!(args[4].ends_with("SHA256SUMS.gpg") && args[5].ends_with("SHA256SUMS"));
    }

    #[test]
    fn an_image_id_may_hold_underscores_and_dots() {
        let f = fixture();
        let n = names("my_os.v2_20261105.1");
        let sig = format!(r#"{{"rootHash":"{ROOT}"}}"#);
        f.index(&[
            (&n[0], b"u"),
            (&n[1], b"v"),
            (&n[2], sig.as_bytes()),
            (&n[3], b"k"),
        ]);
        assert_eq!(f.check().unwrap().index.id, "my_os.v2");
    }

    #[test]
    fn a_changed_file_fails_its_digest() {
        let f = fixture();
        let n = names("server_20261105.1");
        fs::write(f.dir.join(&n[3]), "another uki").unwrap();
        let e = f.check().unwrap_err();
        assert!(e.0.starts_with(&format!("{}: its digest is", n[3])), "{e}");
    }

    #[test]
    fn lines_in_another_order_are_refused() {
        let f = fixture();
        let n = names("server_20261105.1");
        let sig = format!(r#"{{"rootHash":"{ROOT}"}}"#);
        f.index(&[
            (&n[1], b"verity"),
            (&n[0], b"usr"),
            (&n[2], sig.as_bytes()),
            (&n[3], b"uki"),
        ]);
        let e = f.check().unwrap_err();
        assert!(e.0.contains("line 1"), "{e}");
    }

    #[test]
    fn the_index_must_have_exactly_four_lines() {
        let f = fixture();
        let text = fs::read_to_string(f.dir.join("SHA256SUMS")).unwrap();
        let three: String = text.lines().take(3).flat_map(|l| [l, "\n"]).collect();
        fs::write(f.dir.join("SHA256SUMS"), three).unwrap();
        assert!(f.check().unwrap_err().0.contains("has 3 lines"));
        fs::write(f.dir.join("SHA256SUMS"), format!("{text}{text}")).unwrap();
        assert!(f.check().unwrap_err().0.contains("has 8 lines"));
        fs::write(f.dir.join("SHA256SUMS"), text.trim_end()).unwrap();
        assert!(f.check().is_err(), "no final newline");
    }

    #[test]
    fn names_must_share_one_id_and_version() {
        let f = fixture();
        let mut n = names("server_20261105.1");
        n[0] = names("server_20261105.2")[0].clone();
        let sig = format!(r#"{{"rootHash":"{ROOT}"}}"#);
        f.index(&[
            (&n[0], b"usr"),
            (&n[1], b"verity"),
            (&n[2], sig.as_bytes()),
            (&n[3], b"uki"),
        ]);
        let e = f.check().unwrap_err();
        assert!(
            e.0.contains("is not server_20261105.1.usr.<uuid>.raw"),
            "{e}"
        );
    }

    #[test]
    fn a_bad_version_in_the_names_is_refused() {
        let f = fixture();
        let n = names("server_20250229.1");
        let sig = format!(r#"{{"rootHash":"{ROOT}"}}"#);
        f.index(&[
            (&n[0], b"u"),
            (&n[1], b"v"),
            (&n[2], sig.as_bytes()),
            (&n[3], b"k"),
        ]);
        assert!(f.check().unwrap_err().0.contains("not a real date"));
    }

    #[test]
    fn the_uuids_must_come_from_the_signed_root_hash() {
        let f = fixture();
        let n = names("server_20261105.1");
        let other = format!(r#"{{"rootHash":"{}"}}"#, "f".repeat(64));
        f.index(&[
            (&n[0], b"usr"),
            (&n[1], b"verity"),
            (&n[2], other.as_bytes()),
            (&n[3], b"uki"),
        ]);
        let e = f.check().unwrap_err();
        assert!(e.0.contains("first 128 bits"), "{e}");
    }

    #[test]
    fn a_signature_by_another_key_is_refused() {
        let f = fixture();
        fs::write(f.dir.join("SHA256SUMS.gpg"), "forged").unwrap();
        let e = f.check().unwrap_err();
        assert!(e.0.contains("not a signature by the release key"), "{e}");
        assert!(e.0.contains("BAD signature"), "{e}");
    }

    #[test]
    fn no_signature_or_no_key_is_refused() {
        let f = fixture();
        fs::remove_file(f.keys.join("release/index.pgp")).unwrap();
        assert!(f.check().unwrap_err().0.contains("no release key"));
        let f = fixture();
        fs::remove_file(f.dir.join("SHA256SUMS.gpg")).unwrap();
        assert!(f.check().unwrap_err().0.contains("no signature"));
        assert_eq!(f.log(), "", "gpgv must not run without a signature");
    }

    /// gpg in a home of its own, which it must not leave an agent behind in
    fn gpg(home: &Path, args: &[&str]) {
        let out = Command::new("gpg")
            .env("GNUPGHOME", home)
            .args(["--batch", "--pinentry-mode", "loopback", "--passphrase", ""])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "gpg {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    /// An Ed25519 signing key as make-keys makes one; its binary public half at `pgp`.
    fn release_key(home: &Path, pgp: &Path) {
        fs::create_dir_all(home).unwrap();
        fs::set_permissions(home, fs::Permissions::from_mode(0o700)).unwrap();
        gpg(
            home,
            &["--quick-gen-key", "release", "ed25519", "sign", "never"],
        );
        gpg(
            home,
            &["--yes", "--export", "--output", pgp.to_str().unwrap()],
        );
    }

    #[test]
    fn a_real_signature_by_the_release_key_passes_and_by_another_key_fails() {
        let f = fixture();
        let (home, other) = (f.tmp.path().join("gpg"), f.tmp.path().join("other"));
        release_key(&home, &keyring(&f.keys));
        release_key(&other, &f.tmp.path().join("other.pgp"));
        let (index, sig) = (f.dir.join("SHA256SUMS"), f.dir.join("SHA256SUMS.gpg"));
        let sign = |home: &Path| {
            gpg(
                home,
                &[
                    "--yes",
                    "--detach-sign",
                    "--output",
                    sig.to_str().unwrap(),
                    index.to_str().unwrap(),
                ],
            );
        };
        let gpgv = Program::from_env("GOLCONDA_GPGV", "gpgv");
        sign(&home);
        let r = check(&f.dir, &keyring(&f.keys), &gpgv).unwrap();
        assert_eq!(r.index.version, v("20261105.1"));
        // one byte more in the index than the signature covers
        let text = fs::read_to_string(&index).unwrap();
        fs::write(&index, text.replacen("  ", "   ", 1)).unwrap();
        assert!(check(&f.dir, &keyring(&f.keys), &gpgv).is_err());
        fs::write(&index, &text).unwrap();
        sign(&other);
        let e = check(&f.dir, &keyring(&f.keys), &gpgv).unwrap_err();
        assert!(e.0.contains("not a signature by the release key"), "{e}");
        for h in [&home, &other] {
            let _ = Command::new("gpgconf")
                .env("GNUPGHOME", h)
                .args(["--kill", "gpg-agent"])
                .status();
        }
    }
}
