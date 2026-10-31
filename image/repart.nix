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
#
# Labels: slot A's are the sysupdate target patterns with the version (image/sysupdate.nix
# `slots`, such as usr_20261031.1), set by the builder; how sysupdate recognizes the installed
# instance. The B slots are `_empty`, how it recognizes a free slot.
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
      SizeMinBytes = "10G";
      SizeMaxBytes = "10G";
      ReadOnly = true;
      # Label, CopyBlocks, UUID set by builder: usr_<version>, the erofs image, the hash-derived UUID
    };
  };

  "11-usr-a-verity" = {
    Partition = {
      Type = "usr-verity";
      SizeMinBytes = "128M";
      SizeMaxBytes = "128M";
      ReadOnly = true;
      # Label, CopyBlocks, UUID set by builder: usr-verity_<version>, the hash tree, the derived UUID
    };
  };

  "12-usr-a-verity-sig" = {
    Partition = {
      Type = "usr-verity-sig";
      ReadOnly = true;
      SizeMinBytes = "16K";
      SizeMaxBytes = "16K";
      # Label, CopyBlocks set by builder: usr-verity-sig_<version>, systemd's JSON with the PKCS#7
      # signature of the root hash
    };
  };

  # ======== Empty B slot (for A/B updates) ========
  # The same fixed sizes as A: sysupdate writes the next version into whichever slot is free,
  # so both must hold any release (usr 10 GiB; a hash tree is ~1 % of its data).
  # Label `_empty`: an empty partition without it breaks the dissection of the whole disk (an
  # empty usr-verity-sig is not valid JSON) and gpt-auto then mounts nothing. systemd skips the
  # label (src/shared/dissect-image.c) and sysupdate expects it.

  "20-usr-b" = {
    Partition = {
      Type = "usr";
      Label = "_empty"; # empty slot: gpt-auto skips it, sysupdate fills it
      SizeMinBytes = "10G";
      SizeMaxBytes = "10G";
      Weight = 0;
      # slot A's flags: sysupdate keeps a slot's flags when it writes it (image/sysupdate.nix)
      ReadOnly = true;
      GrowFileSystem = false;
      # Empty until first update
    };
  };

  "21-usr-b-verity" = {
    Partition = {
      Type = "usr-verity";
      Label = "_empty"; # empty slot: gpt-auto skips it, sysupdate fills it
      SizeMinBytes = "128M";
      SizeMaxBytes = "128M";
      Weight = 0;
    };
  };

  "22-usr-b-verity-sig" = {
    Partition = {
      Type = "usr-verity-sig";
      Label = "_empty"; # empty slot: gpt-auto skips it, sysupdate fills it
      SizeMinBytes = "16K";
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
      # The mount points, each needed before anything can create it: the initrd mounts root
      # read-only (gpt-auto's default without rw=). /usr is the verity slot's. /dev /proc /sys
      # /run: switch-root chases them in the new root without creating them
      # (systemd src/shared/switch-root.c, chase() without CHASE_NONEXISTENT). /tmp: tmp.mount
      # makes its mount point with mkdir, which a read-only root refuses. There is no /srv:
      # service state lives in /var/lib. /bin /sbin /lib are tmpfiles links (/base).
      MakeDirectories = "/usr /etc /var /home /root /tmp /run /dev /proc /sys";
    };
  };
}
