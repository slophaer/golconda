# The actual system SBOM records downstream provenance, not guessed display names.
{
  check,
  sources,
  platform,
  ...
}:
let
  mkSystem =
    args:
    import ../../lib/system.nix (
      {
        inherit sources platform;
        system = platform;
      }
      // args
    );
  fixture = mkSystem { config = ../fixtures/downstream/server.toml; };
  components = fixture.sbom.bom.components;
  component = name: builtins.head (builtins.filter (c: c.name == name) components);
  properties = c: c.properties or [ ];
  origin = {
    name = "golconda:origin";
    value = "downstream";
  };
  replaces = value: {
    name = "golconda:replaces";
    inherit value;
  };
  ordinary = mkSystem {
    config = {
      "/system" = {
        name = "ordinary";
        version = "20261103.1";
      };
    };
  };
  plain = name: builtins.head (builtins.filter (c: c.name == name) ordinary.sbom.bom.components);
  # Keep the package identity but change its display metadata. Conversely, jq's
  # display name must not make it the downstream hello package.
  identity = mkSystem {
    config = {
      golconda.packages = ../fixtures/downstream/packages;
      "/system" = {
        name = "identity";
        version = "20261103.1";
      };
    };
    extraFragments = [
      {
        name = "/test/package-identity";
        packages = [
          (fixture.pkgs.hello // { pname = "different-display-name"; })
          (fixture.pkgs.jq // { pname = "hello"; })
        ];
      }
    ];
  };
  identified = name: builtins.head (builtins.filter (c: c.name == name) identity.sbom.bom.components);
  alias = mkSystem {
    config = {
      golconda.packages = ../fixtures/sbom-alias;
      "/system" = {
        name = "alias";
        version = "20261103.1";
      };
    };
    extraFragments = [
      {
        name = "/test/upstream-alias";
        packages = [ fixture.pkgs.jq ];
      }
    ];
  };
  aliasJq = builtins.head (builtins.filter (c: c.name == "jq") alias.sbom.bom.components);
  conflictingPkgs =
    (import ../../nix/packages.nix {
      inherit sources;
      system = platform;
      downstream = ../fixtures/sbom-conflict;
    }).pkgs;
  conflict = mkSystem {
    config = {
      golconda.packages = ../fixtures/sbom-conflict;
      "/system" = {
        name = "conflict";
        version = "20261103.1";
      };
    };
    extraFragments = [
      {
        name = "/test/conflicting-provenance";
        packages = [ conflictingPkgs.openssh ];
      }
    ];
  };
in
[
  (check "sbom: a new downstream root records origin without a replacement" (
    (component "hello-binary").version == "0.0.1" && properties (component "hello-binary") == [ origin ]
  ))
  (check "sbom: a transitive downstream replacement records repkgs" (
    (component "ripgrep").version == "0.0.2"
    &&
      properties (component "ripgrep") == [
        origin
        (replaces "repkgs")
      ]
  ))
  (check "sbom: a downstream replacement records golconda" (
    (component "openssh").version == "0.0.3"
    &&
      properties (component "openssh") == [
        origin
        (replaces "golconda")
      ]
  ))
  (check "sbom: ordinary components remain unchanged" (
    component "systemd" == plain "systemd"
    && builtins.all (p: p.name != "golconda:origin" && p.name != "golconda:replaces") (
      properties (component "systemd")
    )
  ))
  (check "sbom: a renamed display name retains downstream identity" (
    properties (identified "different-display-name") == [ origin ]
  ))
  (check "sbom: a display name cannot impersonate a downstream package" (
    properties (identified "hello") == [ ]
  ))
  (check "sbom: a downstream alias does not relabel its upstream package" (properties aliasJq == [ ]))
  (check "sbom: one artifact cannot silently choose conflicting replacement metadata" (
    conflictingPkgs.openssh.drvPath == conflictingPkgs.duplicate.drvPath
    && !(builtins.tryEval (builtins.deepSeq conflict.sbom.bom.components true)).success
  ))
  (check "sbom: unused unsupported packages are not instantiated" (
    !alias.pkgs.unsupported.supported && builtins.deepSeq alias.sbom.bom true
  ))
  (check "sbom: an alias preserves its downstream target's replacement" (
    fixture.pkgs.openssh-alias.drvPath == fixture.pkgs.openssh.drvPath
    &&
      properties (component "openssh") == [
        origin
        (replaces "golconda")
      ]
  ))
]
