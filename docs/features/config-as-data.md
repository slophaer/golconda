# Configuration as data

One TOML document describes a machine. A JSON Schema checks it without Nix, and the image carries
the resolved options beside the schema, so you can read what a machine runs without rebuilding it. A
misspelt option is an error that names it, not a silent default.

## How it works

- **One document.** Each table name is a module path, and the table sets that module's options. A
  document cannot name a derivation or a function.

- **The check is by name.** An unknown table throws and lists the valid paths. An unknown option
  throws and lists the valid names. So `prot = 2222` is an error, not a silent port 22.

- **The schema comes from the modules.** `lib/schema.nix` exports JSON Schema 2020-12 from the
  module tree: type, default and description for each option. The reference pages are generated from
  the same schema and the modules' doc comments.

- **The image keeps the result.** `mkSystem` writes these files, and the `/usr` builder adds the
  rest, all in `/usr/lib/golconda/`:

  | file               | content                                                                                   |
  | ------------------ | ----------------------------------------------------------------------------------------- |
  | `config.json`      | the options of every included module; for each, the value and whether the document set it |
  | `schema.json`      | the schema the image was built against, with the file that declares each option           |
  | `modules.json`     | each module's role and inputs; whether it is included and why; downstream packages        |
  | `attribution.json` | each file, link, unit and line, with the module that emitted it                           |
  | `packages.json`    | each package with its version, store path and the modules that brought it                 |
  | `sbom.json`        | CycloneDX 1.5 bill of materials: `purl`, `cpe`, origin, `pedigree` (replacement, patches) |
  | `vars.d/*.json`    | one manifest per var ([Secrets as vars](vars.md))                                         |

- **The SBOM uses standard identifiers.** Each component has a `purl` (package URL) and, where
  declared, a `cpe` (a vulnerability-database name). `golconda:origin` says `downstream`, `golconda`
  or `repkgs`. A replaced package names its ancestor in `pedigree`, and a patched package lists each
  patch, with its text and the reason from its header, in `pedigree.patches`.

## Using it

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

Export the schema and check the document with any validator:

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
yj -tj < examples/server.toml > config.json
ajv validate -s schema.json -d config.json
```

`iets eval --json -E '(import ./default.nix).configLib.validPaths'` lists the valid table names.

## Status

The artifacts are built and checked by eval tests (`tests/real-packages/sbom.nix`,
`tests/eval/schema.nix` and others). The boot-test images carry them. No boot marker reads these
files. See [What is proven](../proven.md).

## Limits

- **Diffing is *(after v1)*.** `golconda diff <a> <b>` would compare two `config.json` files. It
  does not exist. The console's `golconda diff` of a document against git was removed with the
  console ([Configuration: Diffing](../design/config.md#diffing-after-v1)).
- Nix stays necessary for a module of your own and a package that is not in the set
  ([Your own modules and packages](extending.md)).
- korora hides the members of structs and enums, so the schema marks those types
  `x-golconda-opaque`.
- Golconda ships no validator. The schema is for editors and external tools.
- The SBOM lists the runtime closure only. It does not list unused packages, and it matches package
  identities, not display names.

## More

- [Design: Configuration as data](../design/config.md)
- [Reference: configuration format](../reference/config.md#document-format) and
  [validation](../reference/config.md#validation)
- [Reference: `/usr` tree](../reference/image.md#usr-tree-libusr-treenix) and
  [software bill of materials](../reference/image.md#software-bill-of-materials)
- [Typed modules](typed-modules.md)
