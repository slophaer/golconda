# Packaging

Packages are repkgs packages: a `package.nix` naming a build system and a `sources.toml` naming the
upstream. Golconda adds its own under `packages/` and sets a few set-wide features. The kernel uses
package-local phases; repkgs supplies the shared build machinery.

## Where a package lives

- **In `packages/`**: every package the image needs that upstream repkgs lacks (systemd,
  dbus-broker, openssh, cryptsetup and the rest). They go into the set through its `packages`
  argument, so another package finds them by name. A package's own test goes in
  `tests/packages/<name>/test.nu` and builds as `packages.<system>.tests-<name>`.
- **In the fork**: changes to the shared build system (relocation, `wrap`, `prefix`) and to the
  toolchain packages (glibc, crt-interp, jig). The fork also keeps the packages its own tests need:
  automake and libtool for the aclocal test. The general build tools bc and elfutils also stay
  there. The kernel recipe, kbuild module and policy belong to Golconda.

The fork's branch is meant to hold only what upstream should take. A package goes upstream from
`packages/` when it is general.

## Why repkgs

Golconda pins a fork of repkgs (branch `golconda`; see
[the repkgs fork](../../CONTRIBUTING.md#the-repkgs-fork) for its commits and how to change it) with
relocation fixes: PT_INTERP via libc with relative sysroot links, and glibc `$ORIGIN` expansion from
`AT_EXECFN` instead of `/proc`.

- Outputs are relocatable, so the store can live in `/usr` and no machine needs Nix.
- One LLVM toolchain; cross-compilation is an argument, which the platform record supplies.
- Evaluation is cheap and typed, so iets lints the whole set on every change.
- Debug info is split by build-id into `debug` outputs where `systemd-coredump` looks.

## The build host

Every repkgs output is content-addressed, and the lock-file fetchers are dynamic derivations, so the
daemon that builds them needs `ca-derivations`, `dynamic-derivations` and the system feature
`builder-rpc-v0`. Relocatable outputs are also why the build host keeps the plain `/nix/store` and
the image still holds the same paths under `/usr/nix/store`.
[Build host](../reference/build-host.md) has the `nix.conf` and how to get the first daemon.

## The platform

The platform is repkgs' record (`nix/platforms.nix` in repkgs), which `nix/packages.nix` returns
next to `pkgs`. It holds `cpu`, `os`, `name` (`x86_64-linux`), `march` and `names`, one spelling per
consumer: `names.kernel` (the kernel `ARCH`), `names.systemd` (`systemd-repart --architecture`, the
partition type names) and `names.uefi` (`BOOTX64.EFI`; null where there is no UEFI port). Golconda
keeps no table of its own; a new spelling goes into repkgs. Only `systems` in `default.nix` lists
what Golconda builds.

## Cross-compilation

The build host evaluates a set for the target platform; nothing in the module tree depends on the
build host. `nix/packages.nix` takes `system` (the build host) and `platform` (the target, default:
the build host). When they differ, repkgs cross-compiles packages that run on the target using the
build host's toolchain; `/pkgs.build` is the host's set for tools that run on the builder. The
`/usr` tree, os-release and every package output belong to the target; the derivation's `system` is
the build host where the build runs. The wiring exists, but Golconda exposes OS outputs only where
its kernel is supported, which today is x86_64: no aarch64 `/usr` tree or image is built
([Scope](scope.md#later)). aarch64 is *(later)*.

## Set-wide features

`nix/packages.nix` fixes `tls = "openssl"` for every package that declares the feature. A new
one-of-each decision is a feature value there, and a package that cannot honour it is not packaged.

## Prefixed packages

Some packages compile absolute paths into their binaries: systemd looks for generators in
`/usr/lib/systemd/system-generators`, dbus-broker reads policy from `/usr/share/dbus-1`, sshd its
privilege-separation directory. Their recipes set the relevant prefix or configure flags to `/usr`;
not every build system uses a `prefix` attribute. The image supplies those paths through explicit
links and directory farms ([Layout: The symlink map](layout.md#the-symlink-map)). Examples include
systemd, dbus-broker, openssh, linux-pam, and GnuPG.

Everything else is relocatable and lives only in the store. A package that cannot be relocated and
cannot take a prefix is not packaged.

## Interpreter policy

| context | allowed interpreters                            |
| ------- | ----------------------------------------------- |
| image   | dash (`/bin/sh` only); no bash, no other shells |
| build   | clang/lld, nushell, cpython, perl, rust         |

Dash is the only shell in the image; systemd units run dash scripts. At build time, clang and lld
are the toolchain, nushell drives the repkgs builders, Python is needed for meson, systemd's jinja2
templates and ukify, Perl for OpenSSL's Configure and some autotools, Rust for iets and dbus-broker.

## The kernel belongs to Golconda

`packages/kernel/` owns the recipe, source pin, kbuild module and policy. Its typed base starts from
x86_64 `defconfig` with virtio, a serial console and the initramfs path. The package only advertises
x86_64 support because its ORC unwinder config is architecture-specific.

`golconda.config` adds dm-verity with signed root hashes, erofs, TPM drivers, EFI, LSMs, nftables,
WireGuard and systemd requirements. A comment above each option says why. The package owns its typed
base and make flags. `nix/packages.nix` passes only the fragment and the options the system
requires, such as the built-in verity key, as JSON fields in the build environment. Store references
stay intact. A fragment may change a base option. A fragment that contradicts a required option
fails the build.

The local `kbuild.nu` uses repkgs' existing package-local phase interface. It merges the fragment
with `merge_config.sh` and verifies that the requested settings survive `olddefconfig`. A wrong
option name is a build error, not a silent loss. The result is `packages.<system>.kernel`: Linux
6.18 LTS, monolithic (no modules, so no kmod), built with `LLVM=1`. Its `debug` output holds the
unstripped `vmlinux` with full DWARF 5, for `gdb` and crash analysis; it is large.

## What is packaged

| in the image                                                                                                              | build only                                             |
| ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| systemd (with repart, sysupdate, cryptsetup, TPM2, PKCS#11, PAM), dbus-broker, dash, uutils coreutils, the kernel         | clang/lld, nushell, cpython, perl, rust, GNU coreutils |
| openssh, linux-pam (no setuid helpers), p11-kit, tpm2-tss (ESYS only), iproute2 (minimal)                                 | ukify, dosfstools, erofs-utils                         |
| e2fsprogs (first-boot `mkfs.ext4`), lvm2 (device-mapper only), libtasn1, libmnl, json-c, popt                             | automake, libtool                                      |
| tzdata (zoneinfo), cacert (CA bundle), hwdb (compiled hardware database), GnuPG and its libraries (signed update indexes) |                                                        |

`/base` includes tzdata and links `/usr/share/zoneinfo` to its zoneinfo directory. It includes hwdb
too: systemd-hwdb compiles a server's selection of the target systemd's `hwdb.d` at build time, and
`/base` links the result to `/usr/lib/udev/hwdb.bin`. `/factory` points `/etc/localtime` at the
configured zone there. Release images add GnuPG through the index fragment; the base tree alone does
not need it. btrfs-progs has a package and tests but is not in the image.

GnuPG and libgcrypt remain an intentional exception to the single crypto-stack preference: systemd's
signed-index path uses OpenPGP. systemd PR [#44292](https://github.com/systemd/systemd/pull/44292)
adds UAPI.16 manifests with inline PKCS#7 signatures. Once a released systemd supports that path, it
could replace GnuPG ([Signed index](releases.md#the-signed-index)).

A new daemon starts as a recipe in `packages/` ([Comparison](comparison.md)). Only a missing build
system or toolchain feature needs a fork change. Track such changes in
[the fork's branch](../../CONTRIBUTING.md#the-repkgs-fork); relocation and toolchain maintenance
remain external costs even when a local recipe is small.
