# A read-only, verified /usr

The operating system is one read-only filesystem, and the kernel checks every block against a signed
hash. A changed file in `/usr` does not run. All state lives in one place, `/var` on the state
partition, so you know what an update replaces and what it keeps.

```mermaid
flowchart LR
  uki["signed UKI: usrhash= + root-hash signature"] --> vs[systemd-veritysetup]
  vs --> dm["dm-verity checks the signature against the firmware db"]
  dm --> usr["/usr: erofs, read-only"]
  usr -->|tmpfiles L links| etc["/etc"]
```

## How it works

- **erofs under dm-verity.** `/usr` is an erofs image (`mkfs.erofs -zlz4hc`). A verity hash tree
  protects it. The builder signs the root hash with the Secure Boot `db` key as PKCS#7
  (`lib/image/verity.nu`).
- **The signature rides in the UKI.** The kernel command line (in the signed UKI, a unified kernel
  image) holds `usrhash=` and `systemd.verity_usr_options=root-hash-signature=base64:<sig>`.
  `usrhash=` names the two partitions by UUID, so no root partition is needed to find `/usr`. The
  kernel checks the signature against the firmware `db`. The build fails if the signature does not
  match the UKI's certificate.
- **A/B slots.** The disk has `usr-a` and `usr-b`, each with a verity and a signature partition (10
  GiB, 128 MiB, 16 KiB). An update writes the inactive slot and its UKI. systemd-boot counts boots
  and falls back after three failures.
- **`/etc` links into the factory.** `/factory` seeds `/usr/share/factory/etc`. Tmpfiles lines
  `L /etc/<path> - - - - /usr/share/factory/etc/<path>` link each file. `L` creates only what is
  missing, so an administrator's regular file at the same path wins and stays. PID 1 writes
  `machine-id`, and sysusers write `passwd`, `group` and `shadow`. Nothing writes `hostname`.
- **`/var` is state.** Services use `StateDirectory=` and so `/var/lib/<app>`. Vars sit under
  `/var/lib/golconda/vars`. `/home` and `/root` are on the same partition. `/tmp` and `/run` are
  tmpfs.
- **Only declared paths exist.** A fragment's `files` must be under `/usr`. A path under `/etc` is a
  type error outside `/factory`.

## Using it

Change an `/etc` file by replacing the link with a regular file:

```sh
echo web1 > /etc/hostname      # wins over the hostname credential
find /etc -type f              # lists every change you made
```

A vendor change reaches every unmodified file on the next boot with no tool. A program that rewrites
a file in place needs a directory of its own, not a link.

## Status

Proven in QEMU: `multi-user-reached` and `boot-complete` with `ipe.enforce=1`, so the kernel accepts
the signature. `sysupdate-installed`, `boots-next` and `etc-links-stable` cover the A/B update.
`fallback-to-old-slot` and `counter-exhausted` cover the rollback. `state-gone` and `slots-kept`
cover the factory reset. See [What is proven](../proven.md).

## Limits

- The state partition is unencrypted for now. LUKS2 with TPM2 is *(later)*.
- A signature that does not verify does not stop `systemd-veritysetup`. It logs at info level and
  activates `/usr` unsigned. IPE then denies PID 1's re-exec and the boot stops at switch-root.
- Both slots are fixed at 10 GiB, and each must hold any release.
- A rotated `db` key needs new images.
- Nothing checks `/var` or an administrator's `/etc` file.
- Hardware and real-firmware enrolment have not run.

## More

- [Layout](../design/layout.md#state) and [reference/layout](../reference/layout.md)
- [Trust: verity key](../design/trust.md#2-verity-key)
- [Boot](../design/boot.md#boot-counting-and-ab) and [Updates](../design/updates.md)
- [Principles: immutable by default](../design/principles.md#immutable-by-default)
- [Only signed code runs](execution-policy.md) and [Factory reset](factory-reset.md)
