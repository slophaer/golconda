# error codes and the portability layer (gpgrt) under GnuPG's libraries
{ package }:
package {
  name = "libgpg-error";
  uses = [ "autotools" ];
  # gpg-error --desc reads share/libgpg-error/errorref.txt; upstream compiles in its prefix, the
  # patch looks next to the running tool instead
  patches = [ ./relocatable.patch ];
  autotools.flags = [
    "--sysconfdir=/etc" # the library's one compiled-in path, ambient
    "--disable-doc"
    "--disable-languages" # no C++, Common Lisp or Tcl bindings
  ];
  bin = [
    "gpg-error"
    "gpgrt-config"
  ];
  platforms.os = [ "linux" ];
}
