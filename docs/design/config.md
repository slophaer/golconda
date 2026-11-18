# Configuration as data

A machine is described by one TOML document. The document sets options of modules; a JSON Schema
exported from the module tree validates it without Nix; the image carries the resolved document
beside the schema. A tool that compares two images by their configuration is *(later)*
([Scope](scope.md#later)).

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
stays necessary for a custom module, an out-of-tree package or logic. The document covers the common
path, and it cannot name a derivation or a function.

## From document to image

A document turns a module on by naming it. A table `["/services/sshd"]`, empty for the defaults,
puts the sshd component in the system. A service with no table is off. The built-in components
([Modules](modules.md#which-modules-a-system-has)) are in every system. The document has no `enable`
flag and no other route in: a downstream repository adds a module, never a bare fragment. The
`modules/` directory beside the document is mounted under `/local`. So `/local/motd` is a component
like `/services/sshd`, with typed options, a schema entry and a table that selects it. The optional
`[golconda]` table names another directory (`modules = "site"`). `mkSystem`'s `inventory` therefore
lists every module in the image, with why, and its `fragments` the build's own named fragments
(`/image/loader`, `/image/index`) ([Modules](modules.md#which-modules-a-system-has)).

`lib/system.nix` is the entry point that applies this rule. `mkSystem ./server.toml` (or
`mkSystem { config; platform?; }`) takes the document, binds the package set of the platform,
selects the components, composes, and returns the composed system and its `/usr` tree derivation.
`examples/golconda.nix` is the template a user copies next to `server.toml` (the analogue of a NixOS
`system.nix`). The document is the whole configuration, with no Nix hook beside it. A downstream
repository brings its own modules in `modules/` and its own packages in `packages/` (the same layout
as Golconda's: a `package.nix` and a `sources.toml` per package). So they get purls, the SBOM and
update tracking. A downstream package may replace a Golconda or repkgs package only when
`[golconda] replaces` lists the name. A replacement reaches the kernel, the boot chain and the
signing tools, so it is a stated choice and never a name collision
([Trust](trust.md#downstream-packages)). The SBOM records it. Nix stays where it is code: in a
module and in a package. The interface is in
[reference/config](../reference/config.md#the-entry-point).

## The schema

`lib/schema.nix` exports JSON Schema 2020-12 from the module tree
(`iets eval --json -E '(import ./default.nix).schema'`). Each module path is an object whose
properties are its options, with the type, default and description from the module. Option types
come from the korora type name (`string`, `int`, `bool`, `listOf`, `attrsOf`, `union`). Golconda's
own types (fragment, app, service, sandbox, word, …) are in a registry (`lib/schema/registry-*.nix`)
and export their schema directly. A struct or enum that korora does not expose is
`x-golconda-opaque` with its name. The reference pages under `docs/reference/modules/generated/` are
generated from the same schema and the modules' doc comments, so the docs cannot drift from the
options.

**Upstream ask.** korora's struct type does not expose `members` and its enum type does not expose
`elems`, so the generator cannot walk them. Two one-line additions to `types/types.nix` in the adios
pin would fix it: `mkStruct' { } // { inherit members; }` in `struct`, and
`self.typedef' name (...) // { elems = elems; }` in `enum`. Until then those types are opaque.

## Image artifacts

Every image carries its configuration, its schema, its SBOM and its package list in
`/usr/lib/golconda/`. [Configuration as data](../features/config-as-data.md#how-it-works) lists the
files, and [Image: `/usr` tree](../reference/image.md#usr-tree-libusr-treenix) has their fields.

The sysupdate transfers from `/system.updateSource` are beside them in `/usr/lib/sysupdate.d/`.
There is no `etc.manifest`: `/etc` is symlinks into the factory and `find /etc -type f` lists the
operator's changes ([Layout: State](layout.md#state)).
