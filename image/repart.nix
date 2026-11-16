# systemd-repart partition definitions, rendered to /usr/lib/repart.d/*.conf at build time.
# The builder sets what a definition cannot hold: the labels (the sysupdate target patterns with
# the version, image/sysupdate.nix), the files to copy, and the usr-a and usr-a-verity UUIDs. They
# are the first and second 16 bytes of the dm-verity root hash, for GPT auto-discovery.
# Slot B is `_empty`, how sysupdate recognizes a free slot. `30-root` is made on the machine.
{
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

  "30-root" = {
    Partition = {
      Type = "root";
      Label = "root";
      Format = "ext4";
      SizeMinBytes = "512M";
      GrowFileSystem = true;
      FactoryReset = true;
      # The mount points and top-level directories. /dev /proc /sys /run must exist:
      # switch-root chases them in the new root without creating them
      # (systemd src/shared/switch-root.c, chase() without CHASE_NONEXISTENT). /usr is the
      # verity slot's mount point. The cmdline's rw makes the root writable in the initrd (the
      # first boot needs it for /etc/machine-id, image/uki.nix); making every directory here
      # also lets sysroot-usr.mount and tmp.mount find theirs on a root mounted read-only. There is
      # no /srv: service state lives in /var/lib. /bin /sbin /lib are tmpfiles links (/base).
      MakeDirectories = "/usr /etc /var /home /root /tmp /run /dev /proc /sys";
    };
  };
}
