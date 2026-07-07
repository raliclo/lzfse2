#!/bin/zsh
# Cowork 自動化執行器：compile → 測試守門 → benchmark
# Auto-runner: compile → gate on tests → benchmark
# Usage: run_round.command [-swift_tar]
#   -swift_tar : 測試模式，把 tar 導向已安裝的 swift_tar（不修改 zshrc.sh）；
#                不帶此旗標時完全比照原行為，用系統 tar。
#   -swift_tar : test mode, points tar at the installed swift_tar (zshrc.sh
#                untouched); without this flag, behaves exactly as before
#                (system tar).
cd /Users/raliclo/proj/lzfse2 || exit 1

: > round_status.txt

USE_SWIFT_TAR=0
for arg in "$@"; do
    [[ "$arg" == "-swift_tar" ]] && USE_SWIFT_TAR=1
done

# swift_tar 測試用 PATH shim（不修改 zshrc.sh）：只在明確帶 -swift_tar 旗標時
# 建立 tar→swift_tar 的 symlink 並 prepend 進 PATH，讓 compile.sh/benchmark.sh/
# benchmark2.sh 等子行程呼叫的 tar 全部導向 swift_tar；未帶旗標時完全不動 PATH。
# swift_tar test PATH shim (zshrc.sh untouched): only when -swift_tar is
# explicitly passed, symlink tar -> swift_tar and prepend it to PATH so
# every child process (compile.sh/benchmark.sh/benchmark2.sh) resolves
# `tar` to swift_tar; PATH is left untouched otherwise.
if [[ "$USE_SWIFT_TAR" == "1" ]]; then
    if ! command -v swift_tar > /dev/null 2>&1; then
        echo "SWIFT_TAR_NOT_FOUND $(date +%H:%M:%S)" >> round_status.txt
        echo "[Error] -swift_tar requested but swift_tar not found in PATH. / 已指定 -swift_tar 但 PATH 中找不到 swift_tar。" >&2
        exit 1
    fi
    SWIFT_TAR_SHIM_DIR="/tmp/lzfse2-swift-tar-shim"
    mkdir -p "$SWIFT_TAR_SHIM_DIR"
    ln -sf "$(command -v swift_tar)" "$SWIFT_TAR_SHIM_DIR/tar"
    export PATH="$SWIFT_TAR_SHIM_DIR:$PATH"
    echo "USING_SWIFT_TAR $(command -v swift_tar) $(date +%H:%M:%S)" >> round_status.txt
fi

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
    sudo --preserve-env=PATH ./benchmark2.sh >> round_status.txt 2>&1
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
