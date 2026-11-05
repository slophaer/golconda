# What is proven

This is the one place that says how far the work has got; the design pages say why. Each row is a
marker of `scripts/boot-test`, which runs the image in QEMU with OVMF; the flags are in
[Image artifacts: the boot test](reference/image.md#boot-test-scriptsboot-test). The image enforces
IPE, so every run of the default image uses `--secure-boot`; the last column lists the flags on top
of it. The image for a host without Secure Boot (`/system.secureBoot = false`,
`image-smoke-test-nosb`) runs without it, on OVMF with no Secure Boot and no TPM.

| claim                                                                                    | marker                                                                                                   | flags                                           |
| ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| boots to `multi-user.target` and `boot-complete.target`                                  | `multi-user-reached`, `boot-complete`                                                                    | none                                            |
| sshd is active; the host key var finished; firstboot finished without a prompt           | `sshd-active`, `var-sshd-hostkey`, `no-firstboot-prompt`                                                 | none                                            |
| root login by ssh, host name from the SMBIOS credential                                  | `ssh-login`, `hostname`                                                                                  | `--ssh-test`                                    |
| no failed unit; varlink answers                                                          | `no-failed-units`, `varlinkctl-list-interfaces`                                                          | `--ssh-test`                                    |
| firmware enforces Secure Boot                                                            | `secure-boot-enabled`                                                                                    | `--secure-boot`                                 |
| the kernel accepts the verity signature and IPE enforces                                 | no marker of its own: the boot reaches `multi-user.target` with `ipe.enforce=1`                          | `--secure-boot`                                 |
| IPE refuses a copy of a `/usr` program on the root partition, and logs it                | `ipe-denies-copy`                                                                                        | `--ssh-test`, with or without `--secure-boot`   |
| the compiled hardware database answers; nothing writes one to `/etc`                     | `hwdb`                                                                                                   | `--ssh-test`                                    |
| the host key is sealed to the TPM with the signed PCR policy, and unseals after a reboot | `hostkey-sealed-with-tpm2`, `ssh-after-reboot`, `hostkey-unchanged`                                      | `--ssh-test --tpm`                              |
| the next release unseals it without re-sealing, and so does the old one after a fallback | `hostkey-unchanged` after the update, after the fallback                                                 | `--ssh-test --tpm --next`, with `--fail-health` |
| the ESP loader is the one in `/usr`, and `loader.conf` is read                           | `loader-matches-usr`, `loader-conf-in-effect`, `boot-update-off`                                         | `--ssh-test`                                    |
| the loader updates after a good boot, not after a blessed one                            | `loader-update-ran`, `loader-update-not-run`                                                             | `--ssh-test`                                    |
| the release directory is well formed; sysupdate installs it; it boots; no failed unit    | `release-index`, `sysupdate-installed`, `boots-next`, `etc-links-stable`, `no-failed-units-after-update` | `--next`                                        |
| the recovery commands in [Boot loader](design/bootloader.md#recovery) work               | `loader-reinstall`, `set-oneshot-other-slot`, `set-default-other-slot`, `reboot-to-firmware`             | `--next`                                        |
| a `db` rotation works; the old disk is refused                                           | `boots-after-rotation`, `kernel-db-rotated`, `old-loader-refused`                                        | `--next --rotate`                               |
| a failed health check costs one try, and the old release boots after the third           | `health-check-broken`, `attempt-[1-3]-unblessed`, `fallback-to-old-slot`, `counter-exhausted`            | `--next --fail-health`                          |
| the guest fetches the release from the update server, with its own definition            | `http-source`, `http-fetch`                                                                              | `--next`                                        |
| the image's keyring is the release key; the guest checks the signed index                | `index-keyring` (`--ssh-test`), `index-signed`, `sysupdate-installed`                                    | `--next`                                        |
| a changed index installs nothing                                                         | `sysupdate-installed` fails with `BOOT_TEST_TAMPER_INDEX=1`                                              | `--next`                                        |
| `factory-reset.target` deletes the state and keeps the slots and the ESP                 | `state-gone`, `machine-id-new`, `first-boot-rerun`, `multi-user-after-reset`, `slots-kept`               | `--factory-reset --ssh-test`                    |
| the host name and root's ssh key come from null-key credentials on the ESP               | `hostname`, `esp-authorized-keys`, `ssh-login` with a key only the ESP holds                             | `--ssh-test --esp-creds`                        |
| without Secure Boot, the kernel's built-in key accepts the verity signature              | no marker of its own: `image-smoke-test-nosb` reaches `multi-user.target` with `ipe.enforce=1`           | no `--secure-boot`                              |

Not proven:

- **Enrolment on real firmware.** The harness enrols keys offline in the variable store.
- **Certificate login and admin vars.** The ssh test logs in with a plain key. No marker covers an
  OpenSSH user certificate, `TrustedUserCAKeys`, principals, the revocation list, the host
  certificate, or the push of any admin var.
- **Hardware.** Only QEMU with OVMF on x86_64 has run. aarch64 is postponed after v1
  ([Scope](design/scope.md)), because no aarch64 package can be built here.
- **Loader recovery by hand.** A loader that no longer starts, a lost ESP and a lost `db` key
  ([Boot loader: Recovery](design/bootloader.md#recovery)) have no marker. The rotation run has two
  releases, so it leaves out step 4 of the rotation.
- **A boot without the `db` enrolled.** It stops at switch-root; the harness has no marker for it.

One release was signed with a deployment key set that `scripts/make-keys` wrote outside the store.
It booted on the same markers as the throwaway set, and its next release installed over HTTP
([Release](reference/release.md)).
