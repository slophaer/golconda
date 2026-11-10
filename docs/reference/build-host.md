# Build host

A build host is the machine whose Nix daemon builds Golconda's packages and images. The servers run
no Nix. This page says what that daemon needs and how iets reaches it. Each fact names its source: a
file in this repo, or a file in the repkgs or iets pin (`pins/`). Anything no test in this repo has
shown is marked **unverified**.

## Why the daemon needs more than stock settings

Every output Golconda builds is a content-addressed derivation (`__contentAddressed = true`): every
repkgs package (repkgs `nix/package.nix`), the `/usr` tree (`lib/usr-tree.nix`) and every image step
(`lib/image/common.nix`). Classic Nix cannot even instantiate them without `ca-derivations`
(`nix/tests.nix`: "repkgs needs ca-derivations to instantiate"). repkgs' lock-file fetchers (cargo,
Go, npm and the rest) are dynamic derivations: a producer writes a `.drv` at build time, and the
caller takes `builtins.outputOf` it. The producers require the system feature `builder-rpc-v0` and
need `dynamic-derivations ca-derivations` on the daemon (repkgs `nix/fetch.nix`).

## `nix.conf`

The daemon's own `nix.conf` (by default `/etc/nix/nix.conf`) needs these two lines. They are the
ones the repkgs README gives:

```ini
experimental-features = nix-command ca-derivations dynamic-derivations recursive-nix
system-features = builder-rpc-v0 big-parallel kvm nixos-test benchmark
```

- `ca-derivations` and `dynamic-derivations`: needed, see above.
- `builder-rpc-v0`: needed by the fetch producers. No other derivation in this repo or in the pinned
  repkgs names a system feature: a grep for `requiredSystemFeatures` finds only that one. The kernel
  (`packages/kernel` and its local `kbuild.nu`) asks for none.
- `recursive-nix`, `big-parallel`, `kvm`, `nixos-test`, `benchmark`: the README lists them, and
  nothing here requires them. repkgs `docs/design.md` says the producers use no recursive Nix.
  Keeping them costs nothing; whether a build fails without them is **unverified**.
- `system-features` replaces Nix's default list, so keep every name a builder needs on it.

The settings must sit in the daemon's file. iets's own commands (`iets build`, `eval`, `eval-jobs`)
send the daemon no settings at all (iets `docs/reference/settings.md`), so a client `--option` does
not turn them on.

A classic `nix-build` evaluates on the client, so the client's `nix.conf` needs the same
`experimental-features` line. iets's own commands have every feature built in.

## The first daemon: a chicken-and-egg

`packages.<system>.nix` is not the daemon to start with. It is repkgs' own `nix` package, stock Nix
2.35.2 with a relocation patch (repkgs `pkgs/ni/nix`), and repkgs builds it. So building it already
needs a daemon with the features above.

The first daemon comes from outside the set. repkgs `nix/nix/default.nix` builds Nix master from
branch `repkgs` of `github.com/Mic92/nix-1`, with nixpkgs and not with repkgs, so any stock Nix can
build it. The repkgs README says the daemon needs Nix master with
[NixOS/nix#16459](https://github.com/NixOS/nix/pull/16459) (dynamic derivations rebuild after a
garbage collection) and recommends #16465 and #16477 (CA rebuilds); that branch carries them.

From a clone of this repo, with any Nix:

```sh
nix-build -E 'import "${(import ./pins).repkgs}/nix/nix" { }' -o nix-repkgs
```

This expression evaluates to `nix-2.36pre20260912_203f85b2`. Building it and running it as the
host's daemon is **unverified** in this repo. On NixOS the repkgs README sets it as the system Nix:

```nix
nix.package = import "${repkgs}/nix/nix" { inherit pkgs; };
nix.settings = {
  experimental-features = [ "nix-command" "ca-derivations" "dynamic-derivations" "recursive-nix" ];
  system-features = [ "builder-rpc-v0" "big-parallel" "kvm" "nixos-test" "benchmark" ];
};
```

On another distribution, run this build's `nix-daemon` in place of the one the distribution starts,
with the `nix.conf` above. The repo has no recipe for that; it is **unverified**.

Whether `packages.<system>.nix` (2.35.2) can later replace that daemon is **unverified**: nothing
here says whether it carries #16459.

There is no binary cache for the fork ([Comparison](../design/comparison.md)). The first build
fetches the repkgs seed and builds the whole toolchain from it (repkgs README); after that, builds
are incremental.

## How iets reaches the daemon

iets has no store of its own. It evaluates in memory, sends the daemon the derivations and sources
the daemon lacks, and asks it to build (iets `docs/how-to/build-remotely.md`). It picks the daemon
in this order:

1. `--builder URL` on the command line: `daemon` (this machine's
   `/nix/var/nix/daemon-socket/socket`), `unix:///path`, `ssh-ng://[user@]host` or
   `grpc://host:port`.
1. `builder` in your own `~/.config/iets/iets.toml`, or in `$IETS_CONFIG`.
1. `store` from `nix.conf`. Its default, `auto`, is the local daemon.

The repo's `iets.toml` cannot choose a builder: a project file may hold only the `[lint]` table, and
iets refuses any other key (iets `docs/reference/settings.md`). iets refuses a daemon older than
worker protocol 1.35.

`scripts/lint` and the commands in [Commands](cli.md) use the default, so they build on the local
daemon. To build on another host, set `builder` in your user file or pass `--builder`:

```sh
iets build --builder ssh-ng://buildhost -A packages.x86_64-linux.image-smoke ./default.nix
```

With `ssh-ng://`, iets runs `ssh host nix-daemon --stdio`, so the `nix-daemon` on that host's `PATH`
must be the one described above.

## Keys in the sandbox

`lib.mkImage` reads the deployment's private keys during the build
([Trust: How the private keys reach the build](../design/trust.md#how-the-private-keys-reach-the-build)).
Given as a path value, the keys are copied into the store and need nothing here. Given as a string,
they stay where they are, and the daemon must show them to the sandbox:

```ini
extra-sandbox-paths = /srv/golconda-keys
```

The build users (`nixbld*`) must be able to read the files. This setting belongs in the daemon's
`nix.conf` too: iets does not send it, and a daemon takes it from a client only if the client is a
trusted user. An image built this way is *(being built)*: no test builds one.

repkgs' compile cache uses the same mechanism: when `/nix/var/nix/jigd/socket` is in
`extra-sandbox-paths`, jig asks jigd before it compiles (repkgs `docs/design.md`). It is optional
and does not change any output.

## Keeping rebuilds down

Several people or agents often build on one host at once. These habits keep them from rebuilding the
same things:

- **One repkgs pin.** Build every branch against the pin on `main`. Repin once, on `main`, and
  rebase the other branches onto it. A branch on another pin rebuilds the whole package set, the
  toolchain included.
- **Builder changes small first.** Every repkgs package depends on the whole `builder/` folder, so a
  builder change rebuilds the toolchain. Try it on the matching `tests/builder` case, then on one
  package, and build the whole set once at the end.
- **Room for the compile cache.** jigd keeps `JIGD_SIZE` GiB of objects (default 50) and reads it
  only at start. When it is full it evicts the objects other builds still need; the shared build
  host gives it 200.

The maintainers' notes on build caching, with what triggers rebuilds and the ideas not yet done, are
outside this repository, in the knowledge base on the build host:
`~/kb/projects/golconda/build-caching.md`.

## Store paths

The build host keeps the standard store, `/nix/store`. Do not move it: the store directory is an
input of every store path hash (iets `docs/reference/settings.md`, `NIX_STORE_DIR`), so another
directory gives other paths.

The image holds the closure at `/usr/nix/store/<hash>-<name>`, the same names as on the build host
(`lib/usr-tree.nix` copies it). Every output is relocatable: it refers to other store paths only
relative to itself, so nothing in the image names `/nix/store`. Seen from a build host, the `/usr`
tree is a chroot store `--store /usr`; the machine itself has no `/nix` and no daemon
([Layout](../design/layout.md#usr)).
