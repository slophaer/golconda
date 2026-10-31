# Packaging

Packages are repkgs packages: a `package.nix` naming a build system and a `sources.toml` naming the
upstream. Golconda adds its own under `packages/` and sets a few set-wide features; it has no
builder of its own.

## Why repkgs

Golconda pins a fork of repkgs (branch `golconda`; see
[patches/repkgs](../../patches/repkgs/README.md)) with relocation fixes: PT_INTERP via libc with
relative sysroot links, and glibc `$ORIGIN` expansion from `AT_EXECFN` instead of `/proc`. See
[`patches/repkgs/README.md`](../../patches/repkgs/README.md) for the patches and their issue drafts.

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

## Cross-compilation

The build host evaluates a set for the target platform; nothing in the module tree depends on the
build host. `nix/packages.nix` takes `system` (the build host) and `platform` (the target, default:
the build host). When they differ, repkgs cross-compiles packages that run on the target using the
build host's toolchain. The `/usr` tree, os-release and every package output belong to the target;
the derivation's `system` is the build host where the build runs.

## Set-wide features

`nix/packages.nix` fixes `tls = "openssl"` for every package that declares the feature. A new
one-of-each decision is a feature value there, and a package that cannot honour it is not packaged.

## Farm packages and the prefix rule

Some packages compile absolute paths into their binaries: systemd looks for generators in
`/usr/lib/systemd/system-generators`, dbus-broker reads policy from `/usr/share/dbus-1`. These are
**farm packages**: they are built with `prefix = "/usr"` in the repkgs spec and reached through the
symlink farm at `/usr/bin`, `/usr/lib`.

Farm packages in the image: systemd, dbus-broker, openssh.

Everything else is relocatable and lives only in the store. A package that cannot be relocated and
cannot be a farm package is not packaged.

## Interpreter policy

| context | allowed interpreters                            |
| ------- | ----------------------------------------------- |
| image   | dash (`/bin/sh` only); no bash, no other shells |
| build   | clang/lld, nushell, cpython, perl, rust         |

Dash is the only shell in the image. systemd units run dash scripts. Bash is not packaged.

At build time, clang and lld are the toolchain. Nushell drives repkgs builders. Python is needed for
meson, systemd's jinja2 templates, and ukify (build-only; not in the image). Perl is needed for
OpenSSL's Configure and some autotools. Rust builds iets and dbus-broker's main branch.

## The kernel: base in the fork, policy here

The fork's `linux-kernel` is a small bootable base: x86_64 `defconfig`, virtio, the serial console,
devtmpfs and the initramfs path, enough to boot in QEMU and pass the fork's own smoke test. Golconda
owns every policy choice as a kconfig fragment, `packages/kernel/golconda.config`: dm-verity with
signed root hashes, erofs, the TPM drivers, EFI, the LSMs (built in, not forced on), nftables,
WireGuard, the systemd requirements, and the hardening that costs nothing at run time. A comment
above each option says why. `nix/packages.nix` appends the file through the set's override path
(`overrides.linux-kernel.kbuild.configFragments.append`); the fork merges it onto the base with
`merge_config.sh` and fails the build when a line does not survive `olddefconfig`. A wrong option
name is a build error, not a silent loss. The result is `packages.<system>.kernel`.

## Round-1 packages

Packages in progress on the fork, by work package:

| WP  | packages                                                                                 |
| --- | ---------------------------------------------------------------------------------------- |
| WP1 | kbuild build system, linux-kernel (monolithic, LTS 6.18.y, `LLVM=1`)                     |
| WP2 | automake, libtool, json-c, popt, dosfstools, e2fsprogs, erofs-utils, lvm2 (dm-only)      |
| WP3 | libtasn1, libmnl, p11-kit, tpm2-tss (fapi off), iproute2, linux-pam, openssh, iets       |
| WP4 | python helpers (jinja2, pyelftools), systemd 262 with the prefix field, dbus-broker main |

kmod is deferred: round 1 builds a monolithic kernel with no modules.
