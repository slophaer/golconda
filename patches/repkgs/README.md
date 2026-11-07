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
that shows the bug without the fix. The draft [`0003-sbom-properties.md`](0003-sbom-properties.md)
covers the generic SBOM property hook.

## Changing the fork

Commit to the fork's `golconda` branch, keeping each commit in its series. Then update the pin in
the dev shell (npins asks git for the forge's sign-in, so git needs a credential helper for it):

```console
$ npins update repkgs
```

Without a sign-in for git, update the pin by hand: set `revision` and `url` in `npins/sources.json`,
and `hash` to the output of

```console
$ nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url --unpack <url>)"
```

The lock is npins' format 8. A newer npins that asks for an upgrade (`npins upgrade`) also needs
`npins/default.nix`, which this repository does not keep: create an empty one for the upgrade and
delete it afterwards.

The forge needs a sign-in. Nix reads `netrc-file`, but iets does not: `scripts/lint` then fails with
`cannot read the tarball … Sign in`. Put the archive into the store the build uses, once, under the
name `builtins.fetchTarball` gives it; iets then finds the source by its hash (set `NIX_REMOTE` for
another daemon or a relocated store):

```console
$ nix-prefetch-url --unpack --name source <url>
```

Or give iets the file once; it keeps its own input cache by hash:

```console
$ cp "$(nix-prefetch-url --print-path <url> | tail -n 1)" /tmp/repkgs.tar.gz
$ iets eval --expr 'builtins.fetchTarball { url = "file:///tmp/repkgs.tar.gz"; sha256 = "<hash>"; }'
```

With a relocated store, copy the archive from that store's root instead.
