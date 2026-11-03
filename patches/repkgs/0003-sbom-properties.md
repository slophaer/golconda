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

Tests cover roots, transitive packages, implicit libc, existing approximation properties and records
without source metadata. They compare the default BOM with the baseline and compare the built JSON
with the evaluated document.

Fork commit: `02b32e5daf039a9aa28d7fc9afac659ef4095002`
(`sbom: allow callers to add component properties`). It follows the current fork tip without
rewriting the published series. Fold it into the SBOM series when preparing that series for
upstream.
