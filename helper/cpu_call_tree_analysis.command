#!/bin/zsh
set -u
setopt NULL_GLOB
setopt EXTENDED_GLOB

cd /Users/raliclo/proj/lzfse2 || exit 1
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

TRACE_DIR="./trace"
ANALYSIS_DIR="$TRACE_DIR/analysis"
CPU_CALL_TREE_DIR="$ANALYSIS_DIR/cpu_call_tree"
TIME_PROFILE_DIR="$CPU_CALL_TREE_DIR/time-profile"
TIME_SAMPLE_DIR="$CPU_CALL_TREE_DIR/time-sample"
OUT_DIR="$ANALYSIS_DIR/cpu_call_tree_summary"
STATUS_OUT="$TRACE_DIR/cpu_call_tree_analysis_status.txt"
LOG_OUT="$OUT_DIR/cpu_call_tree_analysis.log"
SUMMARY_OUT="$OUT_DIR/cpu_call_tree_summary.csv"
HOT_BY_FILE_OUT="$OUT_DIR/hot_symbols_by_file.csv"
HOT_GLOBAL_OUT="$OUT_DIR/hot_symbols_global.csv"
NOTES_OUT="$OUT_DIR/notes.md"
CPU_CALL_TREE_GLOBAL_TOP_N="${CPU_CALL_TREE_GLOBAL_TOP_N:-500}"

if ! [[ "$CPU_CALL_TREE_GLOBAL_TOP_N" == <-> ]]; then
    echo "[Error] CPU_CALL_TREE_GLOBAL_TOP_N must be a positive integer: ${CPU_CALL_TREE_GLOBAL_TOP_N}" >&2
    exit 2
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
echo "RUNNING cpu_call_tree_analysis $(date +%H:%M:%S)" > "$STATUS_OUT"

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

xml_unescape() {
    sed \
        -e 's/&quot;/"/g' \
        -e "s/&apos;/'/g" \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&amp;/\&/g'
}

file_kind() {
    case "$1" in
        *.time-profile.xml) echo "time-profile" ;;
        *.time-sample.xml)  echo "time-sample" ;;
        *)                  echo "unknown" ;;
    esac
}

base_name_for_file() {
    local name="${1:t}"
    name="${name%.time-profile.xml}"
    name="${name%.time-sample.xml}"
    echo "$name"
}

dataset_for_base() {
    local base="$1"
    case "$base" in
        claw-code-*) echo "claw-code" ;;
        llama.cpp-*) echo "llama.cpp" ;;
        *)           echo "unknown" ;;
    esac
}

algo_for_base() {
    local base="$1"
    local dataset="$(dataset_for_base "$base")"
    local rest="$base"
    case "$dataset" in
        claw-code) rest="${base#claw-code-}" ;;
        llama.cpp) rest="${base#llama.cpp-}" ;;
    esac
    rest="${rest%-n<->}"
    echo "$rest"
}

n_for_base() {
    local base="$1"
    if [[ "$base" == *-n<-> ]]; then
        echo "${base##*-n}"
    else
        echo ""
    fi
}

category_for_symbol() {
    local symbol="$1"
    case "$symbol" in
        *lzParseChain*|*lzParseStrong*|*lzParseOptimal*|*bestMatch*|*matchLength*|*repLen*|*insert\ #1*) echo "parse" ;;
        *encodeBlockV3*|*encodeBlock*|*compressBody*) echo "encode" ;;
        lzfseEncode*|lzfsePushMatch*) echo "apple_lzfse" ;;
        *fseEncode*|*FSEOutStream*|*symbol\(forValue*) echo "fse" ;;
        *Array.*|*_ArrayBuffer*|*ContiguousArray*|*IndexingIterator*|*Collection.*|*RangeCheck*|*subscript*) echo "swift_array" ;;
        *swift_*|*Swift*) echo "swift_runtime" ;;
        *_platform_memmove*|*memcpy*|*memmove*) echo "memory_copy" ;;
        *read*|*write*|*FileHandle*) echo "io" ;;
        *Compression*|*compression*) echo "apple_compression" ;;
        *tar*|*zstd*|*ZSTD*|*lz4*|*LZ4*|*HUF_*|*FSE_*) echo "external_tool" ;;
        *) echo "other" ;;
    esac
}

extract_symbols() {
    local xml_file="$1"
    rg -o '<frame[^>]+name="[^"]+"' "$xml_file" \
        | sed -E 's/.*name="([^"]+)".*/\1/' \
        | xml_unescape
}

row_count() {
    rg -o '<row>' "$1" 2>/dev/null | wc -l | tr -d ' '
}

contains_text() {
    rg -q "$2" "$1" 2>/dev/null && echo "yes" || echo "no"
}

{
    printf '\357\273\277file,kind,dataset,algorithm,n,total_rows,symbol_status,unique_symbols,lzfse_profile_seen,lzfse_symbol_hits,parse_hits,encode_hits,fse_hits,swift_array_hits,swift_runtime_hits,memory_copy_hits,io_hits,apple_compression_hits,external_tool_hits,top_symbol,top_count,top_category\n' > "$SUMMARY_OUT"
    printf '檔案,種類,資料夾,演算法,N,row總數,symbol狀態,唯一symbol數,看到lzfse-profile,lzfse symbol命中,parse命中,encode命中,FSE命中,Swift Array命中,Swift runtime命中,memory copy命中,IO命中,Apple Compression命中,外部工具命中,最高symbol,最高命中數,最高分類\n' >> "$SUMMARY_OUT"
    printf '\357\273\277file,kind,dataset,algorithm,n,rank,symbol,count,category\n' > "$HOT_BY_FILE_OUT"
    printf '檔案,種類,資料夾,演算法,N,排名,symbol,命中數,分類\n' >> "$HOT_BY_FILE_OUT"
    printf '\357\273\277kind,symbol,count,category\n' > "$HOT_GLOBAL_OUT"
    printf '種類,symbol,命中數,分類\n' >> "$HOT_GLOBAL_OUT"

    tmp_global="$OUT_DIR/.global_symbols.tmp"
    : > "$tmp_global"

    files=( "$TIME_PROFILE_DIR"/*.xml(N) "$TIME_SAMPLE_DIR"/*.xml(N) )
    if (( ${#files[@]} == 0 )); then
        echo "[Error] no cpu call tree XML found under ${CPU_CALL_TREE_DIR}"
        echo "CPU_CALL_TREE_ANALYSIS_FAILED no_xml_found $(date +%H:%M:%S)" >> "$STATUS_OUT"
        analysisRoundStatus "CPU_CALL_TREE_ANALYSIS_FAILED no_xml_found"
        exit 1
    fi

    for xml_file in "${files[@]}"; do
        file_name="${xml_file:t}"
        kind="$(file_kind "$file_name")"
        base="$(base_name_for_file "$file_name")"
        dataset="$(dataset_for_base "$base")"
        algorithm="$(algo_for_base "$base")"
        n_value="$(n_for_base "$base")"
        symbol_tmp="$OUT_DIR/.${base}.${kind}.symbols.tmp"
        count_tmp="$OUT_DIR/.${base}.${kind}.counts.tmp"

        echo "[Info] Analyze ${file_name}"
        echo "RUNNING_CPU_CALL_TREE_ANALYSIS ${file_name} $(date +%H:%M:%S)" >> "$STATUS_OUT"
        analysisRoundStatus "RUNNING_CPU_CALL_TREE_ANALYSIS ${file_name}"

        total_rows="$(row_count "$xml_file")"
        lzfse_profile_seen="$(contains_text "$xml_file" "lzfse-profile")"
        symbol_status="ok"
        unique_symbols="0"
        lzfse_symbol_hits=""
        parse_hits=""
        encode_hits=""
        fse_hits=""
        swift_array_hits=""
        swift_runtime_hits=""
        memory_copy_hits=""
        io_hits=""
        apple_compression_hits=""
        external_tool_hits=""
        top_count=""
        top_symbol=""
        top_category=""

        if [[ "$kind" == "time-profile" ]]; then
            extract_symbols "$xml_file" > "$symbol_tmp"
            awk -v kind="$kind" '{ print kind "\t" $0 }' "$symbol_tmp" >> "$tmp_global"
            sort "$symbol_tmp" | uniq -c | sort -nr > "$count_tmp"

            unique_symbols="$(wc -l < "$count_tmp" | tr -d ' ')"
            if [[ "$unique_symbols" == "0" ]]; then
                symbol_status="no_frame_symbols"
            fi
            lzfse_symbol_hits="$(rg -c 'LZFSEv1|lzParse|matchLength|bestMatch|repLen|encodeBlock|fseEncode|FSEOutStream|compressBody' "$symbol_tmp" 2>/dev/null || true)"
            parse_hits="$(rg -c 'lzParse|bestMatch|matchLength|repLen|insert #1' "$symbol_tmp" 2>/dev/null || true)"
            encode_hits="$(rg -c 'encodeBlock|compressBody' "$symbol_tmp" 2>/dev/null || true)"
            fse_hits="$(rg -c 'fseEncode|FSEOutStream|symbol\\(forValue' "$symbol_tmp" 2>/dev/null || true)"
            swift_array_hits="$(rg -c 'Array\\.|_ArrayBuffer|ContiguousArray|IndexingIterator|Collection\\.|RangeCheck|subscript' "$symbol_tmp" 2>/dev/null || true)"
            swift_runtime_hits="$(rg -c 'swift_|Swift' "$symbol_tmp" 2>/dev/null || true)"
            memory_copy_hits="$(rg -c '_platform_memmove|memcpy|memmove' "$symbol_tmp" 2>/dev/null || true)"
            io_hits="$(rg -c 'read|write|FileHandle' "$symbol_tmp" 2>/dev/null || true)"
            apple_compression_hits="$(rg -c 'Compression|compression' "$symbol_tmp" 2>/dev/null || true)"
            external_tool_hits="$(rg -c 'tar|zstd|ZSTD|lz4|LZ4|HUF_|FSE_' "$symbol_tmp" 2>/dev/null || true)"

            if [[ -s "$count_tmp" ]]; then
                top_count="$(awk 'NR == 1 { print $1 }' "$count_tmp")"
                top_symbol="$(awk 'NR == 1 { $1=""; sub(/^ /, ""); print }' "$count_tmp")"
                top_category="$(category_for_symbol "$top_symbol")"
            fi
        else
            symbol_status="raw_kperf_addresses_only"
            : > "$count_tmp"
        fi

        {
            csv_escape "$file_name"; echo -n ","
            csv_escape "$kind"; echo -n ","
            csv_escape "$dataset"; echo -n ","
            csv_escape "$algorithm"; echo -n ","
            csv_escape "$n_value"; echo -n ","
            csv_escape "$total_rows"; echo -n ","
            csv_escape "$symbol_status"; echo -n ","
            csv_escape "$unique_symbols"; echo -n ","
            csv_escape "$lzfse_profile_seen"; echo -n ","
            csv_escape "$lzfse_symbol_hits"; echo -n ","
            csv_escape "$parse_hits"; echo -n ","
            csv_escape "$encode_hits"; echo -n ","
            csv_escape "$fse_hits"; echo -n ","
            csv_escape "$swift_array_hits"; echo -n ","
            csv_escape "$swift_runtime_hits"; echo -n ","
            csv_escape "$memory_copy_hits"; echo -n ","
            csv_escape "$io_hits"; echo -n ","
            csv_escape "$apple_compression_hits"; echo -n ","
            csv_escape "$external_tool_hits"; echo -n ","
            csv_escape "$top_symbol"; echo -n ","
            csv_escape "$top_count"; echo -n ","
            csv_escape "$top_category"; echo
        } >> "$SUMMARY_OUT"

        if [[ "$kind" == "time-profile" && -s "$count_tmp" ]]; then
            awk -v file="$file_name" -v kind="$kind" -v dataset="$dataset" -v algorithm="$algorithm" -v n="$n_value" '
            NR <= 30 {
                count = $1
                $1 = ""
                sub(/^ /, "")
                print file "\t" kind "\t" dataset "\t" algorithm "\t" n "\t" NR "\t" $0 "\t" count
            }
            ' "$count_tmp" | while IFS=$'\t' read -r out_file out_kind out_dataset out_algorithm out_n out_rank out_symbol out_count; do
                out_category="$(category_for_symbol "$out_symbol")"
                {
                    csv_escape "$out_file"; echo -n ","
                    csv_escape "$out_kind"; echo -n ","
                    csv_escape "$out_dataset"; echo -n ","
                    csv_escape "$out_algorithm"; echo -n ","
                    csv_escape "$out_n"; echo -n ","
                    csv_escape "$out_rank"; echo -n ","
                    csv_escape "$out_symbol"; echo -n ","
                    csv_escape "$out_count"; echo -n ","
                    csv_escape "$out_category"; echo
                } >> "$HOT_BY_FILE_OUT"
            done
        fi

        rm -f "$symbol_tmp" "$count_tmp"
        echo "CPU_CALL_TREE_ANALYSIS_OK ${file_name} $(date +%H:%M:%S)" >> "$STATUS_OUT"
        analysisRoundStatus "CPU_CALL_TREE_ANALYSIS_OK ${file_name}"
    done

    if [[ -s "$tmp_global" ]]; then
        awk -F'\t' '{ print $1 "\t" $2 }' "$tmp_global" \
            | sort \
            | uniq -c \
            | sort -nr \
            | head -n "$CPU_CALL_TREE_GLOBAL_TOP_N" \
            | while read -r count kind symbol; do
                symbol_category="$(category_for_symbol "$symbol")"
                {
                    csv_escape "$kind"; echo -n ","
                    csv_escape "$symbol"; echo -n ","
                    csv_escape "$count"; echo -n ","
                    csv_escape "$symbol_category"; echo
                } >> "$HOT_GLOBAL_OUT"
            done
    fi

    rm -f "$tmp_global"

    {
        echo "# CPU Call Tree Analysis"
        echo
        echo "- 來源：\`trace/analysis/cpu_call_tree/time-profile\` 與 \`time-sample\`。"
        echo "- \`time-profile\` 會產出 symbol occurrence 統計；這不是精確 CPU 百分比。"
        echo "- \`time-sample\` 是 raw kperf address table，目前只記錄 row count 與 target 狀態，不納入 symbol 熱點排名。"
        echo "- \`hot_symbols_global.csv\` 預設只保留全域前 ${CPU_CALL_TREE_GLOBAL_TOP_N} 名；可用 \`CPU_CALL_TREE_GLOBAL_TOP_N\` 調整。"
        echo "- 分析前先看 \`trace_summary.csv\`，確認 \`target_seen=yes\`，並確認來源 trace 是否 timeout。"
        echo "- timeout trace 可用來判斷 hotspot 方向，但不能拿來計算 MB/s 或完整執行時間。"
        echo
        echo "產出檔案："
        echo "- \`cpu_call_tree_summary.csv\`"
        echo "- \`hot_symbols_by_file.csv\`"
        echo "- \`hot_symbols_global.csv\`"
    } > "$NOTES_OUT"

    rm -rf "$TRACE_DIR"/*.trace(N)
    rm -rf "$TRACE_DIR"/*.trace.timeout(N)
    echo "CPU_CALL_TREE_TRACE_CLEANED $(date +%H:%M:%S)" >> "$STATUS_OUT"
    analysisRoundStatus "CPU_CALL_TREE_TRACE_CLEANED"

    echo "CPU_CALL_TREE_ANALYSIS_DONE $(date +%H:%M:%S)" >> "$STATUS_OUT"
    analysisRoundStatus "CPU_CALL_TREE_ANALYSIS_DONE"
} > "$LOG_OUT" 2>&1

exit "$?"
