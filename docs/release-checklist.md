# The release checklist

v0.1 is the first release this checklist describes.

A release is done when every item under [Prove](#prove) and [Build](#build) is checked. Each item
names the test that checks it. [Scope](design/scope.md) says which features the release has;
[What is proven](proven.md) lists the boot-test markers that pass today. This page is the gap
between them.

## What a release means

An image of the release can run a real server unattended:

- an operator can log in with a certificate, and nobody can log in without one;
- an update installs, and a bad one rolls back, with no secret lost on the way;
- the secrets a machine needs reach it without being in the image;
- all of this has run at least once outside QEMU.

## Prove

These exist in the code and the docs, but no test checks them.

- [x] **Unseal after an update.** The next release unseals the sshd host key without re-sealing it,
  and so does the previous release after a fallback. Test: new markers in
  `scripts/boot-test --secure-boot --tpm --ssh-test --next`, and with `--fail-health`.
  ([Measured boot](features/measured-boot.md#status))
- [x] **Certificate login.** A user certificate signed by the CA in `TrustedUserCAKeys` logs in with
  an allowed principal; a revoked certificate (in the KRL) and a wrong principal are refused; the
  host presents its host certificate. Test: boot-test markers.
  ([SSH login](features/ssh-login.md#status))
- [x] **An admin var end to end.** The host certificate and the KRL are pushed, sealed on the
  machine, read by sshd, and survive a reboot. Test: a boot-test marker; needs the
  [deploy tool](#build). ([Vars](features/vars.md#status))
- [x] **IPE denies a copy.** A binary copied to `/var` gets `Permission denied`, with the IPE audit
  record. Test: a boot-test marker. ([Execution policy](features/execution-policy.md))
- [x] **hwdb from `/base`.** The images of `7438a3f` pass the `hwdb` marker in every `--ssh-test`
  run, with and without Secure Boot.
- [x] **One run outside QEMU**, on Hetzner Cloud. Write the disk, enrol or provision, boot, log in
  with a certificate, install the next release over HTTPS, roll back once. Test: the
  [Hetzner guide](reference/hetzner-cloud.md) run step by step, its *(planned)* removed, the results
  recorded in [What is proven](proven.md#on-hetzner-cloud). Ran on 2026-11-09 on a `cpx12`: the ESP
  route, a certificate login, two updates over HTTPS, and one fallback from a third release to the
  second. Found there, not part of this item, and fixed since: `/imds` imported only the host name
  on Hetzner (now the hwdb patch, `ssh-key-json` and the lock on `lo`), the user data's IPv6
  `.network` file came too late (now the generator runs again after the import), and the first boot
  started at the build epoch (now `time-epoch`).

## Build

- [x] **The vars deploy tool** (`golconda-vars`): keeps admin vars age-encrypted on the deploy host,
  pushes them over ssh, and has the machine seal them; rotation is "push again".
  ([Trust: Secrets and vars](design/trust.md#secrets-and-vars))
- [x] **A release tool**, `golconda release` (build, check, publish and list through rclone): it
  refuses a version that does not increase and a version reused with other bytes, because either
  installs nothing and says nothing ([Updates: Versions](design/updates.md#versions)). The release
  commit's trailers are the record of a build, the destination the record of what was published
  ([Making a release](reference/release.md)).

## How to test it

Image builds cost more than boots: a test image takes 2 to 4 minutes to build (the image without
Secure Boot about 11, because it has its own kernel), a boot about 30 seconds. So the tests above
follow three rules:

- **Runtime checks first.** The unseal checks run `--tpm` together with `--next` and
  `--fail-health`, and the IPE check runs in the ssh battery. Neither changes an image.
- **One configuration change.** Every change to the test configuration rebuilds all five test
  images. The test CA and principals, and the host certificate and KRL in the next release, go in
  together, after the deploy tool exists. The first release logs in with a plain key, the harness
  pushes the host certificate and the KRL with the deploy tool, and the next release turns them on:
  the bootstrap that [Trust: Identity](design/trust.md#identity) describes.
- **No new harness logic.** The harness calls the deploy tool rather than copying it, and each check
  is one function that every mode calls.

The boot test runs on QEMU with KVM, cold. Snapshots and deterministic VMs were looked at and left
out: a boot is short, the costly part is the build, and no deterministic VM boots UEFI with a TPM.
Running the modes in parallel is the cheaper gain, and the harness does it: runs on one host with
one image share nothing (each has its own work directory, ssh port, update server and metadata
server; see [the update test](reference/image.md#the-update-test)), so
`scripts/verify --boot-set ARGS …` boots a list of flag sets at the same time, each with its own log
and a summary line with the names of the checks that passed. The default boot, `--next`,
`--next --fail-health`, `--imds` and the tamper run took 6 minutes together on one host, against 16
minutes for the sum of their times. The VMs need about 2 GiB of memory each. A set can name the next
release's image with `--next @next`: `scripts/verify` builds `<image>-next` (and the deploy tool and
`age` that `--next` needs) and puts the paths in. A set that starts with `@image=ATTR` boots that
image instead, and its `@next` is that image's next release; verify builds each image once and names
the image on each summary line. So one run boots the Secure Boot sets and the sets of
`image-smoke-test-nosb`:

```sh
SB="--secure-boot --ssh-test --tpm --timeout 400"
NOSB="@image=image-smoke-test-nosb --ssh-test --timeout 400"
scripts/verify --boot-set "$SB" --boot-set "$SB --next @next" \
  --boot-set "$SB --next @next --fail-health" --boot-set "$SB --next @next --tamper-index" \
  --boot-set "$SB --imds" --boot-set "$SB --imds --next @next" \
  --boot-set "$NOSB --esp-creds" --boot-set "$NOSB --next @next"
```

Every mode runs on QEMU's user network `169.254.169.0/24`, so `--imds` and `--next` also run
together: the endpoint `169.254.169.254` stays locked, the update source `169.254.169.2` is
reachable. Each boot checks the clock (`clock-not-reset`): the first boot, and each later one under
its own name (after the reboot, the update, the fallback and the refused update).

## Later

Wanted, but not needed for v0.1:

- a first-boot enrolment unit before sshd (host key, certificate and KRL in one flow): v0.1 uses the
  two-release bootstrap of [Trust: Identity](design/trust.md#identity), which the boot test runs;
- `golconda diff` between two built images, by their `config.json`: no diff tool exists; the
  console's diff of a document against git left with the console
  ([Configuration: Diffing](design/config.md#diffing-later));
- automatic Secure Boot enrolment (manual enrolment works);
- the p11-kit CA store with anchors and a distrust list
  ([Trust: CA store](design/trust.md#3-ca-store)): the Mozilla bundle covers a server that talks to
  public services;
- private keys on a token (PKCS#11): the signer reads a key directory and refuses a `pkcs11:` URI
  ([Trust: Signing outside Nix](design/trust.md#signing-outside-nix));
- a read-only `/etc` (a confext built from the image): built and boot-tested on 2026-11-05, then
  shelved; the code is the tag `archive/readonly-etc`. It would also drop enable links for units a
  release no longer ships;
- loader recovery by hand and a boot without the `db` enrolled
  ([Boot loader: Recovery](design/bootloader.md#recovery)): documented, no marker;
- everything [Scope](design/scope.md#later) lists under Later.

Internal work that does not change what the release is: a build daemon run as a service, and
splitting `scripts/boot-test`.
