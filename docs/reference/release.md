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

## 1. Make the key set

```sh
scripts/make-keys /srv/golconda-keys
```

The script refuses a relative directory and a directory that exists and is not empty, creates the
directory with mode `0700` and every file with mode `0600`, and prints the paths, what each key
signs and the certificate's SHA-256 fingerprint. It never prints key material. Keep the directory on
the release host: no build reads the private keys, and no step copies them
([Trust: Signing outside Nix](../design/trust.md#signing-outside-nix)).

| file                 | what it does                                                           |
| -------------------- | ---------------------------------------------------------------------- |
| `secureboot/db.key`  | signs systemd-boot, each UKI and each verity root hash                 |
| `secureboot/db.crt`  | the certificate for those signatures; the firmware `db` must hold it   |
| `secureboot/PK.key`  | signed `PK.auth` and `KEK.auth`; no release reads it                   |
| `secureboot/PK.crt`  | the platform key's certificate                                         |
| `secureboot/KEK.key` | signed `db.auth` and `dbx.auth`; a rotation's new set is signed by it  |
| `secureboot/KEK.crt` | the key exchange key's certificate                                     |
| `secureboot/auth/`   | `microsoft/{PK,KEK,db,dbx}.auth`, `golconda/{PK,KEK,db}.auth` (step 4) |
| `pcr/pcr.key`        | signs the PCR 11 policy (`.pcrsig`) in each UKI                        |
| `pcr/pcr.pub`        | the public half, embedded in each UKI as `.pcrpkey`                    |
| `release/index.key`  | signs each release's `SHA256SUMS` (OpenPGP Ed25519, armored secret)    |
| `release/index.pgp`  | the public half (binary), the image's keyring for `Verify=yes`         |

`db.crt` is a self-signed PEM X.509 certificate, valid for 3650 days, with `CA:TRUE`,
`digitalSignature`, `keyCertSign`, `cRLSign` and `codeSigning`. `PK.crt` and `KEK.crt` are the same
without `codeSigning`; each has a key of its own. The enrolment files are signed once, here, by
`golconda-enrol-auth` with Microsoft's certificates and revocation list
(`packages/secureboot-objects`), so a release needs neither the PK key nor the KEK key: keep them
offline. Run `golconda-enrol-auth --keys DIR` again, with them, for a newer `dbx`. `systemd-sbsign`
takes a PEM certificate (systemd 262, `systemd-sbsign(1)`). The signer checks each private key
against its public half and each verity root hash signature against the certificate, so a key and
certificate that do not match fail the release and not the boot. Keep the set: a rotation uses the
old `pcr/` key and the old release key (step 5).

`tests/make-keys/run.sh` (run by `scripts/lint`) runs the script into a temporary directory and
checks the layout, the modes, the certificate's extensions, that each key matches its public half,
that PK, KEK and `db` are three different keys, that each `.auth` enrols its certificate, and that
`--reuse-pk-kek` keeps the old PK and KEK. `tests/sign/enrol-test.nu` checks the files field by
field.

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

Verification: two releases built and signed by `golconda release build` with a fresh key set booted
with `--secure-boot --tpm --ssh-test`, the second as an update over HTTP (`--next`), and none of the
set's private keys was in the store afterwards ([What is proven](../proven.md#signing-outside-nix)).

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
keyring ([Trust: Deployment keys](../design/trust.md#deployment-keys)). Only certificates are
enrolled; the private keys stay on the build host and never enter the image.

**A machine in Setup Mode needs nothing.** The release's ESP carries
`loader/keys/auto/{PK,KEK,db,dbx}.auth` from the key set: by default with Microsoft's KEK, UEFI CAs
and revocation list, with `/system.secureBootMicrosoftKeys = false` the set's certificates alone. On
the first boot of `disk.raw` from firmware without a PK, systemd-boot enrols them, PK last, and
resets the machine; on hardware it first warns for 15 seconds, and a key aborts. The next boot runs
with Secure Boot on ([Boot loader: Enrolment](../design/bootloader.md#enrolment)). A new virtual
machine has an empty variable store; hardware gets one when its keys are cleared in firmware setup.

**Firmware with keys.** Firmware that already has a PK ignores the files. Add `secureboot/db.crt` to
`db` in firmware setup, beside the vendor's keys, or clear the keys there and boot again. The image
cannot change `db` or `dbx` itself
([Boot loader: What is not possible](../design/bootloader.md#what-is-not-possible)). From a running
machine, `bootctl reboot-to-firmware true` and a reboot reach the firmware menu
([Boot loader: Recovery](../design/bootloader.md#recovery)).

The boot test runs both: `--secure-boot` writes an OVMF variable store offline with
`virt-fw-vars --add-db`, and `--secure-boot --auto-enrol` boots from the empty store and lets
systemd-boot enrol, with and without Microsoft's keys (`auto-enrolled`, `db-enrolled`,
`dbx-enrolled`; `scripts/boot-test`).

**Unverified:** enrolment on a machine's own firmware *(being built)*. Not run: clearing the keys in
a real firmware's setup, the 15-second warning on its console, that firmware accepting the four
files, option ROMs running after the enrolment with Microsoft's keys, and adding `db.crt` beside a
vendor's keys.

## 5. Rotate a key

A `db` rotation signs the next loader, UKIs and verity root hashes with a new key. The PCR key and
the release key do not change, and neither do the PK and the KEK, so make a second set that keeps
the first set's PK and KEK, and keep the first:

```sh
scripts/make-keys --reuse-pk-kek /srv/golconda-keys /srv/golconda-keys-2
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

## 6. Keys on a token

The `db` key and the PCR key can stay on a PKCS#11 token instead of in files: the token signs, and
the release host holds no copy of either key. The release key stays a file
([Trust: Keys on a token](../design/trust.md#keys-on-a-token)).

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

The token asks for its PIN in each program that opens it: the signer runs eight (two key checks, the
loader, the root hash, the PCR certificate, and three in `ukify`). A URI can carry the PIN source,
so that the PIN is typed once into a file that lives only in memory, as
`pkcs11:…;type=private?pin-source=file:/run/user/1000/token-pin`. The tests give the PIN with
`pin-value=`; the prompt and `pin-source=` have not run *(being built)*.

Verification: the test image's `db` and PCR keys on a SoftHSM token (a token in software, used for
tests only) sign a release that is the release signed from the same keys in files, byte for byte,
and `golconda release check` passes on it (`packages.<system>.pkcs11-signed-same`); that image boots
with `--secure-boot --ssh-test --tpm` (`@image=image-smoke-test-pkcs11`;
[What is proven](../proven.md#signing-outside-nix)). `checks.image-signer` covers the key checks.

### A YubiKey *(being built)*

**No run on a real YubiKey has been done**, so this is the plan, not a tested procedure, and the
marker stays until a run is named in [What is proven](../proven.md#signing-outside-nix). What has
run, without a token: the packages (`pcsc-lite`, `ccid`, `yubico-piv-tool`, `yubikey-tools`) and
their tests (`packages.<system>.tests-<name>`). They start `pcscd` with ccid's driver directory, run
`yubico-piv-tool` with and without a daemon, and load `libykcs11.so` through p11-kit and
pkcs11-provider, which find no slot and no token. The options below are those of yubico-piv-tool
2.7.3's `--help`; the PKCS#11 ids come from its source (`ykcs11/objects.c`).

The keys are made offline, backed up, and imported into two YubiKeys, a primary and a spare. A key
made on a token cannot be copied, and a lost token would mean a new `db` certificate in every
machine's firmware and a new PCR key for every sealed credential. A YubiKey 5 holds RSA 2048 keys in
its PIV applet, the type `scripts/make-keys` makes for both keys. The release host holds no private
key of the two; the `release/` key stays a file there (above).

1. **The tools**, on the machine that imports (offline) and on the release host:

   ```sh
   nix-build -A packages.x86_64-linux.yubikey-tools -o yubikey-tools
   export PATH=$PWD/yubikey-tools/bin:$PATH
   ```

   `yubikey-tools/bin` has `pcscd`, `yubico-piv-tool` and `ykcs11-module`, which prints the path of
   `libykcs11.so`. Start the daemon as root, in a terminal of its own, and keep it running while a
   command uses the YubiKey (any local user may then use the card; the package has no polkit):

   ```sh
   sudo $PWD/yubikey-tools/bin/pcscd --foreground
   ```

   Without a YubiKey, `yubico-piv-tool --help` and `ykcs11-module` run, and
   `yubico-piv-tool -a status` fails with "PCSC service not available" (no daemon) or "Error in PCSC
   call" (daemon, no reader).

1. **Make the key set on an offline machine** (it needs the Nix daemon and the tools the script
   builds, `openssl` and `gnupg`, built beforehand) and keep two encrypted copies of the two private
   keys on offline media (a passphrase; `age` is `packages.<system>.age`):

   ```sh
   scripts/make-keys /srv/golconda-keys
   tar -C /srv/golconda-keys -cf - secureboot/db.key pcr/pcr.key | age -p -o golconda-keys.tar.age
   ```

   Restore with `age -d golconda-keys.tar.age | tar -xf -`. Check a copy by restoring it into a
   temporary directory before the keys leave the machine.

1. **Give the PCR key a certificate.** ykcs11 lists a key only with a certificate in its slot. The
   certificate is self-signed and nothing checks it:

   ```sh
   openssl req -x509 -new -key pcr/pcr.key -subj "/CN=Golconda PCR policy key/" -days 3650 \
     -out pcr/pcr.crt
   ```

1. **Set up and fill one YubiKey** (plug in one at a time). The default PIN is `123456`, the PUK
   `12345678` and the management key `010203040506070801020304050607080102030405060708`; change all
   three. The management key is needed only to import or delete keys, not to sign: write it down
   with the backup. `--key=` takes the value attached; a bare `--key` asks for it.

   ```sh
   MGM=$(openssl rand -hex 24)
   yubico-piv-tool -a set-mgm-key --new-key="$MGM" --new-key-algo=AES192
   yubico-piv-tool -a change-pin
   yubico-piv-tool -a change-puk
   yubico-piv-tool --key="$MGM" -a import-key -s 9c --pin-policy=once --touch-policy=never \
     -i secureboot/db.key
   yubico-piv-tool --key="$MGM" -a import-certificate -s 9c -i secureboot/db.crt
   yubico-piv-tool --key="$MGM" -a import-key -s 9d --pin-policy=once --touch-policy=never \
     -i pcr/pcr.key
   yubico-piv-tool --key="$MGM" -a import-certificate -s 9d -i pcr/pcr.crt
   ```

   The `db` key goes to slot 9c and the PCR key to slot 9d. `--new-key-algo=AES192` needs firmware
   5.4.2 or newer; leave it out on older keys (3DES). `--pin-policy=once` asks for the PIN once per
   session, not for every signature: the PIV standard's default for 9c is "always", which ykcs11
   reports as `CKA_ALWAYS_AUTHENTICATE`. **Unverified:** that a YubiKey 5 accepts `once` for an
   imported key in 9c.

   Check the slots, and that the key in 9c is the one that was made (the two fingerprints must be
   equal) and signs:

   ```sh
   yubico-piv-tool -a status
   yubico-piv-tool -a read-certificate -s 9c | openssl x509 -noout -fingerprint -sha256
   openssl x509 -in secureboot/db.crt -noout -fingerprint -sha256
   yubico-piv-tool -a verify-pin -a test-signature -s 9c
   ```

1. **Repeat step 4 on the second YubiKey**, the spare, with the same files and its own management
   key. Keep it offline in another place. Then delete the private keys from the offline machine's
   working copy if the backups restore.

1. **The key set for the release host.** Copy `secureboot/db.crt`, `pcr/pcr.pub` and `release/` to
   the release host, not `db.key`, `pcr.key` or `pcr.crt`. Write the two URIs. ykcs11 numbers its
   objects by slot (9a is 1, 9c is 2, 9d is 3, 9e is 4), and the id is in the URI; there is no
   `token=`, so either YubiKey matches, with one plugged in at a time:

   ```sh
   echo 'pkcs11:id=%02;type=private?pin-source=file:/run/user/1000/yubikey-pin' \
     > /srv/golconda-keys/secureboot/db.pkcs11
   echo 'pkcs11:id=%03;type=private?pin-source=file:/run/user/1000/yubikey-pin' \
     > /srv/golconda-keys/pcr/pcr.pkcs11
   ```

   The PIN goes into the file once per sitting, so that the eight programs of one build do not each
   ask for it; `/run/user/<uid>` is memory:

   ```sh
   ( umask 077; read -rs PIN && printf '%s' "$PIN" > /run/user/$(id -u)/yubikey-pin )
   ```

   Delete the file when the build ends. **Unverified:** `pin-source=` has not run (above).

1. **Build with the module**, with `pcscd` running and one YubiKey plugged in:

   ```sh
   golconda release build -f server.toml --keys /srv/golconda-keys \
     --pkcs11-module "$(ykcs11-module)"
   ```

   The signer compares each key on the token with the public half in the key set before it signs
   (above), so a wrong id or a YubiKey with other keys fails the build, not the boot.
