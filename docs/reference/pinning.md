# Pinning Golconda in your repository

Your repository holds `server.toml`, and `modules/` and `packages/` if you have them
([Configuration](config.md)). It also pins one commit of Golconda. This page gives the contract
between the two, then three ways to pin: uptrack (recommended), a flake, and a plain `fetchTarball`.
All three give the same tree, so they give the same image.

## The contract

`import <a Golconda tree>` gives the outputs in the flake schema: `lib`, `packages`, `schema`,
`templates` and the rest ([Outputs](outputs.md)). A Golconda tree is a checkout or an unpacked
tarball of one commit. The flake output is the same set: `flake.nix` is
`outputs = _: import ./default.nix;`.

| function                                        | gives                                                                                                                 |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `lib.mkSystem { config; system; … }`            | the composed system: `usrTree`, `config`, `sbom`, … ([The entry point](config.md#the-entry-point))                    |
| `lib.mkImage { config; publicKeys; system; … }` | the unsigned chain and its signer: `unsigned`, `usrTree`, `initrd`, `signer` ([`lib.mkImage`](outputs.md#libmkimage)) |
| `lib.readPins ./pins`                           | `{ <name> = the unpacked tree; }` for a directory of pins in uptrack's format                                         |

Two arguments matter for every recipe:

- **`system`**: always pass it (`"x86_64-linux"`). Left out, it is `builtins.currentSystem`. A flake
  and `iets eval` evaluate purely and refuse that.
- **`publicKeys`**: the key set's public halves. `lib.mkImage` copies `secureboot/db.crt`,
  `pcr/pcr.pub` and `release/index.pgp` into the store and nothing else; the private keys never
  reach Nix ([`lib.mkImage`](outputs.md#libmkimage)). A flake evaluates purely and reads no absolute
  path outside the store, so commit the three public files and name them as a path (`./keys`).

Golconda's own inputs (repkgs, adios and the rest) come with the tree: `pins/` fetches each one by
its hash. You do not pin them. No recipe needs nixpkgs.

## First: the Nix that builds it

Every Golconda output is a content-addressed derivation, and repkgs' fetchers are dynamic
derivations. A stock Nix daemon cannot build them. The build host needs the Nix fork that repkgs
names, with `ca-derivations` and `dynamic-derivations` in the daemon's `nix.conf`
([Build host](build-host.md)). A client that evaluates (`nix-build`, `nix build`) needs the same
`experimental-features` line; iets has them built in. The recipes below only choose which Golconda
tree you build. They change nothing on the build host.

## uptrack (recommended)

uptrack is the tool Golconda pins its own inputs and packages with. Your pin is one more
`sources.toml` in the same format. Copy three files from Golconda's `examples/`:

```text
my-servers/
├── server.toml                  # examples/server.toml
├── golconda.nix                 # examples/golconda.nix
└── pins/golconda/sources.toml   # examples/pins/golconda/sources.toml
```

The pin follows the branch `main` of the GitHub mirror:

```toml
[upstream]
purl = "pkg:github/slophaer/golconda?branch=main"

[[source]]
key = "default"
url = "https://github.com/slophaer/golconda/archive/{rev}.tar.gz"
hash = "sha256-…"

[pin]
version = "0-unstable-2026-11-09"
date = "2026-11-09"
rev = "b58a62f7e0d71403981d320d426c4ee37ce6339c"
```

`golconda.nix` reads it with about ten lines of `fromTOML` and `fetchTarball`: the url with `{rev}`
filled from `[pin]`, and the hash. Then it calls `lib.mkSystem`:

```sh
iets eval -E '(import ./golconda.nix { }).usrTree.outPath'
nix-build golconda.nix -A usrTree
```

To update, run uptrack on `pins/`. The same Golconda builds uptrack for you:

```sh
nix-build golconda.nix -A pkgs.uptrack -o uptrack
UPTRACK_ROOT=pins uptrack/bin/uptrack check    # exits 10 when Golconda moved
UPTRACK_ROOT=pins uptrack/bin/uptrack apply    # writes the new rev, date, version and hash
```

Release tags *(planned)*: Golconda has no release yet. After the first release (v0.1), remove
`?branch=main` from the purl and put `{tag}` or `{version}` in the url. uptrack then follows
versions. Today, without the branch, uptrack reports "datasource returned no versions".

### Your other inputs

Put them beside Golconda in `pins/`, one directory each, in the same format. `uptrack init` writes a
new one. `golconda.lib.readPins ./pins` reads them all, Golconda included:

```nix
let
  golconda = import (fetchPin ./pins/golconda/sources.toml); # as in golconda.nix
  inputs = golconda.lib.readPins ./pins; # { golconda = …; <name> = the unpacked tree; }
in
…
```

`lib.readPins` is the reader Golconda uses for its own `pins/` (`lib/pins.nix`).

## A flake

`templates.default` is a repository with `server.toml` and a `flake.nix` that takes Golconda as its
one input:

```sh
nix flake init -t github:slophaer/golconda
nix build                       # the /usr tree of server.toml
nix flake update golconda       # move to Golconda's newest commit
```

A run on 2026-11-10 locked the template's input at `ee07323` and built its `image` output (the
`/usr` tree and the chain, signed in the build with the `keys` argument of that commit, which is now
gone) on this host's Nix fork. `nix flake update golconda` then moved the lock to `2393f72`, the
newest `main`, and the flake evaluated again. `tests/flake-template/run.sh` repeats the lock and the
update without the build ([How this is tested](#how-this-is-tested)). The `image` output is now the
unsigned output, and `golconda release build` signs it outside Nix ([Making a release](release.md)).

The client needs `flakes` beside the features above. The template passes `system` and has a
commented `lib.mkImage` call with `publicKeys` as a path. After the first release, pin a tag:
`github:slophaer/golconda/v0.1` *(planned)*.

## Plain `fetchTarball`

No tool and no lock file: the commit and its hash are in the Nix file.

It is the uptrack template's `fetchTarball` without the TOML file. The snippet is
`examples/fetch-tarball.nix`, included here as it is; a test evaluates that file
([How this is tested](#how-this-is-tested)).

```nix
{{#include ../../examples/fetch-tarball.nix}}
```

To update, put in the new rev and print its hash:

```sh
nix-prefetch-url --unpack https://github.com/slophaer/golconda/archive/<rev>.tar.gz
```

## Which one

| recipe         | needs                                               | updating                                      | provenance in your repository                            | evaluation cost                                                  |
| -------------- | --------------------------------------------------- | --------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------- |
| uptrack        | uptrack (Golconda builds it), the template's reader | `uptrack check`, `uptrack apply`              | `sources.toml`: purl, branch or version, rev, date, hash | one tarball, fetched once by its hash                            |
| flake          | `flakes` on the client                              | `nix flake update golconda`                   | `flake.lock`: rev, `narHash`, `lastModified`             | one tarball, and a store copy of your repository when it changed |
| `fetchTarball` | nothing                                             | by hand: new rev, `nix-prefetch-url --unpack` | the url and hash in the Nix file                         | one tarball, fetched once by its hash                            |

## How this is tested

- `tests/real-packages/packages.nix` (`checks.real-packages`) evaluates `examples/golconda.nix` with
  this tree in place of the pin; `tests/eval/config.nix` reads `examples/pins/` with `lib/pins.nix`.
  `checks.uptrack-sources` lists `examples/pins/` with uptrack.
- `tests/real-packages/pins.nix` checks `lib.readPins` against `pins/default.nix`.
  `tests/eval/pins.nix` checks the reader on `tests/fixtures/pins`, and calls the flake template's
  outputs on this tree with the stand-in packages.
- `tests/real-packages/pins.nix` also evaluates `examples/fetch-tarball.nix`, the file this page
  includes for the plain `fetchTarball` recipe, with the example pin's rev and hash in place of the
  two placeholders. Its `usrTree` is the one `examples/golconda.nix` gives from the same pin.
- `tests/flake-template/run.sh` (run by `scripts/lint`) makes a flake with `nix flake init -t` from
  this repository's template, locks the input at `HEAD~1`, runs `nix flake update golconda`, and
  checks that the lock is at `HEAD` with a new `narHash` and that the flake evaluates its `/usr`
  tree. With `--build` it also builds the image's unsigned output from the flake, with the public
  halves of a test key set (`tests/fixtures/public-keys`), and checks that the output holds the
  manifest and the signer and no private key. That build is not in the lint: it takes the time of an
  image build.
- By hand, 2026-11-10 (`~/spikes/pinning-proofs`): the uptrack template in an empty directory
  evaluated `usrTree` from the pin (iets and `nix-instantiate`), and `uptrack check` and `apply`
  moved a copy of the pin to `b58a62f`. No image was built from either. `nix flake init -t` gave a
  flake with the input at the example pin's `ee07323` on the GitHub mirror (the lock held `ee07323`,
  with the pin's `narHash`), and `nix build .#image` built the image, signed in the build with the
  `keys` argument of that commit (task #534, 4 min with the toolchain in the store).
  `nix flake update golconda` moved the lock to `2393f72`.
