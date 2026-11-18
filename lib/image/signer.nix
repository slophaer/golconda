# lib/image/signer.nix: the signer as a program, and the test images it signs in the store.
#
# signer { pkgs; buildSystem; sources; } -> derivation with bin/golconda-sign (lib/image/sign-main.nu), built
#   from the image's own package set. The release host runs it (`golconda release build`) with the
#   key set where it lies; nothing of it enters the store.
# signedWithTestKeys { unsigned; name; keys; pcrKeys ? keys; buildSystem; }
#   -> the release of `unsigned` signed in the store with throwaway keys, for the test images only:
#   never give it a deployment's keys. Its builder is the production signer. The release key is
#   `keys`': it cannot change yet, so an `indexKeys` other than `keys` is refused.
# signedWithTestToken { ...; pkgs; } -> the same release, signed with the db and PCR keys on a
#   SoftHSM token (TEST-ONLY) through pkcs11-provider. RSA PKCS#1 v1.5 draws no random numbers, so
#   it equals signedWithTestKeys' release (checks pkcs11-signed-same).
_:
let
  common = import ./common.nix { };
  # the release key is the one in `keys` (docs/design/releases.md, the signed index)
  sameReleaseKey =
    keys: indexKeys:
    indexKeys == keys
    || throw "golconda: a test image signs with the release key of `keys`; it cannot change yet";
in
{
  signer =
    {
      pkgs,
      buildSystem,
      sources,
    }:
    common.nuDerivation {
      name = "golconda-sign";
      inherit buildSystem sources;
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
      # OpenSSL's provider for keys on a PKCS#11 token: the tools load it by name from here
      attrs.opensslModules = "${pkgs.pkcs11-provider}/lib/ossl-modules";
    };

  # enrolTool { pkgs; buildSystem; sources; } → derivation with bin/golconda-enrol-auth
  #   (lib/image/enrol-main.nu): a key set's enrolment files, secureboot/auth/{microsoft,golconda}
  #   (lib/image/enrol.nu), written by efitools and checked with openssl. scripts/make-keys runs
  #   it on the release host with the PK and KEK keys; Microsoft's objects are
  #   packages/secureboot-objects. No image depends on it.
  enrolTool =
    {
      pkgs,
      buildSystem,
      sources,
    }:
    common.nuDerivation {
      name = "golconda-enrol-auth";
      inherit buildSystem sources;
      module = "signer";
      tools = [
        pkgs.openssl # the key checks and the signature check
        pkgs.efitools # cert-to-efi-sig-list and sign-efi-sig-list write the files
      ];
      attrs = {
        program = "golconda-enrol-auth";
        main = "enrol-main.nu";
        description = "a key set's Secure Boot enrolment files (lib/image/enrol.nu)";
        programEnv.GOLCONDA_SECUREBOOT_OBJECTS = "${pkgs.secureboot-objects}/share/secureboot-objects";
        opensslModules = "";
      };
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
    assert sameReleaseKey keys indexKeys;
    import ../ca-derivation.nix {
      inherit name;
      system = buildSystem;
      builder = "${unsigned}/sign";
      args = [
        "${unsigned}"
        "--keys"
        "${keys}"
        "--pcr-keys"
        "${pcrKeys}"
        "--out"
        (placeholder "out")
      ];
    };

  signedWithTestToken =
    {
      unsigned,
      name,
      keys,
      pcrKeys ? keys,
      indexKeys ? keys,
      buildSystem,
      pkgs,
      sources,
    }:
    assert sameReleaseKey keys indexKeys;
    common.nuDerivation {
      inherit name buildSystem sources;
      module = "token";
      tools = [ pkgs.softhsm ];
      modules = [
        "token.nu"
        "common.nu"
      ];
      attrs = {
        inherit
          unsigned
          keys
          pcrKeys
          ;
        pkcs11Module = "${pkgs.softhsm}/lib/softhsm/libsofthsm2.so";
      };
    };
}
