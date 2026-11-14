# dbus-broker: high-performance D-Bus message broker with Rust parts (unreleased main branch).
# The launcher (dbus-broker-launch) execs dbus-broker by compiled-in path, so this is a farm
# package with prefix=/usr.
#
# Upstream ships no system bus policy and no dbus.socket (distributions take dbus's), so the
# package installs its own beside its unit (phase install-bus):
# - share/dbus-1/system.conf (system.conf here): the policy of dbus's bus/system.conf.in (dbus
#   1.16). Every user may connect; no one owns a name or calls a method unless a policy file in
#   system.d allows it (systemd's, for network1, resolve1, login1, ...). <user>, <listen> and
#   <auth> are for dbus-daemon: dbus-broker takes its socket from dbus.socket and ignores them.
#   <servicedir> is required: dbus-broker compiles in no default, so without it an on-demand
#   name (org.freedesktop.timedate1, for one) is "not activatable" and timedatectl fails. The
#   image farms systemd's share/dbus-1/system-services there; each file names its unit
#   (SystemdService=), and systemd starts it on the first call.
# - lib/systemd/system/dbus.socket (dbus.socket here): the system bus socket, which activates
#   dbus-broker.service (the image's dbus.service alias).
{
  package,
  sources,
  pkgs,
  buildPkgs,
}:
let
  # the bus policy and the socket unit (see above), copied into the output by install-bus
  systemConf = builtins.path {
    path = ./system.conf;
    name = "dbus-system.conf";
  };
  dbusSocket = builtins.path {
    path = ./dbus.socket;
    name = "dbus.socket";
  };
in
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
  # cannot fetch them; we provide them as extra sources. bindgen gets the toolchain's target,
  # sysroot and headers from the builder (BINDGEN_EXTRA_CLANG_ARGS).
  phases.before."meson.configure" = [
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

  phases.after."meson.install" = [
    {
      name = "install-bus";
      run = ''
        mkdir $"($c.out)/share/dbus-1" $"($c.out)/lib/systemd/system"
        ^cp ${systemConf} $"($c.out)/share/dbus-1/system.conf"
        ^cp ${dbusSocket} $"($c.out)/lib/systemd/system/dbus.socket"
        ^chmod 0644 $"($c.out)/share/dbus-1/system.conf" $"($c.out)/lib/systemd/system/dbus.socket"
      '';
    }
  ];

  bin = [
    "dbus-broker"
    "dbus-broker-launch"
  ];

  tests.run = false;
  tests.version = "--version";

  platforms.os = [ "linux" ];
}
