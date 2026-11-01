# repkgs patches

Golconda uses a fork of [Mic92/repkgs](https://github.com/Mic92/repkgs). The fork is the branch
`npins/sources.json` names (`branch`, today `reloc-boot`) of Golconda's repkgs repository (the URL
is there too). It holds the infrastructure commits mirrored below on top of upstream `main`, plus
the packaging round-1 packages under `pkgs/`, which are not mirrored. The patches fix two relocation
bugs (the sysroot in PT_INTERP and RUNPATH, `$ORIGIN` without `/proc`) and the glibc regression that
followed (libunwind must sit next to libc), make aclocal see macros from build tools, and add the
systemd and UEFI platform names, the `wrap` and `closure` package shapes, the `bin` list of
executables, transitive `propagate` for launcher env, the `kbuild` build system with config
fragments, the `prefix` field for packages compiled for `/usr`, jig's passthrough mode, and the
`sbom` function. The issue drafts `0001-interp-via-sysroot.md` and `0002-origin-without-proc.md`
describe the two original bugs for upstream.

The `.patch` files are those commits, numbered in the order they apply to upstream `main`
(`fab7121`). Package commits are excluded: `git log fab7121..reloc-boot -- pkgs` lists them.

The files here were made from branch `golconda`, an ancestor of `reloc-boot`. They lack four
infrastructure commits that `reloc-boot` adds
(`jig: put a package's -rpath into the padded RUNPATH`,
`finish: check that .note.dlopen libraries are on RUNPATH`,
`glibc: resolve AT_EXECFN like realpath for $ORIGIN without /proc`,
`finish: warn about bin/ executables the spec does not list`). Run the steps below to add them.

Regenerate them after a change to the fork:

```console
$ git clone -b reloc-boot <fork url from npins/sources.json> repkgs
$ cd repkgs
$ git remote add upstream https://github.com/Mic92/repkgs
$ git fetch upstream
$ rm -f ../golconda/patches/repkgs/*.patch
$ i=1; for c in $(git rev-list --reverse upstream/main..reloc-boot -- nix builder bootstrap pkgs/gl/glibc pkgs/ll/llvm pkgs/au/autoconf pkgs/la/launch pkgs/ji tests/builder); do git format-patch -1 --start-number $i -o ../golconda/patches/repkgs $c; i=$((i+1)); done
```

Then update the pin (`revision`, `url`, and `hash` = `nix hash convert --to sri` of
`nix-prefetch-url --unpack <url>` in `npins/sources.json`) and commit both.
