# treefmt as checks.treefmt runs it: a config with one formatter (a script that appends a line),
# --ci fails on a file the formatter changes and passes once it is formatted.
use checks.nu *
let treefmt = $"($env.pkg)/bin/treefmt"
let t = $"($env.TMPDIR? | default /tmp)/treefmt-test"
rm -rf $t
mkdir $t
cd $t
"#!/bin/sh\nfor f in \"$@\"; do grep -q '^formatted$' \"$f\" || echo formatted >> \"$f\"; done\n" | save fmt.sh
^chmod +x fmt.sh
$"[formatter.mark]\ncommand = \"($t)/fmt.sh\"\nincludes = [\"*.txt\"]\n" | save treefmt.toml
"text\n" | save a.txt
assert "version is the pin" ((^$treefmt --version | str trim) == "treefmt v2.6.0")
assert "--ci fails while a file changes" ((^$treefmt --ci --no-cache --tree-root . | complete).exit_code != 0)
assert "the formatter ran" ((open --raw a.txt) == "text\nformatted\n")
assert "--ci passes on a formatted tree" ((^$treefmt --ci --no-cache --tree-root . | complete).exit_code == 0)
cd /
rm -rf $t
done
