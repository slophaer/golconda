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
