# ast-grep as the lints in lints/ use it: a project config with one rule, `scan` reports a match
# as an error (non-zero exit) and passes a file without one.
use checks.nu *
let sg = $"($env.pkg)/bin/ast-grep"
let t = $"($env.TMPDIR? | default /tmp)/ast-grep-test"
rm -rf $t
mkdir $"($t)/rules"
cd $t
"ruleDirs:\n  - rules\n" | save sgconfig.yml
"id: no-unwrap\nlanguage: rust\nseverity: error\nmessage: no unwrap\nrule:\n  pattern: $X.unwrap()\n" | save rules/no-unwrap.yml
"fn main() { let x: Option<u8> = None; x.unwrap(); }\n" | save bad.rs
"fn main() { let x: Option<u8> = None; let _ = x.unwrap_or(0); }\n" | save good.rs
assert "version is the pin" ((^$sg --version | str trim) == "ast-grep 0.51.0")
let bad = (^$sg scan bad.rs | complete)
assert $"a match is an error: ($bad.stdout)" ($bad.exit_code != 0 and ($bad.stdout | str contains "no-unwrap"))
assert "a file without one passes" ((^$sg scan good.rs | complete).exit_code == 0)
cd /
rm -rf $t
done
