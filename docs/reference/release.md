# Making a release

This page is the procedure: make a deployment key set, build a release signed with it, and enrol its
certificate in the firmware. The key layout and the reason for each key are in
[Trust: Deployment keys](../design/trust.md#deployment-keys); the files a release holds are in
[Releases](../design/releases.md).

| step                     | needs                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------ |
| 1. make the key set      | a build daemon: the script builds its own `openssl` and `gnupg` (`scripts/tools.sh`) |
| 2. build and sign        | the release host: the daemon of [Build host](build-host.md), `golconda`, git         |
| 3. publish `release/`    | an update source rclone reaches, and `/system.updateSource` on the machine           |
| 4. enrol the certificate | firmware setup, or the `KEK` private key for an authenticated `db` append            |
| 5. rotate                | the old key set, and the same firmware access                                        |

## 1. Make the key set

```sh
scripts/make-keys /srv/golconda-keys
```

The script refuses a relative directory and a directory that exists and is not empty, creates the
directory with mode `0700` and every file with mode `0600`, and prints the paths, what each key
signs and the certificate's SHA-256 fingerprint. It never prints key material. Keep the directory on
the release host: no build reads the private keys, and no step copies them
([Trust: Signing outside Nix](../design/trust.md#signing-outside-nix)).

| file                | what it does                                                         |
| ------------------- | -------------------------------------------------------------------- |
| `secureboot/db.key` | signs systemd-boot, each UKI and each verity root hash               |
| `secureboot/db.crt` | the certificate for those signatures; the firmware `db` must hold it |
| `pcr/pcr.key`       | signs the PCR 11 policy (`.pcrsig`) in each UKI                      |
| `pcr/pcr.pub`       | the public half, embedded in each UKI as `.pcrpkey`                  |
| `release/index.key` | signs each release's `SHA256SUMS` (OpenPGP Ed25519, armored secret)  |
| `release/index.pgp` | the public half (binary), the image's keyring for `Verify=yes`       |

`db.crt` is a self-signed PEM X.509 certificate, valid for 3650 days, with `CA:TRUE`,
`digitalSignature`, `keyCertSign`, `cRLSign` and `codeSigning`. `systemd-sbsign` takes a PEM
certificate (systemd 262, `systemd-sbsign(1)`). The signer checks each private key against its
public half and each verity root hash signature against the certificate, so a key and certificate
that do not match fail the release and not the boot. Keep the set: a rotation uses the old `pcr/`
key and the old release key (step 5).

`tests/make-keys/run.sh` (run by `scripts/lint`) runs the script into a temporary directory and
checks the layout, the modes, the certificate's extensions and that each key matches its public
half.

## 2. Build and sign

Run this in the configuration repository on the release host, with a clean working tree:

```sh
golconda release build -f server.toml --keys /srv/golconda-keys
```

`golconda release build` ([Commands](cli.md#golconda-release)) picks the version (`--version auto`:
today's date and the revision after the document's `/system.version`, and after what `--to DEST`
serves) and writes it into `server.toml`. Then it builds and signs in two steps:

1. `nix-build` builds `lib.mkImage`'s `unsigned` output: the `/usr` tree, the initrd, the kernel and
   a manifest, all unsigned. Nix gets the key directory as a string and copies its three public
   halves into the store, each file alone ([Outputs: `lib.mkImage`](outputs.md#libmkimage)).
1. The signer of that output (`unsigned/sign`) runs on this host with the key directory. It makes
   the erofs image with the signed loader in it, the verity tree and its signature, the UKI, the
   disk and the release directory, and signs `SHA256SUMS`
   ([Trust: Signing outside Nix](../design/trust.md#signing-outside-nix)).

The release goes to `--out`, a new directory (default `result-release`): `disk.raw`, `disk.json`,
`release/`, and `unsigned`, the link to the unsigned outputs. Then the command checks the release
directory (step 3) and commits the version line as `release: <id> <version>`. The commit's trailers
record the document's digest, the four files' digests and the unsigned outputs' store path, so
`git log` finds the source of each release. A failed build or signature removes the directory and
puts the line back, and commits nothing. The command refuses an existing `--out`, and a version that
is not newer than the last one: sysupdate would install nothing and say nothing.

By hand, the same two steps are:

```sh
nix-build -o unsigned -E '((import ./default.nix).lib.mkImage {
  config = ./server.toml;
  publicKeys = "/srv/golconda-keys";
}).unsigned'
unsigned/sign unsigned --keys /srv/golconda-keys --out release-dir
```

`config` is what `lib.mkSystem` takes: a TOML path or an option set. `publicKeys` is a string or a
path; either way only `secureboot/db.crt`, `pcr/pcr.pub` and `release/index.pgp` are copied. A
repository can also commit the three public files and name them as a path, which a flake needs: pure
evaluation reads no absolute path outside the store. `system` (default: `builtins.currentSystem`) is
the build host. `nix-build` prints the output path; iets 0.2 builds the content-addressed output but
finds no path for it ("built, but the builder has no output path"), which is why
`golconda release build` uses `nix-build`.

Verification: a release built and signed this way with a fresh key set booted with `--secure-boot`,
and so did its next release over HTTP *(being built)*.

## 3. Publish the release directory

`release/` holds the four release files, `SHA256SUMS` and `SHA256SUMS.gpg`. The names, the fixed
line order and what a version means are in
[Releases: The release directory](../design/releases.md#the-release-directory); do not rename or
reorder the files. Serve this directory at the URL `/system.updateSource` names; a machine with that
option set fetches the release from it ([Image artifacts: A release](image.md#a-release)).

```sh
golconda release check result-release/release --keys /srv/golconda-keys
golconda release publish result-release/release --to hetzner:updates/web --keys /srv/golconda-keys
golconda release list --to hetzner:updates/web
```

`check` verifies the index (four lines, fixed order, every digest), the names and the signature
against `release/index.pgp`, the key the machines carry. `publish` checks, then uploads through
rclone to a local directory (an HTTP server's root) or any rclone remote (S3 and S3-compatible
stores, SFTP): the four files first, the signature and the index last. It refuses a version that is
not newer than the one the destination serves, the same version with other files, and a release
whose release commit records other digests or that has none (unless `--unrecorded`, for a release
built by hand). It deletes nothing, so the older release's files stay for a cache that still serves
its index. For an S3 bucket, the release prefix needs anonymous `GET`: sysupdate sends no
credentials, and every file is checked against the signed index anyway.

Verification: `scripts/boot-test --next` serves `release/` on `127.0.0.1:8074` (`169.254.169.2:8074`
in the guest) and rewrites no transfer file. The markers `http-source` and `http-fetch` show that
the guest read its own `Type=url-file` definition and fetched each file over HTTP, and
`index-signed` that it fetched `SHA256SUMS.gpg`; with `--tamper-index` the index the server sends
has one byte more than its signature covers, and the run passes only when `sysupdate-refused` shows
that the update installed nothing.

## 4. Enrol the certificate in the firmware

Firmware must hold `secureboot/db.crt` in `db`. It verifies the signed loader and UKI with that
certificate, and the kernel checks each verity root hash signature against the `db` in the platform
keyring ([Trust: Deployment keys](../design/trust.md#deployment-keys)). Enrol the certificate only;
the private keys stay on the build host and never enter the image.

How the variable is written depends on the machine. Firmware setup can enrol a certificate. The
image cannot change `db` or `dbx` itself, and systemd-boot enrols keys from `loader/keys/` only in
setup mode ([Boot loader: What is not possible](../design/bootloader.md#what-is-not-possible)). From
a running machine, `bootctl reboot-to-firmware true` and a reboot reach the firmware menu
([Boot loader: Recovery](../design/bootloader.md#recovery)). The boot test writes an OVMF variable
store offline with `virt-fw-vars --add-db` (`scripts/boot-test`).

**Unverified:** this repository has no procedure for a machine's own firmware. A boot of the
release's `disk.raw` after an enrolment in firmware setup would test it.

## 5. Rotate a key

A `db` rotation signs the next loader, UKIs and verity root hashes with a new key. The PCR key and
the release key do not change, so make a second set with `scripts/make-keys` and keep the first:

```sh
golconda release build -f server.toml --keys /srv/golconda-keys-2 \
  --pcr-keys /srv/golconda-keys --index-keys /srv/golconda-keys
```

`--keys` gives the new `db` key; `--pcr-keys` and `--index-keys` name the old set, whose PCR key and
release key stay: the running image trusts only its own release key. Nix copies the public halves
from the same three places (`publicKeys`, `pcrPublicKeys`, `indexPublicKeys` of `lib.mkImage`).

Both certificates must be in `db` while a slot still holds a release signed with the old key, and
the old certificate goes to `dbx` only after both slots hold a release signed with the new one. The
order of the steps, and what firmware refuses at each, are in
[Boot loader: Key rotation](../design/bootloader.md#key-rotation).

The boot test runs a rotation against OVMF with `virt-fw-vars`
(`scripts/boot-test --next DIR --rotate`). **Unverified:** a rotation on a machine's own firmware. A
rotation on the machine, with a boot of each slot, would test it.
