# Golconda

*Ceci n'est pas un NixOS.*

Golconda is a server operating system built with Nix but without nixpkgs or NixOS. A machine is
described by one TOML document; a builder turns it into one signed image: a read-only, verity-
protected `/usr` with the Nix store inside it, booted by a signed unified kernel image, updated A/B
by systemd-sysupdate. The machine runs systemd and nothing that duplicates it, and it runs no Nix.

## What a Golconda system is

- **One image, no per-machine build.** The image holds no per-machine value. The host name and the
  provisioning data arrive as systemd credentials at first boot; secrets are generated on the
  machine or pushed by the administrator, never built in.
- **Immutable `/usr`, one state partition.** `/usr` is erofs under dm-verity. `/etc` starts as
  symlinks into the image's factory and an administrator's file at the same path wins; `/var` holds
  state. The state partition is unencrypted in v1 (LUKS2+TPM2 later).
- **A/B updates with rollback.** Two `/usr` slots and two UKIs; systemd-boot counts boots and falls
  back to the other slot.
- **One of each.** One libc, one toolchain (LLVM), one TLS stack, one CA store, one init, one
  logger, one network stack. Enforced by package features and lints, not by convention.
- **Typed, explicit modules.** A module returns a typed fragment; the composer unions the fragments
  and refuses a duplicate. No global namespace, no priorities, no overrides.
- **Servers first.** UEFI, the Discoverable Partitions Specification, networkd with DHCP on every
  link, resolved, timesyncd, sshd with certificates. Root only, no local login.

## Status

The module tree, the composer, the `/usr` tree builder, the schema, the TOML loader and the entry
point (`golconda.nix`) exist and are tested. The image builder (erofs, verity, initrd, UKI, disk) is
being built. Secure Boot, measured boot and TPM2-sealed credentials are designed and not yet proven
on a machine. The docs mark each such thing *(planned)* or *(being built)*;
[Scope](docs/design/scope.md) says what is v1, after v1 and out of scope, and
[Comparison](docs/design/comparison.md) says what you give up against NixOS.

## Quick start

```sh
nix-shell                      # or: direnv allow
./scripts/lint                 # strict iets lint, module tests, sandboxed checks
scripts/docs serve             # the book (generates the module pages first)
```

Start with [Principles](docs/design/principles.md), then read the design pages in order; the
[Walkthrough](docs/reference/walkthrough.md) goes from `examples/server.toml` to a booted machine.
Design pages say why; reference pages say what exists. Contributing:
[CONTRIBUTING](CONTRIBUTING.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
