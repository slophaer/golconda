# Moved closures fail: PT_INTERP and RUNPATH go through absolute sysroot links

Copy jq to another root and hide the host `/nix/store`:

```console
$ nix copy --to 'local?root=DIR' $(nix-build -A jq) && mv DIR/nix DIR/usr/nix
$ unshare -rm sh -c 'mount -t tmpfs none /nix/store; env -i DIR/usr/nix/store/<jq>/bin/jq --version'
reloc-interp: cannot open interpreter
```

The relocation test passes only because the host still has `/nix/store`.

Why: PT_INTERP and RUNPATH name ld.so and libc through the sysroot output, a symlink tree made with
`cp -rsf`. GNU `cp -s` writes absolute targets: all 4472 links point into `/nix/store/<hash>-glibc`.
After the move they leave the store. The sysroot also puts linux-headers, compiler-rt and the
runtimes into every closure. libc references the last two in its debug info.

Fix:

- The `cc` recipe writes the libc and runtimes outputs as `libc` and `runtimes` in `jig.json`.
  `package.nix` uses libc for the interpreter. Stage 0/1 keep the sysroot.
- `bootstrap/sysroot.nu` makes the links that `cp` leaves relative.
- glibc builds with `-ffile-prefix-map` for compiler-rt and linux-headers.
