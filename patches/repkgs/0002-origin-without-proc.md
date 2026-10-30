# $ORIGIN in RUNPATH fails when /proc is not mounted

With no `/proc`, as in the init of an initrd, a program with a `$ORIGIN` RUNPATH cannot load its
libraries. The kernel gave ld.so the executable name in `AT_EXECFN`, and `crt-interp` has already
used it to find ld.so:

```console
$ unshare -rm sh -c 'mount -t tmpfs none /proc; env -i ./prog'
```

ld.so fails with `libm.so.6: cannot open shared object file`.

Why: glibc `_dl_get_origin` reads `/proc/self/exe`, else `LD_ORIGIN_PATH`, else it fails. ld.so
drops `AT_EXECFN`.

Fix: `pkgs/gl/glibc/glibc-origin-execfn.patch` keeps `AT_EXECFN` in `_dl_execfn` and uses its
directory when both other sources are missing. A relative name is made absolute with `getcwd`, which
needs no `/proc`. A symbolic link keeps the directory of the link. Setuid programs ignore it, as
they ignore `LD_ORIGIN_PATH`. This fixes every ELF with a `$ORIGIN` RUNPATH; `crt-interp` stays
small.

Tested with a moved jq, `/nix/store` and `/proc` both replaced by tmpfs (output in
`negative-control.txt`). Without the patch:
`jq: error while loading shared libraries: libm.so.6: cannot open shared object file: No such file or directory`.
With it: `jq-1.8.2`.
