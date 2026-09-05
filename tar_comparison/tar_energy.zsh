#!/bin/zsh
# =====================================================================
# tar_energy.zsh — controlled A/B: system tar vs swift_tar, CPU energy
#                 for TGZ encode/decode via powermetrics (needs sudo).
#                 energy_J = duration_s * avg_CPU_mW / 1000
# tar_energy.zsh —— 受控 A/B：系統 tar vs swift_tar，用 powermetrics 量
#                 TGZ encode/decode 的 CPU 能耗（需 sudo）。
#
# Usage / 用法：sudo -v && tar_comparison/tar_energy.zsh [corpus]
#              tar_comparison/tar_energy.zsh --help
# =====================================================================
set -u

script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '3,10p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

zmodload zsh/datetime
cd "${script_path:h}/.." || exit 1  # repo root / 專案根目錄
CORPUS="${1:-claw-code}"
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-/opt/homebrew/bin/swift_tar}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

energyOf() {  # label bin op(czf|xzf) args...
  local label="$1" bin="$2" op="$3"; shift 3
  local log="$TMP/pm.txt"; : > "$log"
  sudo -n powermetrics --samplers cpu_power -i 100 > "$log" 2>/dev/null &
  sleep 0.4
  local s=$EPOCHREALTIME
  if [[ "$op" == czf ]]; then "$bin" czf "$@" >/dev/null 2>&1
  else "$bin" xzf "$@" >/dev/null 2>&1; fi
  local e=$EPOCHREALTIME
  sudo -n pkill -x powermetrics 2>/dev/null
  sleep 0.3
  local dur=$(( e - s ))
  local avg=$(awk -F'[: ]+' '/CPU Power:/{sum+=$3;n++} END{if(n)printf "%.1f",sum/n; else print 0}' "$log")
  local energy=$(( dur * avg / 1000.0 ))
  printf "%-22s dur_s=%-7.2f avgCPU_mW=%-9s energy_J=%-7.2f\n" "$label" "$dur" "$avg" "$energy"
}

echo "[Info] corpus: $CORPUS"
echo "== Pass2: CPU energy (powermetrics) =="
for pair in "systemtar:/usr/bin/tar" "swifttar:$SWIFT_TAR_BIN"; do
  name="${pair%%:*}"; bin="${pair##*:}"
  arc="$TMP/${name}.tgz"; dest="$TMP/${name}_d"
  "$bin" czf "$arc" "$CORPUS" >/dev/null 2>&1
  energyOf "${name}-encode" "$bin" czf "$TMP/${name}_enc.tgz" "$CORPUS"
  mkdir -p "$dest"
  energyOf "${name}-decode" "$bin" xzf "$arc" -C "$dest"
  rm -rf "$dest" "$arc" "$TMP/${name}_enc.tgz"
done
echo "ENERGY_AB_DONE"
