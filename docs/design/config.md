# Configuration as data

Configuration is a TOML document validated by a JSON Schema exported from the adios module tree. The
image carries artifacts that make diffing and auditing possible without Nix. *(Image artifacts,
diffing, SBOM and the entrypoint are planned.)*

## The model

A TOML document (like `config.toml`) holds the machine's configuration. A pure Nix function exports
JSON Schema 2020-12 from the adios module tree. The document is validated against the schema before
evaluation. This gives editors, linters and GUIs a typed surface without loading Nix.

Nix stays necessary for custom modules, out-of-tree packages, and complex logic. The TOML surface
covers the common path.

## What exists

### JSON Schema export

`lib/schema.nix` exports JSON Schema 2020-12 from the module tree:

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
```

The schema maps each module path (`/services/sshd`, `/system`) to an object with properties for its
options. Option types are derived from the korora type name:

| korora        | JSON Schema                                       |
| ------------- | ------------------------------------------------- |
| `string`      | `{"type": "string"}`                              |
| `int`         | `{"type": "integer"}`                             |
| `bool`        | `{"type": "boolean"}`                             |
| `derivation`  | `{"type": "string", "x-golconda": "package"}`     |
| `listOf T`    | `{"type": "array", "items": ...}`                 |
| `attrsOf T`   | `{"type": "object", "additionalProperties": ...}` |
| `union [A B]` | `{"anyOf": [...]}`                                |
| struct/enum   | `{"x-golconda-opaque": "<name>"}` (see below)     |

Golconda's own types (fragment, app, service, sandbox, word, etc.) are in the registry in
`lib/schema.nix` and export their schema directly.

**Korora limitation.** Struct types do not expose `members` and enum types do not expose `elems`.
The generator cannot walk them without parsing the type name (fragile). A two-line upstream change
would fix this; see the [Upstream asks](#upstream-asks) section and
[config-schema.md](https://code.in.a.flawed.cloud/yolobox/golconda/-/blob/main/docs/design/config-schema.md)
in the knowledge base.

### TOML configuration loader

`lib/config.nix` loads a TOML document into adios options:

```toml
# examples/server.toml
["/system"]
name = "server"
version = "2026.10.0"

["/services/sshd"]
port = 22
authorizedKeys = ["ssh-ed25519 AAAA... admin@example.com"]
```

Table names are adios absolute paths (starting with `/`). Unknown paths throw with the list of valid
module paths.

```nix
let
  f = import ./default.nix;
  cfg = f.configLib.loadConfig ./config.toml;
in
f.modules cfg
```

## Image artifacts *(planned)*

Every image carries `/usr/lib/golconda/`:

| file           | content                                                |
| -------------- | ------------------------------------------------------ |
| `config.json`  | the resolved options, with an `explicit` flag per path |
| `schema.json`  | JSON Schema 2020-12 exported from the module tree      |
| `sbom.json`    | CycloneDX SBOM from the closure's `sources.toml` purls |
| `etc.manifest` | type, mode, owner, sha256 for each factory file        |

## Diffing *(planned)*

`golconda diff <a> <b>` compares two images by their `config.json`. Output is a path-based
set/delete list:

```json
[
  {"op": "set", "path": "/services/sshd/port", "value": 2222},
  {"op": "delete", "path": "/services/nginx"}
]
```

This doubles as the edit log and the patch format.

## Entrypoint *(planned)*

`golconda.nix` is the NixOS `system.nix` analogue: a function that takes a config and returns the
image derivation. Today the module tree is `modules/`; the entrypoint and image builder are not
implemented.

## Upstream asks

korora (`types/types.nix` in the adios pin) needs two one-line changes to expose struct members and
enum elements:

```nix
# In the struct function, after the mkStruct' definition:
mkStruct' { } // { inherit members; }

# In the enum function:
self.typedef' name (...) // { elems = elems; }
```

These let the schema generator walk struct and enum types without parsing type names. The change is
backward-compatible; existing code does not read these attributes.
