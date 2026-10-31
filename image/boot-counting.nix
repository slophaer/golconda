# image/boot-counting.nix: the boot counter a release starts with.
#
# One source for the UKI's installed name (lib/image/uki.nix, via
# image/default.nix bootCounting) and for the sysupdate UKI target
# (image/sysupdate.nix). systemd-boot decrements triesLeft and increments
# triesDone on each attempt; systemd-bless-boot removes the suffix when
# boot-complete.target is reached. `+3-0` is the first attempt of a release.
{
  triesLeft = 3;
  triesDone = 0;
}
