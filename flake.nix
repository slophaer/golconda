{
  description = "Golconda: an immutable, systemd-centred server OS built on repkgs and adios. Ceci n'est pas un NixOS.";
  # No flake inputs: npins owns the pins, and fixed-output fetchTarball is pure.
  outputs = _: import ./default.nix;
}
