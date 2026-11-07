#!/bin/sh
cd "$(dirname "$0")/m" || exit 1
cmd=$7
[ -e down ] && { echo "ssh: connect to host: Connection refused" >&2; exit 255; }
echo "$cmd" >> log
entries() {
  while read -r v; do
    sel=false; [ "$v" = "$(cat version)" ] && sel=true
    tries=""; [ "$sel" = true ] && [ -e unblessed ] && tries=',"triesLeft":2,"triesDone":1'
    # the loader boots the newest installed version next: the pending one after an update
    def=$sel; [ -e pending ] && { def=false; [ "$v" = "$(cat pending)" ] && def=true; }
    echo "{\"entry\":{\"type\":\"type2\",\"id\":\"server_$v.efi\",\"version\":\"$v\",\"isDefault\":$def,\"isSelected\":$sel$tries}}"
  done < slots
  echo '{"entry":{"type":"auto","id":"auto-reboot-to-firmware-setup","isDefault":false,"isSelected":false}}'
}
# with a file `source`: what that directory's SHA256SUMS names is available, when it is not
# what runs
from_source() {
  [ -e source ] || return 0
  v=$(sed -n 's/.*_\([0-9.]*\)\.efi$/\1/p' "$(cat source)/SHA256SUMS" 2>/dev/null)
  [ -n "$v" ] && [ "$v" != "$(cat version)" ] && echo "$v" > available
  return 0
}
case "$cmd" in
  *Hostname.Describe*)
    [ -e unblessed ] && { n=$(($(cat unblessed) + 1)); echo "$n" > unblessed; [ "$n" -gt 1 ] && rm unblessed; }
    echo "{\"Hostname\":\"web1\",\"OperatingSystemImageID\":\"server\",\"OperatingSystemImageVersion\":\"$(cat version)\",\"BootID\":\"$(cat boot)\"}" ;;
  *ListBootEntries*) entries ;;
  *CheckNew*)
    from_source
    [ -e offline ] && { echo "Method call io.systemd.SysUpdate.CheckNew() failed: Protocol error" >&2; exit 1; }
    [ -e available ] && echo "{\"available\":\"$(cat available)\"}" && exit 0
    echo "Method call io.systemd.SysUpdate.CheckNew() failed: io.systemd.SysUpdate.NoUpdateNeeded" >&2; exit 1 ;;
  "/usr/lib/systemd/systemd-sysupdate update 2>&1")
    from_source
    [ -e available ] || { echo "No update needed."; exit 0; }
    a=$(cat available); echo "Selected update '$a' for install."; echo "Successfully installed update '$a'."
    echo "$a" > pending; printf '%s\n%s\n' "$(cat version)" "$a" > slots; rm available ;;
  *Shutdown.Reboot*)
    [ -e inhibited ] && { echo "Method call io.systemd.Shutdown.Reboot() failed: io.systemd.Shutdown.BlockedByInhibitor" >&2; exit 1; }
    next=$(cat oneshot 2>/dev/null || cat pending 2>/dev/null || cat version)
    [ -e fallback ] && next=$(cat version)
    echo "$next" > version; echo "boot-$(date +%s%N)" > boot; echo 0 > unblessed; rm -f pending oneshot ;;
  "bootctl set-oneshot "*)
    id=${cmd#bootctl set-oneshot }; id=${id% 2>&1}; v=${id#server_}; v=${v%.efi}; echo "$v" > oneshot ;;
  *) echo "unknown command: $cmd" >&2; exit 127 ;;
esac
