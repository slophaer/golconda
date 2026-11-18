# Signing outside Nix

Private keys never enter the Nix store or a Nix build. Nix builds every part of the image unsigned;
one program, the signer, signs the parts and assembles the release outside Nix, on the release host.

Nix builds, as `lib.mkImage`'s `unsigned` output:

- the `/usr` tree without the signed loader, the initrd, the kernel, systemd's stub and the unsigned
  systemd-boot;
- `manifest.json`, which names these and every parameter of each step (times, salts, UUIDs and
  seeds, all from the version), the repart definitions and the release file names;
- copies of the three public halves, `db.crt`, `pcr.pub` and `index.pgp`;
- `sign`, the signer, built from the image's own package set.

The signer takes the unsigned output and a key directory. It checks that each private key is the
half of the public key the image carries, then:

1. signs systemd-boot with the `db` key (`systemd-sbsign`);
1. copies the `/usr` tree, puts the signed loader into it and runs `mkfs.erofs`;
1. writes the verity hash tree and signs the root hash with the `db` key (PKCS#7);
1. builds the UKI with `ukify`: the cmdline with `usrhash=` and that signature, the Secure Boot
   signature (`db` key) and `.pcrsig` (PCR key);
1. for an image with Secure Boot, copies the key set's enrolment files to `loader/keys/auto/`
   (`secureboot/auth/microsoft` or `golconda`, by `/system.secureBootMicrosoftKeys`). It checks them
   first against `PK.crt`, `KEK.crt` and the image's `db` certificate (`lib/image/enrol.nu`), and it
   reads no PK or KEK key;
1. writes the ESP and `disk.raw` with `systemd-repart --offline`;
1. writes `release/` with `SHA256SUMS` and signs the index with the release key.

The erofs image is a signer step, not a Nix output, because `/usr` carries the signed loader that
`golconda-loader-update` installs on the ESP
([Boot loader: Key rotation](bootloader.md#key-rotation)). Its bytes depend on a signature, and so
do the root hash, the UKI's cmdline and the disk. A loader outside `/usr` would let Nix build the
erofs image, but it would change how a machine updates its loader. The copy and `mkfs.erofs` take a
few seconds.

`golconda release build` builds the unsigned output with `nix-build` and runs its `sign` with the
release host's key directory. The keys stay where they are. The test images run the same program in
a derivation, with throwaway keys that are test fixtures, so every boot test tests the signer a
release uses. The `db` key and the PCR key can also stay on a hardware token
([Keys on a token](#keys-on-a-token)).

The unsigned outputs depend on the public halves only: the release keyring is in `/usr`, the kernel
holds the `db` certificate, and the manifest carries copies of all three. A new private key with the
same public half is impossible, so the proof is the other way round. A new PCR key changes only the
manifest. A new `db` key changes the manifest and the kernel, and with the kernel the `/usr` tree
that holds it. The initrd and the signer keep their store paths.

No private key enters the image or the machine either; only the certificates are enrolled in
firmware, and the ESP holds them only inside the signed `.auth` files. The test outputs
(`packages.<system>.image-smoke*`) sign with throwaway keys made in the store (`throwawayKeys`) and
link only their public halves as `keys/`.

Nothing private in a checkout enters the store either. Nix reads a checkout's files where they lie,
and a store path is world-readable, so a key or a token beside the source would leak with it. The
checks' source is the files git tracks, with their working-tree contents (`nix/source.nix`): an
untracked or ignored file stays out. `scripts/make-keys` refuses a key directory inside a git work
tree. An image reads modules and packages where they lie. So `golconda release build` and
`scripts/verify` refuse a file that no commit holds there: an untracked file, and an ignored one in
the directories of modules and packages
([Making a release: 2](../reference/release.md#2-build-and-sign)).

Rotation and recovery:

- **The ESP loader**: a new `db` key reaches the ESP with the next release. On that release's first
  good boot, `golconda-loader-update.service` (`modules/base`) copies its signed systemd-boot and
  `loader.conf` from `/usr` to the ESP and keeps the old loader as the fallback copy. The unit runs
  only after `systemd-bless-boot.service`, so a release that fails a health unit installs nothing.
  Running `/usr/lib/golconda/golconda-loader-update` by hand puts a damaged loader back.
  `scripts/boot-test` checks all of this (`loader-update-ran`, `loader-matches-usr`,
  `loader-replaced`, `loader-reinstall`). The steps are in
  [Boot loader: Key rotation](bootloader.md#key-rotation) and [Recovery](bootloader.md#recovery).
- **An installed machine** with a rotated key needs its next UKI and root hash signatures from the
  new key, and its firmware must hold the new certificate. Otherwise Secure Boot and the verity
  check fail ([Trust: Execution policy](trust.md#execution-policy)). With no local console path,
  that enrolment is offline work on the variable store or a reinstall
  ([Factory reset and recovery](../features/factory-reset.md)).

## Keys on a token

A key on a token signs without leaving it: the release host holds no file of it. The signer takes
the `db` key and the PCR key from a PKCS#11 token, such as a YubiKey's PIV applet. The release key
stays a file for now.

| key           | signs                                   | tool and how it reaches the token                                                      |
| ------------- | --------------------------------------- | -------------------------------------------------------------------------------------- |
| `db`          | systemd-boot                            | `systemd-sbsign --private-key-source=provider:pkcs11 --private-key=pkcs11:…`           |
| `db`          | the verity root hash (PKCS#7)           | `openssl smime -provider pkcs11 -inkey pkcs11:…`                                       |
| `db`          | the kernel and the UKI                  | `ukify --signing-provider pkcs11`, which runs `systemd-sbsign` with the provider       |
| PCR           | `.pcrsig`, one signature per phase path | `ukify --signing-provider pkcs11`, which runs `systemd-measure sign` with the provider |
| release index | `SHA256SUMS.gpg` (OpenPGP)              | gpg; no PKCS#11 path *(later)*                                                         |

The OpenSSL side is [pkcs11-provider](https://github.com/latchset/pkcs11-provider), an OpenSSL 3
provider, packaged as a tool of the release host (`packages/pkcs11-provider`). It is not in the
image. systemd 262's tools load it by name (`provider:pkcs11`), and so does `openssl`. The signer
writes an OpenSSL configuration that gives the provider the token's PKCS#11 module and keeps digests
off the token. The digests stay with OpenSSL's default provider, because a module that hashes with
OpenSSL itself (SoftHSM) would otherwise call back into itself and hang. OpenSSL engines are
deprecated in OpenSSL 3, and systemd's `engine:` source is the older path. The provider is the one
in use.

A key set names a key on a token in place of the key file. `secureboot/db.pkcs11` and
`pcr/pcr.pkcs11` hold one line each, the key's URI (RFC 7512). The set stays a directory, because
`lib.mkImage` reads the three public halves from it. The signer checks a token's key against the
public half the image carries, as it checks a file. It reads the public half through the provider.
systemd-measure needs a certificate for a key that comes through a provider. The PCR key has only a
public half, so the signer makes a self-signed certificate with the PCR key for that call.
`--pcrpkey` still embeds the image's `pcr.pub`.

RSA PKCS#1 v1.5, the scheme of both keys, draws no random numbers, so a release signed from the
token is the release signed from the same keys in files, byte for byte. The check
`pkcs11-signed-same` compares the two for the test image, whose keys are on a SoftHSM token
(test-only, `packages/softhsm`), and the boot test boots that image
([What is proven](../proven.md)). A run on a real YubiKey has not been done *(being built)*
([Making a release: A YubiKey](../reference/release.md#a-yubikey)).

**The release key** stays a file: gpg signs `SHA256SUMS`, and gpg reaches a token only as an OpenPGP
card, not through PKCS#11. The signer refuses a `release/index.pkcs11`. A token for the release key
is *(later)* ([Scope](scope.md#later)).
