# One of each

Golconda keeps one implementation of each job: one libc, one toolchain, one TLS stack, one CA store,
one init, one logger, one network stack. Fewer parts mean less to patch, less to audit and fewer
ways for two copies to disagree. The rule has one honest exception, and this page names it.

## How it works

The table in [Principles](../design/principles.md#one-of-each) lists the one and the not:

| layer                     | the one                           | not                             |
| ------------------------- | --------------------------------- | ------------------------------- |
| libc, toolchain           | glibc, LLVM                       | musl (seed only), GCC           |
| TLS                       | OpenSSL 3                         | GnuTLS, LibreSSL, NSS           |
| CA trust                  | one store in `/etc/ssl`           | per-package bundles             |
| init, log, net, time, DNS | systemd components                | rsyslog, chrony, NetworkManager |
| D-Bus, shell, coreutils   | dbus-broker, dash, uutils         | dbus-daemon, bash, GNU          |
| boot, disk                | systemd-boot + UKI, repart, erofs | GRUB, squashfs                  |
| store                     | `/usr/nix/store`, image only      | a Nix daemon on the machine     |

Code enforces what it can:

- **TLS.** `nix/packages.nix` sets `features.tls = "openssl"` for the whole package set. A package
  that cannot honour it is not packaged.
- **Duplicates.** Two sources for one unit name, file path, `/usr/bin` name or factory file are an
  error that names both. There is no priority and no override (the composer in `/system`).
- **Shell.** A test (`tests/eval/base.nix`) checks that `/usr/bin/sh` is dash and that no bash
  package is in the base.
- **nixpkgs.** `checks.boundary` fails when a nixpkgs reference leaks outside developer tooling.
- **CA store.** The image ships one bundle, cacert's Mozilla roots, in `/usr`. Tmpfiles links it to
  `/etc/ssl/cert.pem` and `/etc/ssl/certs/ca-certificates.crt`.

## Against NixOS

NixOS lets one system hold several libcs and several versions of the same package side by side: each
program finds its own dependencies by store path. That flexibility is one of its strengths.
Golconda's base system does not use it. A second libc or a second OpenSSL in the base is a second
thing to patch and audit, and a second way for two programs to disagree about the same file,
certificate or protocol.

A service that needs another version can still have one, inside its own boundary:

- **A relocatable closure.** repkgs outputs find their libraries and their dynamic loader relative
  to themselves ([Packaging: Why repkgs](../design/packaging.md#why-repkgs)), so a service can carry
  its own closure without touching what the base links against.
- **A container.** The workload brings its own userland and runs under systemd. No container runtime
  is set up in the image today: systemd is built without `machined` and `portabled`
  (`packages/systemd/package.nix`).

The rule covers the base system: what every image shares. It does not stop a workload from carrying
what it needs.

## Using it

You do not choose. A new daemon is a recipe in `packages/` that fits the existing choices. A new
choice is a feature value in `nix/packages.nix`.

## The exception: GnuPG and libgcrypt

A release image carries GnuPG 2.4 and libgcrypt beside OpenSSL. This is a second crypto library. The
reason: `systemd-pull` checks the signed update index (`SHA256SUMS.gpg`) only by running `gpg`. It
reads the release key from `/usr/lib/systemd/import-pubring.pgp`.

The package is cut down. GnuPG builds with no X.509, keyserver, smartcard, TLS (`--disable-gnutls`)
or database code (`packages/gnupg/package.nix`). The way out is systemd PR
[#44292](https://github.com/systemd/systemd/pull/44292), which adds manifests with an inline PKCS#7
signature. When a systemd release has it, the `db` key's openssl tooling can sign the index and
GnuPG can leave the image. Until then the exception stays
([Releases: the signed index](../design/releases.md#the-signed-index)).

## Status

The dash test runs in `nix/tests.nix` and the boundary check in the sandboxed checks, both from
`scripts/lint`. The duplicate rule has module tests. The `tls` feature has no test of its own. The
CA paths were checked by hand on a booted machine: the image's OpenSSL validated `example.com`, and
failed with the default paths off. No boot-test marker covers them. The signed index is proven by
`index-signed` and `index-keyring`. See [What is proven](../proven.md).

## Limits

- No check lists every library in the closure. Only the rules above are mechanical, and the rest is
  review.
- OpenSSL is the TLS stack, but rustls is tolerated in Rust-only tools.
- The CA store has Mozilla roots only. Administrator anchors and a distrust list are *(planned)*.
- Build-only tools sit outside the rule. Python, Perl and GNU coreutils help build the image and are
  not in it.

## More

- [Principles: one of each](../design/principles.md#one-of-each) and
  [duplicates are errors](../design/principles.md#duplicates-are-errors)
- [Packaging: what is packaged](../design/packaging.md#what-is-packaged)
- [Trust: CA store](../design/trust.md#3-ca-store)
- [Signed releases](signed-releases.md) and [Typed modules](typed-modules.md)
