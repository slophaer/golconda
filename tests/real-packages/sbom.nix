# The system SBOM, as repkgs' generator writes it (moved from tests/eval; tests/eval/sbom-patches.nix
# checks the patch entries on the packages as data): every component says where it comes from (golconda:origin), a downstream
# replacement names the package it replaced (CycloneDX pedigree.ancestors), a patched package
# lists its patches (pedigree.patches), and a sources.toml CPE becomes the component's cpe.
# Identities, not guessed display names.
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
  isProvenance = p: builtins.substring 0 9 p.name == "golconda:";
  originOf =
    c: map (p: p.value) (builtins.filter (p: p.name == "golconda:origin") (c.properties or [ ]));
  # the package set without the downstream directory: where a replaced package comes from
  base = import ../../nix/packages.nix {
    inherit sources;
    system = platform;
  };
  # what the SBOM says about one package of that set, as an ancestor names it
  ancestorOf =
    type: pkg:
    let
      root = builtins.head (
        builtins.filter (c: c.type == "application")
          (base.set.sbom {
            roots = [ pkg ];
            name = "ancestor";
          }).bom.components
      );
    in
    {
      inherit type;
      inherit (root) name version purl;
    };
  baseline =
    (import ../../nix/packages.nix {
      inherit sources;
      system = platform;
      downstream = ../fixtures/downstream/packages;
      replaces = [
        "openssh"
        "ripgrep"
      ];
    }).set.sbom
      {
        roots = fixture.composed.packages;
        name = "${fixture.name}-${fixture.version}";
      };
  withoutProvenance =
    c:
    let
      kept = builtins.filter (p: !isProvenance p) (c.properties or [ ]);
    in
    builtins.removeAttrs c [
      "properties"
      "pedigree"
    ]
    // (if kept == [ ] then { } else { properties = kept; });
  ordinary = mkSystem {
    config = {
      "/system" = {
        name = "ordinary";
        version = "20261103.1";
      };
    };
  };
  plain = name: builtins.head (builtins.filter (c: c.name == name) ordinary.sbom.bom.components);
  patchesOf = c: c.pedigree.patches or [ ];
  sbomPatches = import ../../lib/sbom-patches.nix { };
  # a patch as the SBOM carries it: the file (relative to the package directory) and its text
  patchFile = pkg: file: {
    url = file;
    text = {
      contentType = "text/x-diff";
      content = builtins.readFile (pkg.dir + "/${file}");
    };
  };
  # Keep the package identity but change its display metadata. Conversely, jq's
  # display name must not make it the downstream hello package.
  identity = mkSystem {
    config = {
      golconda.packages = ../fixtures/downstream/packages;
      golconda.replaces = [
        "openssh"
        "ripgrep"
      ];
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
      replaces = [ "openssh" ];
    }).pkgs;
  conflict = mkSystem {
    config = {
      golconda.packages = ../fixtures/sbom-conflict;
      golconda.replaces = [ "openssh" ];
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
  (check "sbom: a new downstream root has origin downstream and no pedigree" (
    (component "hello-binary").version == "0.0.1"
    && originOf (component "hello-binary") == [ "downstream" ]
    && !((component "hello-binary") ? pedigree)
  ))
  (check "sbom: a replacement of a repkgs package names it in pedigree.ancestors" (
    let
      c = component "ripgrep";
    in
    c.version == "0.0.2"
    && originOf c == [ "downstream" ]
    && c.pedigree.ancestors == [ (ancestorOf c.type base.pkgs.ripgrep) ]
    && c.pedigree.notes == "replaced by the downstream package ripgrep; the original comes from repkgs"
  ))
  (check "sbom: a replacement of a Golconda package names it, and carries its own cpe" (
    let
      c = component "openssh";
    in
    c.version == "0.0.3"
    && originOf c == [ "downstream" ]
    && c.cpe == "cpe:2.3:a:example:openssh:0.0.3:*:*:*:*:*:*:*"
    && c.pedigree.ancestors == [ (ancestorOf c.type base.pkgs.openssh) ]
    && (builtins.head c.pedigree.ancestors).version != "0.0.3"
    &&
      c.pedigree.notes == "replaced by the downstream package openssh; the original comes from golconda"
  ))
  (check "sbom: a Golconda package has origin golconda and the cpe of its sources.toml" (
    let
      c = component "systemd";
    in
    originOf c == [ "golconda" ]
    && c.cpe == "cpe:2.3:a:systemd_project:systemd:${c.version}:*:*:*:*:*:*:*"
    && !((c.pedigree or { }) ? ancestors)
    && c == plain "systemd"
  ))
  (check "sbom: a patched package lists its patches in pedigree.patches (lib/sbom-patches.nix)" (
    let
      c = component "systemd";
    in
    builtins.length (patchesOf c) == 3 && patchesOf c == sbomPatches.of fixture.pkgs.systemd
  ))
  (check "sbom: a repkgs patch is listed too; one with no header resolves nothing" (
    patchesOf (component "attr") == [
      {
        type = "unofficial";
        diff = patchFile fixture.pkgs.attr "relocatable.patch";
      }
    ]
  ))
  (check "sbom: a patch with free text before the diff resolves its first paragraph" (
    let
      resolved = map (p: p.resolves or [ ]) (patchesOf (component "readline"));
    in
    resolved != [ ]
    &&
      builtins.head resolved == [
        {
          type = "enhancement";
          name = "SIGWINCH does not exist on Windows (msys2 MINGW-packages).";
        }
      ]
  ))
  (check "sbom: an unpatched package has no pedigree" (
    fixture.pkgs.zstd.patches == [ ] && !((component "zstd") ? pedigree)
  ))
  (check "sbom: a repkgs package has origin repkgs" (
    originOf (component "glibc") == [ "repkgs" ] && !((component "glibc") ? cpe)
  ))
  (check "sbom: every component has exactly one origin, and no marker is left" (
    builtins.all (c: builtins.length (originOf c) == 1) components
    && builtins.all (
      c:
      builtins.all (
        p:
        p.name == "golconda:origin"
        ||
          builtins.substring 0 9 p.name != "golconda:" && builtins.substring 0 14 p.name != "golconda-lift:"
      ) (c.properties or [ ])
    ) components
  ))
  (check "sbom: a renamed display name retains downstream identity" (
    originOf (identified "different-display-name") == [ "downstream" ]
  ))
  (check "sbom: a display name cannot impersonate a downstream package" (
    originOf (identified "hello") == [ "repkgs" ] && !((identified "hello") ? pedigree)
  ))
  (check "sbom: a downstream alias does not relabel its upstream package" (
    originOf aliasJq == [ "repkgs" ] && !(aliasJq ? pedigree)
  ))
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
      (component "openssh").pedigree.ancestors
      == [ (ancestorOf (component "openssh").type base.pkgs.openssh) ]
  ))
  (check "sbom: only golconda:origin and pedigree change the generator's BOM" (
    fixture.sbom.bom // { components = map withoutProvenance components; } == baseline.bom
  ))
  (check "sbom: /usr gets the generator's sbom.json for this document" (
    fixture.usrTree.drvAttrs.sbomPath == "${fixture.sbom}/sbom.json"
  ))
  (check "sbom: hwdb and gen-init-cpio name the source they are built from, as a purl with a subpath"
    (
      let
        of =
          n:
          builtins.head (
            builtins.filter (c: c.name == n)
              (base.set.sbom {
                roots = [ base.pkgs.${n} ];
                name = "source";
              }).bom.components
          );
        hwdb = of "hwdb";
        cpio = of "gen-init-cpio";
      in
      hwdb.purl == "pkg:github/systemd/systemd@${base.pkgs.systemd.version}#hwdb.d"
      && cpio.purl == "pkg:generic/linux@${base.pkgs.linux-kernel.version}#usr/gen_init_cpio.c"
      # the version is the source's pin; and hwdb is not systemd, so it has no systemd cpe
      && hwdb.version == base.pkgs.systemd.version
      && cpio.version == base.pkgs.linux-kernel.version
      && !(hwdb ? cpe)
      && !(cpio ? cpe)
    )
  )
]
