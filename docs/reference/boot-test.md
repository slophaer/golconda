# Boot test

`scripts/boot-test` boots an image in QEMU and checks it. It needs KVM, so it cannot run in the Nix
sandbox: it is a script, not a derivation. Each check prints `PASS: <marker>` or `FAIL: <marker>`.
[What is proven](../proven.md) names each marker, the claim that it proves and the line of the boot
matrix that prints it. `scripts/verify` boots the whole matrix (see [The matrix](#the-matrix)).

## What a run needs

- **KVM.** The script stops at the start when it cannot open `/dev/kvm`. `--allow-tcg` lets QEMU run
  on TCG, which is much slower.
- **An image and its keys.** The disk is `disk/disk.raw` of an image output, and `--keys DIR` is its
  throwaway key set (`keys/` of the same output). The ssh checks need `image-smoke-test` or another
  test image: they log in with `tests/fixtures/snakeoil-ssh`, and `image-smoke` does not take that
  key (`tests/fixtures/README.md` says why the private key is committed).
- **The tools.** `scripts/tools.sh` builds Golconda's own packages before the run and puts them
  first on `PATH`: `qemu-system` (`qemu-system-x86_64`, `qemu-img`), `swtpm`, `virt-firmware`
  (`virt-fw-vars`), `openssh`, `cpython` and `gnupg`. The firmware is the OVMF of `qemu-system`
  (`share/qemu/edk2-*.fd`). The QEMU project builds it from edk2-stable202408 and ships it in its
  release tarball, which `packages/qemu-system/sources.toml` pins by hash. Golconda does not build
  it again, and nothing checks the project's own signatures (`packages/qemu-system/package.nix` says
  what that trusts).
- **`golconda` and `age` for `--next` and `--certify`.** The `golconda` binary
  (`packages.<system>.golconda-cli`) in `BOOT_TEST_GOLCONDA` or on `PATH`, and `age`, `age-keygen`
  (`packages.<system>.age`) and `ssh-keygen` on `PATH`. The script stops when one is missing.
- **About 2 GiB of RAM and 2 CPUs** for each run.

The environment variables:

| variable               | default                                              | what it sets                                       |
| ---------------------- | ---------------------------------------------------- | -------------------------------------------------- |
| `BOOT_TEST_CACHE`      | `${XDG_CACHE_HOME:-$HOME/.cache}/golconda-boot-test` | the directory of the work directories and logs     |
| `BOOT_TEST_SSH_PORT`   | the first free port from 10022 up                    | the host port of the guest's sshd                  |
| `BOOT_TEST_PORT_LOCKS` | `$XDG_RUNTIME_DIR/boot-test-ports-UID`               | the lock files that claim the ssh ports            |
| `BOOT_TEST_GOLCONDA`   | `golconda`                                           | the `golconda` binary for `--next` and `--certify` |

## How to run

```sh
nix-build -A packages.x86_64-linux.image-smoke-test
nix-build -A packages.x86_64-linux.image-smoke-test-next -o next

# the first boot, the ssh checks, the TPM and a reboot
scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test --tpm --timeout 600

# an update to the next release, and the recovery paths
BOOT_TEST_GOLCONDA=$(nix-build -A packages.x86_64-linux.golconda-cli --no-out-link)/bin/golconda \
PATH=$(nix-build -A packages.x86_64-linux.age --no-out-link)/bin:$PATH \
  scripts/boot-test result/disk/disk.raw --keys result/keys --secure-boot --ssh-test --tpm \
  --next next --timeout 600
```

`scripts/boot-test --help` prints the usage. `tests/boot/matrix` has the flag sets that
`scripts/verify` boots, with their timeouts.

## Flags

| flag                          | what it does                                                                                                                   | needs                                  | not with                                                                                |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------- | --------------------------------------------------------------------------------------- |
| `--keys DIR`                  | the key set of the image; `--secure-boot` enrols its certificates                                                              | always                                 |                                                                                         |
| `--timeout SECONDS`           | each QEMU process stops after this time (default 120); a run with reboots needs more                                           |                                        |                                                                                         |
| `--allow-tcg`                 | run QEMU without KVM                                                                                                           |                                        |                                                                                         |
| `--ssh-test`                  | log in over ssh and run the checks of the first boot                                                                           |                                        |                                                                                         |
| `--secure-boot`               | enrol PK, KEK and `db` from `--keys` and boot OVMF with Secure Boot                                                            |                                        |                                                                                         |
| `--auto-enrol`                | enrol nothing: systemd-boot enrols the ESP's `loader/keys/auto`                                                                | `--secure-boot`, `--ssh-test`          | `--rotate`                                                                              |
| `--no-microsoft-keys`         | expect none of Microsoft's certificates: the image has `/system.secureBootMicrosoftKeys = false` (`image-smoke-test-own-keys`) | `--auto-enrol`                         |                                                                                         |
| `--tpm`                       | start swtpm; check that the host key is sealed, reboot, and check that it unseals                                              |                                        |                                                                                         |
| `--secure-boot-off`           | 3 power-ons with Secure Boot off, then Secure Boot on again                                                                    | `--secure-boot`, `--tpm`, `--ssh-test` | `--auto-enrol`, `--factory-reset`, `--certify`, `--esp-creds`, `--imds`, an update mode |
| `--esp-creds`                 | provision through the ESP with `scripts/provision-esp`, not through SMBIOS                                                     | `--ssh-test`                           | `--secure-boot` with `--tpm`, `--imds`                                                  |
| `--imds`                      | fake Hetzner Cloud's metadata endpoint                                                                                         | `--ssh-test`                           | `--esp-creds`                                                                           |
| `--certify`                   | certify the host in its first boot with `golconda vars certify` (`image-smoke-test-next`)                                      | `--ssh-test`                           | `--next`, `--esp-creds`, `--imds`                                                       |
| `--factory-reset`             | reset the state partition and check the reset boot                                                                             | `--ssh-test`                           | `--next`                                                                                |
| `--next DIR`                  | install the release of the image output `DIR` over HTTP and boot it; turns on `--ssh-test`                                     |                                        | `--certify`, `--factory-reset`                                                          |
| `--rotate`                    | `DIR` is signed with a new `db` key: rotate `db` and `dbx`                                                                     | `--next`, `--secure-boot`              | `--auto-enrol`, the other update modes                                                  |
| `--tamper-index`              | serve a changed `SHA256SUMS`, then a changed artifact under the true index: nothing must install                               | `--next`                               | the other update modes                                                                  |
| `--fail-health`               | each try of the new release fails a health unit                                                                                | `--next`                               | the other update modes                                                                  |
| `--fail-initrd`               | each try of the new release fails in the initrd                                                                                | `--next`                               | the other update modes                                                                  |
| `--fail-panic`, `--fail-pid1` | each try of the new release panics, or PID 1 crashes                                                                           | `--next`                               | the other update modes                                                                  |
| `--later DIR`                 | after the recovery paths, install the third release `DIR` into the first release's slot and boot it                            | `--next`                               | `--secure-boot-off`, the update modes but `--fail-blessed`                              |
| `--fail-blessed --later DIR`  | the blessed new release crashes PID 1 on each boot; `DIR` is a third release                                                   | `--next`                               | the other update modes                                                                  |

The update modes are `--rotate`, `--tamper-index` and the `--fail-*` flags. The script refuses two
of them in one run.

## The machine

QEMU runs the q35 machine with:

- a 40 GiB qcow2 overlay over the disk, so that the state partition has room;
- OVMF: with `--secure-boot` or `--tpm`, the Secure Boot build (`edk2-x86_64-secure-code.fd`, with
  SMM, and `-machine smm=on`); else the plain build (`edk2-x86_64-code.fd`), which has no Secure
  Boot. Both use a copy of the empty variable store `edk2-i386-vars.fd`. `--secure-boot` enrols the
  key set's `PK.crt`, `KEK.crt` and `db.crt` as PK, KEK and `db` with `virt-fw-vars` (one fixed
  owner GUID). The checks read PK and KEK back from efivarfs (`pk-kek-enrolled`);
- the SMBIOS credential `system.hostname=boot-test` (not with `--esp-creds` or `--imds`);
- the user network `169.254.169.0/24` in every mode, not QEMU's `10.0.2.0/24`. `--imds` needs
  Hetzner's metadata address, `169.254.169.254`, on the guest's link. The gateway, `169.254.169.2`,
  is the update source of the test images. QEMU's DHCP server offers the host name `dhcp-test`. The
  ssh port is forwarded to `127.0.0.1`;
- an i6300esb watchdog, which PID 1 arms;
- the serial console in a log file, `-display none`, and no monitor or QMP socket. The harness
  reaches the guest through the serial log and ssh only;
- `-no-reboot`, unless `--tpm`, `--next`, `--factory-reset` or `--auto-enrol` is given: those reboot
  the guest.

QEMU runs in the background. The checks run while the guest is up, then the harness stops QEMU.

## The first boot

Without `--ssh-test`, the harness reads only the serial log: `multi-user.target`, sshd, the host key
var, `boot-complete.target`, and no firstboot prompt. `no-firstboot-prompt` passes when the log has
no prompt. When firstboot left no trace in the log, the script prints `INFO` and counts a pass, so
this marker does not prove that firstboot ran.

With `--ssh-test` the harness logs in as root and checks the running system: the host name, failed
units, varlink, the boot loader, hwdb, IPE, the index keyring, the unit links, sshd, the sysctls,
the watchdog, the screen and its driver (simpledrm), the clock and the certificate logins with
`tests/fixtures/snakeoil-user-ca`. It also serves two HTTPS sites to the guest, `169.254.169.5:443`
and `169.254.169.6:443`: QEMU guestfwds to a TLS server over stdio (`scripts/boot-test.d/tls.sh`),
with the certificates of two test CAs (`tests/fixtures/ca-store`). The test image names the first CA
as an anchor, and the second as an anchor and as distrusted. No host port opens.

The image enforces IPE: `/usr` runs only from a dm-verity mapping whose root hash signature the
kernel verified, against the `db` certificate built into the kernel
([Trust: Verity key](../design/trust.md#2-verity-key)). With `--next`, after sysupdate fills the
other slot, the harness activates that slot with its signature through `systemd-veritysetup`. With
`--rotate` the signer is the new `db` key, which `db` holds but the running kernel does not, and the
kernel must refuse it with `-ENOKEY`.

`--tpm` checks the header of the sealed host key and reboots in the same QEMU (swtpm keeps its
state). It then checks that the second boot has a new boot id and the same host key, unsealed and
not made again.

## Provisioning

`--esp-creds` copies the disk into the work directory, makes an ssh key pair there and runs
`scripts/provision-esp` on the copy with `--hostname esp-test --authorized-keys <key>.pub`. It
passes no SMBIOS host name. The checks log in with the new key, and the host name must be
`esp-test`. The first boot must remove the credentials from the ESP. After a reboot, the second boot
must import none and keep the key and the host name. With `--secure-boot` and `--tpm` the guest
refuses null-key credentials ([Bootstrap credentials](../design/boot.md#bootstrap-credentials)), so
the script refuses that set.

`scripts/provision-esp <disk.raw> [--hostname NAME] [--authorized-keys FILE] [--credential NAME=FILE]...`
writes each value as a null-key `loader/credentials/NAME.cred` on the ESP of the disk, in place.
`--hostname` writes `system.hostname` and `firstboot.hostname`. It finds the ESP in the GPT and
refuses a path in `/nix/store`.

`--imds` fakes Hetzner Cloud for `/imds`. The guest finds the endpoint by hwdb alone, as on Hetzner:
QEMU gets `-smbios type=0,vendor=Hetzner`, so `40-imds.hwdb` matches, and the guest has no `imds.*`
credential. A QEMU guestfwd serves port 80 of `169.254.169.254` from a stdio HTTP server in
Hetzner's layout: `/hetzner/v1/metadata/hostname` (`imds-test`), the other metadata keys,
`public-keys` (a JSON array of two keys, with a bad entry between them) and `/hetzner/v1/userdata`.
The user data lists the credentials `imds-canary`, `login.motd`, `ssh.authorized_keys.root` (a third
key, which the import skips) and `network.network.60-imds-ipv6`: the static address
`2001:db8:5eed::1/64`, `IPv6AcceptRA=no`, `UseHostname=no`, and no IMDS lock. QEMU's router
advertisements name only `fec0::/64`, so no other route gives that address. systemd's IMDS lock is a
`prohibit` route for `169.254.169.254` alone, so the update server on the same network stays
reachable. `--imds --next` checks both in one run.

`--certify` runs on `image-smoke-test-next`, which has `hostCertificate` and `revokedKeys` on from
its first boot ([Trust: Host certificate](../design/trust.md#host-certificate)). The harness passes
a second plain key, the bootstrap key, as the SMBIOS credential `ssh.authorized_keys.root`. Before
the push, the bootstrap key logs in and a good certificate is refused. Then `golconda vars certify`
refuses a wrong fingerprint, and with the console's fingerprint it signs the host key with
`tests/fixtures/snakeoil-host-ca` and pushes the host certificate and a KRL. The same boot must then
present the certificate and refuse both plain keys. From the push on, the harness logs in with its
own certificate, `cert-admin`. With `--tpm` the certificate and the KRL hold after the reboot.

## Secure Boot

`--secure-boot` checks that the guest reports `Secure Boot: enabled`. The firmware refuses the same
disk with an unsigned loader on the ESP.

`--auto-enrol` starts OVMF with its empty variable store, in Setup Mode. systemd-boot must enrol the
ESP's `loader/keys/auto` and reset ([Boot loader: Enrolment](../design/bootloader.md#enrolment)).
The checks read the variables from efivarfs over ssh. `PK` is the key set's `PK.crt`. `KEK` and `db`
hold the key set's certificates and Microsoft's KEK and UEFI CAs (never a Windows CA). `dbx` is
Microsoft's list (`packages/secureboot-objects`). With `--no-microsoft-keys`, `KEK` and `db` hold
the key set's certificates alone and `dbx` is empty. Last, the harness puts the enrolment files back
on the ESP, empties the variable store and boots: systemd-boot must enrol nothing. The run ends
there.

`--secure-boot-off` runs after the first boot and its reboot. The harness prints PCR 7's event log,
keeps PK, KEK and `db`, and sets `SecureBootEnable` false
([Boot: Secure Boot off](../design/boot.md#secure-boot-off)). On 3 power-ons the initrd must halt
with its reason on the console. Then one boot masks the refusal with the SMBIOS string
`io.systemd.stub.kernel-cmdline-extra`: it must reach `multi-user.target`, but the host key, sealed
to PCR 7, must not unseal. Last, with Secure Boot on again, the host key unseals, the same release
runs, no entry is marked bad, and the failed-boot count is gone. With `--next` the 3 power-ons come
after the update, when the next release is blessed and the default. The masked boot is skipped,
because its complete boot resets a count. The next release must run at the end.

## The update test

`--next DIR` runs the whole A/B update. `DIR` is an image output with `disk/release` and `keys`. The
harness:

1. checks the release on the host with `golconda release check` and the running image's release key;
1. pushes the host certificate and a KRL with `golconda vars`, as an operator does. It first finds
   the host key's fingerprint on the serial console;
1. copies the release into `$WORKDIR/http` and serves it to the guest at `169.254.169.2:8074`: a
   QEMU guestfwd starts an HTTP server over stdio for each connection, so no host port opens. The
   requests go to `$WORKDIR/http.log`;
1. checks that the guest's own `10-usr.transfer` names that address, and starts
   `systemd-sysupdate-update.service`. sysupdate fetches `SHA256SUMS`, its signature and the
   artifacts. It writes the other slots and a UKI with 3 tries. When the ssh session of the start
   ends first (exit 255, as on a loaded host), the harness waits for the end of the unit and judges
   its `Result`, not the exit status of ssh;
1. moves the window of `systemd-sysupdate-reboot.timer` to every 10 s with a drop-in in `/etc`. The
   guest must reboot into the release by itself, and then the timer must reboot nothing;
1. checks the new release: the host certificate, the KRL and a second KRL, an enable link made
   before the update, the unit links, failed units, the clock, hwdb, `/dev/mapper/usr` and the
   loader (the new loader on the ESP, the old one kept as `systemd-boot-fallbackx64.efi`);
1. runs the recovery paths of [Boot loader](../design/bootloader.md#recovery): `bootctl list`, a
   damaged loader reinstalled by `golconda-loader-update`, `bootctl set-oneshot` and
   `bootctl set-default` to the other slot and back, and `bootctl reboot-to-firmware`;
1. with `--later DIR` (`image-smoke-test-later`, version `20261031.3`): powers the machine on again,
   serves `DIR` and starts sysupdate. The third release must go into the partition that had the
   first release's label, the slot the disk image made, while the second keeps its slot. The reboot
   timer must start it, its `/dev/mapper/usr` must sit on that partition, and `bootctl list` must
   show it as the default beside the second release.

`image-smoke-test-next` is the next release of `image-smoke-test` (version `20261031.2`, the same
keys). The update modes change this flow:

- `--tamper-index`: the server adds one byte to `SHA256SUMS`, so its signature does not match. The
  update must be refused, nothing installed, and after a reboot the old release must run. Then the
  server serves the true `SHA256SUMS` and its signature, and the usr artifact with its middle byte
  changed. The guest must fetch it, the download must fail its checksum, and no transfer, UKI or
  loader entry of the new release may be installed. The slot that sysupdate began keeps the new
  release's label. After a reboot the old release must run. The run skips every check that needs the
  new release.
- `--rotate` takes `image-smoke-test-rotated` (signed with a second `db` key). The harness enrols
  that certificate beside the old one before the first boot. After the update it stops QEMU, sets
  `db` to the new certificate alone and adds the old one to `dbx`, and boots again. The kernel must
  load only the new certificate. Last, the original disk under the rotated store must be refused by
  the firmware. With `--tpm` the vars are sealed again without PCR 7 before the update, and with it
  after the rotated boot.
- `--fail-health` breaks `golconda-health-network.service` with a drop-in: the first try hangs and
  the later ones fail. Another drop-in sets the deadline to 90 s. The harness only watches: the
  [trial boot](../design/boot.md#trial-boot) policy must reboot each try, and the fourth boot must
  run the old release. Then `bootctl set-oneshot` starts the new release with no try left: its
  health unit fails and it stays up.
- `--fail-initrd` zeroes the first MiB of the new release's verity hash partition, so its initrd
  cannot attach `/usr`. `golconda-emergency-reboot.service` must reboot each try, and the fourth
  boot must run the old release.
- `--fail-panic` and `--fail-pid1` arm the test image's `boot-test-panic.service` (a sysrq crash) or
  `boot-test-crash.service` (`kill -SEGV 1`) for the new release. `panic=10` or `CrashAction=reboot`
  must reboot each try at least 8 s after the failure, and the fourth boot must run the old release.
  The serial console shows the path. After each PID 1 crash the kernel prints
  `reboot: Restarting system`, because PID 1 calls `reboot(2)`. After each panic the kernel prints
  `Rebooting in 10 seconds..` (`panic=10`), and the next kernel starts with no `reboot(2)` line. A
  reset by the watchdog prints no line. The fourth boot reads the i6300esb's `bootstatus`: it must
  be 0, so the watchdog did not reset the third try.
- `--fail-blessed --later DIR` tests the [failed-boot counter](../design/boot.md#failed-boots). The
  activated release is blessed, then crashes PID 1 on each boot. After 3 boots the old release runs
  once, resets the count and marks the new release bad (`+0-3`). Then `DIR`
  (`image-smoke-test-later`) is installed and tried. Last, the later and the old release crash too,
  and the seventh boot in a row is not rebooted. The run ends on a halted machine; give it a
  `--timeout` of 1800.

The failure modes skip the loader and recovery checks: no boot of the new release is blessed, or the
run ends on a halted machine. The drop-ins are on the state partition, so they hold for every slot.

The update test does not prove the production transfer. It uses plain HTTP from the host, not HTTPS.
It does not use a real update server with redirects or authentication, or a network that is not
QEMU's.

## The factory reset test

`--factory-reset` is a boot of its own, on the test image (`IMAGE_ID=boot-test`). Give it a
`--timeout` for two boots, such as 480. The harness writes a marker in `/etc`, reads the machine id,
`IMAGE_VERSION` and `bootctl list`, and runs `systemctl start factory-reset.target`
([Updates: Factory reset](../design/updates.md#factory-reset)). On the reset boot the marker must be
gone, the machine id new, firstboot run again, and the boot entries and the version the same. The
reset writes the state partition only. The console names a new host key, and sshd presents it. A
user certificate logs in. With `--certify` the certificate is refused, because the KRL went with the
state; then `golconda vars certify` refuses the old fingerprint and certifies the new one. With
`--esp-creds` the generated key is refused and the host name is gone.

The test does not prove a reset with an update installed (the test image has one `/usr` slot), a TPM
clear, or the console path on a machine whose ssh is down.

## When a run fails

The script exits 0 when every check passes and 1 when one fails. A check passes only on positive
evidence. The output prints the last 100 lines of the first boot's serial log, and ends with
`=== ALL TESTS PASSED ===` or `=== SOME TESTS FAILED ===`. Search it for `FAIL:`.

Each run has a work directory `run.XXXXXX` in `$BOOT_TEST_CACHE`, not in `/tmp`, which a queue task
or a reboot can drop. A run that passes removes it. A run that fails keeps it and prints its path.
It has the serial log of each QEMU process (`serial*.log`), QEMU's output (`qemu.out`) and the logs
of the servers (`http.log`, `imds.log`, `tls-*.log`). Start with the serial log of the boot that
failed.

Several runs can share one host and one image. Each run has its own work directory, swtpm state,
firmware variables, disk overlay, keys, update server and ssh port. A run claims its port with a
`flock` in `$BOOT_TEST_PORT_LOCKS`, and the lock goes when the run ends.

## The parts

`scripts/boot-test` has the command line, the work directory, the tools, the firmware and `main`. It
sources the parts in `scripts/boot-test.d/`: `log.sh` (the serial markers), `vm.sh` (keys, swtpm,
credentials, QEMU), `http.sh` (the update server, the fake IMDS), `tls.sh` (the HTTPS servers),
`guest.sh` (ssh and the verdicts), `checks.sh` (the shared checks), `modes.sh` (the first boot, the
TPM reboot, `--secure-boot-off`, `--factory-reset`) and `update.sh` (`--next` and its modes). To
list the markers that the script can print:

```sh
grep -ho 'verdict "[a-z0-9-]*\|PASS: [a-z0-9-]*' scripts/boot-test scripts/boot-test.d/*.sh | sed 's/verdict "//;s/PASS: //' | sort -u
```

## The matrix

`tests/boot/matrix` lists the boot sets, one for each line: the flags of `scripts/boot-test` after
the disk and `--keys`. Blank lines and lines that start with `#` are skipped. Three words of
`scripts/verify` can be in a set:

| word          | means                                                                                                                      |
| ------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `@image=ATTR` | as the first word: boot `packages.<system>.ATTR`, not the image of `--image` (`image-smoke-test`)                          |
| `@next`       | the next release of the set's image: `packages.<system>.<image>-next`                                                      |
| `@next=ATTR`  | the next release is `packages.<system>.ATTR`; a set can name several (`--next @next --later @next=image-smoke-test-later`) |

`scripts/verify` with no `--boot-set` boots every line. `--boot-set ARGS` (repeat it) gives other
sets, and `--boot-args ARGS` gives one boot. verify builds each image once, and `golconda-cli` and
`age` when a set has `--next` or `--certify`. The out-link of an image is `result-verify-ATTR`
(`result-verify` for the image of `--image`). `@next` adds `-next` to the out-link of its image. It
boots the sets at the same time, at most `--jobs N` (default: MemAvailable / 2.5 GiB). Its summary
has one line for each set: `PASS boot[N] 59s @image=ATTR FLAGS` or
`FAIL(CODE) boot[N] 59s @image=ATTR FLAGS (log PATH)`, then `passed boot[N] (COUNT): NAME …`, the
checks that passed. A set that fails prints its `FAIL` lines and the last 20 lines of its log, and
keeps the log in `$BOOT_TEST_CACHE/verify.XXXXXX`. verify removes its own log directories after 7
days. It exits non-zero when a set fails.
