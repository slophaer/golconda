# The Golconda kernel: the repkgs fork's linux-kernel (a small bootable base) with Golconda's kconfig
# fragment applied. The fragment is applied by the override in nix/packages.nix, so every
# `pkgs.linux-kernel` of the set (the image, the VM test) is this kernel; this file only names it.
{ pkgs }: pkgs.linux-kernel
