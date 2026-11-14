# uutils coreutils: the image's coreutils (Golconda). The set keeps GNU `coreutils` for build
# scripts; nothing here replaces it. One multicall binary, `coreutils`, plus a symlink per tool
# (the `unix` feature = every tool that builds on unix). The links are made after the install
# from `coreutils --list`, the tools the binary has, minus `[`; the image links what bin/ then
# holds (exports.json), so no list of names is kept here.
# tests/packages/uutils-coreutils runs the everyday tools.
{ package }:
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
  # bin is not declared (the names are known only after the build), so the version check names
  # its binary
  tests.version = "coreutils --version";
  phases.after."cargo.install" = [
    {
      name = "tool-links";
      run = ''
        let bin = $"($c.out)/bin"
        # a cross build runs the target's binary in the set's emulator (qemu-user)
        let list = ($c.platform.emulator | append [$"($bin)/coreutils" --list])
        let tools = (run-external ...$list | lines | where { $in != "[" })
        if ($tools | is-empty) { error make {msg: "coreutils --list printed no tools"} }
        for t in $tools { ^ln -s coreutils $"($bin)/($t)" }
        note tool-links $"($tools | length) links to coreutils"
      '';
    }
  ];
}
