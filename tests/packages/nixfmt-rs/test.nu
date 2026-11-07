# nixfmt-rs as treefmt runs it: --check passes a formatted file and fails an unformatted one, and
# formatting turns the second into the first.
use checks.nu *
let nixfmt = $"($env.pkg)/bin/nixfmt"
let t = $"($env.TMPDIR? | default /tmp)/nixfmt-test"
rm -rf $t
mkdir $t
"{ a = 1; b = [\n  1\n  2\n]; }\n" | save $"($t)/bad.nix"
"{\n  a = 1;\n  b = [\n    1\n    2\n  ];\n}\n" | save $"($t)/good.nix"
assert "a formatted file passes --check" ((^$nixfmt --check $"($t)/good.nix" | complete).exit_code == 0)
assert "an unformatted one fails it" ((^$nixfmt --check $"($t)/bad.nix" | complete).exit_code != 0)
^$nixfmt $"($t)/bad.nix"
assert "formatting gives the formatted file" ((open --raw $"($t)/bad.nix") == (open --raw $"($t)/good.nix"))
rm -rf $t
done
