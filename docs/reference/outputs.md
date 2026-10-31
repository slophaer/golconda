# Outputs and inputs

`default.nix` is the entry point for both classic Nix and iets; `flake.nix` calls it. The output
schema is the flake one, produced by flake-incompat.

## Outputs

| attribute                                      | per system  | content                                                                                                                        |
| ---------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `packages.<system>.nix`                        | yes         | the patched Nix daemon repkgs needs (CA + dynamic derivations)                                                                 |
| `packages.<system>.kernel`                     | yes         | the Linux kernel: the fork's bootable base plus `packages/kernel/golconda.config`                                              |
| `packages.<system>.usr-tree-smoke`             | yes         | smoke test for the `/usr` tree builder: a minimal system with jq                                                               |
| `packages.x86_64-linux.usr-tree-smoke-aarch64` | x86_64 only | cross-compiled `/usr` tree for aarch64 (proven with jq; off until the kernel's cross build dependencies are fixed on the fork) |
| `checks.<system>`                              | yes         | `treefmt`, `docs`, `boundary`, `schema`                                                                                        |
| `formatter.<system>`                           | yes         | treefmt with pinned tools                                                                                                      |
| `devShells.<system>.default`                   | yes         | treefmt, mdbook, iets, npins                                                                                                   |
| `modules`                                      | no          | the adios tree                                                                                                                 |
| `schema`                                       | no          | JSON Schema 2020-12 of the module tree (see below)                                                                             |
| `configLib`                                    | no          | TOML configuration loader (see below)                                                                                          |
| `platforms`                                    | no          | the platforms table (repkgs `nix/platforms.nix`)                                                                               |

## Inputs

Pinned in `npins/sources.json`, read by `nix/sources.nix`:

- `repkgs`: the package set (Golconda's fork, branch `golconda`)
- `adios`: the module system (korora types vendored inside)
- `flake-incompat`: the output schema
- `iets`: the evaluator and linter
- `pele`: the diagram renderer for the docs build
- `nixpkgs-dev-only`: developer tooling, used nowhere else

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

TOML configuration loader. Exports
`{ loadConfig; loadConfigText; loadAndApply; validPaths; withPkgs; }`.

```nix
let
  f = import ./default.nix;
  cfg = f.configLib.loadConfig ./examples/server.toml;
in
f.modules cfg
```

- `loadConfig path`: parses the TOML file and returns `{ options = {...}; }` for the adios tree.
  Table names are absolute module paths (`/services/sshd`). Unknown paths throw with the valid list.
- `loadAndApply path`: calls `loadConfig` then applies the result to the module tree.
- `validPaths`: list of all module paths that accept options; `/pkgs` is not one (its `set` is not
  data, and a `/pkgs` table throws).
- `withPkgs set`: the same loader with the repkgs set bound, so its options carry `"/pkgs".set` and
  a module that needs a package evaluates: `(f.configLib.withPkgs set).loadAndApply ./server.toml`.
