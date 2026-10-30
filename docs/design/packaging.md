# Packaging

Packages are repkgs packages: a `package.nix` naming a build system and a `sources.toml` naming the
upstream. Golconda adds its own under `packages/` and sets a few set-wide features; it has no
builder of its own.

## Why repkgs

Golconda pins a fork of repkgs (branch `golconda` at `code.in.a.flawed.cloud/yolobox/repkgs`) with
relocation fixes: PT_INTERP via libc with relative sysroot links, and glibc `$ORIGIN` expansion from
`AT_EXECFN` instead of `/proc`. See [`patches/repkgs/README.md`](../../patches/repkgs/README.md) for
the patches and their issue drafts.

- Outputs are relocatable, so the store can live in `/usr` and no machine needs Nix.
- One LLVM toolchain; cross-compilation is an argument, which the platform record supplies.
- Evaluation is cheap and typed, so iets lints the whole set on every change.
- Debug info is split by build-id into `debug` outputs where `systemd-coredump` looks.

## The platform

The platform is repkgs' record (`nix/platforms.nix` in repkgs), which `nix/packages.nix` returns
next to `pkgs`. It holds `cpu`, `os`, `name` (`x86_64-linux`), `march` and `names`, one spelling per
consumer: `names.kernel` (the kernel `ARCH`), `names.systemd` (`systemd-repart --architecture`, the
partition type names) and `names.uefi` (`BOOTX64.EFI`; null where there is no UEFI port). Golconda
keeps no table of its own; a new spelling goes into repkgs. Only `systems` in `default.nix` lists
what Golconda builds.

## Set-wide features

`nix/packages.nix` fixes `tls = "openssl"` for every package that declares the feature. A new
one-of-each decision is a feature value there, and a package that cannot honour it is not packaged.

## System packages

systemd, kmod, dbus-broker and the kernel address `/usr/lib/...` by absolute path. They are built
with `prefix=/usr` as the compiled-in location and reached through the symlink farm; everything else
is relocatable and lives only in the store.
