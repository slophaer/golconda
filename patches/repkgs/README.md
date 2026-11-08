# repkgs patches

Golconda pins a fork of [Mic92/repkgs](https://github.com/Mic92/repkgs): the branch and URL are in
`pins/repkgs/sources.toml` (`?branch=`, today `golconda`). That branch is upstream `main` plus the
commits Golconda needs from upstream, and nothing else. List them with:

```console
$ git log --oneline origin/main..fork/golconda
```

They form series, one per future upstream pull request, in this order: platforms, relocation,
propagate, aclocal, prefix, wrap, then fork-only work (`buildPkgs`, `sbom`, jig passthrough, two
finish checks). The packages the image needs are not in the fork: they are in
[`packages/`](../../packages/README.md).

This directory holds what goes with the relocation series: the issue drafts
`0001-interp-via-sysroot.md` and `0002-origin-without-proc.md`, and `negative-control.txt`, the run
that shows the bug without the fix. The draft [`0003-sbom-properties.md`](0003-sbom-properties.md)
covers the generic SBOM property hook.

## Changing the fork

Commit to the fork's `golconda` branch, keeping each commit in its series, and push it to the forge
and to its public GitHub mirror, `slophaer/repkgs`. The pin follows the mirror: its archive is byte
for byte the forge's, and it needs no sign-in, neither for Nix nor for iets. Then move the pin:

```console
$ scripts/pins check repkgs
$ scripts/pins apply repkgs
```

`apply` writes the commit (`rev`), its date as the version (`0-unstable-<date>`) and the hash of the
unpacked tree. uptrack itself comes from the repkgs tree pinned before, so the new fork takes effect
for it on the next run.
