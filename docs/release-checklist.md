# The release checklist

v0.1 is the first release this checklist describes.

A release is done when every item under [Prove](#prove) and [Build](#build) is checked. Each item
names the test that checks it. [Scope](design/scope.md) says which features the release has;
[What is proven](proven.md) lists the boot-test markers that pass. This page is the gap between
them.

## What a release means

An image of the release can run a real server unattended:

- an operator can log in with a certificate, and nobody can log in without one;
- an update installs, and a bad one rolls back, with no secret lost on the way;
- the secrets a machine needs reach it without being in the image;
- all of this has run at least once outside QEMU.

## Prove

- [x] **Unseal after an update.** The next release unseals the sshd host key without re-sealing it,
  and so does the previous release after a fallback. Test: `hostkey-unchanged` in
  `scripts/boot-test --secure-boot --tpm --ssh-test --next`, and with `--fail-health`.
  ([Measured boot](features/measured-boot.md#status))
- [x] **Certificate login.** A user certificate signed by the CA in `TrustedUserCAKeys` logs in with
  an allowed principal. A revoked certificate (in the KRL) and a wrong principal are refused. The
  host presents its host certificate. Test: boot-test markers.
  ([SSH login](features/ssh-login.md#status))
- [x] **An admin var end to end.** The host certificate and the KRL are pushed, sealed on the
  machine, read by sshd, and survive a reboot. Test: boot-test markers.
  ([Vars](features/vars.md#status))
- [x] **IPE denies a copy.** A binary copied to `/var` gets `Permission denied`, with the IPE audit
  record. Test: a boot-test marker. ([Execution policy](features/execution-policy.md))
- [x] **hwdb from `/base`.** The images pass the `hwdb` marker in every `--ssh-test` run, with and
  without Secure Boot.
- [x] **One run outside QEMU**, on Hetzner Cloud. Write the disk, provision it, boot, log in with a
  certificate, install the next release over HTTPS, roll back once. Test: the
  [Hetzner guide](reference/hetzner-cloud.md), run step by step by hand
  ([What is proven: Not proven](proven.md#not-proven)).

## Build

- [x] **The vars deploy tool**, `golconda vars`: keeps admin vars age-encrypted on the deploy host,
  pushes them over ssh, and has the machine seal them; rotation is "push again".
  ([Trust: Secrets and vars](design/trust.md#secrets-and-vars))
- [x] **A release tool**, `golconda release` (build, check, publish and list through rclone). It
  refuses a version that does not increase and a version reused with other bytes, because either
  installs nothing and says nothing ([Updates: Versions](design/updates.md#versions)). The release
  commit's trailers are the record of a build, the destination the record of what was published
  ([Making a release](reference/release.md)).

## How to test it

`scripts/verify` with no boot set boots every set of `tests/boot/matrix`.
[Boot test](reference/boot-test.md) explains the flags and the modes.

## Later

Everything that [Scope](design/scope.md#later) lists under Later is not in v0.1. Loader recovery by
hand has no marker ([What is proven: Not proven](proven.md#not-proven)).
