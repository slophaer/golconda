# The fragment type: what every service module returns and what the composer
# (/system) merges. Keys are plain strings now; typed units come later.
# modules/lib is not a module directory (no default.nix); modules import it.
{ types }:
let
  inherit (types)
    struct
    optionalAttr
    attrsOf
    listOf
    string
    derivation
    ;
in
struct "fragment" {
  # unit file name -> unit file text, installed to /usr/lib/systemd/system
  units = optionalAttr (attrsOf string);
  # absolute path under /usr -> file text (os-release, repart.d, sysupdate.d, ...)
  files = optionalAttr (attrsOf string);
  # systemd-sysusers lines
  sysusers = optionalAttr (listOf string);
  # systemd-tmpfiles lines
  tmpfiles = optionalAttr (listOf string);
  # closure roots that go into /usr/nix/store and the /usr/bin farm
  packages = optionalAttr (listOf derivation);
}
