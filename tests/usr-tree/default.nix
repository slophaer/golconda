# Real-builder destination ownership tests, with tiny store-backed farm sources. `run` and
# `tools` come from nix/checks.nix (the seed's shell, repkgs' python3, coreutils and findutils).
{
  run,
  tools,
  src,
}:
let
  fixtures = run "usr-tree-fixtures" [ ] ''
    mkdir -p $out/a/lib/systemd/system/multi-user.target.wants $out/b/lib/systemd/system
    mkdir -p $out/a/lib/security $out/a/share/zoneinfo $out/a/bin
    printf sentinel > $out/a/lib/systemd/system/demo.service
    printf other > $out/b/lib/systemd/system/demo.service
    ln -s ../demo.service $out/a/lib/systemd/system/multi-user.target.wants/demo.service
    printf pam > $out/a/lib/security/pam.so
    printf utc > $out/a/share/zoneinfo/UTC
    printf tool > $out/a/bin/tool
    # packages as repkgs builds them: exports.json `bin` lists what bin/ holds
    mkdir -p $out/pkg-a/bin $out/pkg-b/bin $out/pkg-c/bin $out/pkg-lib
    printf a-tool > $out/pkg-a/bin/tool
    printf a-extra > $out/pkg-a/bin/extra
    printf hidden > $out/pkg-a/bin/.tool-real
    printf '{"bin":["extra","tool"]}' > $out/pkg-a/exports.json
    printf b-tool > $out/pkg-b/bin/tool
    printf '{"bin":["tool"]}' > $out/pkg-b/exports.json
    printf c-tool > $out/pkg-c/bin/tool
    printf '{"bin":[]}' > $out/pkg-lib/exports.json
    for name in os-release golconda/packages.json golconda/sbom.json golconda/attribution.json sysusers.d/golconda.conf tmpfiles.d/golconda.conf; do
      mkdir -p "$out/metadata/$name/lib/$(dirname "$name")"
      printf sentinel > "$out/metadata/$name/lib/$name"
    done
  '';
in
run "usr-tree-builder" tools ''
  python3 ${src}/tests/usr-tree/builder.py ${src}/lib/usr-tree ${fixtures}
  touch $out
''
