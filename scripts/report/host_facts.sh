#!/usr/bin/env bash
# Export host facts that node_exporter does not know about (hourly systemd timer):
#   autoops_apt_security_updates_pending  number of pending security upgrades
#   autoops_apt_updates_pending           all pending upgrades
#   autoops_reboot_required               1 if /var/run/reboot-required exists
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

security=0
all=0
if command -v apt-get >/dev/null; then
  upgrades=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep '^Inst ' || true)
  all=$(grep -c . <<< "$upgrades" || true)
  security=$(grep -ci 'security' <<< "$upgrades" || true)
fi
reboot=0
[[ -f /var/run/reboot-required ]] && reboot=1

write_textfile autoops_host_facts "# HELP autoops_apt_security_updates_pending Pending security upgrades.
# TYPE autoops_apt_security_updates_pending gauge
autoops_apt_security_updates_pending ${security:-0}
# HELP autoops_apt_updates_pending Pending upgrades (all origins).
# TYPE autoops_apt_updates_pending gauge
autoops_apt_updates_pending ${all:-0}
# HELP autoops_reboot_required 1 if the system needs a reboot to finish updates.
# TYPE autoops_reboot_required gauge
autoops_reboot_required $reboot"
