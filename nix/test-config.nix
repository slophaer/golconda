# The test image's configuration (nix/default.nix: image-smoke-test and its variants), a function
# of { version; adminVars ? false; }. checks.sbom-schema reads the same configuration, so the
# SBOM it validates is the test image's.
let
  on = import ../modules/lib/on.nix;
in
# Boot test image: authorizedKeys for testing SSH login.
# The test SSH keypair is a committed test fixture (tests/fixtures/snakeoil-ssh*).
# See tests/fixtures/README.md for why both keys are committed.
# adminVars: the release after the bootstrap. The first release logs in with the plain
# test key and trusts the test user CA; scripts/boot-test pushes the host certificate and the
# revocation list to it with `golconda vars`, and the next release turns both on
# (the bootstrap in docs/design/trust.md).
{
  version,
  adminVars ? false,
}:
{
  # the configured workload is a downstream module (tests/fixtures/image-workload/modules)
  golconda.modules = ../tests/fixtures/image-workload/modules;
  "/local/test-workload" = { };
  "/system" = {
    name = "boot-test";
    inherit version;
    # The update test's release server: 169.254.169.2 is the gateway of the test's QEMU
    # user network (169.254.169.0/24, for --imds: the metadata address 169.254.169.254
    # must be on the link), and the test forwards the guest's connections to port 8074
    # there to a per-run HTTP server of the next release's disk.release/ (guestfwd;
    # docs/reference/image.md). systemd-imds locks only 169.254.169.254.
    updateSource = "http://169.254.169.2:8074/";
  };
  "/services/sshd" = {
    port = 22;
    # The test SSH public key: committed in tests/fixtures/snakeoil-ssh.pub.
    authorizedKeys = [ (builtins.readFile ../tests/fixtures/snakeoil-ssh.pub) ];
    # the test user CA (tests/fixtures/snakeoil-user-ca.pub): a certificate for this
    # principal logs in as root
    trustedUserCAKeys = [ (builtins.readFile ../tests/fixtures/snakeoil-user-ca.pub) ];
    principals.root = [ "boot-test-admin" ];
  }
  // (on adminVars {
    hostCertificate = true;
    revokedKeys = true;
  });
  # cloud metadata: QEMU's DMI names no cloud, so no import runs and no unit fails; a
  # boot test that fakes a cloud's DMI and endpoint imports from it
  "/imds" = { };
}
