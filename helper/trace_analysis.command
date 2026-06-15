#!/bin/zsh
set -u
setopt NULL_GLOB

cd /Users/raliclo/proj/lzfse2 || exit 1
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

TRACE_DIR="./trace"
ANALYSIS_DIR="$TRACE_DIR/analysis"
TOC_DIR="$ANALYSIS_DIR/toc"
CPU_CALL_TREE_DIR="$ANALYSIS_DIR/cpu_call_tree"
TIME_PROFILE_DIR="$CPU_CALL_TREE_DIR/time-profile"
TIME_SAMPLE_DIR="$CPU_CALL_TREE_DIR/time-sample"
LOG_OUT="$ANALYSIS_DIR/trace_analysis.log"
SUMMARY_OUT="$ANALYSIS_DIR/trace_summary.csv"
STATUS_OUT="$TRACE_DIR/trace_analysis_status.txt"

rm -rf "$ANALYSIS_DIR"
mkdir -p "$TOC_DIR" "$TIME_PROFILE_DIR" "$TIME_SAMPLE_DIR"
echo "RUNNING trace_analysis $(date +%H:%M:%S)" > "$STATUS_OUT"

analysisRoundStatus() {
    if [[ -n "${ROUND_STATUS_FILE:-}" ]]; then
        echo "$@ $(date +%H:%M:%S)" >> "$ROUND_STATUS_FILE"
    fi
}

csv_escape() {
    local value="${1:-}"
    value="${value//\"/\"\"}"
    print -rn -- "\"${value}\""
}

trace_size_mb() {
    du -sm "$1" 2>/dev/null | awk '{print $1}'
}

trace_mtime() {
    stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$1" 2>/dev/null || stat -c "%y" "$1" 2>/dev/null
}

has_dir() {
    [[ -d "$1/$2" ]] && echo "yes" || echo "no"
}

toc_schemas() {
    local toc_file="$1"
    grep -Eo 'schema="[^"]+"' "$toc_file" 2>/dev/null \
        | sed -E 's/^schema="([^"]+)"$/\1/' \
        | sort -u \
        | tr '\n' ';' \
        | sed 's/;$//'
}

toc_table_count() {
    grep -Eo '<table ' "$1" 2>/dev/null | wc -l | tr -d ' '
}

toc_duration() {
    awk -F'[<>]' '/<duration>/{print $3; exit}' "$1" 2>/dev/null
}

toc_process_arguments() {
    awk '/<process arguments=/{print; exit}' "$1" 2>/dev/null \
        | sed -E 's/.*arguments="([^"]*)".*/\1/' \
        | sed 's/&quot;/"/g'
}

toc_has_schema() {
    grep -q "schema=\"$2\"" "$1" 2>/dev/null && echo "yes" || echo "no"
}

file_contains() {
    grep -E -q "$2" "$1" 2>/dev/null && echo "yes" || echo "no"
}

exports_contain() {
    local pattern="$1"
    local file_a="$2"
    local file_b="$3"
    grep -E -q "$pattern" "$file_a" "$file_b" 2>/dev/null && echo "yes" || echo "no"
}

expected_target_for_trace() {
    case "$1" in
        *-tgz.trace|*-tgz.trace.timeout)         echo "tar" ;;
        *-zstd.trace|*-zstd.trace.timeout)       echo "zstd" ;;
        *-tar.lz4.trace|*-tar.lz4.trace.timeout) echo "lz4" ;;
        *)                                       echo "lzfse-profile" ;;
    esac
}

export_trace_table() {
    local trace_path="$1"
    local schema="$2"
    local out_file="$3"
    mkdir -p "${out_file:h}"
    xcrun xctrace export \
        --input "$trace_path" \
        --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"${schema}\"]" \
        --output "$out_file"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        return "$rc"
    fi
    [[ -s "$out_file" ]]
}

{
    printf '\357\273\277trace,timeout,size_mb,modified,duration_sec,launched_arguments,expected_target,target_seen,has_corespace,has_instrument_data,has_shared_data,has_symbols,toc_status,time_profile_status,time_sample_status,contains_lzfse_profile,contains_zsh,contains_tar,contains_zstd,contains_lz4,table_count,schemas\n' > "$SUMMARY_OUT"

    trace_path=""
    failures=0
    for trace_path in "$TRACE_DIR"/*.trace(N) "$TRACE_DIR"/*.trace.timeout(N); do
        trace_name="${trace_path:t}"
        trace_base="$trace_name"
        trace_timeout="no"
        if [[ "$trace_base" == *.trace.timeout ]]; then
            trace_timeout="yes"
            trace_base="${trace_base%.trace.timeout}"
        else
            trace_base="${trace_base%.trace}"
        fi
        toc_file="$TOC_DIR/${trace_base}.toc.xml"
        time_profile_file="$TIME_PROFILE_DIR/${trace_base}.time-profile.xml"
        time_sample_file="$TIME_SAMPLE_DIR/${trace_base}.time-sample.xml"
        toc_status="ok"
        time_profile_status="skipped"
        time_sample_status="skipped"
        expected_target="$(expected_target_for_trace "$trace_name")"
        target_seen="unknown"
        table_count="0"
        schemas=""
        duration_sec=""
        launched_arguments=""
        contains_lzfse_profile="unknown"
        contains_zsh="unknown"
        contains_tar="unknown"
        contains_zstd="unknown"
        contains_lz4="unknown"

        echo "[Info] Analyze ${trace_name}"
        echo "RUNNING_TRACE_ANALYSIS ${trace_name} $(date +%H:%M:%S)" >> "$STATUS_OUT"
        analysisRoundStatus "RUNNING_TRACE_ANALYSIS ${trace_name}"

        if [[ ! -d "$trace_path/instrument_data" || ! -d "$trace_path/shared_data" ]]; then
            toc_status="incomplete_package"
            time_profile_status="skipped_incomplete"
            time_sample_status="skipped_incomplete"
            target_seen="unknown"
            contains_lzfse_profile="unknown"
            contains_zsh="unknown"
            contains_tar="unknown"
            contains_zstd="unknown"
            contains_lz4="unknown"
            echo "TRACE_ANALYSIS_SKIPPED_INCOMPLETE ${trace_name} $(date +%H:%M:%S)" >> "$STATUS_OUT"
            analysisRoundStatus "TRACE_ANALYSIS_SKIPPED_INCOMPLETE ${trace_name}"
        elif xcrun xctrace export --input "$trace_path" --toc --output "$toc_file"; then
            table_count="$(toc_table_count "$toc_file")"
            schemas="$(toc_schemas "$toc_file")"
            duration_sec="$(toc_duration "$toc_file")"
            launched_arguments="$(toc_process_arguments "$toc_file")"
            echo "TRACE_ANALYSIS_OK ${trace_name} $(date +%H:%M:%S)" >> "$STATUS_OUT"
            analysisRoundStatus "TRACE_ANALYSIS_OK ${trace_name}"

            if [[ "$(toc_has_schema "$toc_file" "time-profile")" == "yes" ]]; then
                echo "RUNNING_TRACE_TABLE_EXPORT ${trace_name} time-profile $(date +%H:%M:%S)" >> "$STATUS_OUT"
                analysisRoundStatus "RUNNING_TRACE_TABLE_EXPORT ${trace_name} time-profile"
                if export_trace_table "$trace_path" "time-profile" "$time_profile_file"; then
                    time_profile_status="ok"
                    echo "TRACE_TABLE_EXPORT_OK ${trace_name} time-profile $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    analysisRoundStatus "TRACE_TABLE_EXPORT_OK ${trace_name} time-profile"
                else
                    rc=$?
                    time_profile_status="failed:${rc}"
                    failures=$(( failures + 1 ))
                    echo "TRACE_TABLE_EXPORT_FAILED ${trace_name} time-profile ${rc} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    analysisRoundStatus "TRACE_TABLE_EXPORT_FAILED ${trace_name} time-profile ${rc}"
                fi
            else
                time_profile_status="missing_schema"
            fi

            if [[ "$(toc_has_schema "$toc_file" "time-sample")" == "yes" ]]; then
                echo "RUNNING_TRACE_TABLE_EXPORT ${trace_name} time-sample $(date +%H:%M:%S)" >> "$STATUS_OUT"
                analysisRoundStatus "RUNNING_TRACE_TABLE_EXPORT ${trace_name} time-sample"
                if export_trace_table "$trace_path" "time-sample" "$time_sample_file"; then
                    time_sample_status="ok"
                    contains_lzfse_profile="$(exports_contain "lzfse-profile" "$time_profile_file" "$time_sample_file")"
                    contains_zsh="$(exports_contain "zsh" "$time_profile_file" "$time_sample_file")"
                    contains_tar="$(exports_contain "/tar|>tar<| tar " "$time_profile_file" "$time_sample_file")"
                    contains_zstd="$(exports_contain "zstd" "$time_profile_file" "$time_sample_file")"
                    contains_lz4="$(exports_contain "lz4" "$time_profile_file" "$time_sample_file")"
                    target_seen="$(exports_contain "$expected_target" "$time_profile_file" "$time_sample_file")"
                    echo "TRACE_TABLE_EXPORT_OK ${trace_name} time-sample $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    analysisRoundStatus "TRACE_TABLE_EXPORT_OK ${trace_name} time-sample"
                else
                    rc=$?
                    time_sample_status="failed:${rc}"
                    failures=$(( failures + 1 ))
                    echo "TRACE_TABLE_EXPORT_FAILED ${trace_name} time-sample ${rc} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    analysisRoundStatus "TRACE_TABLE_EXPORT_FAILED ${trace_name} time-sample ${rc}"
                fi
            else
                time_sample_status="missing_schema"
            fi
        else
            rc=$?
            toc_status="failed:${rc}"
            failures=$(( failures + 1 ))
            echo "TRACE_ANALYSIS_FAILED ${trace_name} ${rc} $(date +%H:%M:%S)" >> "$STATUS_OUT"
            analysisRoundStatus "TRACE_ANALYSIS_FAILED ${trace_name} ${rc}"
        fi

        {
            csv_escape "$trace_name"; echo -n ","
            csv_escape "$trace_timeout"; echo -n ","
            csv_escape "$(trace_size_mb "$trace_path")"; echo -n ","
            csv_escape "$(trace_mtime "$trace_path")"; echo -n ","
            csv_escape "$duration_sec"; echo -n ","
            csv_escape "$launched_arguments"; echo -n ","
            csv_escape "$expected_target"; echo -n ","
            csv_escape "$target_seen"; echo -n ","
            csv_escape "$(has_dir "$trace_path" corespace)"; echo -n ","
            csv_escape "$(has_dir "$trace_path" instrument_data)"; echo -n ","
            csv_escape "$(has_dir "$trace_path" shared_data)"; echo -n ","
            csv_escape "$(has_dir "$trace_path" symbols)"; echo -n ","
            csv_escape "$toc_status"; echo -n ","
            csv_escape "$time_profile_status"; echo -n ","
            csv_escape "$time_sample_status"; echo -n ","
            csv_escape "$contains_lzfse_profile"; echo -n ","
            csv_escape "$contains_zsh"; echo -n ","
            csv_escape "$contains_tar"; echo -n ","
            csv_escape "$contains_zstd"; echo -n ","
            csv_escape "$contains_lz4"; echo -n ","
            csv_escape "$table_count"; echo -n ","
            csv_escape "$schemas"; echo
        } >> "$SUMMARY_OUT"
    done

    if [[ ! -s "$SUMMARY_OUT" || "$(wc -l < "$SUMMARY_OUT" | tr -d ' ')" == "1" ]]; then
        echo "[Error] no trace packages found in ${TRACE_DIR}"
        echo "TRACE_ANALYSIS_FAILED no_trace_found $(date +%H:%M:%S)" >> "$STATUS_OUT"
        analysisRoundStatus "TRACE_ANALYSIS_FAILED no_trace_found"
        exit 1
    fi

    if (( failures > 0 )); then
        echo "[Error] ${failures} trace TOC export(s) failed"
        echo "TRACE_ANALYSIS_DONE_WITH_FAILURES ${failures} $(date +%H:%M:%S)" >> "$STATUS_OUT"
        analysisRoundStatus "TRACE_ANALYSIS_DONE_WITH_FAILURES ${failures}"
        exit 1
    fi

    echo "TRACE_ANALYSIS_DONE $(date +%H:%M:%S)" >> "$STATUS_OUT"
    analysisRoundStatus "TRACE_ANALYSIS_DONE"
} > "$LOG_OUT" 2>&1

exit "$?"
