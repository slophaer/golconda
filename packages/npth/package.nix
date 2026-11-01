# the portable thread library gpg-agent runs on
{ package }:
package {
  name = "npth";
  uses = [ "autotools" ];
  bin = [ ]; # library only
}
