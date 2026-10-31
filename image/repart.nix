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
      SizeMinBytes = "512M";
      SizeMaxBytes = "512M";
      # CopyFiles set by builder: systemd-boot, UKI
    };
  };

  "10-usr-a" = {
    Partition = {
      Type = "usr";
      Label = "usr-a";
      SizeMinBytes = "10G";
      SizeMaxBytes = "10G";
      ReadOnly = true;
      # CopyBlocks set by builder: the erofs image
    };
  };

  "11-usr-a-verity" = {
    Partition = {
      Type = "usr-verity";
      Label = "usr-a-verity";
      SizeMinBytes = "128M";
      SizeMaxBytes = "128M";
      ReadOnly = true;
      # CopyBlocks set by builder: the verity hash tree
    };
  };

  "12-usr-a-verity-sig" = {
    Partition = {
      Type = "usr-verity-sig";
      Label = "usr-a-verity-sig";
      ReadOnly = true;
      SizeMinBytes = "16K";
      SizeMaxBytes = "16K";
      # CopyBlocks set by builder: systemd's JSON with the PKCS#7 signature of the root hash
    };
  };

  # ======== Empty B slot (for A/B updates) ========
  # The same fixed sizes as A: sysupdate writes the next version into whichever slot is free,
  # so both must hold any release (usr 10 GiB; a hash tree is ~1 % of its data).

  "20-usr-b" = {
    Partition = {
      Type = "usr";
      Label = "usr-b";
      SizeMinBytes = "10G";
      SizeMaxBytes = "10G";
      Weight = 0;
      # Empty until first update
    };
  };

  "21-usr-b-verity" = {
    Partition = {
      Type = "usr-verity";
      Label = "usr-b-verity";
      SizeMinBytes = "128M";
      SizeMaxBytes = "128M";
      Weight = 0;
    };
  };

  "22-usr-b-verity-sig" = {
    Partition = {
      Type = "usr-verity-sig";
      Label = "usr-b-verity-sig";
      SizeMinBytes = "16K";
      SizeMaxBytes = "16K";
      Weight = 0;
    };
  };

  # ======== First-boot partition (created on machine) ========
  # This definition goes into /usr/lib/repart.d on the image, not
  # into the build-time definitions. systemd-repart runs on first
  # boot to create the root partition.

  # PROTOTYPE (no initrd): the state partition, made by systemd-repart in the host at first
  # boot and mounted on /var (modules/base var.mount). / is the erofs image itself.
  "30-state" = {
    Partition = {
      Type = "linux-generic";
      Label = "state";
      Format = "ext4";
      SizeMinBytes = "512M";
      FactoryReset = true;
      # /etc is seeded from the image once; /var is the rest of the partition
      CopyFiles = "/usr/lib/golconda/state-etc:/etc";
    };
  };
}
