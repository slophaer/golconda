# secureboot-objects: Microsoft's public Secure Boot certificates and revocation list, from
# microsoft/secureboot_objects (pinned by tag and hash). Data for the Secure Boot variables that
# systemd-boot enrols from the ESP (lib/image/enrol.nu, scripts/make-keys); nothing of it is in
# an image's /usr, and nothing here is private.
#
#   share/secureboot-objects/KEK/   Microsoft Corporation KEK CA 2011 and KEK 2K CA 2023: Microsoft
#                                   signs its db and dbx updates with them
#   share/secureboot-objects/db/    Microsoft Corporation UEFI CA 2011, Microsoft UEFI CA 2023 and
#                                   Microsoft Option ROM UEFI CA 2023 (third-party loaders such as
#                                   shim, and option ROMs); Microsoft Windows Production PCA 2011
#                                   and Windows UEFI CA 2023 (only Windows' boot manager; Golconda
#                                   leaves them out of db, the boot test checks they stay out)
#   share/secureboot-objects/dbx/   DBXUpdate-amd64.bin, Microsoft's revocation list for x86_64 as
#                                   it ships it: an authenticated variable signed by Microsoft's
#                                   KEK. Golconda takes its signature lists and signs them with the
#                                   deployment's KEK
#
# The names are Golconda's; the files are the repository's PreSignedObjects/{KEK,DB}/Certificates
# and PostSignedObjects/DBX/amd64/DBXUpdate.bin, byte for byte. tests/packages/secureboot-objects
# checks each certificate's subject and SHA-1 fingerprint against systemd's loader.conf(5).
{ package }:
package {
  name = "secureboot-objects";
  install = {
    "share/secureboot-objects/KEK/microsoft-kek-ca-2011.der" =
      "PreSignedObjects/KEK/Certificates/MicCorKEKCA2011_2011-06-24.der";
    "share/secureboot-objects/KEK/microsoft-kek-2k-ca-2023.der" =
      "PreSignedObjects/KEK/Certificates/microsoft corporation kek 2k ca 2023.der";
    "share/secureboot-objects/db/microsoft-uefi-ca-2011.der" =
      "PreSignedObjects/DB/Certificates/MicCorUEFCA2011_2011-06-27.der";
    "share/secureboot-objects/db/microsoft-uefi-ca-2023.der" =
      "PreSignedObjects/DB/Certificates/microsoft uefi ca 2023.der";
    "share/secureboot-objects/db/microsoft-option-rom-uefi-ca-2023.der" =
      "PreSignedObjects/DB/Certificates/microsoft option rom uefi ca 2023.der";
    "share/secureboot-objects/db/windows-production-pca-2011.der" =
      "PreSignedObjects/DB/Certificates/MicWinProPCA2011_2011-10-19.der";
    "share/secureboot-objects/db/windows-uefi-ca-2023.der" =
      "PreSignedObjects/DB/Certificates/windows uefi ca 2023.der";
    "share/secureboot-objects/dbx/DBXUpdate-amd64.bin" = "PostSignedObjects/DBX/amd64/DBXUpdate.bin";
  };
  # data only: no libraries, no programs
  exports = {
    libDirs = [ ];
    libs = [ ];
  };
  bin = [ ];
  tests.version = false;
  platforms.os = [ "linux" ];
}
