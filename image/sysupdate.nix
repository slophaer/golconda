# systemd-sysupdate transfer definitions
#
# Rendered to /usr/lib/sysupdate.d/*.transfer on the image (modules/system).
# Defines how updates are fetched and applied.
#
# All transfers use InstancesMax=2 to keep exactly two versions (A/B).
# ProtectVersion=%A prevents overwriting the currently booted version.
#
# The update source URL is /system.updateSource: the composer renders these
# definitions into /usr/lib/sysupdate.d/ with Path= set when it is given.
#
# The naming contract (`slots`) is shared with the disk builder (lib/image/disk.nix), which labels
# slot A and names the release artifacts from the same patterns:
#   - label: the GPT partition label of an installed instance. sysupdate finds an installed
#     version by this pattern and writes it, formatted, as the label of the slot it fills; a free
#     slot is `_empty` (image/repart.nix). The partition type already tells the transfers apart,
#     so the label carries only a short kind and the version, never the image id: GPT allows 36
#     characters, and `usr-verity-sig_` (15) leaves 21 for the version (YYYYMMDD.N is 10 + N's digits).
#   - artifact: the release file name after `<imageId>_`. The data and hash files carry `@u`, the
#     partition UUID systemd derives from the verity root hash (usr: its first 128 bits,
#     usr-verity: its last); sysupdate sets the written partition's UUID from it, so the new UKI's
#     usrhash= finds the new slot. The signature has no hash-derived UUID (its JSON names the root
#     hash), so its name has no `@u`.
#
# Called as a function ({ imageId; updateSource; } → transfers); `slots` is the contract.
#
# See docs/reference/image.md for artifact naming conventions.
let
  bootCounting = import ./boot-counting.nix;
  slots = {
    usr = {
      label = "usr_@v";
      artifact = "@v.usr.@u.raw";
    };
    usr-verity = {
      label = "usr-verity_@v";
      artifact = "@v.usr-verity.@u.raw";
    };
    usr-verity-sig = {
      label = "usr-verity-sig_@v";
      artifact = "@v.usr-verity-sig.raw";
    };
  };

  transfer = {
    ProtectVersion = "%A";
    Verify = false; # v1: trust is verity-sig + Secure Boot, no SHA256SUMS.gpg (docs/design/updates.md)
  };

  # one partition transfer: the artifact from the source, the slot found and labelled by `label`
  partition = imageId: updateSource: type: {
    Transfer = transfer;
    Source = {
      Type = "url-file";
      Path = updateSource;
      MatchPattern = "${imageId}_${slots.${type}.artifact}";
    };
    Target = {
      Type = "partition";
      MatchPartitionType = type;
      Path = "auto";
      MatchPattern = slots.${type}.label;
      InstancesMax = 2;
      # No ReadOnly= or PartitionGrowFileSystem=: systemd 262.1 sets them while the partition
      # has its "pending" type, which knows no flags, so they do nothing. The written slot keeps
      # the flags the builder gave it (image/repart.nix).
    };
  };

  transfers =
    {
      imageId,
      updateSource ? null,
    }:
    {
      "10-usr" = partition imageId updateSource "usr";
      "20-usr-verity" = partition imageId updateSource "usr-verity";
      "30-usr-verity-sig" = partition imageId updateSource "usr-verity-sig";

      "40-uki" = {
        Transfer = transfer;
        Source = {
          Type = "url-file";
          Path = updateSource;
          MatchPattern = "${imageId}_@v.efi";
        };
        Target = {
          Type = "regular-file";
          Path = "/EFI/Linux";
          # on the ESP (or XBOOTLDR), not the root file system
          PathRelativeTo = "boot";
          # Match existing entries with boot counting, or plain .efi
          MatchPattern = [
            "${imageId}_@v+@l-@d.efi"
            "${imageId}_@v.efi"
          ];
          Mode = "0644";
          TriesLeft = bootCounting.triesLeft;
          TriesDone = bootCounting.triesDone;
          InstancesMax = 2;
        };
      };
    };
in
{
  inherit slots;
  __functor = _: transfers;
}
