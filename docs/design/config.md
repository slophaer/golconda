# Configuration as data

*(Planned.)* Configuration will be a TOML document validated by a JSON Schema, not arbitrary Nix.
The image carries artifacts that make diffing and auditing possible without Nix.

## The model

A TOML document (like `config.toml`) holds the machine's configuration. A pure Nix function exports
JSON Schema 2020-12 from the adios module tree. The document is validated against the schema before
evaluation. This gives editors, linters and GUIs a typed surface without loading Nix.

Nix stays necessary for custom modules, out-of-tree packages, and complex logic. The TOML surface
covers the common path.

## Image artifacts

Every image carries `/usr/lib/golconda/`:

| file           | content                                                |
| -------------- | ------------------------------------------------------ |
| `config.json`  | the resolved options, with an `explicit` flag per path |
| `schema.json`  | JSON Schema 2020-12 exported from the module tree      |
| `sbom.json`    | CycloneDX SBOM from the closure's `sources.toml` purls |
| `etc.manifest` | type, mode, owner, sha256 for each factory file        |

## Diffing

`golconda diff <a> <b>` compares two images by their `config.json`. Output is a path-based
set/delete list:

```json
[
  {"op": "set", "path": "/services/sshd/port", "value": 2222},
  {"op": "delete", "path": "/services/nginx"}
]
```

This doubles as the edit log and the patch format.

## Entrypoint

`golconda.nix` is the NixOS `system.nix` analogue: a function that takes a config and returns the
image derivation. Today the module tree is `modules/`; the entrypoint and image builder are not
implemented.

## Dependencies

The schema export needs korora to expose `members` on struct types and `elems` on enum types. Two
one-line changes to the upstream. Until then, the generator must parse type names (fragile) or skip
introspection (incomplete).
