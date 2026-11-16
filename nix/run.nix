# run SET NAME TOOLS SCRIPT: a content-addressed derivation NAME whose builder is the repkgs seed's
# shell, as repkgs' own tests are. TOOLS' bin/ come before the seed's on PATH; SCRIPT must create
# $out. nix/checks.nix makes its checks with it, nix/dev its scripts and the treefmt config, so
# that they need no nixpkgs. (The retired chroot-store daemon also refused an input-addressed
# derivation that names a repkgs, content-addressed, output; the system daemon takes one.)
#
# (run SET).sameRelease A B: the shell lines that fail unless the signed releases A and B have the
# same files with the same bytes: disk.raw, cmdline, release/, and disk.json without the
# directories of its "file" and "node" paths (repart's definitions and the output: each signer
# run has its own). For each file that differs it prints the count and the first bytes.
set: {
  __functor =
    _: name: tools: script:
    import ../lib/ca-derivation.nix {
      inherit name;
      system = set.platform.system;
      builder = "${set.bootstrap.seed}/bin/sh";
      args = [
        "-eu"
        "-c"
        script
      ];
      PATH = builtins.concatStringsSep ":" (map (t: "${t}/bin") tools ++ [ "${set.bootstrap.seed}/bin" ]);
    };

  sameRelease = a: b: ''
    (cd ${a} && find . | sort) > $TMPDIR/a.txt
    (cd ${b} && find . | sort) > $TMPDIR/b.txt
    if ! cmp -s $TMPDIR/a.txt $TMPDIR/b.txt; then
      echo "the two releases have other files:"
      diff $TMPDIR/a.txt $TMPDIR/b.txt || true
      exit 1
    fi
    strip() { sed -e 's|"file" : "[^"]*/|"file" : "|' -e 's|"node" : "[^"]*/|"node" : "|' "$1"; }
    strip ${a}/disk.json > $TMPDIR/a.json
    strip ${b}/disk.json > $TMPDIR/b.json
    rc=0
    for f in $(cd ${a} && find . -type f | sort); do
      fa=${a}/$f fb=${b}/$f
      [ "$f" = ./disk.json ] && fa=$TMPDIR/a.json fb=$TMPDIR/b.json
      if ! cmp -s "$fa" "$fb"; then
        cmp -l "$fa" "$fb" > $TMPDIR/diff.txt || true
        echo "differs: $f, $(wc -l < $TMPDIR/diff.txt) bytes; first (offset, octal a, b):"
        head -8 $TMPDIR/diff.txt
        rc=1
      fi
    done
    [ $rc = 0 ] || exit 1
  '';
}
