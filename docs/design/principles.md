# Principles

Golconda keeps one of everything and makes the machine disposable: the image is the unit of
configuration, state is small and explicit. These rules decide what goes in; they are not
preferences; [Scope](scope.md) says what they put in the current release, what comes later and what
is out of scope. The pages that follow apply them in order: the pieces
([Architecture](architecture.md)), the disk ([Layout](layout.md), [Boot](boot.md),
[Updates](updates.md)), the keys ([Trust](trust.md)), the kernel ([Kernel](kernel.md)), how a system
is described ([Modules](modules.md), [Configuration](config.md)), where the programs come from
([Packaging](packaging.md)), and what is lost ([Comparison](comparison.md)).

## Immutable by default

`/usr` is read-only and verity-protected. Anything that changes at runtime lives under `/etc` or
`/var` on the state partition and is declared: a `StateDirectory=`, a tmpfiles line, a repart
definition. A path that is neither in the image nor declared does not exist.

Enforced: a fragment's `files` must be under `/usr` (a path under `/etc` is a type error outside
`/factory`), and the `/usr` tree builder refuses a top-level directory other than `bin`, `lib`,
`share`, `libexec`, `nix` and the `sbin` link. Nothing checks `/var`.

## The image holds no per-machine value

One image serves every machine of its kind. A host name, a key, a certificate or a password hash
never enters the image: it is a bootstrap credential, a var generated on the machine, or a value the
administrator pushes ([Boot](boot.md#bootstrap-credentials), [Trust](trust.md#secrets-and-vars)).
Enforced: an app file that contains a credential path or a key marker is a type error.

## systemd first

If systemd has a component for it, that component is used and nothing else is packaged for the job:
journald, networkd, resolved, timesyncd, sysusers, tmpfiles, repart, sysupdate, boot, stub,
cryptsetup, veritysetup, pcrlock, creds, firstboot. Vendor configuration lives in `/usr/lib`,
administrator overrides in `/etc`, state in `/var`, exactly as systemd documents it.

## One of each

| layer                     | the one                                        | not                             |
| ------------------------- | ---------------------------------------------- | ------------------------------- |
| libc, toolchain           | glibc, LLVM                                    | musl (seed only), GCC           |
| TLS                       | OpenSSL 3; rustls tolerated in Rust-only tools | GnuTLS, LibreSSL, NSS           |
| CA trust                  | one store, `/etc/ssl`, see [Trust](trust.md)   | per-package bundles             |
| init, log, net, time, DNS | systemd components                             | rsyslog, chrony, NetworkManager |
| D-Bus                     | dbus-broker                                    | dbus-daemon                     |
| shell                     | dash as `/bin/sh`                              | bash                            |
| coreutils                 | uutils                                         | GNU coreutils (build only)      |
| users                     | sysusers + factory `/etc`                      | shadow suite                    |
| boot                      | systemd-boot + UKI                             | GRUB, loose kernel and initrd   |
| disk                      | repart, sysupdate, erofs, dm-verity, LUKS2     | runtime partitioners, squashfs  |
| time zone data            | tzdata, UTC unless `/factory.timezone` says so | per-service `TZ`                |
| filesystem layout         | merged `/usr`, `/usr/sbin → bin`               | `/lib64`, `/usr/local`, `/opt`  |
| store                     | `/usr/nix/store`, image only                   | a Nix daemon on the machine     |

The choice is enforced where it can be: repkgs `features` (`tls = "openssl"` set-wide), lints, and
the boundary check that keeps nixpkgs out of every Nix file, script and pin.

The one CA file is Mozilla's roots (cacert), kept in `/usr` and linked into `/etc/ssl` at boot at
the two paths the image's clients read by default: `/etc/ssl/cert.pem` for OpenSSL
(`OPENSSLDIR=/etc/ssl`) and `/etc/ssl/certs/ca-certificates.crt` for curl. The file lives in `/usr`,
so an update replaces it and `/etc` keeps no copy to go stale.

## Duplicates are errors

Two sources for one thing (a unit name, a file path, a `/usr/bin` name, a factory file) are an error
that names both. There is no priority, no `mkForce`, no override: a module that wants another's
result calls it and transforms the value ([Modules](modules.md)).

## No compatibility layers

`/bin`, `/sbin` and `/lib` are links into `/usr` (merged `/usr`, so `#!/bin/sh` works), and no other
FHS path exists: no `/lib64`, `/usr/local` or `/opt`. There are no FHS shims for foreign binaries,
no NixOS module compatibility, no channel or flake-registry support, no cloud-init. A thing that
needs them is not packaged.

## Nothing from nixpkgs

Packages come from repkgs and `packages/`, and so do the tools the scripts run on the build host
(`scripts/tools.sh`) and the sandboxed checks' builders (the repkgs seed's shell, `nix/checks.nix`).
The boot test's virtual machine is no exception: QEMU, swtpm and virt-firmware are `packages/`, and
OVMF is the edk2 build that the QEMU project ships in its release tarball (`pc-bios/edk2-*`,
edk2-stable202408), kept in `qemu-system`'s `share/qemu`: prebuilt by QEMU, trusted by the tarball's
pinned hash, and not rebuilt here. Building edk2 from source is a later step. `checks.boundary`
fails when a Nix file or a script names nixpkgs as a search path or as the old `nixpkgs-dev-only`
pin, or when `pins/` pins it.
