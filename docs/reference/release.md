# Making a release

This page is the procedure: make a deployment key set, build a release signed with it, and enrol its
certificate in the firmware. The key layout and the reason for each key are in
[Trust: Deployment keys](../design/trust.md#deployment-keys); the files a release holds are in
[Releases](../design/releases.md).

| step                        | needs                                                                                  |
| --------------------------- | -------------------------------------------------------------------------------------- |
| 1. make the key set         | `openssl` with `-addext` (OpenSSL 1.1.1 or later), and `gpg` (GnuPG 2.2 or later)      |
| 2. keep it out of the store | `extra-sandbox-paths` on the build daemon, and build users that can read the directory |
| 3. build                    | a build host with the daemon of [Build host](build-host.md), `golconda`, git           |
| 4. publish `release/`       | an update source rclone reaches, and `/system.updateSource` on the machine             |
| 5. enrol the certificate    | firmware setup, or the `KEK` private key for an authenticated `db` append              |
| 6. rotate                   | the old key set, and the same firmware access                                          |

## 1. Make the key set

```sh
scripts/make-keys /srv/golconda-keys
```

The directory must be absolute, because `lib.mkImage` takes it as a string path and refuses a
relative one. The script refuses a directory that exists and is not empty, creates the directory
with mode `0700` and every file with mode `0600`, and prints the paths, what each key signs and the
certificate's SHA-256 fingerprint. It never prints key material.

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
certificate (systemd 262, `systemd-sbsign(1)`), and `lib/image/uki.nu` checks each verity root hash
signature against the certificate alone, so a key and certificate that do not match fail the build
and not the boot. Keep the set: a rotation uses the old `pcr/` key and the old certificate (step 6).

**Unverified:** no check in this repository runs this script. A check that runs it into a temporary
directory, inspects the modes and the certificate, and signs with the `db` key would test it.

## 2. Keep the private keys out of the store

Pass the directory as a string:

```nix
keys = "/srv/golconda-keys";
```

A string is not copied: the derivation names the path, and the builder reads the files where they
are. The daemon must show the directory to the sandbox with `extra-sandbox-paths` in its own
`nix.conf`, and the build users must be able to read it
([Build host: Keys in the sandbox](build-host.md#keys-in-the-sandbox)). A path value
(`keys = ./golconda-keys;`, or an unquoted absolute path) copies the whole directory into the store,
private keys included, until a garbage collection removes it; a remote builder gets a copy too
([Trust: How the private keys reach the build](../design/trust.md#how-the-private-keys-reach-the-build)).

The directory must be on the machine whose daemon builds the image: with a remote builder, that is
the builder, not the client. The derivation names only the path, not the file contents, so new keys
under the same path rebuild nothing. Put a new set under a new path (step 6).

A daemon that builds in a chroot store (`--store local?root=DIR`) copies only the derivation's
inputs into a fresh root directory. A string is not an input, so the builder sees nothing at that
path and signing stops with `Failed to load X.509 certificate from … No such file or directory`. On
such a daemon use the path form, and accept the store copy.

**Unverified:** no test builds an image with a string key directory. A build on a daemon with the
`extra-sandbox-paths` line, then a boot test of the result, would test it. The path form was used to
build the two releases of the real-key boot test ([`image.md`](image.md)).

## 3. Build

Run this in the configuration repository on the build host, with a clean working tree:

```sh
golconda release build -f server.toml --keys /srv/golconda-keys
```

`golconda release build` (console/README.md) picks the version (`--version auto`: today's date and
the revision after the document's `/system.version`, and after what `--to DEST` serves), writes it
into `server.toml`, builds the image, checks the release directory (step 4) and commits the version
line as `release: <id> <version>`. The commit's trailers record the document's digest, the four
files' digests and the store path, so `git log` finds the source of each release; a failed build
puts the line back and commits nothing. It refuses a version that is not newer than the last one:
sysupdate would install nothing and say nothing. The output is linked at `result-release`.

By hand, the same build is:

```sh
iets build -E '((import ./default.nix).lib.mkImage {
  config = ./server.toml;
  keys = "/srv/golconda-keys";
}).disk'
```

`config` is what `lib.mkSystem` takes: a TOML path or an option set. `pcrKeys` (default: `keys`)
names a second directory, read for `pcr/` only, and `indexKeys` (default: `keys`) one read for
`release/` only: a key set made before it had a release key gets one from a second `make-keys` run.
`system` (default: `builtins.currentSystem`) is the build host. The expression returns seven
attributes, `erofs` to `disk` plus `release`, listed in
[Outputs: `lib.mkImage`](outputs.md#libmkimage). `disk` needs every other step; its output holds
`disk.raw`, `disk.json` and `release/`. `nix-build -E` with the same expression prints the output
path; iets 0.2 builds the content-addressed disk but finds no output path for it ("built, but the
builder has no output path"), which is why `golconda release build` uses `nix-build`.

Verification: two releases were built from the path form (`keys = /srv/keys;`) and both booted with
`--secure-boot --keys` and the whole update test ([What is proven](../proven.md)). **Unverified:**
no build uses the string form. It is the one that keeps the private keys out of the store, so a
build with `keys = "/srv/golconda-keys";` and a boot of its disk would test it.

## 4. Publish the release directory

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

Verification: `scripts/boot-test --next` serves `release/` on `127.0.0.1:8074` (`10.0.2.2:8074` in
the guest) and rewrites no transfer file. The markers `http-source` and `http-fetch` show that the
guest read its own `Type=url-file` definition and fetched each file over HTTP, and `index-signed`
that it fetched `SHA256SUMS.gpg`; with `BOOT_TEST_TAMPER_INDEX=1` the index the server sends has one
byte more than its signature covers, and the update installs nothing.

## 5. Enrol the certificate in the firmware

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

## 6. Rotate a key

A `db` rotation signs the next loader, UKIs and verity root hashes with a new key. The PCR key and
the release key do not change, so make a second set with `scripts/make-keys` and keep the first:

```nix
let
  f = import ./default.nix;
in
(f.lib.mkImage {
  config = ./server.toml;
  keys = "/srv/golconda-keys-2"; # the new db key
  pcrKeys = "/srv/golconda-keys"; # the old set: the PCR key stays
  indexKeys = "/srv/golconda-keys"; # and the release key: the running image trusts only it
}).disk
```

Both certificates must be in `db` while a slot still holds a release signed with the old key, and
the old certificate goes to `dbx` only after both slots hold a release signed with the new one. The
order of the steps, and what firmware refuses at each, are in
[Boot loader: Key rotation](../design/bootloader.md#key-rotation).

The boot test runs a rotation against OVMF with `virt-fw-vars`
(`scripts/boot-test --next DIR --rotate`). **Unverified:** a rotation on a machine's own firmware. A
rotation on the machine, with a boot of each slot, would test it.
