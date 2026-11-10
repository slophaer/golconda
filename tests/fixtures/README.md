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
