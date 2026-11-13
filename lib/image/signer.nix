# lib/image/signer.nix: the signer as a program, and the test images it signs in the store.
#
# signer { pkgs; buildSystem; } → derivation with bin/golconda-sign (lib/image/sign-main.nu):
#   golconda-sign UNSIGNED --keys DIR [--pcr-keys DIR] [--index-keys DIR]
#     [--pkcs11-module FILE] --out DIR
#   The tools are the image's own (its package set, downstream replacements included):
#   systemd-sbsign, ukify and systemd-measure, mkfs.erofs, veritysetup, openssl, systemd-repart
#   with mtools and dosfstools, gpg, and pkcs11-provider for keys on a token (OPENSSL_MODULES).
#   The release host runs it (`golconda release build`), with the key set where it lies; nothing
#   of it enters the store.
#
# signedWithTestKeys { unsigned; name; keys; pcrKeys ? keys; indexKeys ? keys; buildSystem; }
#   → derivation: the release of `unsigned` (lib/image/manifest.nix) signed in the store with
#   throwaway keys (lib/image/default.nix throwawayKeys), for the test images only. Its builder
#   is the program the release host runs, `unsigned`'s `sign`, so the boot test tests the
#   production signer. A key set given here enters the store: never give it a deployment's keys.
#
# signedWithTestToken { unsigned; name; keys; pcrKeys ? keys; indexKeys ? keys; buildSystem;
#   pkgs; } → derivation: the same release, signed with the db and PCR keys on a SoftHSM token
#   (TEST-ONLY) through pkcs11-provider, as a release host signs with keys on a YubiKey
#   (lib/image/token.nu). The release key stays a file. RSA PKCS#1 v1.5 draws no random numbers,
#   so the release is the one signedWithTestKeys makes, byte for byte (checks pkcs11-signed-same).
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
      # OpenSSL's provider for keys on a PKCS#11 token: the tools load it by name from here
      attrs.opensslModules = "${pkgs.pkcs11-provider}/lib/ossl-modules";
      libs = [
        pkgs.openssl # systemd-sbsign, systemd-measure, systemd-repart: libcrypto
        pkgs.tpm2-tss # systemd-measure: libtss2-mu for the PCR policy
        pkgs.util-linux # systemd-repart: libfdisk, libblkid, libmount
        pkgs.cryptsetup # libcryptsetup, opened when a definition has Verity=
      ];
    };

  # enrolTool { pkgs; buildSystem; } → derivation with bin/golconda-enrol-auth
  #   (lib/image/enrol-main.nu): a key set's enrolment files, secureboot/auth/{microsoft,golconda}
  #   (lib/image/enrol.nu). scripts/make-keys runs it on the release host with the PK and KEK
  #   keys; Microsoft's objects are packages/secureboot-objects. No image depends on it.
  enrolTool =
    { pkgs, buildSystem }:
    common.nuDerivation {
      name = "golconda-enrol-auth";
      inherit buildSystem;
      module = "signer";
      tools = [ pkgs.openssl ];
      attrs = {
        program = "golconda-enrol-auth";
        main = "enrol-main.nu";
        description = "a key set's Secure Boot enrolment files (lib/image/enrol.nu)";
        programEnv.GOLCONDA_SECUREBOOT_OBJECTS = "${pkgs.secureboot-objects}/share/secureboot-objects";
        opensslModules = "";
      };
      libs = [ pkgs.openssl ];
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

  signedWithTestToken =
    {
      unsigned,
      name,
      keys,
      pcrKeys ? keys,
      indexKeys ? keys,
      buildSystem,
      pkgs,
    }:
    common.nuDerivation {
      inherit name buildSystem;
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
          indexKeys
          ;
        pkcs11Module = "${pkgs.softhsm}/lib/softhsm/libsofthsm2.so";
      };
    };
}
