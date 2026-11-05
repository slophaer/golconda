# Your own modules and packages

You extend Golconda from your own repository, beside the TOML document. Your modules and packages
follow the same layout and the same rules as Golconda's. They get types, a schema entry, an SBOM
entry and update tracking. A package that replaces one of Golconda's is a stated choice, never a
name collision.

## How it works

- **Modules.** A `modules/` directory beside the document mounts under `/local`. A module in
  `modules/motd/default.nix` is `/local/motd`. A table `["/local/motd"]` selects it, as it selects
  `/services/sshd`. The optional `[golconda] modules = "site"` names another directory.
- **Packages.** A `packages/` directory beside the document adds packages to the target set after
  Golconda's own. Each package is a directory with a `package.nix` and a `sources.toml`, the layout
  of Golconda's `packages/`. `[golconda] packages = "…"` names another directory. A package option
  takes a name, such as `package = "openssh"`.
- **Replacing is opt-in.** A downstream package that takes the name of a Golconda or repkgs package
  replaces it only when `[golconda] replaces` lists the name. Without the entry, evaluation fails
  and names the package. An entry that no package uses is also an error, so the list says exactly
  what you replace.
- **A replacement reaches everything.** It applies to the image, the initrd, the loader and the
  keyring, so a replaced kernel, systemd or signing tool is trusted code. Golconda does not check
  what it does. Whoever lists it owns the review.
- **The record.** `modules.json` has your module's role and why it is included, and under `packages`
  each downstream package: `{ "openssh": { "replaces": "golconda" } }` (`"repkgs"` for one of the
  fork's, `null` for a new name). The SBOM marks the component `golconda:origin = downstream`. A
  replacement names the package it replaced in `pedigree.ancestors`.

## Using it

```text
my-servers/
├── server.toml
├── modules/
│   └── motd/default.nix     # /local/motd
└── packages/
    └── openssh/             # package.nix, sources.toml
```

```toml
["/local/motd"]
text = "hello\n"

[golconda]
replaces = ["openssh"]
```

A module looks like the one on [Typed modules](typed-modules.md#using-it). The full example is in
[Reference: your own modules](../reference/config.md#your-own-modules).

## Status

Eval tests cover this path (`tests/eval/components.nix`, `tests/eval/provenance.nix` and
`tests/eval/sbom.nix`). The boot-test image carries one downstream module, `/local/test-workload`
(`tests/fixtures/image-workload/modules`, `nix/default.nix`); no boot test has a downstream package.
See [What is proven](../proven.md).

## Limits

- A package option names a target package. A build-host tool cannot be named.
- Golconda refuses a package that takes the name of a repkgs alias: repkgs applies aliases last, so
  the alias would win.
- Golconda reviews no replacement. A replacement can drop the IPE policy, the verity key or the boot
  checks.
- A downstream module is not in the generated module pages. Those cover Golconda's own tree.
- Nix is still the language of a module and a package. The document stays data.

## More

- [Design: Configuration as data](../design/config.md#from-document-to-image)
- [Design: Trust: Downstream packages](../design/trust.md#downstream-packages)
- [Reference: configuration](../reference/config.md#your-own-modules) and
  [your own packages](../reference/config.md#your-own-packages)
- [Configuration as data](config-as-data.md), [Typed modules](typed-modules.md)
