# error codes and the portability layer (gpgrt) under GnuPG's libraries
{ package }:
package {
  name = "libgpg-error";
  uses = [ "autotools" ];
  autotools.flags = [
    "--sysconfdir=/etc" # the library's one compiled-in path, ambient
    "--disable-doc"
    "--disable-languages" # no C++, Common Lisp or Tcl bindings
  ];
  # gpg-error, a tool that prints what an error code means, compiles in the path of its
  # errorref.txt (which --disable-doc does not install), so it names the install prefix. Nothing
  # runs it: GnuPG needs the library
  phases.after."autotools.install" = {
    name = "drop-gpg-error";
    run = ''rm $"($c.out)/bin/gpg-error"'';
  };
  bin = [ "gpgrt-config" ];
  platforms.os = [ "linux" ];
}
