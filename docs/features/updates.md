# A/B updates with health-checked rollback

An update writes a new version to the inactive copy of `/usr` and installs its boot image beside the
old one. The machine boots the new version on trial. If the trial fails three times, the boot loader
starts the previous version again. You keep a working machine without a console and without a script
on the host.

## How it works

The image holds two slots, A and B. A slot is three partitions: `/usr`, its verity hash tree and the
verity signature. Each slot also has a UKI (Unified Kernel Image, a signed boot file) on the ESP
(EFI System Partition). `systemd-sysupdate` fills the inactive slot with four transfers: `10-usr`,
`20-usr-verity`, `30-usr-verity-sig` and `40-uki`, each a `.transfer` file in
`/usr/lib/sysupdate.d`. Each transfer keeps two versions (`InstancesMax=2`) and never overwrites the
running one (`ProtectVersion=%A`). Every transfer has `Verify=yes`: sysupdate checks the signed
index before it writes ([Signed releases](signed-releases.md)).

The UKI lands on the ESP as `EFI/Linux/<id>_<version>+3-0.efi`. The suffix is the boot counter:
three tries left, none done. systemd-boot counts down on each attempt.

```mermaid
stateDiagram-v2
  [*] --> t3: sysupdate installs id_version+3-0.efi
  t3: +3-0 (installed, not yet tried)
  t2: +2-1 (try 1 running)
  t1: +1-2 (try 2 running)
  t0: +0-3 (try 3 running)
  good: blessed (id_version.efi)
  t3 --> t2: systemd-boot starts try 1
  t2 --> t1: try 1 fails, next boot
  t1 --> t0: try 2 fails, next boot
  t2 --> good: health checks pass, bless-boot
  t1 --> good: health checks pass, bless-boot
  t0 --> good: health checks pass, bless-boot
  t0 --> [*]: try 3 fails: systemd-boot prefers the other slot
```

A boot is good only if it reaches `boot-complete.target`. Two health units gate it:

- `golconda-health-network.service` needs a routable link within 60 seconds.
- `golconda-health-sshd.service` needs `sshd.service` active.

When both pass, `systemd-bless-boot` removes the suffix. After a good boot,
`golconda-loader-update.service` copies this release's signed systemd-boot to the ESP. A release
that fails its health gate never touches the loader.

## Using it

Set the source in the system table. It becomes part of the image.

```toml
["/system"]
name = "web"
version = "20261101.1"
updateSource = "https://updates.example.com/web/"
```

Serve the `release/` directory of the build at that URL. The image enables
`systemd-sysupdate-update.timer`. With `updateSource` unset, the image has no transfers and no
update runs. Read the counters with `bootctl list`.

## Status

The boot test proves this in QEMU with OVMF ([What is proven](../proven.md)):

- `release-index`, `sysupdate-installed`, `boots-next`, `etc-links-stable` and
  `no-failed-units-after-update`: the update installs and the new version boots (`--next`).
- `http-source`, `http-fetch`, `index-signed`: the guest fetches over HTTP with its own definition.
- `health-check-broken`, `attempt-[1-3]-unblessed`, `fallback-to-old-slot`, `counter-exhausted`: a
  failed health check costs one try each, and the old release boots after the third
  (`--next --fail-health`).
- `loader-update-ran` and `loader-update-not-run`: the loader updates after a good boot only.

## Limits

- A failed health check does not reboot the machine. The counter falls at the next boot, which the
  operator starts.
- A fresh disk has one slot. There the loader still boots the exhausted entry, so the machine stays
  up and unblessed until you fill the other slot.
- The machine supports no downgrade except the boot-counting fallback. `golconda release` refuses a
  version that does not increase before it is built or published.
- Nothing stops an older image signed by the same key from booting. Rollback protection is *(after
  v1)*.
- The tests use plain HTTP in QEMU. HTTPS from a real update server ran by hand on Hetzner Cloud
  ([What is proven](../proven.md#on-hetzner-cloud)); it has no marker. The timer and real hardware
  have none either.

## More

- [Updates](../design/updates.md): transfers, update source, versions.
- [Boot](../design/boot.md#boot-counting-and-ab) and [Boot health](../design/boot.md#boot-health):
  the counter and the two units.
- [Boot loader](../design/bootloader.md#the-loader-on-a-running-machine): the loader update.
- [Image artifacts](../reference/image.md#a-release) and [Releases](../design/releases.md).
- [Factory reset and recovery](factory-reset.md).
