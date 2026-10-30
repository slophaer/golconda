# Glossary

- **A/B**: two copies of `/usr` and two UKIs; updates go to the inactive one.
- **composer**: the `/system` module that unions fragments into one system.
- **DDI**: Discoverable Disk Image, a GPT image following the DPS that systemd tools can mount.
- **DPS**: Discoverable Partitions Specification, the type GUIDs systemd-gpt-auto-generator reads.
- **fragment**: the typed value a module returns; see [Modules](../design/modules.md).
- **PCR**: a TPM Platform Configuration Register; PCR 11 holds the UKI measurements.
- **relocatable**: an output that refers to other store paths only relative to itself.
- **symlink farm**: `/usr/bin` and friends as links into `/usr/nix/store`.
- **UKI**: Unified Kernel Image, one signed PE file with stub, kernel, initrd and cmdline.
- **verity**: dm-verity, block-level integrity of a read-only partition against a root hash.
