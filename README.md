# Golconda

*Ceci n'est pas un NixOS.*

Golconda is a server operating system built with Nix but without nixpkgs or NixOS. Images are built
on a builder and shipped whole: a signed, verity-protected `/usr` with the Nix store inside it,
booted by a signed unified kernel image, updated A/B by systemd-sysupdate. The machine runs systemd
and nothing that duplicates it.

## Features

- **Immutable by default.** `/usr` is a read-only erofs image under dm-verity. State lives on one
  encrypted partition; everything else is regenerated from the image at boot.
- **A/B updates with automatic rollback.** Two `/usr` slots, two UKIs, boot counting by
  systemd-boot, blessing by `systemd-bless-boot`.
- **Secure Boot and measured boot.** UKIs are signed; PCR 11 policies are precomputed and signed, so
  the TPM-bound disk unlocks after an update without re-enrolment.
- **No Nix on the machine.** The store at `/usr/nix/store` is a build-time concept; repkgs makes
  every output relocatable, so nothing is patched or rewritten.
- **One of each.** One libc, one toolchain (LLVM), one TLS stack, one CA store, one init, one
  logger, one network stack. Choices are enforced by package features, not by convention.
- **Typed, explicit modules.** adios modules return typed fragments; the composer unions them and
  refuses duplicates. No global namespace, no priorities.
- **Fast, lintable evaluation.** iets evaluates the whole package set in under a second and lints it
  strictly; npins pins the inputs.
- **Servers first.** UEFI, DPS/DDI partition layout, networkd, resolved, sshd.

## Limitations

- Linux, x86_64 and aarch64, UEFI only. No BIOS, no desktops.
- Only the packages repkgs and `packages/` provide. There is no nixpkgs fallback.
- No per-machine `nix`: configuration changes mean a new image.
- No runtime generations list; rollback is to the other slot.
- Developer tooling (formatter, docs) still comes from a dev-only nixpkgs pin.
- Young dependencies: repkgs needs a patched Nix daemon to build; adios and iets change often.

## Golconda and NixOS

| | NixOS | Golconda | |---|---|---| | Packages | nixpkgs, bash builders, store paths baked in |
repkgs, nushell builders, relocatable outputs | | Store | `/nix/store` on every machine, Nix daemon
required | `/usr/nix/store` inside the image, no daemon | | Modules | global namespace,
`mkForce`/priorities, fixpoint | typed fragments, explicit inputs, duplicates are errors | |
Activation | `switch-to-configuration`, generations in the store | image swap, A/B slots, boot
counting | | Boot | systemd-boot or GRUB, kernel + initrd per generation | signed UKI per slot,
measured boot | | `/etc` | generated, mostly symlinks into the store | factory seed from `/usr`,
admin state on the data partition | | Evaluator | Nix | iets (Nix only on the build daemon) | |
Inputs | flakes or channels | npins; flake output schema via flake-incompat |

## Quick start

```sh
nix-shell                      # or: direnv allow
iets build -A packages.x86_64-linux.nix
./scripts/lint                 # iets lint + treefmt + docs + boundary checks
mdbook serve docs              # the book
```

Documentation: [docs/](docs/SUMMARY.md). Design pages say why; reference pages say what.
