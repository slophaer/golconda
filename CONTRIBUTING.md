# Contributing

## Repository map

| directory   | what it holds                                                                                                                                                                                                                    |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `modules/`  | the adios modules, one directory per path (`/base`, `/services/sshd`, …); `modules/lib/`: the shared types, grammar and renderers that `lib/` uses too                                                                           |
| `lib/`      | the build functions: `mkSystem` (`system.nix`), the `/usr` tree, the image chain (`lib/image/`), the schema, the TOML loader, the component selection (`components.nix`), the docs generator, the one module walker (`tree.nix`) |
| `image/`    | image parameters as data (partitions, sysupdate transfers, the UKI cmdline); `lib/image/` builds from them, file for file                                                                                                        |
| `nix/`      | the outputs (`default.nix`), the repkgs set (`packages.nix`), checks, the dev shell                                                                                                                                              |
| `packages/` | Golconda's package specs; a name here replaces the repkgs fork's                                                                                                                                                                 |
| `tests/`    | `eval/`: the pure-Nix tests by area (`nix/tests.nix` imports them); `packages/`: package tests; `usr-tree/`; `kernel/`: the kernel's kbuild phases on a stub tree; `errors/`: configuration error messages; fixtures             |
| `scripts/`  | developer tools: `lint`, `docs`, `make-keys`, `provision-esp`, `boot-test`                                                                                                                                                       |
| `cli/`      | the `golconda` command line (`vars`, `release`): one Rust crate, `packages.<system>.golconda-cli`; its README is for developers                                                                                                  |
| `examples/` | example configurations                                                                                                                                                                                                           |
| `docs/`     | `design/` says why, `reference/` says what exists                                                                                                                                                                                |

Start with [Walkthrough](docs/reference/walkthrough.md): it follows one `server.toml` through these
directories to a booted machine.

## Commits and branches

1. Use kernel commit style: `area: summary` (lower case, imperative, 50 characters or fewer, no
   period), a blank line, then a body that explains what and why, wrapped at 72 columns. Sign off
   with `git commit -s`.
1. One commit per feature. Each commit must leave the tree evaluating and the lint passing.
1. Work on a feature branch in a git worktree
   (`git worktree add ../golconda-<branch> -b <branch> origin/main`). Do not commit to `main`; merge
   fast-forward after review.

## Conventions

- **One of each.** No second implementation of anything the image already has (see
  [design/principles](docs/design/principles.md)). A new package or option that duplicates an
  existing one needs a reason in the commit body.
- **No nixpkgs** outside `nix/dev/` (developer tooling); `checks.boundary` fails otherwise. Packages
  come from the repkgs fork; Golconda-specific ones live in `packages/`.
- **Typed, explicit modules.** A module returns a fragment; shared types live in `modules/lib/`.
  Duplicates are errors, never overrides. Credentials are references, never file contents.
- **Module doc comments.** Every module's Nix file starts with `#! ` lines (hash-bang-space) that
  document what the module does, in two to five lines of Markdown. These mirror Rust's `//!` module
  docs. The test `module-docs: every module file has a #! doc comment` enforces this.
- **Type descriptions.** Every type in the registry (`lib/schema/registry-*.nix`) must have a
  `description` field. The test `module-docs: every registry type has a description` enforces this.
- **No typed store paths.** A `/nix/store` string in `modules/` or `lib/` is a relocation bug (the
  image's store is `/usr/nix/store`); paths come from derivations. `scripts/lint` fails on one; mark
  a legitimate mention `store-path-ok`.
- **Lint rules.** `lints/` holds ast-grep rules for Rust (from iets), nu and Nix (from repkgs), each
  with cases in `lints/tests/` (`checks.lint-rules`); treefmt runs them. A rule that is wrong for a
  line is fixed in the rule, not silenced at the line. An optional list or set is `on cond value`
  (`modules/lib/on.nix`), not `if … else [ ]`. The clippy levels of `cli/` are pedantic
  (`cli/Cargo.toml`, `checks.cli-clippy`).
- **Docs split.** `docs/design/` says why, `docs/reference/` says what exists in code today. Mark
  what is designed and not started as *(planned)*, and what is deferred past v1 as *(after v1)*. No
  planning or history pages.
- **Pins.** `pins/<name>/sources.toml`, one per input, in uptrack's format; `pins/default.nix` reads
  them. `scripts/pins check` shows what moved, `scripts/pins apply repkgs` moves the repkgs pin (see
  [The repkgs fork](#the-repkgs-fork)).
- **Fork patches.** A change to repkgs' build system goes to the fork (see
  [The repkgs fork](#the-repkgs-fork)). A new package goes to `packages/` instead.

## The repkgs fork

Golconda pins a fork of [Mic92/repkgs](https://github.com/Mic92/repkgs): the branch and URL are in
`pins/repkgs/sources.toml` (`?branch=`, today `golconda`). That branch is upstream `main` plus
commits meant for upstream, one per topic, and nothing else; each commit message is the text we
would send upstream. List them with `git log --oneline origin/main..fork/golconda` in a repkgs
clone. The packages the image needs are not in the fork: they are in `packages/`.

To change the fork, commit to its `golconda` branch, in the topic the change belongs to, and push it
to the forge and to its public GitHub mirror, `slophaer/repkgs`. The pin follows the mirror: its
archive is byte for byte the forge's, and it needs no sign-in, neither for Nix nor for iets. Then
move the pin and run the full check:

```console
$ scripts/pins check repkgs
$ scripts/pins apply repkgs
$ scripts/verify
```

`apply` writes the commit (`rev`), its date as the version (`0-unstable-<date>`) and the hash of the
unpacked tree. uptrack itself comes from the repkgs tree pinned before, so the new fork takes effect
for it on the next run.

## Getting started

```sh
nix-shell                                   # or: direnv allow
nix fmt                                     # treefmt: format and lint (lints/, nu --ide-check, shellcheck too)
scripts/tool NAME ARGS...                   # run one of our packages' programs (scripts/tools.sh), e.g. hcloud
./scripts/lint                              # strict iets lint, module tests, sandboxed and native package checks
scripts/docs                                # generate the module pages, then build the book
scripts/docs serve                          # the same, then mdbook serve (pages are not committed)
nix-build -A checks.x86_64-linux.docs       # the book in the sandbox (generates the pages itself)
iets eval --expr 'import ./nix/tests.nix { }'   # the module tests alone

# Boot test (needs KVM, cannot run in the sandbox)
nix-build -A packages.x86_64-linux.image-smoke-test
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test --timeout 120

# All of it for one commit: lint, image, boot; stops at the first failure (clean tree)
scripts/verify                              # --each-commit origin/main for every commit of a branch
```

The required checks include the native tests in `tests/packages/`, also available as
`packages.<system>.tests-<name>`. They do not build foreign-target tests or every package output. A
cold run can build these packages; a cached run reuses their results.

The dev shell carries iets, uptrack, treefmt (the formatter output, `nix fmt`, which also scans with
the rules in `lints/`), `golconda-ast-grep` (those rules; `checks.lint-rules` tests them), and
mdbook and its diagram preprocessor for `scripts/docs`. `./scripts/lint` now builds native package
tests and needs the same patched Nix client and daemon as package builds. The daemon needs
`ca-derivations`, `dynamic-derivations` and the system feature `builder-rpc-v0`;
[reference/build-host](docs/reference/build-host.md) says how to get one. Start reading at
[README](README.md), then [docs/SUMMARY](docs/SUMMARY.md); the module code is small enough to read
whole, starting with `modules/system/default.nix` and `modules/lib/`.
