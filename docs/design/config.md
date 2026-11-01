# Configuration as data

A machine is described by one TOML document. The document sets options of modules; a JSON Schema
exported from the module tree validates it without Nix; the image carries the resolved document
beside the schema so two images can be diffed as data. The diff tool is *(planned)*.

## The model

```toml
["/system"]
name = "server"
version = "20261031.1"

["/services/sshd"]
port = 22
trustedUserCAKeys = ["ssh-ed25519 AAAA... user-ca"]
["/services/sshd".principals]
root = ["alice@example.com"]
```

Each table is an adios module path and sets that module's options; a table name that is not a module
path throws with the valid list. The format is in [reference/config](../reference/config.md). Nix
stays necessary for a custom module, an out-of-tree package or logic; the document covers the common
path, and nothing in it can name a derivation or a function.

## From document to image

A document turns a module on by naming it: a table `["/services/sshd"]` means the sshd fragment is
in `/system.fragments`; a service with no table is off. `/base`, `/network` and `/security` are on
in every image, and `/factory` and `/vars` are added once to every system. So there is no `enable`
flag at either level: in Nix a service is on when its fragment is listed, in TOML when its table
exists.

The entry point that applies this rule is `lib/system.nix`:
`mkSystem { config; platform?; extra?; }` takes the document (a path, or options already loaded),
binds the package set of the platform, lists the fragments, composes, and returns the composed
system and its `/usr` tree derivation. `golconda.nix` at the repository root is the template a user
copies next to `server.toml` (the analogue of a NixOS `system.nix`). `extra` is the one Nix hook: an
attribute set merged into the options, for a package override or a fragment that needs a derivation,
so a configuration is pure TOML or TOML plus Nix. A fragment of plain data (units, files, sysusers
and tmpfiles lines) needs no Nix: `/system.fragments` takes it in the TOML as an array of tables.
The interface is in [reference/config](../reference/config.md#the-entry-point).

## The schema

`lib/schema.nix` exports JSON Schema 2020-12 from the module tree
(`iets eval --json -E '(import ./default.nix).schema'`). Each module path is an object whose
properties are its options, with the type, default and description from the module. Option types
come from the korora type name (`string`, `int`, `bool`, `listOf`, `attrsOf`, `union`); Golconda's
own types (fragment, app, service, sandbox, word, …) are in a registry (`lib/schema/registry-*.nix`)
and export their schema directly; a struct or enum korora does not expose is `x-golconda-opaque`
with its name. The reference pages under `docs/reference/modules/generated/` are generated from the
same schema and the modules' doc comments, so the docs cannot drift from the options.

**Upstream ask.** korora's struct type does not expose `members` and its enum type does not expose
`elems`, so the generator cannot walk them. Two one-line additions to `types/types.nix` in the adios
pin would fix it: `mkStruct' { } // { inherit members; }` in `struct`, and
`self.typedef' name (...) // { elems = elems; }` in `enum`. Until then those types are opaque.

## Image artifacts

Every image carries `/usr/lib/golconda/`:

| file            | content                                                                                       |
| --------------- | --------------------------------------------------------------------------------------------- |
| `config.json`   | the resolved options by module path, after type-checking, derivations replaced by their names |
| `schema.json`   | the JSON Schema the image was built against                                                   |
| `sbom.json`     | CycloneDX SBOM from the closure's `sources.toml` purls                                        |
| `packages.json` | every package with its version, store path and the fragments that brought it                  |
| `vars.d/*.json` | one manifest per var: class, files, credential ids                                            |

The sysupdate transfers from `/system.updateSource` are beside them in `/usr/lib/sysupdate.d/`.
There is no `etc.manifest`: `/etc` is symlinks into the factory and `find /etc -type f` lists the
administrator's changes ([Layout: State](layout.md#state)).

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
