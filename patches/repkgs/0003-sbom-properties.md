# Draft: let SBOM callers add component properties

Suggested upstream request, once the SBOM generator itself goes upstream. That generator lives in
the fork's SBOM series; this hook does not stand alone.

`set.sbom` can describe package sources but cannot know a caller's provenance policy. Add an
optional `extraProperties = pkg: [ { name = "example:origin"; value = "local"; } ];` argument.
Append its entries to each component's existing properties. With the default empty hook, keep the
BOM and its output derivation unchanged. Do not emit an empty `properties` array.

The callback receives the package record, including its identity metadata. The implicit libc record
has no `drvPath`, so callers must allow records without one. The generator contains no
Golconda-specific attribution policy; Golconda supplies that policy at its call site.

Tests cover roots, transitive packages, implicit libc, wrappers, same-name variants, existing
approximation properties and records without source metadata. They check the exact dependency edges,
compare the default BOM with the baseline and compare the built JSON with the evaluated document.

Fork commit: `3053ab5a6afef4945f6abf97a612ae88be371851`
(`sbom: allow callers to add component properties`) on `upstream-prep`, after `481129b`. It follows
the branch tip without rewriting the published series. Fold it into the SBOM series when preparing
that series for upstream.
