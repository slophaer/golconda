# Comparison

Golconda takes NixOS's reproducible, declarative build and ParticleOS's image-based, systemd-native
runtime, and drops what each needs to be general. This page lists what was taken and what was left
behind.

## Golconda and NixOS

|            | NixOS                                                | Golconda                                                |
| ---------- | ---------------------------------------------------- | ------------------------------------------------------- |
| Packages   | nixpkgs, bash builders, store paths baked in         | repkgs, nushell builders, relocatable outputs           |
| Store      | `/nix/store` on every machine, Nix daemon required   | `/usr/nix/store` inside the image, no daemon            |
| Modules    | global namespace, `mkForce`/priorities, fixpoint     | typed fragments, explicit inputs, duplicates are errors |
| Activation | `switch-to-configuration`, generations in the store  | image swap, A/B slots, boot counting                    |
| Boot       | systemd-boot or GRUB, kernel + initrd per generation | signed UKI per slot, measured boot                      |
| `/etc`     | generated, mostly symlinks into the store            | symlinks into the image's factory, admin files win      |
| Evaluator  | Nix                                                  | iets (Nix only on the build daemon)                     |
| Inputs     | flakes or channels                                   | npins; flake output schema via flake-incompat           |

| taken                                                                   | left behind                                                     |
| ----------------------------------------------------------------------- | --------------------------------------------------------------- |
| the Nix language, the store, content-addressed derivations              | nixpkgs, stdenv, overlays, store paths on the machine           |
| building the whole system from one expression                           | the NixOS module system, generations, `switch-to-configuration` |
| `image.repart`, `boot.uki`, `systemd.sysupdate` as prior art            | GRUB, non-systemd initrd, `/etc` generated per activation       |
| units that say what runs: `ExecStart=` is the program and its arguments | wrapping programs into launchers that carry their configuration |

## From ParticleOS and mkosi

| taken                                                                    | left behind                                                       |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| DPS layout, `/usr`-only images, first-boot repart of the state partition | distribution packages, mkosi                                      |
| UKIs, boot counting, PCR policies, sysupdate; `/etc` as tmpfiles lines   | sysext as the way to add software (modules do that at build time) |

## What neither does

A relocatable Nix store inside a verity image, so one tree is both reproducible and an ordinary
systemd image; and typed modules whose composition is a plain function.

## What you give up against NixOS

An honest list for someone who runs NixOS today, with when (if ever) the gap closes.

| you lose                                     | what it costs                                                                                                                                                               | when                         |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| nixpkgs' packages                            | about 100 000 packages become the few dozen repkgs and `packages/` hold ([Packaging](packaging.md#what-is-packaged)); a new daemon is a packaging job on the fork first     | never                        |
| the NixOS module library                     | every service is written as a typed module; there is one (`/services/sshd`)                                                                                                 | grows per service            |
| module overrides (`mkForce`, priorities)     | a duplicate is an error; a module that wants another's result calls it ([Modules](modules.md))                                                                              | never                        |
| overlays                                     | a package override is the typed `package` option of the service that uses it, or a fork patch                                                                               | never                        |
| `nixos-rebuild switch`, `test`, generations  | a change is a new image and a reboot; there are two slots, not a list of generations                                                                                        | never                        |
| Nix on the machine (`nix-shell`, `nix repl`) | no debugging on the host; a debug image or a sysext with tools is the plan                                                                                                  | after v1                     |
| local login                                  | no getty, no password, no rescue shell; recovery is the other slot or a reflash                                                                                             | never (debug image after v1) |
| per-machine evaluation                       | the image holds no per-machine value; host name and secrets arrive as credentials and vars                                                                                  | never                        |
| the NixOS VM test framework                  | tests are pure-Nix module tests plus a build-time image smoke (`image-smoke`, `proof.txt`); the QEMU boot is run by hand, and a VM test harness for Golconda is not written | after v1                     |
| a binary cache                               | the fork has none; a build host needs the patched Nix daemon and builds the toolchain once                                                                                  | after v1                     |
| cross-compilation for every package          | the `/usr` tree cross-builds; no bootable aarch64 image is built                                                                                                            | after v1                     |
| encrypted root, rollback protection          | the state partition is unencrypted and an older signed image boots ([Trust](trust.md#rollback-weakness))                                                                    | after v1                     |

## What Golconda takes from the image-based systems

- **Flatcar**: the A/B partition pair with automatic rollback, and the update contract (a server
  serves versioned artifacts, the client decides by version). Left behind: Ignition and the
  container-first userland.
- **openSUSE MicroOS**: transactional updates that only take effect on reboot, and a `/etc` that the
  administrator owns. Left behind: the btrfs snapshot machinery and RPM.
- **bootc / Fedora CoreOS**: an explicit "what is not supported" page (this one), and the image as
  the unit of configuration. Left behind: OCI as the transport and `rpm-ostree`'s package layering.
- **ParticleOS**: nearly everything on the machine: DPS, `/usr`-only verity images, UKIs with
  measured boot, sysupdate, first-boot repart, credentials for provisioning, and `/etc` as tmpfiles
  lines. Left behind: distribution packages and mkosi.

Why not ParticleOS itself, then? ParticleOS is built from a distribution's packages, so the system
is reproducible only as far as that distribution is; Golconda builds every package and the whole
image from one pinned expression, with one toolchain and one of each library, and the module tree is
typed data that a schema, a diff and a GUI can read. The runtime is the same systemd; the build is
the difference.
