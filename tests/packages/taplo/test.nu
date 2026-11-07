# taplo as treefmt runs it (`taplo format`): it formats a file in place, and --check passes the
# result and fails the original.
use checks.nu *
let taplo = $"($env.pkg)/bin/taplo"
let t = $"($env.TMPDIR? | default /tmp)/taplo-test"
rm -rf $t
mkdir $t
"[pin]\nversion=\"1\"\ntag   =   \"v1\"\n" | save $"($t)/a.toml"
assert "--check fails an unformatted file" ((^$taplo format --check $"($t)/a.toml" | complete).exit_code != 0)
^$taplo format $"($t)/a.toml"
assert "format writes the canonical form" ((open --raw $"($t)/a.toml") == "[pin]\nversion = \"1\"\ntag = \"v1\"\n")
assert "--check passes it" ((^$taplo format --check $"($t)/a.toml" | complete).exit_code == 0)
rm -rf $t
done
