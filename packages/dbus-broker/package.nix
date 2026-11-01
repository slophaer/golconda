# dbus-broker: high-performance D-Bus message broker with Rust parts (unreleased main branch).
# The launcher (dbus-broker-launch) execs dbus-broker by compiled-in path, so this is a farm
# package with prefix=/usr.
{
  package,
  sources,
  pkgs,
  buildPkgs,
}:
package {
  name = "dbus-broker";
  uses = [ "meson" ];
  prefix = "/usr";

  meson.defs = {
    # The launcher connects to systemd via libsystemd (journal, activation)
    launcher = true;
    docs = false;
    audit = false;
    selinux = false;
    apparmor = false;
  };

  # bindgen needs libclang at runtime (it dlopens it)
  env.LIBCLANG_PATH = "${buildPkgs.clang}/lib";

  buildDependencies = [
    buildPkgs.rust
    buildPkgs.bindgen
    buildPkgs.jq # libc-rs meson.build runs cargo metadata | jq
    buildPkgs.cpython # sys meson.build runs python3
    buildPkgs.clang # for libclang (bindgen dlopens it)
  ];

  dependencies = [
    pkgs.expat
    pkgs.systemd # libsystemd for the launcher
  ];

  # Copy all wrap subprojects before meson configure. Meson's wrap_mode=nodownload
  # cannot fetch them; we provide them as extra sources.
  # Also set up env for bindgen (libclang needs header paths that cc knows about).
  phases.before."meson.configure" = [
    {
      name = "bindgen-env";
      run = ''
        # bindgen invokes libclang directly, bypassing our cc wrapper. Tell it
        # where to find headers via CPATH (which libclang respects).
        # The sysroot contains both libc headers and Linux headers.
        let cc_dir = (which cc | first | get path | path dirname | path dirname)
        let jig = (open $"($cc_dir)/etc/jig.json")
        # Extract sysroot from the --sysroot flag
        let sysroot = ($jig.flags | where ($it | str starts-with "--sysroot=") | first | split row "=" | last)
        $env.CPATH = $"($sysroot)/include"
        note bindgen-env $"CPATH=($env.CPATH)"
      '';
    }
    {
      name = "populate-wraps";
      run = ''
        cd $c.src
        mkdir subprojects

        # C utility libraries
        ^cp -r ${sources.fetch "c-stdaux"}/. subprojects/libcstdaux-1
        ^cp -r ${sources.fetch "c-list"}/. subprojects/libclist-3
        ^cp -r ${sources.fetch "c-rbtree"}/. subprojects/libcrbtree-3
        ^cp -r ${sources.fetch "c-dvar"}/. subprojects/libcdvar-1
        ^cp -r ${sources.fetch "c-ini"}/. subprojects/libcini-1
        ^cp -r ${sources.fetch "c-shquote"}/. subprojects/libcshquote-1
        ^cp -r ${sources.fetch "c-utf8"}/. subprojects/libcutf8-1

        # Rust libraries
        ^cp -r ${sources.fetch "sys"}/. subprojects/sys-1
        ^cp -r ${sources.fetch "libc"}/. subprojects/libc-rs-0.2

        # Make writable first (store paths are read-only)
        ^chmod -R u+w subprojects

        # libc-rs needs patch files: meson.build and meson-detect-version.sh
        # These are in subprojects/packagefiles/libc-rs/ in the dbus-broker source
        ^cp -r subprojects/packagefiles/libc-rs/. subprojects/libc-rs-0.2/

        # Fix shebang in Python scripts (nix sandbox has no /usr/bin/env)
        let python = "${buildPkgs.cpython}/bin/python3"
        for f in (glob "subprojects/**/*.py") {
          edit $f { str replace "#!/usr/bin/env python3" $"#!($python)" }
        }

        note populate-wraps "copied 9 wrap subprojects"
      '';
    }
  ];

  # Custom install: farm package with prefix=/usr
  phases.replace."meson.install" = {
    name = "install";
    run = ''
      let destdir = $"($c.build)/dest"
      with-env {DESTDIR: $destdir} { x meson install --no-rebuild }
      # Copy /usr subtree to $out
      ^cp -r $"($destdir)/usr/." $c.out
      # .pc files: make prefix relative
      for f in (files $"($c.out)/lib/pkgconfig/*.pc") {
        edit $f { str replace "prefix=/usr" "prefix=''${pcfiledir}/../.." }
      }
    '';
  };

  bin = [
    "dbus-broker"
    "dbus-broker-launch"
  ];

  tests.run = false;
  tests.version = "--version";

  platforms.os = [ "linux" ];
}
