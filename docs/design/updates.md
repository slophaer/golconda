# Updates

An update is a new version of three artifacts, written to the inactive slot by systemd-sysupdate,
and a reboot. Rollback is the previous slot, chosen by boot counting or by hand.

```mermaid
flowchart TD
  rel[release: usr image, verity, signature, UKI, SHA256SUMS signed] --> src[http source or local directory]
  src -->|systemd-sysupdate update| chk{version newer than installed?}
  chk -->|no| done[nothing to do]
  chk -->|yes| w1[write usr, verity, sig to inactive slot]
  w1 --> w2[write UKI to ESP as id_version+3-0.efi]
  w2 --> reboot
  reboot --> good{boot-complete?}
  good -->|yes| bless[bless-boot: entry good; old slot is now inactive]
  good -->|3 failures| fallback[systemd-boot falls back to previous UKI and slot]
```

## Transfers

Four `sysupdate.d` definitions, one per artifact: `usr` (partition, type usr), `usr-verity`,
`usr-verity-sig`, and the UKI (regular file on the ESP). `InstancesMax=2` keeps exactly two of each.
The definitions are generated from the image name and are listed in
[reference/image](../reference/image.md).

## Versions

sysupdate orders versions with `strverscmp`. A version is therefore a counter or a date, never a
hash, and the composer refuses an image whose version does not sort above the one it replaces.
