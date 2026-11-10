# Reproducible, signed releases

Building the same inputs gives the same release, byte for byte. The release carries a signed index,
and the machine installs nothing that the index does not list. You can rebuild a release to check
it, and a hostile update server cannot slip in a payload.

## How it works

A version is `YYYYMMDD.N`: a real date, and a counter `N` inside that day (`20261031.1`). The
`/system.version` type refuses anything else. The version also gives a timestamp,
`versionToEpoch = epoch(date) + N` (`lib/usr-tree.nix`, on `toEpoch` in `lib/version.nix`). That
timestamp is the mtime of every file in the `/usr` image. The verity salt and the filesystem UUID
come from the version string. So the same inputs (image id, version, `/usr` tree, keys) give the
same `/usr` image, root hash, file names and `SHA256SUMS`.

The release directory `release/` holds:

| file                                   | what                                         |
| -------------------------------------- | -------------------------------------------- |
| `<id>_<version>.usr.<uuid>.raw`        | the `/usr` image                             |
| `<id>_<version>.usr-verity.<uuid>.raw` | the verity hash tree                         |
| `<id>_<version>.usr-verity-sig.raw`    | the verity signature                         |
| `<id>_<version>.efi`                   | the UKI (Unified Kernel Image)               |
| `SHA256SUMS`                           | four lines, fixed order, one digest per file |
| `SHA256SUMS.gpg`                       | a detached OpenPGP signature of `SHA256SUMS` |

Every transfer in `/usr/lib/sysupdate.d` has `Verify=yes`. `systemd-pull` fetches `SHA256SUMS.gpg`
and runs `gpg --verify` against `/usr/lib/systemd/import-pubring.pgp`, the release key's public half
inside the running image. A payload whose digest the signed index does not list is never written.
OpenPGP is the one signature systemd 262 checks here, so the image carries GnuPG.

No image turns this off: there is no `Verify=no`, with or without Secure Boot. The signed index
matters most without Secure Boot, where nothing else checks a UKI before it runs
([Updates: What an update authenticates](../design/updates.md#what-an-update-authenticates)).

## Using it

`scripts/make-keys` makes a key set once. `lib.mkImage` signs the release with it.

```sh
scripts/make-keys /srv/golconda-keys
```

```nix
(import ./default.nix).lib.mkImage {
  config = ./server.toml;
  keys = "/srv/golconda-keys"; # a string: the private keys stay out of the store
}
```

The set holds `secureboot/db.key` and `db.crt`, `pcr/pcr.key` and `pcr.pub`, and `release/index.key`
(OpenPGP Ed25519) and `index.pgp`. `mkImage` returns `erofs`, `verity`, `initrd`, `uki`, `loader`,
`disk` and `release`. Serve `release/` at `/system.updateSource`.

## Status

The boot test proves this with `--next` ([What is proven](../proven.md)):

- `release-index`: the index has four lines in this order, and each digest matches its file.
- `index-keyring`, `index-signed`, `sysupdate-installed`: the image's keyring is the release key,
  and the guest checks the signed index.
- `sysupdate-refused` with `--tamper-index`: a changed index installs nothing, and the old release
  still runs after a reboot (`boots-old`).

One release signed with a `scripts/make-keys` set, passed as a path (so copied into the store),
booted on the same markers as the throwaway set. Its next release installed over HTTP.

## Limits

- The signature does not stop a replay of an older signed index. sysupdate installs only newer
  versions, and rollback protection is *(after v1)*.
- The image trusts only the release key it carries. Changing that key takes two releases.
- No automated check runs `scripts/make-keys`. The string key directory is *(being built)*: no build
  uses it.
- The `release/` file mtimes are 1 in the store. Do not read them as a release date.
- GnuPG stays in the image until systemd can check an x509 signature on the index.

## More

- [Releases](../design/releases.md#version-and-timestamp): version rules, stable values, the
  [signed index](../design/releases.md#the-signed-index).
- [Making a release](../reference/release.md): keys, build, serve, rotate.
- [Trust: Deployment keys](../design/trust.md#deployment-keys).
- [Outputs: `lib.mkImage`](../reference/outputs.md#libmkimage).
- [A/B updates](updates.md).
