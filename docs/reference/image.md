# Image artifacts

What a release contains and how sysupdate finds it. Names carry the image id and version; the
version sorts with `strverscmp`.

| artifact | file name | sysupdate transfer | |---|---|---| | `/usr` image |
`<id>_<version>.usr.raw` | `Type=partition`, `MatchPartitionType=usr` | | verity hash tree |
`<id>_<version>.usr-verity.raw` | `MatchPartitionType=usr-verity` | | verity signature |
`<id>_<version>.usr-verity-sig.raw` | `MatchPartitionType=usr-verity-sig` | | UKI |
`<id>_<version>.efi` → installed as `<id>_<version>+3-0.efi` | `Type=regular-file`, path
`/EFI/Linux` | | manifest | `SHA256SUMS`, `SHA256SUMS.gpg` | verification |

All transfers use `InstancesMax=2`.
