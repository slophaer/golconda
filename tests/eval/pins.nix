# Checks of the pin reader (lib/pins.nix): uptrack's sources.toml → fetchTarball arguments, read
# from the fixtures as data. What fetches the real pins is in tests/real-packages/pins.nix.
# A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
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
]
