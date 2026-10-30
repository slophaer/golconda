# Packaging

Packages are repkgs packages: a `package.nix` naming a build system and a `sources.toml` naming the
upstream. Golconda adds its own under `packages/` and sets a few set-wide features; it has no
builder of its own.

## Why repkgs

- Outputs are relocatable, so the store can live in `/usr` and no machine needs Nix.
- One LLVM toolchain; cross-compilation is an argument, which the platform record supplies.
- Evaluation is cheap and typed, so iets lints the whole set on every change.
- Debug info is split by build-id into `debug` outputs where `systemd-coredump` looks.

## The platform

`nix/system.nix` turns a Nix double into one record with every spelling in use: repkgs' cpu/os,
systemd's architecture name, the UEFI suffix, the kernel `ARCH`. Nothing else spells a platform.

## Set-wide features

`nix/packages.nix` fixes `tls = "openssl"` for every package that declares the feature. A new
one-of-each decision is a feature value there, and a package that cannot honour it is not packaged.

## System packages

systemd, kmod, dbus-broker and the kernel address `/usr/lib/...` by absolute path. They are built
with `prefix=/usr` as the compiled-in location and reached through the symlink farm; everything else
is relocatable and lives only in the store.
