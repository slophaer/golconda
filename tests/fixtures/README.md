# Test SSH Key Pair for Boot Tests

This key pair is a TEST FIXTURE, not a secret. It is used by scripts/boot-test to authenticate SSH
connections during testing. The image trusts the public key via authorizedKeys.

Files:

- snakeoil-ssh.pub: Public key (trusted by the image, committed)
- snakeoil-ssh: Private key (used by test script, committed)

These keys are intentionally committed because:

1. They are test-only fixtures, not production secrets
1. Both keys must be available: public at build time, private at test time
1. The keys have no value outside this test harness

To regenerate (if needed): ssh-keygen -t ed25519 -N '' -f snakeoil-ssh -C "golconda-boot-test" Then
update nix/default.nix to read the new public key.

## Test SSH certificate authorities

`snakeoil-user-ca` and `snakeoil-host-ca` (with their `.pub` halves) are the boot test's two OpenSSH
CAs, test fixtures like the key above. The test image trusts `snakeoil-user-ca.pub` in
`TrustedUserCAKeys` (nix/default.nix); scripts/boot-test signs user certificates with the private
half at test time, and signs the machine's host key with `snakeoil-host-ca` before it pushes the
host certificate with `golconda vars`. To regenerate:
`ssh-keygen -t ed25519 -N '' -C 'golconda-boot-test user CA' -f snakeoil-user-ca`, and the same for
the host CA.

## Public halves of an image key set

`public-keys/` holds `secureboot/db.crt`, `pcr/pcr.pub` and `release/index.pgp` in the layout of
`scripts/make-keys`, and nothing else: the private halves were deleted when the set was made. The
eval tests in `tests/real-packages/image-config.nix` give the directory to `lib.mkImage` as
`publicKeys`, which reads only these three files. Nothing signs with it; the test images sign with
throwaway keys made in the store (`lib/image/default.nix` `throwawayKeys`). To regenerate, run
`scripts/make-keys` into a scratch directory and copy the three files.

## Test CA certificates (`ca-store/`)

The CA store's tests (`checks.ca-store`, the boot test's `tls-*` markers) need certificates that
chain to a CA the image trusts, and to one it distrusts. All of it is test data, with no value
outside the tests:

- `anchor-ca.crt`: a CA the test images name in `/trust.anchors`. `server-anchor.{crt,key}` is a
  server certificate it issued, for the IP address `169.254.169.5`.
- `distrusted-ca.crt`: a CA that the test images name in both `anchors` and `distrust`; distrust
  wins. `server-distrusted.{crt,key}` is its server certificate, for `169.254.169.6`.
- `mozilla-root.crt`: one of Mozilla's roots (COMODO ECC Certification Authority, from cacert),
  which the test images list in `distrust`. The package test of `ca-bundle` checks that cacert has
  it, so a cacert update that drops it fails there and not silently here.

Both CAs are EC P-256 and valid from 2020-01-01 to 2120-01-01, so the guest's clock does not matter.
The CAs' private keys are not kept: the two server certificates are all the tests need. The server
keys are committed because the boot test serves TLS with them. To regenerate, make two CAs and sign
each server certificate with `openssl ca -startdate 20200101000000Z -enddate 21200101000000Z`,
`subjectAltName = IP:<address>`, `extendedKeyUsage = serverAuth`.
