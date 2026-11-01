# libaio: Linux-native asynchronous I/O facility
{ package }:
package {
  name = "libaio";
  uses = [ "make" ];
  # The Makefile uses $(DESTDIR)$(prefix); repkgs' make helper sets prefix=$out,
  # so we don't need DESTDIR. The default flags work.
  # libaio has no --version flag and no CLI binary
  tests.version = false;
  # Tests fail with clang due to old-style C designators and require root/devices
  tests.run = false;
  bin = [ ];
  platforms.os = [ "linux" ];
}
