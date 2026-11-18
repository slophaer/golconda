# lib/image: from a /usr tree to a bootable disk image, with repkgs packages only. Nix builds the
# unsigned parts (initrd, index, manifest, the signer); the signer signs and assembles the release
# outside the store (docs/design/signing.md). The artifacts:
# docs/reference/image.md; why: docs/design/{layout,boot,trust,signing}.md.
_:
let
  common = import ./common.nix { };
in
(import ./erofs.nix { })
// (import ./verity.nix { })
// (import ./initrd.nix { })
// (import ./uki.nix { })
// (import ./loader.nix { })
// (import ./disk.nix { })
// (import ./index.nix { })
// (import ./manifest.nix { })
// (import ./signer.nix { })
// (import ./smoke.nix { })
// {
  inherit (common) uuidOfHex hexOf;

  # throwawayKeys { buildSystem; pkgs; sources; version; variant ? null; reusePkKek ? null; } -> derivation with the
  # key set of the test images, made by scripts/make-keys inside the store, because the keys are
  # fixtures: a production key never enters it. `out` is the set (docs/reference/release.md),
  # `private` its DIR.private (PK.key, KEK.key), `public` the public halves (the chain's
  # publicKeys, the boot test's --keys). A `variant` is a second set for the key rotation test
  # (docs/design/bootloader.md): `reusePkKek`, another set, makes it with make-keys
  # --reuse-pk-kek. The builder sees make-keys and golconda-enrol-auth only, so an edit of another
  # step keeps the keys and every unsigned output. `version`, the first test release's, dates the
  # set: SOURCE_DATE_EPOCH is its timestamp (lib/version.nix).
  throwawayKeys =
    {
      buildSystem,
      pkgs,
      sources,
      version,
      variant ? null,
      reusePkKek ? null,
    }:
    let
      inherit
        (import "${sources.repkgs}/bootstrap" {
          seed = null;
          system = buildSystem;
        })
        seed
        ;
      makeKeys = builtins.path {
        path = ../../scripts/make-keys;
        name = "make-keys";
      };
      enrolAuth = (import ./signer.nix { }).enrolTool { inherit pkgs buildSystem sources; };
      reuse = if reusePkKek == null then "" else "--reuse-pk-kek $TMPDIR/k/old";
    in
    import ../ca-derivation.nix {
      name = "golconda-throwaway-keys" + (if variant == null then "" else "-${variant}");
      system = buildSystem;
      builder = "${seed}/bin/sh";
      outputs = [
        "out"
        "private"
        "public"
      ];
      PATH = "${seed}/bin";
      SOURCE_DATE_EPOCH = toString ((import ../version.nix { }).toEpoch version);
      args = [
        "-eu"
        "-c"
        ''
          # make-keys gets its tools from the tools.sh beside it: here the store's
          mkdir -p $TMPDIR/scripts $TMPDIR/k
          cp ${makeKeys} $TMPDIR/scripts/make-keys
          echo 'tools_path() { printf %s ${pkgs.openssl}/bin:${pkgs.gnupg}/bin:${enrolAuth}/bin; }' > $TMPDIR/scripts/tools.sh
          ${
            if reusePkKek == null then
              ""
            else
              "cp -R ${reusePkKek} $TMPDIR/k/old && cp -R ${reusePkKek.private} $TMPDIR/k/old.private && chmod -R u+w $TMPDIR/k"
          }
          sh $TMPDIR/scripts/make-keys ${reuse} $TMPDIR/k/set
          cp -R $TMPDIR/k/set $out
          mkdir $private
          [ ! -d $TMPDIR/k/set.private ] || cp $TMPDIR/k/set.private/* $private/
          for f in secureboot/db.crt secureboot/PK.crt secureboot/KEK.crt secureboot/auth pcr/pcr.pub release/index.pgp; do
            mkdir -p $(dirname $public/$f)
            cp -R $out/$f $public/$f
          done
        ''
      ];
    };
}
