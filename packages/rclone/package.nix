# rclone, the copy tool `golconda release publish` uploads a release with: one program for every
# destination (a local directory, S3 and S3-compatible stores, SFTP, ...), configured by the
# operator's rclone.conf. Not part of an image: it goes on PATH beside golconda on the deploy host
# (docs/reference/release.md), and scripts/boot-test publishes with it.
{
  package,
  sources,
  fetch,
}:
package {
  name = "rclone";
  uses = [ "go" ];
  go = {
    packages = [ "." ];
    # rclone prints fs.Version; unset it is VersionTag + "-DEV"
    ldflags = [ "-X github.com/rclone/rclone/fs.Version=v${sources.version}" ];
    # the backends' tests want their services; these two run offline
    testPackages = [
      "./fs/hash/..."
      "./lib/encoder/..."
    ];
    # module hashes in the format of repkgs' locks/go.toml, for this package alone
    deps = fetch.goModules {
      source = sources.fetch "default";
      locks = ./locks/go.toml;
    };
  };
  bin = [ "rclone" ];
}
