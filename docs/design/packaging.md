# Packaging

Packages are repkgs packages: a `package.nix` naming a build system and a `sources.toml` naming the
upstream. Golconda adds its own under `packages/` and sets a few set-wide features; it has no
builder of its own.

## Why repkgs

Golconda pins a fork of repkgs (branch `golconda`; see
[patches/repkgs](../../patches/repkgs/README.md) for the patches and their issue drafts) with
relocation fixes: PT_INTERP via libc with relative sysroot links, and glibc `$ORIGIN` expansion from
`AT_EXECFN` instead of `/proc`.

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
build host's toolchain; `/pkgs.build` is the host's set for tools that run on the builder. The
`/usr` tree, os-release and every package output belong to the target; the derivation's `system` is
the build host where the build runs. A cross-compiled `/usr` tree for aarch64 builds today
(`packages.x86_64-linux.usr-tree-smoke-aarch64`); a bootable aarch64 image is *(planned)*.

## Set-wide features

`nix/packages.nix` fixes `tls = "openssl"` for every package that declares the feature. A new
one-of-each decision is a feature value there, and a package that cannot honour it is not packaged.

## Prefixed packages

Some packages compile absolute paths into their binaries: systemd looks for generators in
`/usr/lib/systemd/system-generators`, dbus-broker reads policy from `/usr/share/dbus-1`, sshd its
privilege-separation directory. These are built with `prefix = "/usr"` in the repkgs spec and
reached through the symlink farm: their directories are `farm` links the builder expands file by
file ([Layout: The symlink map](layout.md#the-symlink-map)). Prefixed packages in the image:
systemd, dbus-broker, openssh.

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

## The kernel: base in the fork, policy here

The fork's `linux-kernel` is a small bootable base: x86_64 `defconfig`, virtio, the serial console,
devtmpfs and the initramfs path, enough to boot in QEMU and pass the fork's own smoke test. Golconda
owns every policy choice as a kconfig fragment, `packages/kernel/golconda.config`: dm-verity with
signed root hashes, erofs, the TPM drivers, EFI, the LSMs (built in, not forced on), nftables,
WireGuard, the systemd requirements, and the hardening that costs nothing at run time. A comment
above each option says why. `nix/packages.nix` appends the file through the set's override path
(`overrides.linux-kernel.kbuild.configFragments.append`); the fork merges it onto the base with
`merge_config.sh` and fails the build when a line does not survive `olddefconfig`. A wrong option
name is a build error, not a silent loss. The result is `packages.<system>.kernel`: the latest LTS
series, monolithic (no modules, so no kmod), built with `LLVM=1`.

## What is packaged

| in the image                                                                                                      | build only                                             |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| systemd (with repart, sysupdate, cryptsetup, TPM2, PKCS#11, PAM), dbus-broker, dash, uutils coreutils, the kernel | clang/lld, nushell, cpython, perl, rust, GNU coreutils |
| openssh, linux-pam (no setuid helpers), p11-kit, tpm2-tss (ESYS only), iproute2 (minimal)                         | ukify, dosfstools, erofs-utils                         |
| e2fsprogs (first-boot `mkfs.ext4`), lvm2 (device-mapper only), libtasn1, libmnl, json-c, popt                     | automake, libtool                                      |

Missing: tzdata. No zoneinfo package is in the image, so `/factory`'s `/etc/localtime` link to
`/usr/share/zoneinfo/UTC` dangles (a v1 gap; packaging tzdata is a fork task).

A new daemon is a packaging job on the fork first ([Comparison](comparison.md)).
