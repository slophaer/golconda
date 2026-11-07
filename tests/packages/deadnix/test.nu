# deadnix as treefmt runs it (--fail): an unused let binding fails, a used one passes.
use checks.nu *
let deadnix = $"($env.pkg)/bin/deadnix"
let t = $"($env.TMPDIR? | default /tmp)/deadnix-test"
rm -rf $t
mkdir $t
"let unused = 1; used = 2; in used\n" | save $"($t)/dead.nix"
"let used = 2; in used\n" | save $"($t)/clean.nix"
let bad = (^$deadnix --fail $"($t)/dead.nix" | complete)
assert $"an unused binding fails: ($bad.stdout)" ($bad.exit_code != 0 and ($bad.stdout | str contains "unused"))
assert "a clean file passes" ((^$deadnix --fail $"($t)/clean.nix" | complete).exit_code == 0)
rm -rf $t
done
