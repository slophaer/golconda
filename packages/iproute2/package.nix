# ip, ss, tc, bridge and friends. No libbpf/libelf (tc BPF loading), libdb (arpd), iptables,
# libselinux or libtirpc: configure only enables what pkg-config finds
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "iproute2";
  uses = [ "make" ];
  # configure is not autoconf: it writes config.mk, and only --prefix/--libdir feed the compiled-in
  # paths. They name the ambient directories the programs read (rt_tables & co. in
  # /usr/share/iproute2, tc and ip plugins in /usr/lib), never the scratch prefix
  make.configureFlags = [
    "--prefix=/usr"
    "--libdir=/usr/lib"
  ];
  make.flags = [
    "PREFIX=/usr"
    "SBINDIR=/usr/bin"
    "NETNS_RUN_DIR=/run/netns"
    "CC=cc"
    "HOSTCC=cc"
    "AR=llvm-ar"
  ];
  # the Makefile installs below $(DESTDIR)$(PREFIX): /usr is the ambient prefix, the package is
  # what lands in it
  phases.replace."make.install" = {
    name = "install";
    run = ''
      with-env {DESTDIR: $"($c.build)/dest"} { x make ...(options make | get flags) install }
      ^cp -r $"($c.build)/dest/usr/." $c.out
      rm $"($c.out)/bin/routel" # a python script
    '';
  };
  buildDependencies = [
    buildPkgs.bison
    buildPkgs.flex
  ];
  dependencies = [
    pkgs.libmnl
    pkgs.libcap
  ];
  tests.run = false; # the suite wants root, network namespaces and the kernel's modules
  tests.version = "-V";
  bin = [
    "ip"
    "ss"
    "tc"
    "bridge"
  ];
  platforms.os = [ "linux" ];
}
