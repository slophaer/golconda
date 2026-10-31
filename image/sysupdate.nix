# systemd-sysupdate transfer definitions
#
# Rendered to /usr/lib/sysupdate.d/*.conf on the image.
# Defines how updates are fetched and applied.
#
# All transfers use InstancesMax=2 to keep exactly two versions (A/B).
# ProtectVersion=%A prevents overwriting the currently booted version.
#
# The update source URL is /system.updateSource: the composer renders these
# definitions into /usr/lib/sysupdate.d/ with Path= set when it is given.
#
# See docs/reference/image.md for artifact naming conventions.
{
  imageId,
  updateSource ? null,
}:
{
  "10-usr" = {
    Transfer = {
      ProtectVersion = "%A";
    };
    Source = {
      Type = "url-file";
      Path = updateSource;
      MatchPattern = "${imageId}_@v.usr.raw";
    };
    Target = {
      Type = "partition";
      MatchPartitionType = "usr";
      Path = "auto";
      InstancesMax = 2;
    };
  };

  "20-usr-verity" = {
    Transfer = {
      ProtectVersion = "%A";
    };
    Source = {
      Type = "url-file";
      Path = updateSource;
      MatchPattern = "${imageId}_@v.usr-verity.raw";
    };
    Target = {
      Type = "partition";
      MatchPartitionType = "usr-verity";
      Path = "auto";
      InstancesMax = 2;
    };
  };

  "30-usr-verity-sig" = {
    Transfer = {
      ProtectVersion = "%A";
    };
    Source = {
      Type = "url-file";
      Path = updateSource;
      MatchPattern = "${imageId}_@v.usr-verity-sig.raw";
    };
    Target = {
      Type = "partition";
      MatchPartitionType = "usr-verity-sig";
      Path = "auto";
      InstancesMax = 2;
    };
  };

  "40-uki" = {
    Transfer = {
      ProtectVersion = "%A";
    };
    Source = {
      Type = "url-file";
      Path = updateSource;
      MatchPattern = "${imageId}_@v.efi";
    };
    Target = {
      Type = "regular-file";
      Path = "/EFI/Linux";
      # Match existing entries with boot counting, or plain .efi
      MatchPattern = [
        "${imageId}_@v+@l-@d.efi"
        "${imageId}_@v.efi"
      ];
      Mode = "0644";
      TriesLeft = 3;
      TriesDone = 0;
      InstancesMax = 2;
    };
  };
}
