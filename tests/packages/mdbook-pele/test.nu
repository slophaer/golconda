# mdbook-pele as mdbook runs it: `supports html` succeeds, and a chapter with a mermaid block
# comes back with an inline SVG instead.
use checks.nu *
let pre = $"($env.pkg)/bin/mdbook-pele"
assert "it supports the html renderer" ((^$pre supports html | complete).exit_code == 0)
let chapter = {Chapter: {name: "c", content: "# C\n\n```mermaid\nflowchart LR\n  a --> b\n```\n", number: null, sub_items: [], path: "c.md", source_path: "c.md", parent_names: []}}
let book = {items: [$chapter], __non_exhaustive: null}
let ctx = {root: "/tmp", config: {book: {}}, renderer: "html", mdbook_version: "0.5.4"}
let out = ([$ctx $book] | to json | ^$pre | complete)
assert $"it renders: ($out.stderr)" ($out.exit_code == 0)
let content = ($out.stdout | from json | get items.0.Chapter.content)
assert "the mermaid block became an SVG" (($content | str contains "<svg") and not ($content | str contains "```mermaid"))
done
