# Golconda image definitions
#
# Tool-independent data for building Golconda disk images. These are rendered
# to INI files at build time by the image builder. No nixpkgs references.
#
# See docs/design/layout.md for the partition layout.
# See docs/design/updates.md for the sysupdate mechanism.
# See docs/reference/image.md for artifact naming.
{
  # Partitions and their repart.d definitions
  repart = import ./repart.nix;

  # Sysupdate transfer definitions
  sysupdate = import ./sysupdate.nix;

  # UKI configuration (for ukify)
  uki = import ./uki.nix;

  # erofs configuration
  erofs = import ./erofs.nix;

  # os-release template
  osRelease = import ./os-release.nix;

  # Boot counting and blessing
  bootCounting = {
    triesLeft = 3;
    triesDone = 0;
    # UKI naming: <imageId>_<version>+<triesLeft>-<triesDone>.efi
    # After blessing: <imageId>_<version>.efi (no counter suffix)
  };

  # Key layout (paths relative to deployment keys directory)
  keys = {
    secureBootPk = "secureboot/PK.crt";
    secureBootKek = "secureboot/KEK.crt";
    secureBootDb = "secureboot/db.crt";
    secureBootDbKey = "secureboot/db.key";
    # the verity root hash is signed with the db key: the kernel checks the signature against
    # the platform keyring, which holds the firmware db and nothing else (docs/design/trust.md)
    verityCert = "secureboot/db.crt";
    verityKey = "secureboot/db.key";
    pcrCert = "pcr/pcr.crt";
    pcrKey = "pcr/pcr.key";
  };
}
