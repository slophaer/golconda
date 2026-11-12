# virt-firmware: tools for virtual machines' UEFI firmware. scripts/boot-test writes the Secure
# Boot keys into a copy of OVMF's variable store with its virt-fw-vars, offline. A development
# tool, not part of an image. Of its declared requirements, pyyaml, requests and crypt_r serve only
# virt.qemutest (booting distribution images), which the boot test does not use: left out, with its
# three programs
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "virt-firmware";
  uses = [ "python" ];
  python.module = "virt.firmware.vars";
  buildDependencies = [ buildPkgs.python-setuptools ];
  dependencies = [
    # bin/virt-fw-vars is `#!.../python3`: the interpreter, found via the launcher
    pkgs.cpython
    pkgs.python-cryptography
    pkgs.python-pefile
  ];
  phases.after."python.install" = {
    name = "no-qemutest";
    run = ''
      for b in [virt-cloud-boot virt-cloud-fetch virt-kvm-caps] { rm $"($c.out)/bin/($b)" }
    '';
  };
  bin = [ "virt-fw-vars" ];
  # no program of virt-firmware has --version
  tests.version = false;
}
