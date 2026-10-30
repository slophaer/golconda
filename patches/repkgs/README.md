# repkgs patches

Golconda uses a fork of [Mic92/repkgs](https://github.com/Mic92/repkgs). The fork is branch
`golconda` of Golconda's repkgs repository (the URL is in `npins/sources.json`). It holds eight
commits on top of upstream `main`. Three fix two relocation bugs (the sysroot in PT_INTERP and
RUNPATH, `$ORIGIN` without `/proc`); one adds the systemd and UEFI architecture names and exposes
the platform record; four add the `wrap` package shape (rewritten launch records), the `closure`
tarball with a `bin/` profile, and the `bin` list of executables in `exports.json` and as a
derivation attribute. The issue drafts `0001-interp-via-sysroot.md` and
`0002-origin-without-proc.md` describe the two bugs for upstream.

The `.patch` files here are the same eight commits. They apply to upstream `main` (`fab7121`) in
this order.

Regenerate them after a change to the fork:

```console
$ git clone -b golconda <fork url from npins/sources.json> repkgs
$ cd repkgs
$ git remote add upstream https://github.com/Mic92/repkgs
$ git fetch upstream
$ rm -f ../golconda/patches/repkgs/*.patch
$ git format-patch -o ../golconda/patches/repkgs upstream/main..golconda
```

Then update the pin (`revision`, `url`, and `hash` = `nix hash convert --to sri` of
`nix-prefetch-url --unpack <url>` in `npins/sources.json`) and commit both.
