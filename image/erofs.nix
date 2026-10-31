# erofs image configuration
#
# Controls how the /usr erofs image is built.
#
# CRITICAL: The timestamp must increase per version so that ConditionNeedsUpdate=
# fires on first boot of each new image. systemd-update-done.service touches
# /etc/.updated and /var/.updated to /usr's mtime; services like systemd-sysusers,
# systemd-tmpfiles, systemd-hwdb-update only run when /usr is newer.
#
# See: systemd.unit(5) ConditionNeedsUpdate=, systemd-update-done(8)
{
  # Compression algorithm
  compression = "lz4hc";

  # The timestamp comes from the version: lib/usr-tree.nix versionToEpoch computes the -T
  # argument for mkfs.erofs and throws on a version that is not YYYYMMDD.N.
  #
  # Version format: YYYYMMDD.N (e.g., 20261031.1)
  # Epoch formula: parse date to epoch, add N seconds for revision ordering
  #
  # Example: 20261031.1 -> 1793404800 + 1 = 1793404801
  #          20261031.2 -> 1793404800 + 2 = 1793404802
  #
  # This ensures:
  # 1. Each version has a unique, increasing timestamp
  # 2. Images are reproducible (same version = same timestamp)
  # 3. ConditionNeedsUpdate= fires exactly once per new version

  # mkfs.erofs arguments (in addition to -T and compression)
  extraArgs = [ ];
}
