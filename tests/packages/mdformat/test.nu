# mdformat as treefmt runs it (--wrap=100), with the GFM plugin: a long paragraph wraps at 100, a
# table gets its columns padded (the plugin; plain mdformat would not know tables), and --check
# then passes.
use checks.nu *
let mdformat = $"($env.pkg)/bin/mdformat"
let t = $"($env.TMPDIR? | default /tmp)/mdformat-test"
rm -rf $t
mkdir $t
let long = (1..30 | each { "word" } | str join " ")
$"# Title\n\n($long) ($long)\n\n| a | bb |\n|---|---|\n| ccc | d |\n" | save $"($t)/a.md"
assert "--check fails before" ((^$mdformat --check --wrap=100 $"($t)/a.md" | complete).exit_code != 0)
^$mdformat --wrap=100 $"($t)/a.md"
let out = (open --raw $"($t)/a.md" | lines)
assert "no line is longer than 100" ($out | all { ($in | str length) <= 100 })
assert $"the table is padded by the GFM plugin: ($out)" ($out | any { $in == "| ccc | d   |" })
assert "--check passes after" ((^$mdformat --check --wrap=100 $"($t)/a.md" | complete).exit_code == 0)
rm -rf $t
done
