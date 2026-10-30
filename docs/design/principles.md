# Principles

Golconda keeps one of everything and makes the machine disposable: the image is the unit of
configuration, state is small and explicit. These rules decide what goes in; they are not
preferences.

## Immutable by default

`/usr` is read-only and verity-protected. Anything that changes at runtime lives under `/var` or
`/etc` on the data partition, and must be declared as such (a `StateDirectory=`, a tmpfiles line, a
repart definition). A path that is neither in the image nor declared does not exist.

## systemd first

If systemd has a component for it, that component is used and nothing else is packaged for the job:
journald, networkd, resolved, timesyncd, sysusers, tmpfiles, repart, sysupdate, boot, stub,
cryptsetup, veritysetup, pcrlock. Vendor configuration lives in `/usr/lib`, administrator overrides
in `/etc`, state in `/var`, exactly as systemd documents it.

## One of each

| layer                     | the one                                        | not                             |
| ------------------------- | ---------------------------------------------- | ------------------------------- |
| libc, toolchain           | glibc, LLVM                                    | musl (seed only), GCC           |
| TLS                       | OpenSSL 3; rustls tolerated in Rust-only tools | GnuTLS, LibreSSL, NSS           |
| CA trust                  | one store, `/etc/ssl`, see [Trust](trust.md)   | per-package bundles             |
| init, log, net, time, DNS | systemd components                             | rsyslog, chrony, NetworkManager |
| D-Bus                     | dbus-broker                                    | dbus-daemon                     |
| users                     | sysusers + factory `/etc`                      | shadow suite                    |
| boot                      | systemd-boot + UKI                             | GRUB, loose kernel and initrd   |
| disk                      | repart, sysupdate, erofs, dm-verity, LUKS2     | runtime partitioners, squashfs  |
| filesystem layout         | merged `/usr`, `/usr/sbin → bin`               | `/lib64`, `/usr/local`, `/opt`  |
| store                     | `/usr/nix/store`, image only                   | a Nix daemon on the machine     |

The choice is enforced where it can be: repkgs `features` (`tls = "openssl"` set-wide), lints, and
the boundary check that keeps nixpkgs out of everything but developer tooling.

## No compatibility layers

No `/bin` beyond the `sh` symlink, no FHS shims for foreign binaries, no NixOS module compatibility,
no channel or flake-registry support. A thing that needs them is not packaged.

## Nothing from nixpkgs

Packages come from repkgs and `packages/`. The only nixpkgs reference is the `nixpkgs-dev-only` pin
behind the formatter, the docs build and the dev shell, and `checks.boundary` fails when it leaks
anywhere else.
