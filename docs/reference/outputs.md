# Outputs and inputs

`default.nix` is the entry point for both classic Nix and iets; `flake.nix` calls it. The output
schema is the flake one, produced by flake-incompat.

## Outputs

| attribute                                                           | per system  | content                                                                                                                                                         |
| ------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `packages.<system>.nix`                                             | yes         | repkgs' own Nix package, built by repkgs; not the first daemon ([Build host](build-host.md#the-first-daemon-a-chicken-and-egg))                                 |
| `packages.<system>.golconda-cli`                                    | yes         | the `golconda` command line from `cli/` (`vars`, `release`), built by repkgs ([Commands](cli.md#the-golconda-tool))                                             |
| `packages.<system>.{systemd,mtools,util-linux,cpython}`             | yes         | the tools `scripts/provision-esp` runs on the build host (`scripts/tools.sh`), from repkgs and `packages/`                                                      |
| `packages.x86_64-linux.kernel`                                      | x86_64 only | the Linux kernel from `packages/kernel/`, including the Golconda policy fragment                                                                                |
| `packages.<system>.tests-<name>`                                    | yes         | the test of package `<name>` in `tests/packages/<name>/test.nu` (uutils-coreutils, btrfs-progs)                                                                 |
| `packages.x86_64-linux.usr-tree-smoke`                              | x86_64 only | smoke test for the `/usr` tree builder: the base system plus jq                                                                                                 |
| `packages.x86_64-linux.usr-tree-base-smoke`                         | x86_64 only | the `/usr` tree of a system with no table: the built-in components alone                                                                                        |
| `packages.x86_64-linux.image-smoke`                                 | x86_64 only | the image chain over `examples/server.toml`, with `proof.txt` ([Image artifacts](image.md))                                                                     |
| `packages.x86_64-linux.image-smoke-{unsigned,initrd,signer,signed}` | x86_64 only | the parts: the unsigned outputs, the initrd, the signer, and the release signed with throwaway keys                                                             |
| `packages.x86_64-linux.image-smoke-test`                            | x86_64 only | the boot test image, version `20261031.1`: `image-smoke` with the test SSH key and an update source (`scripts/boot-test`)                                       |
| `packages.x86_64-linux.image-smoke-test-nosb`                       | x86_64 only | the test image for a host without Secure Boot (`/system.secureBoot = false`): its kernel carries the throwaway `db` certificate                                 |
| `packages.x86_64-linux.image-smoke-test-nosb-next`                  | x86_64 only | its next release, `20261031.2`                                                                                                                                  |
| `packages.x86_64-linux.image-smoke-test-next`                       | x86_64 only | its next release, `20261031.2`, with the same throwaway keys: what `scripts/boot-test --next` installs                                                          |
| `packages.x86_64-linux.image-smoke-test-rotated`                    | x86_64 only | the same next release signed with a second throwaway `db` key: `scripts/boot-test --next <it> --rotate`                                                         |
| `checks.<system>`                                                   | yes         | `treefmt`, `docs`, `module-docs`, `usr-tree-test`, `boundary`, `etc-systemd-links`, `schema`, `lint-rules`, `cli-clippy`, `image-signer` (the sandboxed checks) |
| `formatter.<system>`                                                | yes         | treefmt (`nix fmt`) with its formatters and the lint rules in `lints/`, built by repkgs                                                                         |
| `devShells.<system>.default`                                        | yes         | mdbook, iets, uptrack                                                                                                                                           |
| `modules`                                                           | no          | the adios tree; `modules { options = {...}; }` evaluates it                                                                                                     |
| `docs-pages`, `docs-summary`                                        | no          | the generated reference pages, and the module lines `docs/SUMMARY.md` must carry                                                                                |
| `docs-modules`, `docs-module-paths`                                 | no          | the same pages by module path, and the module paths discovered in `modules/`                                                                                    |
| `schema`                                                            | no          | JSON Schema 2020-12 of the module tree (see below)                                                                                                              |
| `configLib`                                                         | no          | TOML configuration loader (see below)                                                                                                                           |
| `platforms`                                                         | no          | the platforms table (repkgs `nix/platforms.nix`)                                                                                                                |
| `lib.mkSystem`                                                      | no          | the entry point: a TOML document → the composed system and its `/usr` tree ([Configuration](config.md#the-entry-point))                                         |
| `lib.mkImage`                                                       | no          | a TOML document and a key set's public halves → the unsigned image chain and its signer ([`lib.mkImage`](#libmkimage))                                          |
| `lib.readPins`                                                      | no          | a directory of pins in uptrack's format → `{ <name> = the unpacked tree; }`, the reader of `pins/` ([Pinning](pinning.md#your-other-inputs))                    |

OS outputs require the local x86_64 kernel. Golconda exposes no aarch64 images or cross-compiled OS
trees until the kernel supports that architecture ([Scope](../design/scope.md)). Package tests, Nix
and developer tools still have per-system outputs.

## Inputs

Pinned in `pins/<name>/sources.toml` (uptrack's format, `scripts/pins`), read by `pins/default.nix`
with `lib/pins.nix`, the reader `lib.readPins` exports:

- `repkgs`: the package set (Golconda's fork, branch `golconda`, the one the pin follows)
- `adios`: the module system (korora types vendored inside)
- `flake-incompat`: the output schema
- `iets`: the evaluator and linter

## `lib.mkImage`

```nix
let
  image = (import ./default.nix).lib.mkImage {
    config = ./server.toml;                   # what lib.mkSystem takes
    publicKeys = "/srv/golconda-keys";        # the key set: only its public halves are read
    # pcrPublicKeys = "/srv/golconda-old";    # pcr/pcr.pub from another set; default: publicKeys
    # indexPublicKeys = "/srv/golconda-old";  # release/index.pgp from another set; default: publicKeys
    # system = "x86_64-linux";                # the build host; default: builtins.currentSystem
  };
in
image.unsigned
```

Nothing it builds is signed, and no private key is read
([Trust: Signing outside Nix](../design/trust.md#signing-outside-nix)). It returns:

- `unsigned`: `manifest.json`, which names the `/usr` tree, the initrd, the kernel, systemd's stub
  and unsigned systemd-boot and every parameter of the signer's steps; `keys/`, copies of the public
  halves; and `sign`, the signer of this image's package set
  (`sign UNSIGNED --keys DIR [--pcr-keys DIR] [--index-keys DIR] --out DIR`);
- `usrTree` (without the signed loader, which the signer adds), `initrd`, `signer`, `pkgs`,
  `imageId` and `version`;
- `signWithTestKeys { keys; pcrKeys ? keys; indexKeys ? keys; }`: the release signed in the store by
  the same signer, for throwaway keys only (the test images use it with `throwawayKeys`). The keys
  it gets enter the store: never give it a deployment's keys.

`publicKeys` is a path or an absolute string. From it the chain copies three files into the store,
each alone: `secureboot/db.crt`, `pcr/pcr.pub` and `release/index.pgp`; a directory that also holds
the private keys gives nothing else. A relative string is an error, and so are the old arguments
`keys`, `pcrKeys` and `indexKeys`. A flake evaluates purely and reads no absolute path outside the
store: give it the three public files committed in the repository, as a path.
`golconda release build` builds `unsigned` and runs its `sign`; the procedure, from making the key
set to enrolling the certificate, is in [Making a release](release.md).

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
  `mkSystem` runs it over an attribute-set `config`.
- `optionError path table`: the check's message for one table, or `null`.
- `validPaths`: list of all module paths that accept options; `/pkgs` is not one (its `target` is
  not data, and `mkSystem` binds it to the platform's set).
