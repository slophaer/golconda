# The CycloneDX pedigree.patches entries lib/sbom-patches.nix makes of a package's patches, on
# the packages as data (tests/fixtures/repkgs); tests/real-packages/sbom.nix checks that the SBOM
# carries them. A function of the harness (./harness.nix); it returns a list of checks.
{
  check,
  fixturePkgs,
  ...
}:
let
  sbomPatches = import ../../lib/sbom-patches.nix { };
  # a patch as the SBOM carries it: the file (relative to the package directory) and its text
  patchFile = pkg: file: {
    url = file;
    text = {
      contentType = "text/x-diff";
      content = builtins.readFile (pkg.dir + "/${file}");
    };
  };
in
[
  (check "sbom-patches: one entry per patch, in order, with its header's subject" (
    let
      file = patchFile fixturePkgs.systemd;
    in
    sbomPatches.of fixturePkgs.systemd == [
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
  (check "sbom: each Golconda patch says why in its header, and an upstream link is a reference" (
    let
      golcondaPatched = [
        "dosfstools"
        "gnupg"
        "libgpg-error"
        "p11-kit"
        "systemd"
      ];
      patches = builtins.concatMap (n: sbomPatches.of fixturePkgs.${n}) golcondaPatched;
    in
    builtins.length patches == 7
    && builtins.all (p: p ? resolves) patches
    &&
      (builtins.head (sbomPatches.of fixturePkgs.dosfstools)).resolves == [
        {
          type = "enhancement";
          name = "Honor the SOURCE_DATE_EPOCH variable";
          references = [
            "https://reproducible-builds.org/specs/source-date-epoch/"
            "https://github.com/dosfstools/dosfstools/pull/106"
          ];
        }
      ]
  ))
  (check "sbom: a package without patches has no entries" (sbomPatches.of fixturePkgs.zstd == [ ]))
]
