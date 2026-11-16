# CycloneDX 1.5 fixtures

`checks.sbom-schema` (nix/checks.nix) validates the test image's SBOM with python's jsonschema
(`tests/sbom-schema/validate.py`) against the JSON schema of CycloneDX 1.5. The schema is the
`schema/` directory of `pins/cyclonedx` (branch `1.5` of
<https://github.com/CycloneDX/specification>, Apache-2.0): `bom-1.5.schema.json` and the two schemas
it refers to, registered by their `$id`, so nothing is fetched in the check. `scripts/pins` updates
the pin. CycloneDX 1.6 would be a new schema and a new check, not an update.

`valid-patch.json` is a small SBOM with one patch that must pass. Each `invalid-*.json` differs from
it, or lacks a field, in one way and must be refused, so that a validator which accepts everything
fails the check:

- `invalid-patch-type.json`: a patch of type `bogus` (CycloneDX knows `unofficial`, `monkey`,
  `backport`, `cherry-pick`).
- `invalid-no-bom-format.json`: no `bomFormat`.

The schema does not constrain `specVersion` (any string passes), so the check does not claim to
catch a wrong one.
