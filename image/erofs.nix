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

  # Derive timestamp from IMAGE_VERSION
  # The builder calls versionToEpoch to compute -T argument for mkfs.erofs
  #
  # Version format: YYYYMMDD.N (e.g., 20261030.1)
  # Epoch formula: parse date to epoch, add N seconds for revision ordering
  #
  # Example: 20261030.1 -> 1730246400 + 1 = 1730246401
  #          20261030.2 -> 1730246400 + 2 = 1730246402
  #
  # This ensures:
  # 1. Each version has a unique, increasing timestamp
  # 2. Images are reproducible (same version = same timestamp)
  # 3. ConditionNeedsUpdate= fires exactly once per new version
  timestampFromVersion = true;

  # Fallback for non-date versions (e.g., "1", "2", "test")
  # Uses revision number directly as offset from a base epoch
  baseEpoch = 1609459200; # 2021-01-01 00:00:00 UTC

  # mkfs.erofs arguments (in addition to -T and compression)
  extraArgs = [ ];
}
