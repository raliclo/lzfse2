#!/bin/zsh
# Cowork 自動化執行器：compile → 測試守門 → benchmark
# Auto-runner: compile → gate on tests → benchmark
# Usage: run_round.command [-swift_tar] [-power-test] [-full]
#   -swift_tar  : 把 tar 導向已安裝的 swift_tar（不修改 zshrc.sh）；
#                 不帶此旗標時用系統 tar。
#   -power-test : 執行 Time Profiler trace（helper/tracer.command）。預設關閉，
#                 因為它會主導整輪耗時；關閉時 trace_analysis 與
#                 cpu_call_tree_analysis 會沿用 trace/ 中上一輪的結果。
#   -full       : 等同同時指定 -swift_tar 與 -power-test，即完整一輪。這是最慢
#                 的組合，但唯有它能在同一輪內同時取得 swift_tar 的數據與新的
#                 trace，兩者因而共用相同的機器狀態與熱度條件。
#   -swift_tar  : points tar at the installed swift_tar (zshrc.sh untouched);
#                 without this flag, uses system tar.
#   -power-test : runs the Time Profiler traces (helper/tracer.command). Off by
#                 default because they dominate the round's wall time; when off,
#                 trace_analysis and cpu_call_tree_analysis reuse the previous
#                 round's results from trace/.
#   -full       : equivalent to -swift_tar -power-test, i.e. a complete round.
#                 It is the slowest combination, but it is the only one that
#                 collects swift_tar figures and fresh traces in the same round,
#                 so the two share identical machine state and thermal history.
cd /Users/raliclo/proj/lzfse2 || exit 1

: > round_status.txt

USE_SWIFT_TAR=0
export LZFSE_REQUIRE_NATIVE_ZLIB=0
# Time Profiler traces are off by default because they dominate the round's wall
# time. -power-test turns them back on; without it, trace_analysis and
# cpu_call_tree_analysis reuse the previous round's results from trace/.
# Time Profiler trace 預設關閉，因為它會主導整輪的執行時間。-power-test 可重新
# 開啟；未啟用時，trace_analysis 與 cpu_call_tree_analysis 會沿用 trace/ 中上一
# 輪的結果。
export LZFSE_POWER_TEST=0
for arg in "$@"; do
    [[ "$arg" == "-swift_tar" ]] && USE_SWIFT_TAR=1
    [[ "$arg" == "-power-test" ]] && export LZFSE_POWER_TEST=1
    # -full is a shorthand, not a third mode: it sets the same two variables the
    # individual flags do, so there is one code path to reason about.
    # -full 只是簡寫而非第三種模式：它設定的就是那兩個旗標各自會設的變數，因此
    # 只有一條程式路徑需要推敲。
    [[ "$arg" == "-full" ]] && { USE_SWIFT_TAR=1; export LZFSE_POWER_TEST=1 }
done
echo "MODE swift_tar=$USE_SWIFT_TAR power_test=$LZFSE_POWER_TEST $(date +%H:%M:%S)" >> round_status.txt

# swift_tar compile + test（無條件，與 lzfse 相同）
# swift_tar compile + test (unconditional, same gate as lzfse)
echo "RUNNING_SWIFT_TAR_COMPILE $(date +%H:%M:%S)" >> round_status.txt
./swift_tar/compile_tar.sh >> round_status.txt 2>&1
swift_tar_compile_rc=$?
SWIFT_TAR_BIN="/opt/homebrew/bin/swift_tar"
if [[ $swift_tar_compile_rc -ne 0 ]] || [[ ! -x "$SWIFT_TAR_BIN" ]]; then
    echo "SWIFT_TAR_COMPILE_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
echo "SWIFT_TAR_COMPILE_OK $SWIFT_TAR_BIN $(date +%H:%M:%S)" >> round_status.txt
echo "RUNNING_SWIFT_TAR_TEST $(date +%H:%M:%S)" >> round_status.txt
COPYFILE_DISABLE=1 "$SWIFT_TAR_BIN" -test -debug > debug/swift_tar-test.txt 2>&1
if [[ $? -ne 0 ]] || grep -q "✗" debug/swift_tar-test.txt; then
    echo "SWIFT_TAR_TEST_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
echo "SWIFT_TAR_TEST_OK $(date +%H:%M:%S)" >> round_status.txt

# -test covers interop with the system tar only. These two guard what it does
# not touch: the crypto layer, where a fault is silent rather than loud, and the
# parallel extract write path, which -test never exercises for symlink
# clobbering, duplicate-entry order or hardlink identity.
# -test 只涵蓋與系統 tar 的互通。以下兩項守住它沒碰到的部分：加密層（其錯誤
# 是靜默而非明顯的），以及平行解出的寫入路徑（-test 從未測試 symlink 覆蓋、
# 重複項目順序與 hardlink 身分）。
echo "RUNNING_SWIFT_TAR_CRYPTO_SELFTEST $(date +%H:%M:%S)" >> round_status.txt
"$SWIFT_TAR_BIN" --crypto-selftest > debug/swift_tar-crypto-selftest.txt 2>&1
if [[ $? -ne 0 ]] || grep -q "^FAIL:" debug/swift_tar-crypto-selftest.txt; then
    echo "SWIFT_TAR_CRYPTO_SELFTEST_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
echo "SWIFT_TAR_CRYPTO_SELFTEST_OK $(date +%H:%M:%S)" >> round_status.txt

# Report goes to debug/ so the run does not dirty the swift_tar submodule.
# 報告寫到 debug/，避免本輪執行弄髒 swift_tar submodule。
echo "RUNNING_SWIFT_TAR_PARALLEL_EXTRACT $(date +%H:%M:%S)" >> round_status.txt
SWIFT_TAR="$SWIFT_TAR_BIN" ./swift_tar/verifications/parallel_extract_correctness.zsh \
    debug/swift_tar-parallel-extract.txt > debug/swift_tar-parallel-extract.log 2>&1
if [[ $? -ne 0 ]] || grep -q "FAIL" debug/swift_tar-parallel-extract.txt; then
    echo "SWIFT_TAR_PARALLEL_EXTRACT_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
echo "SWIFT_TAR_PARALLEL_EXTRACT_OK $(date +%H:%M:%S)" >> round_status.txt

# -swift_tar PATH shim（不修改 zshrc.sh）：只在明確帶 -swift_tar 旗標時
# 建立 tar→swift_tar symlink 並 prepend 進 PATH。
# PATH shim (zshrc.sh untouched): only when -swift_tar is explicitly passed,
# symlink tar -> swift_tar and prepend it to PATH.
if [[ "$USE_SWIFT_TAR" == "1" ]]; then
    SWIFT_TAR_SHIM_DIR="/tmp/lzfse2-swift-tar-shim"
    mkdir -p "$SWIFT_TAR_SHIM_DIR"
    ln -sf "$SWIFT_TAR_BIN" "$SWIFT_TAR_SHIM_DIR/tar"
    export PATH="$SWIFT_TAR_SHIM_DIR:$PATH"
    export SWIFT_TAR_BIN
    export LZFSE_REQUIRE_NATIVE_ZLIB=1
    rehash
    swift_tar_identity="$("$SWIFT_TAR_BIN" --version 2>&1)"
    if [[ $? -ne 0 || "$swift_tar_identity" != swift_tar\ * ]]; then
        echo "SWIFT_TAR_IDENTITY_FAILED ${swift_tar_identity} $(date +%H:%M:%S)" >> round_status.txt
        exit 1
    fi
    if [[ "$(command -v tar)" != "$SWIFT_TAR_SHIM_DIR/tar" ]]; then
        echo "SWIFT_TAR_SHIM_RESOLUTION_FAILED $(command -v tar) $(date +%H:%M:%S)" >> round_status.txt
        exit 1
    fi
    echo "USING_SWIFT_TAR $SWIFT_TAR_BIN NATIVE_ZLIB=required ${swift_tar_identity} $(date +%H:%M:%S)" >> round_status.txt
fi

echo PATH="$PATH" >> round_status.txt

git gc --prune=now --aggressive >> round_status.txt 2>&1
echo "RUNNING compile $(date +%H:%M:%S)" >> round_status.txt
rm -f ./lzfse
./compile.sh >> round_status.txt 2>&1
if [[ ! -x ./lzfse ]]; then
    echo "COMPILE_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
if grep -q "✗" lzfse-test.txt; then
    echo "TEST_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
echo "TEST_OK $(date +%H:%M:%S)" >> round_status.txt
echo "RUNNING benchmark $(date +%H:%M:%S)" >> round_status.txt
./benchmark.sh >> round_status.txt 2>&1
if [[ "$USE_SWIFT_TAR" == "1" ]]; then
    sudo --preserve-env=PATH,SWIFT_TAR_BIN,LZFSE_REQUIRE_NATIVE_ZLIB ./benchmark2.sh >> round_status.txt 2>&1
else
    sudo ./benchmark2.sh >> round_status.txt 2>&1
fi
rc=$?
if [[ $rc -eq 0 ]]; then
    echo "BENCH_DONE $(date +%H:%M:%S)" >> round_status.txt
else
    echo "BENCH_FAILED $rc $(date +%H:%M:%S)" >> round_status.txt
fi
git gc --prune=now --aggressive >> round_status.txt 2>&1

sudo ./gitOwner.sh
exit $rc
