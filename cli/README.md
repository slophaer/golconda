# cli

The `golconda` command line, for the people who deploy and release Golconda machines. One Rust crate
(package `golconda`, binary `golconda`), built with repkgs' toolchain like every Golconda package
(`cli/package.nix`, `packages.<system>.golconda-cli`). It runs on an operator's or build host, not
on a machine, and is not part of an image.

How to use it is in [docs/reference/cli.md](../docs/reference/cli.md). This file is for developers.

## The two commands

- `golconda vars set|push|list|pub|enrol` (`src/vars.rs`): admin vars from the deploy host. It keeps
  each value age-encrypted in the configuration repository (`vars/<host>/<var>/<file>.age`), reads
  the machine's manifests over ssh, and pushes the values; the machine seals them. `enrol` signs the
  machine's host key with `ssh-keygen` and pushes the certificate and the KRL through `push`. See
  [Trust: Secrets and vars](../docs/design/trust.md#secrets-and-vars).
- `golconda release check|publish|build|list` (`src/release.rs`): release directories. It checks the
  index and its signature, publishes with rclone, and builds a release from a clean git tree with
  `nix-build`, committing the version line. See [Releases](../docs/design/releases.md) and
  [Making a release](../docs/reference/release.md).

`src/main.rs` holds the argument parsing (clap) and the output of both.

## Programs and environment

The crate has no library for age, ssh, ssh-keygen, git, gpgv, nix-build or rclone: it runs them.
Each is found on `PATH`, or named by a variable, with arguments split at spaces
(`GOLCONDA_SSH="ssh -p 2222"`):

| variable                | program or value                                 |
| ----------------------- | ------------------------------------------------ |
| `GOLCONDA_AGE`          | `age` (or `rage`)                                |
| `GOLCONDA_SSH`          | `ssh`                                            |
| `GOLCONDA_SSH_KEYGEN`   | `ssh-keygen` (`vars enrol`)                      |
| `GOLCONDA_AGE_IDENTITY` | the identity file for `vars push` (same as `-i`) |
| `GOLCONDA_NIX_BUILD`    | `nix-build`                                      |
| `GOLCONDA_GIT`          | `git`                                            |
| `GOLCONDA_GPGV`         | `gpgv`                                           |
| `GOLCONDA_RCLONE`       | `rclone`                                         |

Variables that start with `GOLCONDA_TEST_` belong to the tests: `GOLCONDA_TEST_PKCS11_MODULE` names
SoftHSM's `libsofthsm2.so`, for the test that signs with a CA key on a token.

## Build and test

```sh
nix-build -A packages.x86_64-linux.golconda-cli      # builds and runs the tests; result/bin/golconda
nix-build -A checks.x86_64-linux.cli-clippy          # clippy at the levels in Cargo.toml, warnings fail
```

cargo, rustc and the C linker come from repkgs, so both need a build host for repkgs
([Build host](../docs/reference/build-host.md)). The tests run git, gpg, rclone, ssh-keygen and
SoftHSM on scratch repositories and directories, so the package build lists them as build
dependencies (`cli/package.nix`). To run them by hand, put those programs on `PATH` and run
`cargo test` in this directory.

`treefmt` (`nix fmt`) formats the Rust code and runs the ast-grep rules in `lints/rust/`.
