# lib/image/signer.nix: the signer as a program, and the test images it signs in the store.
#
# signer { pkgs; buildSystem; } → derivation with bin/golconda-sign (lib/image/sign-main.nu):
#   golconda-sign UNSIGNED --keys DIR [--pcr-keys DIR] [--index-keys DIR] --out DIR
#   The tools are the image's own (its package set, downstream replacements included):
#   systemd-sbsign, ukify and systemd-measure, mkfs.erofs, veritysetup, openssl, systemd-repart
#   with mtools and dosfstools, gpg. The release host runs it (`golconda release build`), with
#   the key set where it lies; nothing of it enters the store.
#
# signedWithTestKeys { unsigned; name; keys; pcrKeys ? keys; indexKeys ? keys; buildSystem; }
#   → derivation: the release of `unsigned` (lib/image/manifest.nix) signed in the store with
#   throwaway keys (lib/image/default.nix throwawayKeys), for the test images only. Its builder
#   is the program the release host runs, `unsigned`'s `sign`, so the boot test tests the
#   production signer. A key set given here enters the store: never give it a deployment's keys.
_:
let
  common = import ./common.nix { };
in
{
  signer =
    { pkgs, buildSystem }:
    common.nuDerivation {
      name = "golconda-sign";
      inherit buildSystem;
      module = "signer";
      tools = [
        pkgs.systemd # systemd-sbsign, systemd-measure, systemd-repart (lib/systemd, on PATH too)
        pkgs.ukify
        pkgs.erofs-utils
        pkgs.cryptsetup # veritysetup
        pkgs.openssl # the root hash signature, the key checks
        pkgs.dosfstools # mkfs.vfat
        pkgs.mtools # mcopy, mmd: how repart fills a vfat offline
        pkgs.gnupg # SHA256SUMS.gpg
      ];
      libs = [
        pkgs.openssl # systemd-sbsign, systemd-measure, systemd-repart: libcrypto
        pkgs.tpm2-tss # systemd-measure: libtss2-mu for the PCR policy
        pkgs.util-linux # systemd-repart: libfdisk, libblkid, libmount
        pkgs.cryptsetup # libcryptsetup, opened when a definition has Verity=
      ];
    };

  signedWithTestKeys =
    {
      unsigned,
      name,
      keys,
      pcrKeys ? keys,
      indexKeys ? keys,
      buildSystem,
    }:
    derivation {
      inherit name;
      system = buildSystem;
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      builder = "${unsigned}/sign";
      args = [
        "${unsigned}"
        "--keys"
        "${keys}"
        "--pcr-keys"
        "${pcrKeys}"
        "--index-keys"
        "${indexKeys}"
        "--out"
        (placeholder "out")
      ];
    };
}
