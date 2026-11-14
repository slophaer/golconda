# Golconda's x86_64 kernel, built by this directory's package-local kbuild module.
# nix/packages.nix appends the policy fragment and substitutes the IPE boot policy path.
# Kernel code compiles through jig in passthrough (cached, no jig policy flags); host tools
# use jig's normal policy, which they need for the sysroot.
{
  package,
  buildPkgs,
}:
let
  baseConfig = import ./config.nix;
in
package {
  name = "linux-kernel";

  phases = [
    "kbuild.configure"
    "kbuild.build"
    "kbuild.install"
  ];
  # The local kbuild.nu reads these JSON fields (structured attrs, not generated source).
  # An override replaces a whole field: nix/packages.nix sets only the extra config, fragments
  # and files.
  env = {
    GOLCONDA_KERNEL_CONFIG = builtins.toJSON baseConfig;
    # what the system requires on top (nix/packages.nix): verified even where a fragment names it
    GOLCONDA_KERNEL_EXTRA_CONFIG = "{}";
    GOLCONDA_KERNEL_FRAGMENTS = "[]";
    # files copied into the tree before configure, { "<path in the tree>" = "<file>"; }
    GOLCONDA_KERNEL_FILES = "{}";
    GOLCONDA_KERNEL_MAKE = builtins.toJSON [
      # Kernel code through jig in passthrough, set per command as jig documents it: the compile
      # cache applies, the policy flags (hardening, sysroot, RUNPATH, interpreter, prefix map)
      # do not. The kernel brings its own.
      "CC=env JIG_PASSTHROUGH=1 cc"
      "LD=ld.lld"
      "AR=llvm-ar"
      "NM=llvm-nm"
      "STRIP=llvm-strip"
      "OBJCOPY=llvm-objcopy"
      "OBJDUMP=llvm-objdump"
      "READELF=llvm-readelf"
      # Use jig's cc for host tools: they need sysroot headers
      "HOSTCC=cc"
      "HOSTCXX=c++"
      "HOSTLD=ld.lld"
      "HOSTAR=llvm-ar"
      # Reproducibility
      "KBUILD_BUILD_TIMESTAMP=@315532800"
      "KBUILD_BUILD_USER=golconda"
      "KBUILD_BUILD_HOST=build"
      "KBUILD_BUILD_VERSION=1"
    ];
  };

  # Disable jig's hardening: the kernel sets its own
  cc.hardening = false;

  # Everything here runs or links on the build machine (kconfig, objtool, sorttable, extract-cert),
  # so a cross build needs it for the build platform: buildDependencies (tools on PATH) and
  # buildLibraries (libraries for the build machine's compiler), not dependencies.
  # kconfig needs flex and bison; timeconst.h needs bc; oid_registry needs perl.
  buildDependencies = [
    buildPkgs.flex
    buildPkgs.bison
    buildPkgs.bc
    buildPkgs.perl
  ];
  # objtool links libelf, extract-cert libcrypto: the builder gives HOSTCC (jig) their headers
  # (-isystem), libraries (-L) and RUNPATH, which the kernel's own code ignores (it uses jig in
  # passthrough, CC=env JIG_PASSTHROUGH=1 cc)
  buildLibraries = [
    buildPkgs.elfutils
    buildPkgs.openssl
  ];

  # No version test: kernel has no --version flag
  bin = [ ];
  tests.run = false;

  platforms = {
    os = [ "linux" ];
    cpu = [ "x86_64" ];
  };
}
