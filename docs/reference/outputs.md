# Outputs and inputs

`default.nix` is the entry point for both classic Nix and iets; `flake.nix` calls it. The output
schema is the flake one, produced by flake-incompat.

## Outputs

| attribute                                                             | per system  | content                                                                                                                         |
| --------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `packages.<system>.nix`                                               | yes         | repkgs' own Nix package, built by repkgs; not the first daemon ([Build host](build-host.md#the-first-daemon-a-chicken-and-egg)) |
| `packages.<system>.kernel`                                            | yes         | the Linux kernel: the fork's bootable base plus `packages/kernel/golconda.config`                                               |
| `packages.<system>.usr-tree-smoke`                                    | yes         | smoke test for the `/usr` tree builder: the base system plus jq                                                                 |
| `packages.<system>.usr-tree-base-smoke`                               | yes         | the `/usr` tree of a system with no fragments: `/base`, `/network` and `/security` alone                                        |
| `packages.x86_64-linux.usr-tree-smoke-aarch64`                        | x86_64 only | cross-compiled `/usr` tree for aarch64                                                                                          |
| `packages.<system>.image-smoke`                                       | yes         | the image chain over `examples/server.toml`, with `proof.txt` ([Image artifacts](image.md))                                     |
| `packages.<system>.image-smoke-{erofs,verity,initrd,uki,loader,disk}` | yes         | one step of the chain each                                                                                                      |
| `packages.<system>.image-smoke-test`                                  | yes         | the boot test image, version `20261031.1`: `image-smoke` with the test SSH key and an update source (`scripts/boot-test`)       |
| `packages.<system>.image-smoke-test-next`                             | yes         | its next release, `20261031.2`, with the same throwaway keys: what `scripts/boot-test --next` installs                          |
| `packages.<system>.image-smoke-test-rotated`                          | yes         | the same next release signed with a second throwaway `db` key: `scripts/boot-test --next <it> --rotate`                         |
| `checks.<system>`                                                     | yes         | `treefmt`, `docs`, `module-docs`, `usr-tree-test`, `boundary`, `etc-systemd-links`, `schema` (the sandboxed checks)             |
| `formatter.<system>`                                                  | yes         | treefmt with pinned tools                                                                                                       |
| `devShells.<system>.default`                                          | yes         | treefmt, mdbook, iets, npins                                                                                                    |
| `modules`                                                             | no          | the adios tree; `modules { options = {...}; }` evaluates it                                                                     |
| `docs-pages`, `docs-summary`                                          | no          | the generated reference pages and `SUMMARY.md` (`scripts/docs` writes them)                                                     |
| `docs-modules`, `docs-module-paths`                                   | no          | the same pages by module path, and the module paths discovered in `modules/`                                                    |
| `schema`                                                              | no          | JSON Schema 2020-12 of the module tree (see below)                                                                              |
| `configLib`                                                           | no          | TOML configuration loader (see below)                                                                                           |
| `platforms`                                                           | no          | the platforms table (repkgs `nix/platforms.nix`)                                                                                |
| `lib.mkSystem`                                                        | no          | the entry point: a TOML document → the composed system and its `/usr` tree ([Configuration](config.md#the-entry-point))         |
| `lib.mkImage`                                                         | no          | a TOML document and a key directory → the signed image chain ([`lib.mkImage`](#libmkimage))                                     |

## Inputs

Pinned in `npins/sources.json`, read by `nix/sources.nix`:

- `repkgs`: the package set (Golconda's fork, branch `reloc-boot`, the one the pin follows)
- `adios`: the module system (korora types vendored inside)
- `flake-incompat`: the output schema
- `iets`: the evaluator and linter
- `pele`: the diagram renderer for the docs build
- `nixpkgs-dev-only`: developer tooling, used nowhere else

## `lib.mkImage`

```nix
let
  image = (import ./default.nix).lib.mkImage {
    config = ./server.toml;          # what lib.mkSystem takes
    keys = "/srv/golconda-keys";      # the key directory, below
    # pcrKeys = "/srv/golconda-pcr";  # pcr/ from another directory; default: keys
    # system = "x86_64-linux";        # the build host; default: builtins.currentSystem
  };
in
image.disk
```

It returns `erofs`, `verity`, `initrd`, `uki`, `loader`, `disk` and `release` (the string
`"${disk}/release"`, the directory sysupdate fetches). The steps are those of the smoke outputs
([Image artifacts](image.md)). The chain reads four files under `keys`: `secureboot/db.key`,
`secureboot/db.crt`, `pcr/pcr.key` and `pcr/pcr.pub`. A relative string is an error. A path value
copies the keys into the store; a string does not, and needs `extra-sandbox-paths` on the daemon
([Trust: How the private keys reach the build](../design/trust.md#how-the-private-keys-reach-the-build)).

## `schema`

JSON Schema 2020-12 export of the module tree. The schema does not depend on any packages; it is not
per-system.

```sh
iets eval --json -E '(import ./default.nix).schema' > schema.json
```

The schema has a property for each module path (`/services/sshd`, `/system`). Each property is an
object describing that module's options with their types, descriptions and defaults. Use any JSON
Schema validator (ajv, jsonschema, etc.) to validate a TOML config after converting it to JSON.

Golconda does not ship a validator in the image yet.

## `configLib`

TOML configuration loader: a document in, checked options out. It applies nothing;
[`lib.mkSystem`](config.md#the-entry-point) is the one entry point that does. Exports
`{ loadConfig; loadConfigText; checkOptions; optionError; validPaths; }`.

```nix
let
  f = import ./default.nix;
in
(f.configLib.loadConfig ./examples/server.toml).options."/services/sshd".port
```

- `loadConfig path`, `loadConfigText text`: parse the TOML and return `{ options = {...}; }`. Table
  names are absolute module paths (`/services/sshd`). An unknown path throws with the valid list, an
  undeclared option name throws with the module's valid names, and a `/pkgs` table throws.
- `checkOptions options`: the same checks over an attribute set of options; returns it unchanged.
  `mkSystem` runs it over an attribute-set `config` and `extra`.
- `optionError path table`: the check's message for one table, or `null`.
- `validPaths`: list of all module paths that accept options; `/pkgs` is not one (its `target` is
  not data, and `mkSystem` binds it to the platform's set).
