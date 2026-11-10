# CycloneDX 1.5 schema

The JSON schema of CycloneDX 1.5, vendored so that `checks.sbom-schema` (nix/checks.nix) runs
offline. It validates the test image's SBOM with python's jsonschema
(`tests/sbom-schema/validate.py`); the two schemas that `bom-1.5.schema.json` refers to are
registered by their `$id`, so nothing is fetched.

- Source: <https://github.com/CycloneDX/specification>, branch `1.5` (commit
  `c320fc0f0b46873864927d9d5684eea7ba439728`, 2026-11-10), directory `schema/`.
- Files: `bom-1.5.schema.json`, `spdx.schema.json`, `jsf-0.82.schema.json`, unchanged.
- License: Apache-2.0, `LICENSE` is the specification's.

To update, copy the three files from the same directory of a newer commit of the `1.5` branch and
change the commit above. CycloneDX 1.6 would be a new schema and a new check, not an update.

## Fixtures

`valid-patch.json` is a small SBOM with one patch that must pass. Each `invalid-*.json` differs from
it, or lacks a field, in one way and must be refused, so that a validator which accepts everything
fails the check:

- `invalid-patch-type.json`: a patch of type `bogus` (CycloneDX knows `unofficial`, `monkey`,
  `backport`, `cherry-pick`).
- `invalid-no-bom-format.json`: no `bomFormat`.

The schema does not constrain `specVersion` (any string passes), so the check does not claim to
catch a wrong one.
