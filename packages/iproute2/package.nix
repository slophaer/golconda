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
  # /usr/share/iproute2, tc and ip plugins in /usr/lib), never the scratch prefix. The declared
  # prefix gives configure --prefix and make PREFIX=, and the install goes through DESTDIR; the
  # output is what lands in /usr
  prefix = "/usr";
  make.configureFlags = [ "--libdir=/usr/lib" ];
  make.flags = [
    "SBINDIR=/usr/bin"
    "NETNS_RUN_DIR=/run/netns"
    "CC=cc"
    "HOSTCC=cc"
    "AR=llvm-ar"
  ];
  stagedRoots = {
    "/etc" = null;
    "/var" = null;
  };
  phases.after."make.install" = [
    {
      name = "drop-routel";
      run = ''rm $"($c.out)/bin/routel" # a python script'';
    }
  ];
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
