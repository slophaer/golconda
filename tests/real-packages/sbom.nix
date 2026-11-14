# The system SBOM, as repkgs' generator writes it: every component says where it comes from
# (golconda:origin), a downstream replacement names the package it replaced (CycloneDX
# pedigree.ancestors), a patched package lists its patches (pedigree.patches, the generator's), and
# a sources.toml CPE becomes the component's cpe. Identities, not guessed display names.
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
  # a component without what Golconda adds: the golconda: properties, and a replacement's
  # pedigree.ancestors and notes (the generator's pedigree.patches stay)
  withoutProvenance =
    c:
    let
      kept = builtins.filter (p: !isProvenance p) (c.properties or [ ]);
      pedigree = builtins.removeAttrs (c.pedigree or { }) [
        "ancestors"
        "notes"
      ];
    in
    builtins.removeAttrs c [
      "properties"
      "pedigree"
    ]
    // (if kept == [ ] then { } else { properties = kept; })
    // (if pedigree == { } then { } else { inherit pedigree; });
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
  # one package's own component, as the generator writes it for the set without a document
  ownComponent =
    n:
    builtins.head (
      builtins.filter (c: c.name == n)
        (base.set.sbom {
          roots = [ base.pkgs.${n} ];
          name = "own";
        }).bom.components
    );
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
  (check "sbom: a patched package lists its patches, in order, with its header's subject" (
    let
      file = patchFile fixture.pkgs.systemd;
    in
    patchesOf (component "systemd") == [
      {
        type = "unofficial";
        diff = file "hwdb-imds-hetzner.patch";
        resolves = [
          {
            type = "defect";
            name = "hwdb: fix the IMDS paths for Hetzner Cloud";
          }
        ];
      }
      {
        type = "unofficial";
        diff = file "imds-ssh-key-json.patch";
        resolves = [
          {
            type = "enhancement";
            name = "imds: import SSH keys provided as a JSON array";
          }
        ];
      }
      {
        type = "unofficial";
        diff = file "hwdb-imds-hetzner-ssh-keys.patch";
        resolves = [
          {
            type = "enhancement";
            name = "hwdb: import the SSH keys on Hetzner Cloud";
            references = [ "https://docs.hetzner.cloud/reference/cloud#server-metadata" ];
          }
        ];
      }
    ]
  ))
  (check "sbom: each Golconda patch says why in its header" (
    let
      patched = [
        "dosfstools"
        "gnupg"
        "libgpg-error"
        "libtpms"
        "p11-kit"
        "systemd"
      ];
      patches = builtins.concatMap (n: patchesOf (ownComponent n)) patched;
    in
    builtins.length patches == 8 && builtins.all (p: p ? resolves) patches
  ))
  (check "sbom: a patch marked Origin: upstream is a backport, linked to its upstream commit" (
    let
      dosfstools = builtins.head (patchesOf (ownComponent "dosfstools"));
      libtpms = builtins.head (patchesOf (ownComponent "libtpms"));
    in
    dosfstools.type == "backport"
    &&
      dosfstools.diff.url
      == "https://github.com/dosfstools/dosfstools/commit/8da7bc93315cb0c32ad868f17808468b81fa76ec"
    &&
      dosfstools.resolves == [
        {
          type = "enhancement";
          name = "Honor the SOURCE_DATE_EPOCH variable";
          references = [
            "https://reproducible-builds.org/specs/source-date-epoch/"
            "https://github.com/dosfstools/dosfstools/pull/106"
          ];
        }
      ]
    && libtpms.type == "backport"
    &&
      libtpms.diff.url
      == "https://github.com/stefanberger/libtpms/commit/fc8820cfaa8b5e17328f731df93911f6ab92443b"
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
  (check "sbom: only golconda:origin and a replacement's ancestors change the generator's BOM" (
    fixture.sbom.bom // { components = map withoutProvenance components; } == baseline.bom
  ))
  (check "sbom: /usr gets the generator's sbom.json for this document" (
    fixture.usrTree.drvAttrs.sbomPath == "${fixture.sbom}/sbom.json"
  ))
  (check
    "sbom: hwdb, gen-init-cpio and ca-bundle name the source they are built from, as a purl with a subpath"
    (
      let
        hwdb = ownComponent "hwdb";
        cpio = ownComponent "gen-init-cpio";
        bundle = ownComponent "ca-bundle";
      in
      hwdb.purl == "pkg:github/systemd/systemd@${base.pkgs.systemd.version}#hwdb.d"
      && cpio.purl == "pkg:generic/linux@${base.pkgs.linux-kernel.version}#usr/gen_init_cpio.c"
      # the version is the source's pin; and hwdb is not systemd, so it has no systemd cpe
      && hwdb.version == base.pkgs.systemd.version
      && cpio.version == base.pkgs.linux-kernel.version
      && !(hwdb ? cpe)
      && !(cpio ? cpe)
      # the CA bundle is cacert's roots (certifi's file), arranged by trust extract
      && bundle.purl == "pkg:github/certifi/python-certifi@${base.pkgs.cacert.version}#certifi/cacert.pem"
      && bundle.version == base.pkgs.cacert.version
      && !(bundle ? cpe)
    )
  )
]
