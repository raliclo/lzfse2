#!/bin/zsh
# ==============================================================================
# lz4bench.zsh -- lzfse2 專用的 benchmark 函式庫 / lzfse2's benchmark function library
#
# 由 zshrc.zsh 分離而來（2026-08-26）。zshrc.zsh 要與 ~/proj/fastZsh 共用，而這裡
# 的東西是 lzfse2 的量測程式碼，不屬於共用的 shell 設定。
# Split out of zshrc.zsh. zshrc.zsh is to be shared with ~/proj/fastZsh, and this
# is lzfse2's measurement code, which does not belong in a shared shell profile.
#
# 用法 / Usage: 先 source zshrc.zsh 再 source 本檔。順序有意義——lz4bench() 呼叫
# zshrc.zsh 的 nanoTimeElapsed()，那是本檔唯一的跨檔相依。
# Source zshrc.zsh first, then this file. The order matters: lz4bench() calls
# nanoTimeElapsed() from zshrc.zsh, which is this file's only outward dependency.
#
# extract() 一併搬來，因為它並非通用函式了：它呼叫 benchmarkTgzTar()、
# benchmarkZstdDecode() 與 memProbe()，且帶有純為量測而生的 `probe` 模式。
# fastZsh 的 zshrc 自有一份較早、未長出這些閘門的 extract()，故此處搬走不會使
# 那邊失去該功能。
# extract() came along because it is no longer general purpose: it calls
# benchmarkTgzTar(), benchmarkZstdDecode() and memProbe(), and carries a `probe`
# mode that exists only for measurement. fastZsh's zshrc has its own earlier
# extract() without those gates, so moving this one costs it nothing.
# ==============================================================================

# ------------------------------------------------------------------------------
# FUNCTION: extract()
# DESCRIPTION: A smart, single-command utility to automatically detect and 
#              extract almost all known archive formats based on their extensions.
#              (Supports: .tar.lz4, .tar.xz, .tar.bz2, .tar.gz, .bz2, .rar, .gz, 
#               .tar, .tbz2, .tgz, .zip, .Z, .xz, .7z, .lz4, .lzma)
# 功能描述：智慧型萬用解壓功能。只需單一指令，即可自動根據副檔名判別並解開絕
#          大多數常見的壓縮檔格式，省去記憶各種不同解壓參數的麻煩。
# ------------------------------------------------------------------------------
extract () {
    if [[ -z "$1" ]]; then
        echo "使用方法: extract <archive> [probe]"
        return 1
    fi

    if [[ -f "$1" ]] ; then
        local n_args=()
        if [[ -n "${LZFSE_BENCH_N:-}" ]]; then
            n_args=(-n "$LZFSE_BENCH_N")
        fi
        # 記憶體峰值量測模式：extract <file> probe → 只量「解碼程序」peak RSS，不真正解壓。
        # 解碼輸出寫 /dev/null（不經 tar 管線），確保 time -l 量到的是 lzfse 本身。
        if [[ "$2" == "probe" ]]; then
            local da arg2
            case "$1" in
                *.lzfse.bvx3.lazy2)   da=bvx3; arg2=lazy2 ;;
                *.lzfse.bvx3.optimal) da=bvx3; arg2=optimal ;;
                *.lzfse.other3.optimal3) da=other3 ;;
                *.lzfse.bvx3)         da=bvx3 ;;
                *.lzfse.other3)       da=other3 ;;
                *.lzfse.apple)        da=apple ;;
                *.tgz)
                    if [[ "${LZFSE_REQUIRE_NATIVE_ZLIB:-0}" == "1" ]]; then
                        [[ -n "${SWIFT_TAR_BIN:-}" && -x "$SWIFT_TAR_BIN" ]] || { echo "[Error] native zlib probe requires SWIFT_TAR_BIN." >&2; return 1; }
                        memProbe "decode ${1##*/}" "$SWIFT_TAR_BIN" tzf "$1"
                    else
                        memProbe "decode ${1##*/}" tar tzf "$1"
                    fi
                    return 0
                    ;;
                *.zst)
                    # 兩支都只做 raw decompression，與 helper_windows/rss-win.bat 同口徑：
                    # native 以 --cat 在 zstd filter 之後停止，external 用 zstd -d -c，兩者
                    # 皆不解析 tar。先前 native 用 -t、external 用 tar tzf，兩者都會走過每一
                    # 個 header——在 llama.cpp 的 40,675 個成員上，那是 native 側與 external
                    # 側都揹著、而「解壓縮速度／記憶體」一詞並不包含的工作。
                    # Both sides do raw decompression only, matching rss-win.bat: --cat stops
                    # after the zstd filter and zstd -d -c never parses tar. The former pair
                    # (-t and tar tzf) walked every header, which on llama.cpp's 40,675
                    # members is work the phrase "decode speed/memory" does not cover.
                    #
                    # stdout 必須在此丟棄。memProbe 是 `/usr/bin/time -l "$@" 2>&1 | awk`，
                    # 受測程序的 stdout 會流進 awk；-t 只吐檔名無妨，但 --cat 會把整條 tar
                    # 串流灌進管線，寫管線的成本會被記進受測程序。以 sh -c 'exec "$@" >…'
                    # 重導：exec 取代行程映像，故 time -l 量到的仍是目標本身。
                    # stdout must be discarded here. memProbe pipes the measured process's
                    # stdout into awk, and --cat would send the whole tar stream through it,
                    # charging the pipe writes to the measurement. exec replaces the process
                    # image, so time -l still measures the target and not a wrapper.
                    if [[ "${LZFSE_REQUIRE_NATIVE_ZSTD:-0}" == "1" ]]; then
                        [[ -n "${SWIFT_TAR_BIN:-}" && -x "$SWIFT_TAR_BIN" ]] || { echo "[Error] native zstd probe requires SWIFT_TAR_BIN." >&2; return 1; }
                        memProbe "decode ${1##*/}" /bin/sh -c 'exec "$@" >/dev/null' sh "$SWIFT_TAR_BIN" --cat -f "$1"
                    else
                        memProbe "decode ${1##*/}" /bin/sh -c 'exec "$@" >/dev/null' sh zstd -d -c "$1"
                    fi
                    return 0
                    ;;
                *.tar.lz4)            memProbe "decode ${1##*/}" lz4 -d -q -f "$1" /dev/null; return 0 ;;
                *) echo "[MEM] $1: 非 lzfse 格式，略過解碼量測 / non-lzfse, skipped"; return 0 ;;
            esac
            memProbe "decode ${1##*/}${LZFSE_BENCH_N:+ -n ${LZFSE_BENCH_N}}" \
                lzfse -decode -i "$1" -o /dev/null -algo "$da" ${arg2:+-$arg2} "${n_args[@]}"
            return 0
        fi
        case "$1" in
            *.lzfse.bvx3.lazy2) echo "lzfse -decode -i $1 -so -algo bvx3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.bvx3.optimal) echo "lzfse -decode -i $1 -so -algo bvx3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.bvx3)       echo "lzfse -decode -i $1 -so -algo bvx3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.other3.optimal3) echo "lzfse -decode -i $1 -so -algo other3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo other3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.other3)     echo "lzfse -decode -i $1 -so -algo other3 ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo other3 "${n_args[@]}" | tar -xf -  ;;
            *.lzfse.apple)      echo "lzfse -decode -i $1 -so -algo apple ${n_args[*]} | tar -xf - " ; lzfse -decode -i "$1" -so -algo apple "${n_args[@]}" | tar -xf -  ;;
            *.tar.lz4)   lz4 -T0 -d -q -c $1 | tar -xf - ;;
            *.zst)       benchmarkZstdDecode "$1" ;;
            *.tar.xz)    tar xf "$1"      ;;
            *.tar.bz2)   tar xjf "$1"     ;;
            *.tar.gz)    benchmarkTgzTar xzf "$1" ;;
            *.tgz)       benchmarkTgzTar xzf "$1" ;;
            *.bz2)       bunzip2 "$1"     ;;
            *.rar)       unrar e "$1"     ;;
            *.gz)        gunzip "$1"      ;;
            *.tar)       tar xf "$1"      ;;
            *.tbz2)      tar xjf "$1"     ;;
            *.tgz)       benchmarkTgzTar xzf "$1" ;;
            *.zip)       unzip "$1"       ;;
            *.Z)         uncompress "$1"  ;;
            *.xz)        xz -d "$1"       ;;
            *.7z)        7z x "$1"        ;;
            *.lz4)       unlz4 "$1"       ;;
            *.lzma)      tar --lzma -xvf "$1" ;;
            *.lz4a)      unlz4a "$1"        ;;
            *)           echo "'$1' cannot be extracted via extract()" ; return 1 ;;
        esac
    else
        echo "'$1' is not a valid file"
        return 1
    fi
}

# ==============================================================================
# 🗜️ COMPRESSION TOOLS / 目錄壓縮工具
# ==============================================================================

# R47 TGZ backend gate: -swift_tar mode exports LZFSE_REQUIRE_NATIVE_ZLIB=1
# and SWIFT_TAR_BIN. Outside that mode, keep the existing PATH-resolved tar.
# R47 TGZ 後端守門：-swift_tar 模式會匯出上述變數；未啟用時
# 維持原本由 PATH 解析 tar 的行為。
function benchmarkTgzTar() {
    if [[ "${LZFSE_REQUIRE_NATIVE_ZLIB:-0}" == "1" ]]; then
        if [[ -z "${SWIFT_TAR_BIN:-}" || ! -x "$SWIFT_TAR_BIN" ]]; then
            echo "[Error] -swift_tar native zlib mode requires executable SWIFT_TAR_BIN." >&2
            return 1
        fi
        "$SWIFT_TAR_BIN" "$@"
    else
        tar "$@"
    fi
}

function benchmarkZstdDecode() {   # $1 = archive
    if [[ "${LZFSE_REQUIRE_NATIVE_ZSTD:-0}" == "1" ]]; then
        if [[ -z "${SWIFT_TAR_BIN:-}" || ! -x "$SWIFT_TAR_BIN" ]]; then
            echo "[Error] -swift_tar native zstd mode requires executable SWIFT_TAR_BIN." >&2
            return 1
        fi
        # swift_tar detects zstd by magic and untars in the same process, so no
        # pipe and no second binary. / swift_tar 依 magic 偵測 zstd 並於同一行程
        # 內解 tar，因此不需管線、也不需第二個 binary。
        "$SWIFT_TAR_BIN" -x -f "$1"
    else
        zstd -d -c "$1" | tar -xf -
    fi
}

## This script helps to creat a tar.xz for a folder.
function getar() {
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
    XZ_OPT=-e9 benchmarkTgzTar czf "$1".tgz -C "$tar_parent" "$tar_leaf"
    du -sh "$1"
    du -sh "$1.tgz"
}

function lzfseX() {
    # 如果參數 $1 為空則提示並退出
    if [[ -z "$1" ]]; then
        echo "使用方法: lzfseX <檔案或目錄> [other3|apple|bvx3|lazy2|optimal|optimal3|bvx3_lazy2|bvx3_optimal|other3_optimal3] [run|probe]"
        return 1
    fi
    if [[ ! -e "$1" ]]; then
        echo "[Error] lzfseX target not found: $1"
        return 1
    fi

    # 設置預設值為 'other3' (若 $2 為空)；第三參數 mode：run（預設）或 probe（僅量測記憶體峰值）
    local algo="${2:-other3}"
    local mode="${3:-run}"
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."

    # 根據演算法設定副檔名（lazy2/optimal 為 bvx3 的解析器旗標）
    local extension="lzfse.other3"
    local flags=""
    local n_args=()
    if [[ -n "${LZFSE_BENCH_N:-}" ]]; then
        n_args=(-n "$LZFSE_BENCH_N")
    fi
    case "$algo" in
        apple)    extension="lzfse.apple" ;;
        bvx3)     extension="lzfse.bvx3" ;;
        lazy2|bvx3_lazy2)    extension="lzfse.bvx3.lazy2";   algo="bvx3"; flags="-lazy2" ;;
        optimal|bvx3_optimal)  extension="lzfse.bvx3.optimal"; algo="bvx3"; flags="-optimal" ;;
        optimal3|other3_optimal3) extension="lzfse.other3.optimal3"; algo="other3"; flags="-optimal3" ;;
        other3)   extension="lzfse.other3" ;;
        *)        echo "[Error] unknown lzfseX algorithm: $algo"; return 1 ;;
    esac

    # 記憶體峰值量測模式（沿用上方 algo/flags 對應）：直接量「lzfse 編碼程序」的 peak RSS，
    # 不產生 benchmark 產物。lazy2/optimal 皆走 bvx3 平行編碼，用以實證「已讀未寫 ≤ maxTasks」
    # → 記憶體上界 ≈ maxTasks × chunkSize（見 OPTIMIZATION.md R19）。輸出寫 /dev/null 不佔磁碟。
    if [[ "$mode" == "probe" ]]; then
        local probe_label="encode ${1##*/} ${algo}${flags:+ }${flags}${LZFSE_BENCH_N:+ -n ${LZFSE_BENCH_N}}"
        echo "[Info] 記憶體峰值量測 (${probe_label}) / Encode peak-RSS probe:"
        if ! /usr/bin/time -l true 2>/dev/null; then
            echo "[MEM] ${probe_label}: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
            return 0
        fi
        tar -cf - -C "$tar_parent" "$tar_leaf" | memProbe "$probe_label" \
            lzfse -encode -si -o /dev/null -algo "$algo" ${=flags} "${n_args[@]}"
        return 0
    fi

    # 執行壓縮
    echo "執行中: tar -cf - -C $tar_parent $tar_leaf | lzfse -encode -si -o $1.$extension -algo $algo $flags ${n_args[*]}"
    tar -cf - -C "$tar_parent" "$tar_leaf" | lzfse -encode -si -o "$1.$extension" -algo "$algo" ${=flags} "${n_args[@]}"
    local rc=$?
    if [[ $rc -ne 0 || ! -f "$1.$extension" ]]; then
        echo "[Error] lzfseX failed to create $1.$extension"
        return 1
    fi
    
    # 顯示檔案大小（含精確 byte 數，供 benchmark 計算精確壓縮比）
    # Show sizes (incl. exact bytes so benchmarks can compute precise ratios)
    echo "--- 壓縮資訊 ---"
    du -sh "$1"
    du -sh "$1.$extension"
    echo "[SIZE] $1.$extension: $(stat -f%z "$1.$extension" 2>/dev/null || stat -c%s "$1.$extension") bytes"
}

function getzstd() {
   local tar_parent="${1:h}"
   local tar_leaf="${1:t}"
   [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
   # Encode must go through the same gate as decode. Otherwise native mode would
   # pair a system-tar archive with a swift_tar extraction, and the AppleDouble
   # entries bsdtar writes for extended attributes (com.apple.provenance is on
   # every file in both corpora) come back as literal `._` files instead of
   # being restored as attributes -- a different file count, a different amount
   # of write work, and a decode number that is not comparable.
   # encode 必須與 decode 走同一個閘門，否則 native 模式會變成「系統 tar 建檔、
   # swift_tar 解出」：bsdtar 為擴充屬性寫入的 AppleDouble 項目（兩份語料的每個
   # 檔案都帶有 com.apple.provenance）會被還原成實體的 `._` 檔案，而非還原為屬性
   # ——檔案數不同、寫入工作量不同，解碼數字也就失去可比性。
   if [[ "${LZFSE_REQUIRE_NATIVE_ZSTD:-0}" == "1" ]]; then
       if [[ -z "${SWIFT_TAR_BIN:-}" || ! -x "$SWIFT_TAR_BIN" ]]; then
           echo "[Error] -swift_tar native zstd mode requires executable SWIFT_TAR_BIN." >&2
           return 1
       fi
       # Level 9 matches the external path's `zstd -9`, so the two rows differ only
       # by implementation, not by setting. swift_tar still compresses in
       # independent 4 MiB chunks (that is what makes it parallel), so its output
       # can be larger than a single external stream on highly redundant data --
       # a design trade-off to report, not a defect.
       # 等級 9 與外部路徑的 `zstd -9` 一致，使兩列只差在實作而非設定。swift_tar
       # 仍以獨立的 4 MiB 分塊壓縮（正是其得以並行的原因），故在高度冗餘的資料上
       # 其輸出可能大於單一外部串流——這是應如實回報的設計取捨，並非缺陷。
       "$SWIFT_TAR_BIN" -c --zstd --zstd-level 9 -f "$1.zst" -C "$tar_parent" "$tar_leaf"
   else
       tar -cf - -C "$tar_parent" "$tar_leaf" | zstd -9 -T0 -c > "$1.zst"
   fi
    # tar -I 'zstd -1' -cvf $1.zst $1
    du -sh "$1"
    du -sh "$1.zst"
}

function tlz4() {
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
    tar -cf - -C "$tar_parent" "$tar_leaf" | lz4 -T0 -6 -q > "$1.tar.lz4"
    # tar --use-compress-program=lz4 -cf  $1.tar.lz4 $1
    du -sh "$1"
    du -sh "$1.tar.lz4" 
}

function diskcheck() {
    # 磁碟空間預檢（xbenchTest 峰值約 2 × 原始大小；建議保留 ≥20GB）
    # Disk space pre-check (xbenchTest peaks at ~2× raw size; recommend ≥20GB free)
    local avail_kb avail_gb
    avail_kb=$(df -k . | tail -1 | awk '{print $4}')
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if (( avail_gb < 20 )); then
        echo "[Warning] 磁碟可用空間僅 ${avail_gb}GB，建議 ≥20GB，否則解壓可能失敗！"
        echo "[Warning] Only ${avail_gb}GB free — recommend ≥20GB to avoid disk-full failures."
        return 1
    else
        echo "[Info] 磁碟可用空間充足：${avail_gb}GB / Sufficient disk space: ${avail_gb}GB"
        return 0
    fi

}

function benchStatus() {
    local status_file="${ROUND_STATUS_FILE:-round_status.txt}"
    echo "$@ $(date +%H:%M:%S)" >> "$status_file"
}

function benchAlgoName() {
    case "$1" in
        *.tgz)                echo "tgz" ;;
        *.zst)                echo "zstd" ;;
        *.tar.lz4)            echo "tar.lz4" ;;
        *.lzfse.other3.optimal3) echo "optimal3" ;;
        *.lzfse.other3)       echo "other3" ;;
        *.lzfse.apple)        echo "apple" ;;
        *.lzfse.bvx3.lazy2)   echo "lazy2" ;;
        *.lzfse.bvx3.optimal) echo "optimal" ;;
        *.lzfse.bvx3)         echo "bvx3" ;;
        *)                    echo "${1##*.}" ;;
    esac
}

function benchStatMode() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%a' "$1" 2>/dev/null
    else
        stat -f '%Lp' "$1" 2>/dev/null
    fi
}

function benchStatMtime() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%Y' "$1" 2>/dev/null
    else
        stat -f '%m' "$1" 2>/dev/null
    fi
}

function benchStatSize() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%s' "$1" 2>/dev/null
    else
        stat -f '%z' "$1" 2>/dev/null
    fi
}

function benchStatIdentity() {
    if stat --version > /dev/null 2>&1; then
        stat -c '%d:%i:%h' "$1" 2>/dev/null
    else
        stat -f '%d:%i:%l' "$1" 2>/dev/null
    fi
}

function benchSha256() {
    local digest
    if command -v sha256sum > /dev/null 2>&1; then
        digest="$(sha256sum "$1")"
        echo "${digest%% *}"
    elif command -v shasum > /dev/null 2>&1; then
        digest="$(shasum -a 256 "$1")"
        echo "${digest%% *}"
    elif command -v openssl > /dev/null 2>&1; then
        digest="$(openssl dgst -sha256 "$1")"
        echo "${digest##* }"
    else
        echo "[Error] sha256sum, shasum, or openssl is required for manifest hashing." >&2
        return 1
    fi
}

function benchManifestLine() {
    local root="$1"
    local rel="$2"
    local entry_path="$root"
    [[ "$rel" != "." ]] && entry_path="$root/$rel"

    local file_mode file_mtime
    file_mode="$(benchStatMode "$entry_path")"
    file_mtime="$(benchStatMtime "$entry_path")"

    if [[ -L "$entry_path" ]]; then
        local target
        target="$(readlink "$entry_path")"
        printf 'L\t%s\tmode=%s\tmtime=%s\ttarget=%s\n' "$rel" "$file_mode" "$file_mtime" "$target"
    elif [[ -d "$entry_path" ]]; then
        printf 'D\t%s\tmode=%s\tmtime=%s\n' "$rel" "$file_mode" "$file_mtime"
    elif [[ -f "$entry_path" ]]; then
        local size sha identity nlink hardlink
        size="$(benchStatSize "$entry_path")"
        sha="$(benchSha256 "$entry_path")"
        identity="$(benchStatIdentity "$entry_path")"
        nlink="${identity##*:}"
        hardlink="none"
        if [[ "$nlink" == <-> && "$nlink" -gt 1 ]]; then
            if [[ -n "${bench_manifest_seen_hardlinks[$identity]:-}" ]]; then
                hardlink="${bench_manifest_seen_hardlinks[$identity]}"
            else
                bench_manifest_seen_hardlinks[$identity]="$rel"
                hardlink="self"
            fi
        fi
        printf 'F\t%s\tmode=%s\tmtime=%s\tsize=%s\tsha256=%s\thardlink=%s\n' "$rel" "$file_mode" "$file_mtime" "$size" "$sha" "$hardlink"
    else
        printf 'O\t%s\tmode=%s\tmtime=%s\n' "$rel" "$file_mode" "$file_mtime"
    fi
}

function benchManifestRoot() {
    local root="$1"
    local out="$2"
    if [[ ! -d "$root" ]]; then
        echo "[Error] manifest root not found: $root" >&2
        return 1
    fi

    mkdir -p "${out:h}" > /dev/null 2>&1
    typeset -gA bench_manifest_seen_hardlinks
    bench_manifest_seen_hardlinks=()

    {
        benchManifestLine "$root" "."
        local rel
        local entries=()
        (
            cd "$root" || exit 1
            entries=(**/*(DN))
            printf '%s\n' "${entries[@]}"
        ) | LC_ALL=C sort -u | while IFS= read -r rel; do
            [[ -n "$rel" ]] && benchManifestLine "$root" "$rel"
        done
    } > "$out"
}

function benchCompareTreeManifest() {
    local expected_root="$1"
    local actual_root="$2"
    local label="$3"
    local reusable_expected_manifest="${4:-}"
    local manifest_dir="${LZ4BENCH_LOG_DIR:-lz4bench_log}/tree_manifest"
    local expected_manifest="$manifest_dir/${label}.tgz-manifest.txt"
    local actual_manifest="$manifest_dir/${label}.actual-manifest.txt"
    local diff_file="$manifest_dir/${label}.manifest-diff.txt"

    mkdir -p "$manifest_dir" > /dev/null 2>&1
    if [[ -n "$reusable_expected_manifest" && -f "$reusable_expected_manifest" ]]; then
        expected_manifest="$reusable_expected_manifest"
    else
        benchManifestRoot "$expected_root" "$expected_manifest" || return 1
    fi
    benchManifestRoot "$actual_root" "$actual_manifest" || return 1

    if diff -u "$expected_manifest" "$actual_manifest" > "$diff_file"; then
        rm -f "$diff_file"
        return 0
    fi

    echo "[Info] manifest expected: $expected_manifest"
    echo "[Info] manifest actual:   $actual_manifest"
    echo "[Info] manifest diff:     $diff_file"
    return 1
}

# ------------------------------------------------------------------------------
# FUNCTION: memProbe()
# DESCRIPTION: 以 /usr/bin/time -l（macOS）量測「單一程序」的 peak RSS。
#   關鍵：time -l 必須「直接」前綴目標程序（如 lzfse），不可包成 `sh -c "管線"`，
#   否則 wait4 取得的是 shell 的 rusage（僅數 MB），而非 lzfse 真正的常駐記憶體。
#   $1 = 標籤；其餘參數 = 要量測的命令（直接 exec，不經 shell）。
#   stdin 由呼叫端以管線/重導提供（如 `tar -cf - dir | memProbe ... lzfse -encode -si ...`）。
# ------------------------------------------------------------------------------
function memProbe() {
    local label="$1"; shift
    if ! /usr/bin/time -l true 2>/dev/null; then
        echo "[MEM] ${label}: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
        return 0
    fi
    /usr/bin/time -l "$@" 2>&1 \
        | awk -v l="$label" '/maximum resident set size/ {printf "[MEM] %s peak RSS: %.1f MB\n", l, $1/1048576}'
}

function archiveMemProbe() {
    local target="$1"
    local fmt="$2"
    local folder="${target##*/}"
    if [[ -z "$target" || -z "$fmt" ]]; then
        echo "使用方法: archiveMemProbe <target> [tgz|zst|zstd|tar.lz4]"
        return 1
    fi

    case "$fmt" in
        tgz)
            echo "[Info] 記憶體峰值量測 (encode ${folder} tgz) / Encode peak-RSS probe:"
            if ! /usr/bin/time -l true 2>/dev/null; then
                echo "[MEM] encode ${folder} tgz: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
                return 0
            fi
            local tar_parent="${target:h}"
            local tar_leaf="${target:t}"
            [[ -z "$tar_parent" || "$tar_parent" == "$target" ]] && tar_parent="."
            if [[ "${LZFSE_REQUIRE_NATIVE_ZLIB:-0}" == "1" ]]; then
                [[ -n "${SWIFT_TAR_BIN:-}" && -x "$SWIFT_TAR_BIN" ]] || { echo "[Error] native zlib probe requires SWIFT_TAR_BIN." >&2; return 1; }
                memProbe "encode ${folder} tgz" "$SWIFT_TAR_BIN" czf /dev/null -C "$tar_parent" "$tar_leaf"
            else
                memProbe "encode ${folder} tgz" tar czf /dev/null -C "$tar_parent" "$tar_leaf"
            fi
            ;;
        zst|zstd)
            echo "[Info] 記憶體峰值量測 (encode ${folder} zstd) / Encode peak-RSS probe:"
            if ! /usr/bin/time -l true 2>/dev/null; then
                echo "[MEM] encode ${folder} zstd: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
                return 0
            fi
            local tar_parent="${target:h}"
            local tar_leaf="${target:t}"
            [[ -z "$tar_parent" || "$tar_parent" == "$target" ]] && tar_parent="."
            tar -cf - -C "$tar_parent" "$tar_leaf" | memProbe "encode ${folder} zstd" zstd -9 -T0 -q -f -o /dev/null
            ;;
        tar.lz4)
            echo "[Info] 記憶體峰值量測 (encode ${folder} tar.lz4) / Encode peak-RSS probe:"
            if ! /usr/bin/time -l true 2>/dev/null; then
                echo "[MEM] encode ${folder} tar.lz4: /usr/bin/time -l 不可用（非 macOS？），略過 / skipped"
                return 0
            fi
            local tar_parent="${target:h}"
            local tar_leaf="${target:t}"
            [[ -z "$tar_parent" || "$tar_parent" == "$target" ]] && tar_parent="."
            tar -cf - -C "$tar_parent" "$tar_leaf" | memProbe "encode ${folder} tar.lz4" lz4 -T0 -6 -q -f - /dev/null
            ;;
        *)
            echo "[Error] unknown archiveMemProbe format: $fmt"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# FUNCTION: lz4bench()
# DESCRIPTION: Benchmarks and compares the performance (speed and execution time)
#              between 'lz4a','tgz', 'tlz4' ,'getzstd' using precise 'date' timestamps.
#
# 功能描述：壓縮效能基準測試。利用 'date' 時間戳記精準計算並比較 'lz4a' ,'tgz', 'tlz4' ,'getzstd'
#        在壓縮與解壓縮過程中的實際耗時（秒）。
# ------------------------------------------------------------------------------
function lz4bench() {
    # 檢查是否輸入測試目標 / Check if input target is specified
    if [[ -z "$1" ]]; then
        echo "錯誤: 請指定要測試的目錄 / Error: Please specify a directory to benchmark" >&2
        return 1
    fi

    # 磁碟空間預檢（lazy2/optimal 解壓在磁碟壓力下數據嚴重失真，見 OPTIMIZATION.md R11/R12）
    # Disk pre-check (lazy2/optimal decompression numbers degrade badly under disk pressure)
    diskcheck "$1" || return 1

    if [[ -n "${LZFSE_BENCH_N:-}" ]]; then
        echo "[Info] Fixed LZFSE -n for this round: -n ${LZFSE_BENCH_N}"
    fi
    local status_suffix="${LZFSE_BENCH_SUFFIX:-}"
    benchStatus "RUNNING_LZ4BENCH ${1}${status_suffix}"

    # Warm-cache：預讀整個資料集進 OS page cache，消除「第一個格式 cold-cache、
    # 後續格式 warm-cache」造成的壓縮計時偏差（見 OPTIMIZATION.md R15/R16 cold-cache 註）
    # Warm-cache: pre-read the whole dataset so every compression format is timed
    # under the same warm-cache condition (removes first-format cold-cache skew).
    echo $'\n[Info] Warm-cache 預讀資料集 / Pre-reading dataset to warm OS cache...'
    local tar_parent="${1:h}"
    local tar_leaf="${1:t}"
    [[ -z "$tar_parent" || "$tar_parent" == "$1" ]] && tar_parent="."
    tar -cf - -C "$tar_parent" "$tar_leaf" > /dev/null 2>&1

    echo $'[Info] 開始執行 tgz, lzfse, tlz4, zstd 基準測試...\n'

    # --------------------------------------------------------------------------
    # 1. 壓縮測試
    # --------------------------------------------------------------------------
    echo $'\n[Info] 測試 getar 壓縮 / Testing getar compression:'
    nanoTimeElapsed getar $1
    local encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.tgz" ]] && benchStatus "ENCODED ${1}${status_suffix} tgz" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} tgz ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX other3 壓縮 / Testing lzfseX other3 compression:'
    nanoTimeElapsed lzfseX $1 other3
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.other3" ]] && benchStatus "ENCODED ${1}${status_suffix} other3" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} other3 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX other3_optimal3 壓縮 / Testing lzfseX other3_optimal3 compression:'
    nanoTimeElapsed lzfseX $1 optimal3
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.other3.optimal3" ]] && benchStatus "ENCODED ${1}${status_suffix} optimal3" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} optimal3 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX bvx3_lazy2 壓縮 / Testing lzfseX bvx3_lazy2 compression:'
    nanoTimeElapsed lzfseX $1 lazy2
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.bvx3.lazy2" ]] && benchStatus "ENCODED ${1}${status_suffix} lazy2" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} lazy2 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX bvx3_optimal 壓縮 / Testing lzfseX bvx3_optimal compression:'
    nanoTimeElapsed lzfseX $1 optimal
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.bvx3.optimal" ]] && benchStatus "ENCODED ${1}${status_suffix} optimal" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} optimal ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX bvx3 壓縮 / Testing lzfseX bvx3 compression:'
    nanoTimeElapsed lzfseX $1 bvx3
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.bvx3" ]] && benchStatus "ENCODED ${1}${status_suffix} bvx3" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} bvx3 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 lzfseX apple 壓縮 / Testing lzfseX apple compression:'
    nanoTimeElapsed lzfseX $1 apple
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.lzfse.apple" ]] && benchStatus "ENCODED ${1}${status_suffix} apple" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} apple ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 tlz4  壓縮 / Testing tlz4 compression:'
    nanoTimeElapsed tlz4 $1
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.tar.lz4" ]] && benchStatus "ENCODED ${1}${status_suffix} tar.lz4" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} tar.lz4 ${encode_rc}"; return 1; }

    echo $'\n[Info] 測試 zstd  壓縮 / Testing zstd compression:'
    nanoTimeElapsed getzstd $1
    encode_rc=$?
    [[ $encode_rc -eq 0 && -f "$1.zst" ]] && benchStatus "ENCODED ${1}${status_suffix} zstd" || { benchStatus "ENCODE_FAILED ${1}${status_suffix} zstd ${encode_rc}"; return 1; }

    # --------------------------------------------------------------------------
    # 1b. 壓縮產物精確大小摘要（lazy2/optimal 等的壓縮比以此為準）
    #     Exact compressed sizes summary (authoritative for ratio calculation)
    # --------------------------------------------------------------------------
    echo $'\n[Info] 壓縮產物精確大小 / Exact compressed sizes:'
    echo "[SIZE] $1 (raw): $(du -sk "$1" | awk '{print $1}') KB"
    local size_targets=("$1.tgz" "$1.lzfse.other3" "$1.lzfse.other3.optimal3" "$1.lzfse.bvx3.lazy2" "$1.lzfse.bvx3.optimal" "$1.lzfse.bvx3" "$1.lzfse.apple" "$1.tar.lz4" "$1.zst")
    local missing_artifacts=0
    for f in "${size_targets[@]}"; do
        if [[ -f "$f" ]]; then
            echo "[SIZE] $f: $(stat -f%z "$f" 2>/dev/null || stat -c%s "$f") bytes"
        else
            echo "[SIZE] $f: MISSING（壓縮產物不存在 / artifact not found）"
            missing_artifacts=1
        fi
    done
    if (( missing_artifacts )); then
        echo "[Error] one or more compression artifacts are missing; abort benchmark."
        return 1
    fi

    echo $'\n=================================================='
    echo $'[Info] 開始評測解壓縮速度 / Benchmarking decompression score:'
    echo $'=================================================='

    # --------------------------------------------------------------------------
    # 2. 解壓縮測試 + 即時一致性驗證
    #    每個格式解壓後立即核對 tgz 基準並清理，避免 xbenchTest 峰值過大導致磁碟爆滿
    #    Decompression + inline consistency check: each format is verified then
    #    immediately removed, keeping peak xbenchTest disk usage to ~2× raw size.
    # --------------------------------------------------------------------------
    local extract_targets=("$1.tgz" "$1.lzfse.other3" "$1.lzfse.other3.optimal3" "$1.lzfse.bvx3.lazy2" "$1.lzfse.bvx3.optimal" "$1.lzfse.bvx3" "$1.lzfse.apple" "$1.tar.lz4" "$1.zst")
    local base_dir="./xbenchTest/tgz"   # tgz 保留到最後作為比對基準
    local is_first=true
    local manifest_label_base="${1}${status_suffix}"
    manifest_label_base="${manifest_label_base//\//_}"
    local manifest_dir="${LZ4BENCH_LOG_DIR:-lz4bench_log}/tree_manifest"
    local base_manifest="$manifest_dir/${manifest_label_base}.tgz-baseline-manifest.txt"

    for target in "${extract_targets[@]}"; do
        local test_dir="./xbenchTest/${target##*.}"
        local target_algo
        target_algo="$(benchAlgoName "$target")"
        mkdir -p "$test_dir" > /dev/null 2>&1
        if ! mv "$target" "$test_dir" > /dev/null 2>&1; then
            benchStatus "DECODE_FAILED ${1}${status_suffix} ${target_algo} move_artifact"
            echo "[Error] failed to move $target into $test_dir"
            return 1
        fi

        echo $'\n[Info] 測試 '$target' 解壓:'
        (
            cd "$test_dir" > /dev/null 2>&1
            rm -rf "$1" > /dev/null 2>&1
            nanoTimeElapsed extract "$target"
        )
        local extract_rc=$?
        if ! mv "$test_dir/$target" "$target" > /dev/null 2>&1; then
            benchStatus "DECODE_FAILED ${1}${status_suffix} ${target_algo} restore_artifact"
            echo "[Error] failed to restore $target from $test_dir"
            return 1
        fi
        if [[ $extract_rc -ne 0 ]]; then
            benchStatus "DECODE_FAILED ${1}${status_suffix} ${target_algo} ${extract_rc}"
            echo "[Error] $target 解壓失敗 / decompression failed"
            return "$extract_rc"
        fi
        benchStatus "DECODED ${1}${status_suffix} ${target_algo}"

        # 即時一致性核對 + 立即清理（tgz 基準保留到所有格式完成）
        # Inline consistency check + immediate cleanup (tgz base kept until end)
        if $is_first; then
            is_first=false   # tgz 作為基準，跳過自比對
            if benchManifestRoot "$base_dir/$1" "$base_manifest"; then
                benchStatus "COMPARE_BASE ${1}${status_suffix} tgz"
            else
                benchStatus "COMPARE_BASE_FAILED ${1}${status_suffix} tgz manifest"
                echo "[Error] failed to create tgz baseline tree manifest"
                return 1
            fi
        else
            local compare_label="${manifest_label_base}.${target_algo}"
            if benchCompareTreeManifest "$base_dir/$1" "$test_dir/$1" "$compare_label" "$base_manifest"; then
                echo "[Success] $target 解壓 tar 語意與 tgz 一致！"
                benchStatus "COMPARED_WITH_TGZ_OK ${1}${status_suffix} ${target_algo}"
            else
                echo "[Warning] $target 解壓 tar 語意與 tgz 不一致！"
                benchStatus "COMPARED_WITH_TGZ_FAILED ${1}${status_suffix} ${target_algo}"
                rm -rf "$test_dir"
                return 1
            fi
            rm -rf "$test_dir"   # 立即釋放此格式的解壓空間
        fi
    done

    # --------------------------------------------------------------------------
    # 3. 最終清理 / Final cleanup
    # --------------------------------------------------------------------------
    rm -rf "./xbenchTest"

    # --------------------------------------------------------------------------
    # 4. 記憶體峰值量測（選用，LZFSE_MEMPROBE=1）/ Peak-RSS probes (opt-in)
    #    必須放在壓縮與解壓 benchmark 後，避免 probe 改變 page-cache / memory pressure，
    #    污染正式解壓 MB/s。encode：直接量目標編碼程序；decode：用既有壓縮產物。
    # --------------------------------------------------------------------------
    if [[ "$LZFSE_MEMPROBE" == "1" ]]; then
        mkdir -p memprobeResults > /dev/null 2>&1
        echo $'\n[Info] 記憶體峰值量測 (tgz / zstd / tar.lz4 / other3 / optimal3 / apple / bvx3 / lazy2 / optimal，encode + decode) / Peak-RSS probes:'
        local probe_algo probe_file probe_artifact probe_suffix
        probe_suffix="${LZFSE_BENCH_SUFFIX:-}"
        for probe_algo in tgz zstd tar.lz4 other3 optimal3 apple bvx3 lazy2 optimal; do
            case "$probe_algo" in
                tgz)      probe_artifact="$1.tgz" ;;
                zstd)     probe_artifact="$1.zst" ;;
                tar.lz4)  probe_artifact="$1.tar.lz4" ;;
                other3)   probe_artifact="$1.lzfse.other3" ;;
                optimal3) probe_artifact="$1.lzfse.other3.optimal3" ;;
                apple)    probe_artifact="$1.lzfse.apple" ;;
                bvx3)     probe_artifact="$1.lzfse.bvx3" ;;
                lazy2)    probe_artifact="$1.lzfse.bvx3.lazy2" ;;
                optimal)  probe_artifact="$1.lzfse.bvx3.optimal" ;;
            esac
            probe_file="memprobeResults/${1}${probe_suffix}-${probe_algo}-memprobe.txt"
            benchStatus "RUNNING_MEMPROBE ${1}${status_suffix} ${probe_algo}"
            case "$probe_algo" in
                tgz|zstd|tar.lz4) archiveMemProbe "$1" "$probe_algo" > "$probe_file" 2>&1 || { benchStatus "MEMPROBE_FAILED ${1}${status_suffix} ${probe_algo} encode"; return 1; } ;;
                *) lzfseX "$1" "$probe_algo" probe > "$probe_file" 2>&1 || { benchStatus "MEMPROBE_FAILED ${1}${status_suffix} ${probe_algo} encode"; return 1; } ;;
            esac
            extract "$probe_artifact" probe >> "$probe_file" 2>&1 || { benchStatus "MEMPROBE_FAILED ${1}${status_suffix} ${probe_algo} decode"; return 1; }
            benchStatus "MEMPROBE_DONE ${1}${status_suffix} ${probe_algo}"
        done
    fi

    benchStatus "LZ4BENCH_DONE ${1}${status_suffix}"
    echo $'\n[Info] 基準測試完成！ / Benchmark finished!'
}
