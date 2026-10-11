#!/usr/bin/env bash
# Scenario 4: the disk fills up (runaway logs, forgotten dumps, uploads...).
# Expected: usage > 85% is seen, the watchdog cleans known garbage and reports how much
# space it freed; disk alerts fire/resolve accordingly.
#
# Laptop demo (default): fills the 300 MB tmpfs volume "autoops_chaosdisk" that node-exporter
# and the watchdog watch - your real disk is never touched.
# Server: CHAOS_DISK_MODE=host fills / with /var/tmp/autoops-chaos-fill.bin (cleaned by the
# watchdog's WATCHDOG_CLEAN_GLOBS) up to CHAOS_DISK_TARGET percent.
source "$(dirname "$0")/lib.sh"
preflight

name="4. Заполнен диск"
banner "$name"
target=${CHAOS_DISK_TARGET:-92}
mode=${CHAOS_DISK_MODE:-volume}
volume=${CHAOS_DISK_VOLUME:-autoops_chaosdisk}
T0=$(date +%s)

if [[ $mode == volume ]]; then
  docker volume inspect "$volume" >/dev/null 2>&1 || die "volume $volume not found (is the local stack up?)"
  mount_q='mountpoint="/chaosdisk"'
  step "заполняем том $volume до ${target}%"
  docker run --rm -v "$volume:/chaosdisk" --entrypoint sh "$HELPER_IMAGE" -c "
    set -e; mkdir -p /chaosdisk/tmp
    total=\$(df -k /chaosdisk | awk 'NR==2{print \$2}'); used=\$(df -k /chaosdisk | awk 'NR==2{print \$3}')
    need=\$(( total * $target / 100 - used ))
    [ \$need -gt 0 ] && dd if=/dev/zero of=/chaosdisk/tmp/chaos-fill.bin bs=1024 count=\$need 2>/dev/null
    df -h /chaosdisk | tail -1"
  usage() { docker run --rm -v "$volume:/chaosdisk" --entrypoint sh "$HELPER_IMAGE" -c "df -P /chaosdisk | awk 'NR==2{gsub(\"%\",\"\",\$5); print \$5}'"; }
else
  mount_q='mountpoint="/"'
  step "заполняем / до ${target}% файлом /var/tmp/autoops-chaos-fill.bin"
  total=$(df -k / | awk 'NR==2{print $2}'); used=$(df -k / | awk 'NR==2{print $3}')
  need=$(( total * target / 100 - used ))
  (( need > 0 )) && fallocate -l "${need}K" /var/tmp/autoops-chaos-fill.bin
  df -h / | tail -1
  usage() { df -P / | awk 'NR==2{gsub("%","",$5); print $5}'; }
fi

full_seen() { prom_gt "100 * (1 - node_filesystem_avail_bytes{$mount_q} / node_filesystem_size_bytes{$mount_q})" 85; }
detected=$(wait_until 60 full_seen) || true
step "node-exporter видит заполнение >85% через ${detected} с; ждём watchdog…"
cleaned() { (( $(usage) < 85 )); }
recovered=$(wait_until 180 cleaned) || true
step "место освобождено через ${recovered} с (сейчас $(usage)%)"
if wait_until 30 relay_has "$T0" 'Освобождено' >/dev/null; then
  alert="watchdog 🔧 (сколько освобождено)"
else
  alert="нет"
fi

result=PASS
[[ "$detected" == - || "$recovered" == - ]] && result=FAIL
record "$name" "$detected" "$recovered" "$alert" "$result"
[[ $result == PASS ]]
