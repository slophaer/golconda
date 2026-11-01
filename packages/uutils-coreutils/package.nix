# uutils coreutils: the image's coreutils (Golconda). The set keeps GNU `coreutils` for build
# scripts; nothing here replaces it. One multicall binary, `coreutils`, plus a symlink per tool
# (the `unix` feature = every tool that builds on unix). `bin` is `coreutils` and the tool names.
# The list is `coreutils --list` of 0.12.0 minus `[`; re-read it on a bump.
# tests/builder/uutils runs the everyday tools.
{ package }:
let
  tools = [
    "arch"
    "b2sum"
    "base32"
    "base64"
    "basename"
    "basenc"
    "cat"
    "chgrp"
    "chmod"
    "chown"
    "chroot"
    "cksum"
    "comm"
    "cp"
    "csplit"
    "cut"
    "date"
    "dd"
    "df"
    "dir"
    "dircolors"
    "dirname"
    "du"
    "echo"
    "env"
    "expand"
    "expr"
    "factor"
    "false"
    "fmt"
    "fold"
    "groups"
    "head"
    "hostid"
    "hostname"
    "id"
    "install"
    "join"
    "kill"
    "link"
    "ln"
    "logname"
    "ls"
    "md5sum"
    "mkdir"
    "mkfifo"
    "mknod"
    "mktemp"
    "more"
    "mv"
    "nice"
    "nl"
    "nohup"
    "nproc"
    "numfmt"
    "od"
    "paste"
    "pathchk"
    "pinky"
    "pr"
    "printenv"
    "printf"
    "ptx"
    "pwd"
    "readlink"
    "realpath"
    "rm"
    "rmdir"
    "seq"
    "sha1sum"
    "sha224sum"
    "sha256sum"
    "sha384sum"
    "sha512sum"
    "shred"
    "shuf"
    "sleep"
    "sort"
    "split"
    "stat"
    "stdbuf"
    "stty"
    "sum"
    "sync"
    "tac"
    "tail"
    "tee"
    "test"
    "timeout"
    "touch"
    "tr"
    "true"
    "truncate"
    "tsort"
    "tty"
    "uname"
    "unexpand"
    "uniq"
    "unlink"
    "uptime"
    "users"
    "vdir"
    "wc"
    "who"
    "whoami"
    "yes"
  ];
in
package {
  name = "uutils-coreutils";
  uses = [ "cargo" ];
  cargo.features = [ "unix" ];
  # upstream's integration suite wants a tty, root, locales and a populated /etc; the tests/builder
  # check covers what Golconda uses
  tests.run = false;
  # no [pin] sys: the lock can link clang (bindgen, selinux feature) and openssl (checksum
  # feature), both off in this build. Our clang/openssl packages would join the closure and put
  # their bin/ on PATH through a launcher, which also breaks the multicall symlinks (argv[0])
  sys = null;
  tests.version = true;
  links = builtins.listToAttrs (
    map (t: {
      name = "bin/${t}";
      value = "coreutils";
    }) tools
  );
  bin = [ "coreutils" ] ++ tools;
}
