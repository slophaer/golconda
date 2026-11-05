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

A document turns a module on by naming it: a table `["/services/sshd"]`, empty for the defaults,
puts the sshd component in the system; a service with no table is off. The built-in components
(`/base`, `/network`, `/security`, `/factory`, `/vars`) are in every system. There is no `enable`
flag, and no other route in: a downstream repository adds a module, never a bare fragment. Its
`modules/` directory beside the document is mounted under `/local`, so `/local/motd` is a component
like `/services/sshd`, with typed options, a schema entry and a table that selects it. The optional
`[golconda]` table names another directory (`modules = "site"`). `/usr/lib/golconda/modules.json`
therefore lists every module in the image, with why, and the build's own named fragments
(`/image/hwdb`) ([Modules](modules.md#which-modules-a-system-has)).

The entry point that applies this rule is `lib/system.nix`: `mkSystem ./server.toml` (or
`mkSystem { config; platform?; }`) takes the document, binds the package set of the platform,
selects the components, composes, and returns the composed system and its `/usr` tree derivation.
`examples/golconda.nix` is the template a user copies next to `server.toml` (the analogue of a NixOS
`system.nix`). The document is the whole configuration, with no Nix hook beside it: a package option
takes a package name (`package = "openssh"`), looked up in the target set, and a downstream
repository brings its own modules in `modules/` and its own packages in `packages/` (the same layout
as Golconda's: a `package.nix` and a `sources.toml` per package), so they get purls, the SBOM and
update tracking. A downstream package may replace a Golconda or repkgs package only when
`[golconda] replaces` lists the name: a replacement reaches the kernel, the boot chain and the
signing tools, so it is a stated choice, never a name collision
([Trust](trust.md#downstream-packages)). `modules.json` records it. Nix stays where it is code: in a
module and in a package. The interface is in
[reference/config](../reference/config.md#the-entry-point).

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

| file               | content                                                                                     |
| ------------------ | ------------------------------------------------------------------------------------------- |
| `config.json`      | the resolved options of every included component, after type-checking, derivations as names |
| `modules.json`     | every module's role and inputs; for a component, whether it is included and why             |
| `schema.json`      | the JSON Schema the image was built against                                                 |
| `sbom.json`        | CycloneDX SBOM: purl and cpe per component, its origin, pedigree for a replacement          |
| `packages.json`    | every package with its version, store path and the fragments that brought it                |
| `attribution.json` | each file, link, unit, sysusers and tmpfiles line → the module or fragment that emitted it  |
| `vars.d/*.json`    | one manifest per var: class, files, credential ids                                          |

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
