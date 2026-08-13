#!/bin/zsh
set -u
setopt NULL_GLOB
zmodload zsh/datetime

cd /Users/raliclo/proj/lzfse2 || exit 1

POWER_DIR="${POWER_DIR:-powerResults}"
POWER_RAW_DIR="${POWER_RAW_DIR:-${POWER_DIR}/raw}"
POWER_TMP_DIR="${POWER_TMP_DIR:-${POWER_DIR}/tmp}"
POWER_TAR_DIR="${POWER_TAR_DIR:-${TMPDIR:-/tmp}/lzfse2-power-tar.$$}"
POWER_CSV="${POWER_CSV:-${POWER_DIR}/power_summary.csv}"
POWER_STATUS="${POWER_STATUS:-${POWER_DIR}/power_status.txt}"
# 500ms 間隔：每個 powermetrics period 覆蓋更完整的能量積分，
# 避免短窗口在 CPU 負載驟升瞬間只取到極少樣本，確保覆蓋完整 decode 執行期。
POWER_INTERVAL_MS="${POWER_INTERVAL_MS:-500}"
# tasks + --show-process-energy adds the ALL_TASKS "Energy Impact" total. It is
# Apple's unitless relative metric, not mW, but it keeps reading when the CPU
# power estimate does not: macOS 27.0 build 26A5388g reported CPU Power 0 mW
# while Energy Impact still tracked load (26A5406e restored CPU Power).
# tasks 加上 --show-process-energy 可取得 ALL_TASKS 的 "Energy Impact" 總計。
# 它是 Apple 的無單位相對指標而非 mW，但在 CPU 功率估算失效時仍有讀數：
# macOS 27.0 build 26A5388g 回報 CPU Power 0 mW，Energy Impact 仍隨負載變動
# （26A5406e 已修復 CPU Power）。
POWER_SAMPLERS="${POWER_SAMPLERS:-cpu_power,gpu_power,tasks}"
LZFSE_DECODE_REPEAT="${LZFSE_DECODE_REPEAT:-3}"
# TGZ 必須明確走 swift_tar，不依賴 PATH shim（power 步驟未帶 shim，裸 tar 會
# 落到 /usr/bin/tar 的單執行緒 gzip，量到的能耗與官方 swift_tar benchmark 不符）。
# TGZ must go through swift_tar explicitly rather than the PATH shim (the power
# step runs without the shim, so a bare `tar` falls back to /usr/bin/tar's
# single-threaded gzip and its energy does not match the swift_tar benchmark).
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-/opt/homebrew/bin/swift_tar}"

mkdir -p "$POWER_DIR" "$POWER_RAW_DIR" "$POWER_TMP_DIR" "$POWER_TAR_DIR"
echo "RUNNING_POWER_BENCHMARK $(date +%H:%M:%S)" > "$POWER_STATUS"

cleanupPowerTmp() {
    rm -rf "$POWER_TMP_DIR"
    mkdir -p "$POWER_TMP_DIR"
}

cleanupPowerArtifacts() {
    cleanupPowerTmp
    rm -rf "$POWER_TAR_DIR"
}

cleanupPowerTmp
trap cleanupPowerArtifacts EXIT

powerRoundStatus() {
    if [[ -n "${ROUND_STATUS_FILE:-}" ]]; then
        echo "$@ $(date +%H:%M:%S)" >> "$ROUND_STATUS_FILE"
    fi
}

csvHeader() {
    cat > "$POWER_CSV" <<'EOF'
algorithm,encode_decode,n,duration_ns,cpu_power_mw,cpu_energy_j,gpu_power_mw,ane_power_mw,dram_power_mw,combined_power_mw,energy_j,energy_impact,status
演算法,壓縮/解壓縮,在途任務數,耗時(ns),CPU功率(mW),CPU能耗(J),GPU功率(mW),ANE功率(mW),DRAM功率(mW),總功率(mW),總能耗(J),Energy Impact(相對值),狀態
EOF
}

csvEscape() {
    local s="$1"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

appendCsv() {
    local dataset="$1" n="$2" phase="$3" algo="$4" duration_ns="$5"
    local cpu="$6" cpu_energy="$7" gpu="$8" ane="$9" dram="${10}" combined="${11}" energy="${12}"
    local energy_impact="${13}" csv_status="${14}"
    local algorithm="${dataset}-${algo}"
    {
        csvEscape "$algorithm"
        printf ",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s" "$phase" "$n" "$duration_ns" "$cpu" "$cpu_energy" "$gpu" "$ane" "$dram" "$combined" "$energy" "$energy_impact" "$csv_status"
        printf "\n"
    } >> "$POWER_CSV"
}

parsePowerLog() {
    local raw_log="$1" duration_ns="$2" repeat="${3:-1}"
    awk -v duration_ns="$duration_ns" -v repeat="$repeat" '
        function add(name, value) {
            sum[name] += value
            cnt[name] += 1
        }
        function valueAfterColon(line, tmp) {
            tmp = line
            sub(/^[^:]*:[[:space:]]*/, "", tmp)
            sub(/[[:space:]].*$/, "", tmp)
            return tmp + 0
        }
        /CPU Power:/ {
            add("cpu", valueAfterColon($0))
        }
        /GPU Power:/ {
            add("gpu", valueAfterColon($0))
        }
        /ANE Power:/ {
            add("ane", valueAfterColon($0))
        }
        /DRAM Power:/ {
            add("dram", valueAfterColon($0))
        }
        /Combined Power/ {
            add("combined", valueAfterColon($0))
        }
        # ALL_TASKS is the system-wide roll-up row; Energy Impact is its last field.
        # ALL_TASKS 為系統層級彙總列，Energy Impact 是該列最後一個欄位。
        /^ALL_TASKS/ {
            add("energy_impact", $NF)
        }
        END {
            cpu = cnt["cpu"] ? sprintf("%.3f", sum["cpu"] / cnt["cpu"]) : ""
            gpu = cnt["gpu"] ? sprintf("%.3f", sum["gpu"] / cnt["gpu"]) : ""
            ane = cnt["ane"] ? sprintf("%.3f", sum["ane"] / cnt["ane"]) : ""
            dram = cnt["dram"] ? sprintf("%.3f", sum["dram"] / cnt["dram"]) : ""
            combined = cnt["combined"] ? sprintf("%.3f", sum["combined"] / cnt["combined"]) : ""
            samples = cnt["cpu"] + cnt["gpu"] + cnt["ane"] + cnt["dram"] + cnt["combined"]
            power_for_energy = combined
            if (power_for_energy == "") power_for_energy = cpu
            if (power_for_energy == "") power_for_energy = 0
            cpu_energy = cpu == "" ? "" : sprintf("%.6f", (duration_ns / 1000000000.0 / repeat) * ((cpu + 0) / 1000.0))
            energy = sprintf("%.6f", (duration_ns / 1000000000.0 / repeat) * (power_for_energy / 1000.0))
            energy_impact = cnt["energy_impact"] ? sprintf("%.2f", sum["energy_impact"] / cnt["energy_impact"]) : ""
            printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n", samples, cpu, cpu_energy, gpu, ane, dram, combined, energy, energy_impact
        }
    ' "$raw_log"
}

stopPowermetrics() {
    local pm_pid="$1"
    local waited=0 signal_name
    local -a targets

    # powermetrics 透過 sudo 啟動；$! 通常是 sudo，真正 sampler 是 root child。
    # macOS sudo 可能形成 sudo -> sudo -> powermetrics，多層 descendant 都要 signal。
    for signal_name in INT TERM KILL; do
        targets=("${(@f)$(powermetricsTargets "$pm_pid")}")
        (( ${#targets[@]} == 0 )) && break

        sudo -n kill "-${signal_name}" "${targets[@]}" >/dev/null 2>&1
        waited=0
        while [[ -n "$(powermetricsTargets "$pm_pid")" && $waited -lt 20 ]]; do
            sleep 0.1
            waited=$((waited + 1))
        done
    done

    if [[ -n "$(powermetricsTargets "$pm_pid")" ]]; then
        echo "POWER_STOP_FAILED ${pm_pid} $(date +%H:%M:%S)" >> "$POWER_STATUS"
        powerRoundStatus "POWER_STOP_FAILED ${pm_pid}"
        return 1
    fi

    wait "$pm_pid" >/dev/null 2>&1 || true
}

powermetricsTargets() {
    local root="$1"
    local -a targets
    targets=("$root" "${(@f)$(descendantPids "$root")}")
    typeset -U targets
    for target in "${targets[@]}"; do
        sudo -n kill -0 "$target" >/dev/null 2>&1 && print -r -- "$target"
    done
}

descendantPids() {
    local root="$1"
    local child
    for child in "${(@f)$(pgrep -P "$root" 2>/dev/null)}"; do
        [[ -n "$child" ]] || continue
        print -r -- "$child"
        descendantPids "$child"
    done
}

anyPidAlive() {
    local pid
    for pid in "$@"; do
        kill -0 "$pid" >/dev/null 2>&1 && return 0
    done
    return 1
}

fileSize() {
    if [[ -f "$1" ]]; then
        stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
    else
        echo 0
    fi
}

measurePower() {
    local dataset="$1" n="$2" phase="$3" algo="$4" label="$5" raw_bytes="$6" compressed_file="$7"
    shift 7
    local raw_log="${POWER_RAW_DIR}/${label}.powermetrics.txt"
    local start_real end_real duration_ns rc stop_rc compressed_bytes mbps parsed samples cpu cpu_energy gpu ane dram combined energy result_status

    rm -f "$raw_log"
    echo "RUNNING_POWER ${label} $(date +%H:%M:%S)" >> "$POWER_STATUS"
    powerRoundStatus "RUNNING_POWER ${label}"

    sudo -n /usr/bin/powermetrics --samplers "$POWER_SAMPLERS" --show-process-energy -i "$POWER_INTERVAL_MS" > "$raw_log" 2>&1 &
    local pm_pid=$!
    sleep 0.2
    start_real="$EPOCHREALTIME"
    "$@"
    rc=$?
    end_real="$EPOCHREALTIME"
    # 等待超過一個完整 500ms 採樣窗口，確保最後一個 period 的數據被寫入日誌。
    sleep 0.6
    stopPowermetrics "$pm_pid"
    stop_rc=$?

    duration_ns=$(awk -v start="$start_real" -v end="$end_real" 'BEGIN { printf "%.0f", (end - start) * 1000000000.0 }')
    compressed_bytes=$(fileSize "$compressed_file")
    mbps=$(awk -v bytes="$raw_bytes" -v ns="$duration_ns" 'BEGIN { if (ns > 0) printf "%.2f", bytes / ns * 1000.0; else printf "" }')
    local repeat=1
    if [[ "$phase" == "decode" && "$algo" != "tgz" && "$algo" != "zstd" && "$algo" != "tar.lz4" ]]; then
        repeat="$LZFSE_DECODE_REPEAT"
    fi
    parsed="$(parsePowerLog "$raw_log" "$duration_ns" "$repeat")"
    IFS='|' read -r samples cpu cpu_energy gpu ane dram combined energy energy_impact <<< "$parsed"

    if [[ $stop_rc -ne 0 ]]; then
        result_status="failed:powermetrics_stop"
        echo "POWER_FAILED ${label} powermetrics_stop $(date +%H:%M:%S)" >> "$POWER_STATUS"
        powerRoundStatus "POWER_FAILED ${label} powermetrics_stop"
    elif [[ $rc -eq 0 && ( -z "$samples" || "$samples" == "0" ) ]]; then
        result_status="ok:no_samples"
        echo "POWER_NO_SAMPLES ${label} $(date +%H:%M:%S)" >> "$POWER_STATUS"
        powerRoundStatus "POWER_NO_SAMPLES ${label}"
    elif [[ $rc -eq 0 ]]; then
        result_status="ok"
        echo "POWER_DONE ${label} $(date +%H:%M:%S)" >> "$POWER_STATUS"
        powerRoundStatus "POWER_DONE ${label}"
    else
        result_status="failed:${rc}"
        echo "POWER_FAILED ${label} ${rc} $(date +%H:%M:%S)" >> "$POWER_STATUS"
        powerRoundStatus "POWER_FAILED ${label} ${rc}"
    fi
    appendCsv "$dataset" "$n" "$phase" "$algo" "$duration_ns" "$cpu" "$cpu_energy" "$gpu" "$ane" "$dram" "$combined" "$energy" "$energy_impact" "$result_status"
    [[ $stop_rc -eq 0 ]] || return "$stop_rc"
    return "$rc"
}

makeTarInput() {
    local dataset="$1"
    local tar_input="${POWER_TAR_DIR}/${dataset}.tar"
    rm -f "$tar_input"
    tar -cf "$tar_input" "$dataset"
    echo "$tar_input"
}

runEncode() {
    local dataset="$1" algo="$2" n="$3" tar_input="$4" out="$5"
    case "$algo" in
        tgz)      "$SWIFT_TAR_BIN" czf "$out" "$dataset" ;;
        zstd)     zstd -9 -T0 -q -f "$tar_input" -o "$out" ;;
        tar.lz4)  lz4 -T0 -6 -q -f "$tar_input" "$out" ;;
        other3)   ./lzfse -encode -si -o "$out" -algo other3 -n "$n" < "$tar_input" ;;
        optimal3) ./lzfse -encode -si -o "$out" -algo other3 -optimal3 -n "$n" < "$tar_input" ;;
        apple)    ./lzfse -encode -si -o "$out" -algo apple -n "$n" < "$tar_input" ;;
        bvx3)     ./lzfse -encode -si -o "$out" -algo bvx3 -n "$n" < "$tar_input" ;;
        lazy2)    ./lzfse -encode -si -o "$out" -algo bvx3 -lazy2 -n "$n" < "$tar_input" ;;
        optimal)  ./lzfse -encode -si -o "$out" -algo bvx3 -optimal -n "$n" < "$tar_input" ;;
        *)        echo "[Error] unknown encode algorithm: $algo" >&2; return 1 ;;
    esac
}

runDecode() {
    local algo="$1" n="$2" input="$3"
    case "$algo" in
        tgz)      "$SWIFT_TAR_BIN" tzf "$input" >/dev/null ;;
        zstd)     zstd -d -q -f "$input" -o /dev/null ;;
        tar.lz4)  lz4 -d -q -f "$input" /dev/null ;;
        other3|optimal3)
                  for i in 1 2 3; do ./lzfse -decode -i "$input" -o /dev/null -algo other3 -n "$n"; done ;;
        apple)    for i in 1 2 3; do ./lzfse -decode -i "$input" -o /dev/null -algo apple -n "$n"; done ;;
        bvx3|lazy2|optimal)
                  for i in 1 2 3; do ./lzfse -decode -i "$input" -o /dev/null -algo bvx3 -n "$n"; done ;;
        *)        echo "[Error] unknown decode algorithm: $algo" >&2; return 1 ;;
    esac
}

if ! sudo -n true >/dev/null 2>&1; then
    echo "[Error] sudo -n failed; powermetrics requires passwordless sudo for non-interactive benchmark." | tee -a "$POWER_STATUS"
    powerRoundStatus "POWER_BENCHMARK_FAILED sudo"
    exit 1
fi

csvHeader

typeset -a POWER_N_SWEEP
if [[ -n "${POWER_N_SWEEP_OVERRIDE:-}" ]]; then
    POWER_N_SWEEP=(${=POWER_N_SWEEP_OVERRIDE})
elif [[ -n "${LZFSE_N_SWEEP_OVERRIDE:-}" ]]; then
    POWER_N_SWEEP=(${=LZFSE_N_SWEEP_OVERRIDE})
else
    POWER_N_SWEEP=(40 8 4)
fi

typeset -a EXTERNAL_ALGOS
EXTERNAL_ALGOS=(tgz zstd tar.lz4)
typeset -a LZFSE_ALGOS
LZFSE_ALGOS=(other3 optimal3 apple bvx3 lazy2 optimal)

for dataset in claw-code llama.cpp; do
    if [[ ! -d "$dataset" ]]; then
        echo "[Error] dataset not found: $dataset" | tee -a "$POWER_STATUS"
        powerRoundStatus "POWER_BENCHMARK_FAILED ${dataset} missing"
        exit 1
    fi
    raw_bytes=$(du -sk "$dataset" | awk '{print $1 * 1024}')
    tar_input="$(makeTarInput "$dataset")"

    for algo in "${EXTERNAL_ALGOS[@]}"; do
        out="${POWER_TMP_DIR}/${dataset}.${algo}.power.out"
        case "$algo" in
            tgz) out="${POWER_TMP_DIR}/${dataset}.power.tgz" ;;
            zstd) out="${POWER_TMP_DIR}/${dataset}.power.zst" ;;
            tar.lz4) out="${POWER_TMP_DIR}/${dataset}.power.tar.lz4" ;;
        esac
        rm -f "$out"
        label="${dataset}-${algo}-encode"
        measurePower "$dataset" "" "encode" "$algo" "$label" "$raw_bytes" "$out" runEncode "$dataset" "$algo" "" "$tar_input" "$out" || exit $?
        label="${dataset}-${algo}-decode"
        measurePower "$dataset" "" "decode" "$algo" "$label" "$raw_bytes" "$out" runDecode "$algo" "" "$out" || exit $?
        cleanupPowerTmp
    done

    for n in "${POWER_N_SWEEP[@]}"; do
        for algo in "${LZFSE_ALGOS[@]}"; do
            out="${POWER_TMP_DIR}/${dataset}.${algo}-n${n}.power.lzfse"
            rm -f "$out"
            label="${dataset}-${algo}-n${n}-encode"
            measurePower "$dataset" "$n" "encode" "$algo" "$label" "$raw_bytes" "$out" runEncode "$dataset" "$algo" "$n" "$tar_input" "$out" || exit $?
            label="${dataset}-${algo}-n${n}-decode"
            measurePower "$dataset" "$n" "decode" "$algo" "$label" "$raw_bytes" "$out" runDecode "$algo" "$n" "$out" || exit $?
            cleanupPowerTmp
        done
    done

    rm -f "$tar_input"
done

echo "POWER_BENCHMARK_DONE $(date +%H:%M:%S)" >> "$POWER_STATUS"
powerRoundStatus "POWER_BENCHMARK_DONE"
