# systemd-sysupdate transfer definitions, rendered to /usr/lib/sysupdate.d/*.transfer by the
# composer (modules/system), with Path= set from /system.updateSource. InstancesMax=2 keeps two
# versions (A/B) and ProtectVersion=%A keeps the booted one.
# `slots` is the naming contract that the disk builder (lib/image/disk.nix) shares: the GPT label
# of an installed instance (a free slot is `_empty`) and the release artifact name after
# `<imageId>_`. The patterns, the 36-character GPT limit and the `@u` UUID: docs/reference/image.md,
# "A release". Called as a function: { imageId; updateSource; } -> transfers.
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
    # systemd-pull fetches SHA256SUMS.gpg beside SHA256SUMS and checks it against
    # /usr/lib/systemd/import-pubring.pgp (lib/image/index.nix), which the signer signs with the
    # release key (docs/design/releases.md). systemd 262 verifies only OpenPGP here, so the image
    # carries GnuPG and libgcrypt beside OpenSSL.
    Verify = true;
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
