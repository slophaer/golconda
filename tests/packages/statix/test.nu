# statix as treefmt runs it (`statix check FILE`): a file with a lint fails, a clean one passes.
use checks.nu *
let statix = $"($env.pkg)/bin/statix"
let t = $"($env.TMPDIR? | default /tmp)/statix-test"
rm -rf $t
mkdir $t
# manual_inherit: `a = a;` is `inherit a;`
"let a = 1; in { a = a; }\n" | save $"($t)/lint.nix"
"let a = 1; in { inherit a; }\n" | save $"($t)/clean.nix"
let bad = (^$statix check $"($t)/lint.nix" | complete)
assert $"a lint fails the check: ($bad.stdout)($bad.stderr)" ($bad.exit_code != 0 and (($bad.stdout + $bad.stderr) | str contains "Assignment instead of inherit"))
assert "a clean file passes" ((^$statix check $"($t)/clean.nix" | complete).exit_code == 0)
rm -rf $t
done
