# Comparison

Golconda takes NixOS's reproducible, declarative build and ParticleOS's image-based, systemd-native
runtime, and drops what each needs to be general. This page lists what was taken and what was left
behind.

## From NixOS and nixpkgs

| taken | left behind | |---|---| | the Nix language, the store, content-addressed derivations |
nixpkgs, stdenv, overlays, store paths on the machine | | building the whole system from one
expression | the NixOS module system, generations, `switch-to-configuration` | | `image.repart`,
`boot.uki`, `systemd.sysupdate` as prior art | GRUB, non-systemd initrd, `/etc` as a symlink farm |

## From ParticleOS and mkosi

| taken | left behind | |---|---| | DPS layout, `/usr`-only images, first-boot repart of an
encrypted root | distribution packages, mkosi | | UKIs, boot counting, PCR policies, sysupdate |
sysext as the way to add software (modules do that at build time) |

## What neither does

A relocatable Nix store inside a verity image, so one tree is both reproducible and an ordinary
systemd image; and typed modules whose composition is a plain function.
