# mdbook as checks.docs runs it: a two-page book builds to HTML with both pages and the search
# index (the `search` feature).
use checks.nu *
let mdbook = $"($env.pkg)/bin/mdbook"
let t = $"($env.TMPDIR? | default /tmp)/mdbook-test"
rm -rf $t
mkdir $"($t)/src"
"[book]\ntitle = \"test\"\n" | save $"($t)/book.toml"
"# Summary\n\n[Intro](intro.md)\n\n- [Page](page.md)\n" | save $"($t)/src/SUMMARY.md"
"# Intro\n\nhello\n" | save $"($t)/src/intro.md"
"# Page\n\nworld\n" | save $"($t)/src/page.md"
assert "version is the pin" ((^$mdbook --version | str trim) == "mdbook v0.5.4")
^$mdbook build -d $"($t)/out" $t
assert "the pages are HTML" (($"($t)/out/intro.html" | path exists) and ((open --raw $"($t)/out/page.html") | str contains "world"))
assert "the search index is built" ((glob $"($t)/out/searchindex*.js" | sort | length) > 0)
rm -rf $t
done
