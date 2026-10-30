# systemd-repart partition definitions
#
# Rendered to /usr/lib/repart.d/*.conf at build time.
# These define what partitions exist and how they are created/updated.
#
# Build-time definitions (used by the image builder):
#   esp, usr-a, usr-a-verity, usr-a-verity-sig
#
# First-boot definitions (in /usr/lib/repart.d on the image):
#   root
#
# Empty slot definitions (reserved space for A/B updates):
#   usr-b, usr-b-verity, usr-b-verity-sig
#
# IMPORTANT: The usr-a and usr-a-verity partition UUIDs must be derived from
# the dm-verity root hash for GPT auto-discovery:
#   - usr-a UUID: first 16 bytes of root hash, formatted as UUID
#   - usr-a-verity UUID: second 16 bytes of root hash, formatted as UUID
#
# The builder computes these and sets them in the partition definitions.
{
  # ======== Build-time partitions (created by image builder) ========

  "00-esp" = {
    Partition = {
      Type = "esp";
      Format = "vfat";
      SizeMinBytes = "256M";
      SizeMaxBytes = "1G";
      # CopyFiles set by builder: systemd-boot, UKI, loader.conf
    };
  };

  "10-usr-a" = {
    Partition = {
      Type = "usr";
      Label = "usr-a";
      SizeMinBytes = "64M";
      ReadOnly = true;
      # CopyBlocks set by builder: the erofs image
    };
  };

  "11-usr-a-verity" = {
    Partition = {
      Type = "usr-verity";
      Label = "usr-a-verity";
      ReadOnly = true;
      # CopyBlocks set by builder: the verity hash tree
    };
  };

  "12-usr-a-verity-sig" = {
    Partition = {
      Type = "usr-verity-sig";
      Label = "usr-a-verity-sig";
      ReadOnly = true;
      SizeMinBytes = "4K";
      SizeMaxBytes = "16K";
      # CopyBlocks set by builder: PKCS#7 signature of root hash
    };
  };

  # ======== Empty B slot (for A/B updates) ========

  "20-usr-b" = {
    Partition = {
      Type = "usr";
      Label = "usr-b";
      SizeMinBytes = "64M";
      Weight = 0;
      # Empty until first update
    };
  };

  "21-usr-b-verity" = {
    Partition = {
      Type = "usr-verity";
      Label = "usr-b-verity";
      SizeMinBytes = "1M";
      Weight = 0;
    };
  };

  "22-usr-b-verity-sig" = {
    Partition = {
      Type = "usr-verity-sig";
      Label = "usr-b-verity-sig";
      SizeMinBytes = "4K";
      SizeMaxBytes = "16K";
      Weight = 0;
    };
  };

  # ======== First-boot partition (created on machine) ========
  # This definition goes into /usr/lib/repart.d on the image, not
  # into the build-time definitions. systemd-repart runs on first
  # boot to create the root partition.

  "30-root" = {
    Partition = {
      Type = "root";
      Label = "root";
      Format = "ext4";
      SizeMinBytes = "512M";
      GrowFileSystem = true;
      FactoryReset = true;
      # Future: Encrypt = "tpm2"; for TPM2-bound LUKS
      MakeDirectories = "/etc /var /home /root /tmp /run /srv";
    };
  };
}
