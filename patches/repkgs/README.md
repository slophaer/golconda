# repkgs patches

Golconda pins a fork of [Mic92/repkgs](https://github.com/Mic92/repkgs): the branch and URL are in
`npins/sources.json` (`branch`, today `golconda`). That branch is upstream `main` plus the commits
Golconda needs from upstream, and nothing else. List them with:

```console
$ git log --oneline origin/main..fork/golconda
```

They form series, one per future upstream pull request, in this order: platforms, relocation,
propagate, aclocal, prefix, wrap, then fork-only work (`buildPkgs`, `sbom`, jig passthrough, two
finish checks). The packages the image needs are not in the fork: they are in
[`packages/`](../../packages/README.md).

This directory holds what goes with the relocation series: the issue drafts
`0001-interp-via-sysroot.md` and `0002-origin-without-proc.md`, and `negative-control.txt`, the run
that shows the bug without the fix.

## Changing the fork

Commit to the fork's `golconda` branch, keeping each commit in its series. Then update the pin: set
`revision` and `url` in `npins/sources.json`, and `hash` to the output of

```console
$ nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url --unpack <url>)"
```

The forge needs a sign-in. Nix reads `netrc-file`, but iets does not, so fetch the pin once into the
store before `scripts/lint`:

```console
$ nix-instantiate --eval -E 'builtins.fetchTarball { url = "<url>"; sha256 = "<hash>"; }'
```
