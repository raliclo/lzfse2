#!/bin/zsh
setopt NULL_GLOB

rm -rf xbenchTest
rm -rf llama.cpp.*(N)
rm -rf claw-code.*(N)
git gc --prune=now --aggressive >> round_status.txt 2>&1

source ./zshrc.sh
source ./compile.sh
sleep 60
# 下一輪啟用記憶體峰值量測（probe）：對 lazy2/optimal 的 encode+decode 量 peak RSS（見 zshrc.sh memProbe）。
# 預設開啟；要關閉就在呼叫前 export LZFSE_MEMPROBE=0。probe 會多跑 lazy2/optimal 各一次 encode（~1.3GB），耗時略增。
# Enable peak-RSS probe for the next round (default on); set LZFSE_MEMPROBE=0 to disable.
export LZFSE_MEMPROBE="${LZFSE_MEMPROBE:-1}"
if [[ "$LZFSE_MEMPROBE" == "1" ]]; then
    echo "[Info] Running Benchmark WITH probe mode (LZFSE_MEMPROBE=1). Peak-RSS for lazy2/optimal (encode+decode) will be recorded in the result txt."
else
    echo "[Info] Running Benchmark without probe mode. Results will be saved to lz4bench-claw-code.txt and lz4bench-llama.cpp.txt."
fi
# Pre-check storage before benchmarking. Stop if available space is less than 25GB.
diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; exit 1; }
lz4bench claw-code > lz4bench-claw-code.txt 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "Benchmark aborted: claw-code lz4bench failed with status $rc." >&2
    exit $rc
fi
rm -rf claw-code.*(N)
rm -rf xbenchTest
rm -rf llama.cpp.*(N)

git gc --prune=now --aggressive >> round_status.txt 2>&1

sleep 60
# Second disk check before llama.cpp section
diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; exit 1; }
lz4bench llama.cpp > lz4bench-llama.cpp.txt 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "Benchmark aborted: llama.cpp lz4bench failed with status $rc." >&2
    exit $rc
fi

rm -rf xbenchTest
rm -rf llama.cpp.*(N)
rm -rf claw-code.*(N)
git gc --prune=now --aggressive >> round_status.txt 2>&1

echo "Done."
