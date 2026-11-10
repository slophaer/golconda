# Checks of the pin reader (lib/pins.nix): uptrack's sources.toml → fetchTarball arguments, read
# from the fixtures as data, and the flake template. What fetches the real pins is in
# tests/real-packages/pins.nix.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  f,
  ...
}:
let
  pins = import ../../lib/pins.nix;
in
[
  (check "pins: each directory's first [[source]] gives url (with [pin] placeholders) and hash" (
    pins.specs ../fixtures/pins == {
      alpha = {
        url = "https://example.org/alpha/1.2/abc123.tar.gz";
        sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      };
      beta = {
        url = "https://example.org/beta.tar.xz";
        sha256 = "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=";
      };
    }
  ))
  # the flake template (templates/default), its golconda input this tree on the stand-in
  # packages: no lock, no fetch
  (check "pins: the flake template's usr tree is the one of its server.toml" (
    let
      outputs = (import (f.templates.default.path + "/flake.nix")).outputs { golconda = f; };
    in
    outputs.packages.x86_64-linux.default.name == "golconda-usr-20261110.1"
  ))
]
