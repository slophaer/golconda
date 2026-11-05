# Garage, an S3-compatible object store (Rust): the S3 endpoint the release tool's tests publish to
# through rclone (`golconda release publish`), as a bucket on Hetzner Object Storage or any other
# S3 store would be in production. A test tool, not part of an image. Built lean: one database
# (lmdb), linking our libsodium and zstd, no metrics and no K2V API.
{ package }:
package {
  name = "garage";
  uses = [ "cargo" ];
  cargo = {
    # the binary is the `garage` crate of the workspace
    flags = [
      "--package"
      "garage"
    ];
    noDefaultFeatures = true;
    features = [
      "system-libs"
      "lmdb"
    ];
  };
  # upstream's integration tests start servers and use the K2V API and metrics, which this build
  # leaves out; tests/packages/garage/test.nu starts one node instead
  tests.run = false;
  bin = [ "garage" ];
}
