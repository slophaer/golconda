# Making a release

This page is the procedure: make a deployment key set, build a release signed with it, and enrol its
certificate in the firmware. The key layout and the reason for each key are in
[Trust: Deployment keys](../design/trust.md#deployment-keys); the files a release holds are in
[Releases](../design/releases.md).

| step                     | needs                                                                                                       |
| ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| 1. make the key set      | a build daemon: the script builds its own `openssl`, `gnupg` and `golconda-enrol-auth` (`scripts/tools.sh`) |
| 2. build and sign        | the release host: the daemon of [Build host](build-host.md), `golconda`, git                                |
| 3. publish `release/`    | an update source rclone reaches, and `/system.updateSource` on the machine                                  |
| 4. enrol the certificate | nothing on a machine in Setup Mode; firmware setup on one that has keys                                     |
| 5. rotate                | the old key set, and the same firmware access                                                               |
| 6. keys on a token       | a PKCS#11 token (a YubiKey) and its module, for the `db` and PCR keys                                       |

## Get the tools

`scripts/make-keys`, `scripts/provision-esp` and the `golconda` command come from a Golconda tree,
not from your repository. Use the tree at the revision that your pin names. Read that revision in
your repository, from the uptrack pin or from `flake.lock` ([Pinning Golconda](pinning.md)). With
the plain `fetchTarball` recipe, the revision is in the url of your Nix file.

```sh
# an uptrack pin
rev=$(nix-instantiate --eval -E '(builtins.fromTOML (builtins.readFile ./pins/golconda/sources.toml)).pin.rev' | tr -d '"')
# a flake
rev=$(nix-instantiate --eval -E 'let l = builtins.fromJSON (builtins.readFile ./flake.lock); in l.nodes.${l.nodes.root.inputs.golconda}.locked.rev' | tr -d '"')
```

Clone Golconda outside your repository, because `golconda release build` refuses an untracked file
there. Check out the revision and build `golconda` from it:

```sh
git clone https://github.com/slophaer/golconda ~/golconda
git -C ~/golconda checkout "$rev"
nix-build ~/golconda -A packages.x86_64-linux.golconda-cli -o ~/golconda/result-cli
export PATH=~/golconda/result-cli/bin:$PATH
```

On this page and on [Deploying to Hetzner Cloud](hetzner-cloud.md), `scripts/` is the `scripts/`
directory of that tree, such as `~/golconda/scripts/make-keys`. `nix-build` and the scripts need the
daemon of [Build host](build-host.md): the scripts build their own tools with it. When the pin
moves, check out the new revision and build `golconda` again.

## 1. Make the key set

```sh
scripts/make-keys /srv/golconda-keys
```

The script makes a relative directory absolute. It refuses a directory inside a git work tree (Nix
reads a checkout's files where they lie, and the store is world-readable; `--auth-only` refuses a
set there too). It also refuses a directory that exists and is not empty. It creates the directory
with mode `0700` and every file with mode `0600`, and prints the paths, what each key signs and the
certificate's SHA-256 fingerprint. It never prints key material. Keep the directory on the release
host: no build reads the private keys, and no step copies them
([Signing outside Nix](../design/signing.md)).

The PK and KEK keys go to a second directory beside the set, `DIR.private/` (`PK.key` and `KEK.key`,
mode `0600`, the directory `0700`; new or empty, as `DIR`). The script ends with one line that says
to move it to offline media. No release reads it: only `scripts/make-keys --auth-only` and
`--reuse-pk-kek` do, from that place beside the set.

| file                 | what it does                                                           |
| -------------------- | ---------------------------------------------------------------------- |
| `secureboot/db.key`  | signs systemd-boot, each UKI and each verity root hash                 |
| `secureboot/db.crt`  | the certificate for those signatures; the firmware `db` must hold it   |
| `secureboot/PK.crt`  | the platform key's certificate; its key is `DIR.private/PK.key`        |
| `secureboot/KEK.crt` | the key exchange key's certificate; its key is `DIR.private/KEK.key`   |
| `secureboot/auth/`   | `microsoft/{PK,KEK,db,dbx}.auth`, `golconda/{PK,KEK,db}.auth` (step 4) |
| `pcr/pcr.key`        | signs the PCR 11 policy (`.pcrsig`) in each UKI                        |
| `pcr/pcr.pub`        | the public half, embedded in each UKI as `.pcrpkey`                    |
| `release/index.key`  | signs each release's `SHA256SUMS` (OpenPGP Ed25519, armored secret)    |
| `release/index.pgp`  | the public half (binary), the image's keyring for `Verify=yes`         |

`db.crt` is a self-signed PEM X.509 certificate, valid for 3650 days, with `CA:TRUE`,
`digitalSignature`, `keyCertSign`, `cRLSign` and `codeSigning`. `PK.crt` and `KEK.crt` are the same
without `codeSigning`; each has a key of its own. `golconda-enrol-auth` signs the enrolment files
once, here, with Microsoft's certificates and revocation list (`packages/secureboot-objects`). So a
release needs neither the PK key nor the KEK key: keep `DIR.private` offline. `systemd-sbsign` takes
a PEM certificate (systemd 262, `systemd-sbsign(1)`). The signer checks each private key against its
public half, and each verity root hash signature against the certificate. A key and certificate that
do not match therefore fail the release and not the boot. Keep the set: a rotation uses the old
`pcr/` key and the old release key (step 5). The release key is made at 00:00 UTC of the day before,
so a machine whose clock is at its release's date takes it
([Updates: What an update authenticates](../design/updates.md#what-an-update-authenticates)).
`SOURCE_DATE_EPOCH`, when it is set, is the day of the set in place of today. The test images' set
(`throwawayKeys` in `lib/image/default.nix`) is made by the same script in the store, dated to the
first test release.

**A set without the enrolment files** is refused for a Secure Boot image; the error names the
command for that set. `scripts/make-keys --auth-only DIR` writes `secureboot/auth` into the existing
set and keeps its `db` certificate, with the keys in `DIR.private`. A set with no PK and KEK gets a
pair of its own first. A rotated set has the PK and KEK of another set. Name that set, whose
`KEYS.private` holds the keys: `scripts/make-keys --auth-only --reuse-pk-kek KEYS DIR`.

**The `dbx` is fixed when the files are made.** `auth/microsoft/dbx.auth` holds Microsoft's
revocation list as `packages/secureboot-objects` pins it on the day `make-keys` ran. To take a newer
list, move the package's pin in the Golconda tree (uptrack on `packages/`, with
`UPTRACK_ROOT=packages` as for `pins/` in [Pinning](pinning.md#uptrack-recommended):
`uptrack check secureboot-objects`, `uptrack apply secureboot-objects`). Then bring `DIR.private`
back from offline media to its place beside the set, run `scripts/make-keys --auth-only DIR` (or
`--reuse-pk-kek KEYS DIR` for a rotated set), and put `DIR.private` away again. The next release
carries the new files. That changes only what a machine enrols in Setup Mode. A machine that is
already enrolled keeps the `dbx` it got and ignores the ESP's files. Updating `dbx` on an enrolled
machine (an authenticated append signed by the KEK) is *(later)*
([Scope: Later](../design/scope.md#later)).

`tests/make-keys/run.sh` (run by `scripts/lint`) runs the script into a temporary directory. It
checks the layout, the modes, the certificate's extensions, that each key matches its public half,
that PK, KEK and `db` are three different keys, and that each `.auth` enrols its certificate. It
also checks that `--reuse-pk-kek` keeps the old PK and KEK, and that `--auth-only` adds the files to
an old set and writes them again. It also builds the test images' set and compares its files with
the set it made. `tests/sign/enrol-test.nu` checks the files field by field.

## 2. Build and sign

Run this in the configuration repository on the release host, with a clean working tree:

```sh
golconda release build -f server.toml --keys /srv/golconda-keys
```

`golconda release build` ([Commands](cli.md#golconda-release)) picks the version (`--version auto`:
today's date and the revision after the document's `/system.version`, and after what `--to DEST`
serves). Then it builds and signs in two steps, from a copy of `server.toml` with that version
beside it:

1. `nix-build` builds `lib.mkImage`'s `unsigned` output: the `/usr` tree, the initrd, the kernel and
   a manifest, all unsigned. Nix gets the key directory as a string and copies its three public
   halves into the store, each file alone ([Outputs: `lib.mkImage`](outputs.md#libmkimage)).
1. The signer of that output (`unsigned/sign`) runs on this host with the key directory. It makes
   the erofs image with the signed loader in it, the verity tree and its signature, the UKI, the
   disk and the release directory. Then it signs `SHA256SUMS`
   ([Signing outside Nix](../design/signing.md)).

The release goes to `--out`, a new directory (default `result-release`): `disk.raw`, `disk.json`,
`release/`, and `unsigned`, the link to the unsigned outputs. Then the command checks the release
directory (step 3), writes the version line into `server.toml` and commits it as
`release: <id> <version>`. The commit's trailers record the document's digest, the four files'
digests and the unsigned outputs' store path, so `git log` finds the source of each release. A
failed build, signature, check or commit removes the directory and the copy, leaves `server.toml` as
it was, and commits nothing. The command refuses an existing `--out`, and a version that is not
newer than the last one, because sysupdate would install nothing and say nothing.

Before it builds anything, it also refuses a file that no commit holds, because Nix reads the
checkout's files where they lie. This covers an uncommitted change or an untracked file in the
document's repository or in Golconda's. It also covers any file that git does not track, ignored
ones too, in the directories of modules and packages. Those directories are Golconda's and the
document's: `modules/` and `packages/` beside it, or the ones `[golconda]` names, which must be in a
git work tree. Ignored files elsewhere, such as the `result*` links, do not count.

By hand, the same two steps are:

```sh
nix-build -o unsigned -E '((import ./default.nix).lib.mkImage {
  config = ./server.toml;
  publicKeys = "/srv/golconda-keys";
}).unsigned'
unsigned/sign unsigned --keys /srv/golconda-keys --out release-dir
```

`config` is a TOML path or an option set. `publicKeys` is a string or a path; either way only
`secureboot/db.crt`, `pcr/pcr.pub` and `release/index.pgp` are copied. A repository can also commit
the three public files and name them as a path, which a flake needs: pure evaluation reads no
absolute path outside the store. `system` (default: `builtins.currentSystem`) is the build host;
`golconda release build` passes its `--system` (default: this host's CPU and `-linux`, such as
`x86_64-linux`). `nix-build` prints the output path. iets 0.2 builds the content-addressed output
but finds no path for it ("built, but the builder has no output path"). For that reason
`golconda release build` uses `nix-build`.

Verification: `golconda release build` built and signed two releases with a fresh key set. Both
booted with `--secure-boot --tpm --ssh-test`, the second as an update over HTTP (`--next`). None of
the set's private keys was in the store afterwards. This ran by hand
([What is proven: Not proven](../proven.md#not-proven)).

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
stores, SFTP). It uploads the four files first, and the signature and the index last. It refuses
three things: a version that is not newer than the one the destination serves, the same version with
other files, and a release whose release commit records other digests or that has none (unless
`--unrecorded`, for a release built by hand). It deletes nothing, so the older release's files stay
for a cache that still serves its index. For an S3 bucket, the release prefix needs anonymous `GET`:
sysupdate sends no credentials, and every file is checked against the signed index anyway.

Verification: `scripts/boot-test --next` serves `release/` to the guest at `169.254.169.2:8074`,
through a QEMU guest forward that opens no host port, and rewrites no transfer file. The markers
`http-source` and `http-fetch` show that the guest read its own `Type=url-file` definition and
fetched each file over HTTP. The marker `index-signed` shows that it fetched `SHA256SUMS.gpg`. With
`--tamper-index` the index the server sends has one byte more than its signature covers, and the run
passes only when `sysupdate-refused` shows that the update installed nothing.

## 4. Enrol the certificate in the firmware

Firmware must hold `secureboot/db.crt` in `db`. It verifies the signed loader and UKI with that
certificate. The kernel checks each verity root hash signature against the copy of `db.crt` built
into it, never against the firmware `db` ([Trust: verity key](../design/trust.md#2-verity-key)).
Only certificates are enrolled; the private keys stay on the build host and never enter the image.

**A machine in Setup Mode needs nothing.** The release's ESP carries
`loader/keys/auto/{PK,KEK,db,dbx}.auth` from the key set. By default they hold Microsoft's KEK, UEFI
CAs and revocation list; with `/system.secureBootMicrosoftKeys = false` they hold the set's
certificates alone. On the first boot of `disk.raw` from firmware without a PK, systemd-boot enrols
them, PK last, and resets the machine. On hardware it first warns for 15 seconds, and a key aborts.
The next boot runs with Secure Boot on
([Boot loader: Enrolment](../design/bootloader.md#enrolment)). A new virtual machine has an empty
variable store; hardware gets one when its keys are cleared in firmware setup. This happens on the
first boot of a new disk only. Its first good boot puts `/usr`'s `loader.conf`, which enrols
nothing, on the ESP and removes the files once Secure Boot is on. A machine whose keys are cleared
later is enrolled from a new disk or in firmware setup.

**Firmware with keys.** Firmware that already has a PK ignores the files. Add `secureboot/db.crt` to
`db` in firmware setup, beside the vendor's keys, or clear the keys there and boot again. The image
cannot change `db` or `dbx` itself
([Boot loader: What is not possible](../design/bootloader.md#what-is-not-possible)). From a running
machine, `bootctl reboot-to-firmware true` and a reboot reach the firmware menu
([Boot loader: Recovery](../design/bootloader.md#recovery)).

The boot test runs both. `--secure-boot` writes the set's `PK.crt`, `KEK.crt` and `db.crt` into an
OVMF variable store offline with `virt-fw-vars` (`pk-kek-enrolled`). `--secure-boot --auto-enrol`
boots from the empty store and lets systemd-boot enrol, with and without Microsoft's keys
(`auto-enrolled`, `db-enrolled`, `dbx-enrolled`). It then checks that a second Setup Mode enrols
nothing (`no-reenrol`; `scripts/boot-test`).

**Unverified:** enrolment on a machine's own firmware *(being built)*. Not run: clearing the keys in
a real firmware's setup, the 15-second warning on its console, that firmware accepting the four
files, option ROMs running after the enrolment with Microsoft's keys, and adding `db.crt` beside a
vendor's keys.

## 5. Rotate a key

A `db` rotation signs the next loader, UKIs and verity root hashes with a new key. The PCR key and
the release key do not change, and neither do the PK and the KEK. So make a second set that keeps
the first set's PK, KEK and release key, and keep the first:

```sh
scripts/make-keys --reuse-pk-kek /srv/golconda-keys /srv/golconda-keys-2
golconda release build -f server.toml --keys /srv/golconda-keys-2 --pcr-keys /srv/golconda-keys
```

`--keys` gives the new `db` key and the release key, a copy of the old set's. The running image
trusts only its own release key, and the release key cannot change yet. `--pcr-keys` names the old
set, whose PCR key stays. Nix copies the public halves from the same two places (`publicKeys`,
`pcrPublicKeys` of `lib.mkImage`).

Both certificates must be in `db` while a slot still holds a release signed with the old key. The
old certificate goes to `dbx` only after both slots hold a release signed with the new one. The
order of the steps, what firmware refuses at each, and the two reseals of the vars around them are
in [Boot loader: Key rotation](../design/bootloader.md#key-rotation).

The boot test runs a rotation against OVMF with `virt-fw-vars`
(`scripts/boot-test --next DIR --rotate`). **Unverified:** a rotation on a machine's own firmware. A
rotation on the machine, with a boot of each slot, would test it.

## 6. Keys on a token

The `db` key and the PCR key can stay on a PKCS#11 token instead of in files: the token signs, and
the release host holds no copy of either key. The release key stays a file
([Signing: Keys on a token](../design/signing.md#keys-on-a-token)).

In the key set, a key on a token replaces its key file with a `.pkcs11` file of one line, the key's
PKCS#11 URI (RFC 7512). The public halves stay: `lib.mkImage` reads them.

| file                   | instead of          | holds                                                              |
| ---------------------- | ------------------- | ------------------------------------------------------------------ |
| `secureboot/db.pkcs11` | `secureboot/db.key` | the URI of the `db` key, e.g. `pkcs11:token=…;id=%02;type=private` |
| `pcr/pcr.pkcs11`       | `pcr/pcr.key`       | the URI of the PCR key                                             |

The signer refuses a set with both files for one key, a `.pkcs11` file without a `pkcs11:` URI, and
a `release/index.pkcs11`. Build with the token's PKCS#11 module:

```sh
golconda release build -f server.toml --keys /srv/golconda-keys \
  --pkcs11-module /path/to/libykcs11.so
```

The signer checks each key on the token against the public half the image carries before it signs,
as it does for a file. It gives the tools the key through pkcs11-provider: `systemd-sbsign` for the
loader, `openssl smime` for the verity root hash, `ukify` for the kernel, the UKI and `.pcrsig`.

The token asks for its PIN in each program that opens it. The signer runs eight such programs (two
key checks, the loader, the root hash, the PCR certificate, and three in `ukify`). A URI can carry
the PIN source, so that the PIN is typed once into a file that lives only in memory, as
`pkcs11:…;type=private?pin-source=file:/run/user/1000/token-pin`. The tests give the PIN with
`pin-value=`; the prompt and `pin-source=` have not run *(being built)*.

Verification: the test image's `db` and PCR keys on a SoftHSM token (a token in software, used for
tests only) sign a release. That release is the same, byte for byte, as the release signed from the
same keys in files. `golconda release check` passes on it (`packages.<system>.pkcs11-signed-same`).
The image boots with `--secure-boot --ssh-test --tpm` (`@image=image-smoke-test-pkcs11` in
`tests/boot/matrix`). `checks.image-signer` covers the key checks.

### A YubiKey

`libykcs11.so` makes a YubiKey's PIV applet a PKCS#11 token. `packages.<system>.yubikey-tools` holds
`pcscd`, `yubico-piv-tool` and `ykcs11-module`, which prints the path of that module for
`--pkcs11-module`. The `db` and PCR keys on a SoftHSM token run in the boot matrix (above). No run
on a real YubiKey has been done *(being built)*.
