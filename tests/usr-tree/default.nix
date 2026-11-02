# Real-builder destination ownership tests, with tiny store-backed farm sources.
{ pkgs, src }:
let
  fixtures = pkgs.runCommand "usr-tree-fixtures" { } ''
    mkdir -p $out/a/lib/systemd/system/multi-user.target.wants $out/b/lib/systemd/system
    mkdir -p $out/a/lib/security $out/a/share/zoneinfo $out/a/bin
    printf sentinel > $out/a/lib/systemd/system/demo.service
    printf other > $out/b/lib/systemd/system/demo.service
    ln -s ../demo.service $out/a/lib/systemd/system/multi-user.target.wants/demo.service
    printf pam > $out/a/lib/security/pam.so
    printf utc > $out/a/share/zoneinfo/UTC
    printf tool > $out/a/bin/tool
    for name in os-release golconda/packages.json golconda/sbom.json sysusers.d/golconda.conf tmpfiles.d/golconda.conf; do
      mkdir -p "$out/metadata/$name/lib/$(dirname "$name")"
      printf sentinel > "$out/metadata/$name/lib/$name"
    done
  '';
in
pkgs.runCommand "check-usr-tree-builder"
  {
    nativeBuildInputs = [
      pkgs.nushell
      pkgs.python3
      pkgs.coreutils
      pkgs.findutils
    ];
  }
  ''
    python3 ${src}/tests/usr-tree/builder.py ${src}/lib/usr-tree ${fixtures}
    touch $out
  ''
