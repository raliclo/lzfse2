#!/bin/zsh
# compile.zsh -- build the lzfse CLI, install it to /opt/homebrew/bin, self-test.
# compile.zsh -- 建置 lzfse CLI、安裝到 /opt/homebrew/bin，並執行自我測試。
#
#   ./compile.zsh          # release + debug build, install, then -test
#   ./compile.zsh --help
#
# Two binaries are built on purpose: the release one (-O -swift-version 6) is
# what the benchmarks measure, while lzfse-debug keeps symbols for lldb and is
# written straight into /opt/homebrew/bin. That destination is why benchmark2.zsh
# drops back to the invoking user before calling this script -- once lzfse-debug
# is root-owned, every later non-root build dies at link time.
# 刻意建置兩個執行檔：release 版（-O -swift-version 6）是 benchmark 量測的對象；
# lzfse-debug 保留符號供 lldb 使用，並直接寫入 /opt/homebrew/bin。正因為寫入該處，
# benchmark2.zsh 才會先降回呼叫者身分再執行本腳本——lzfse-debug 一旦變成 root 所有，
# 之後每次非 root 建置都會在連結階段失敗。
script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,16p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

# swiftc lzfse2.swift -o lzfse2
# swiftc lzfse.swift -o lzfse
swiftc -O -swift-version 6 lzfse-cli.swift -o lzfse
swiftc -g lzfse-cli.swift -o /opt/homebrew/bin/lzfse-debug
cp ./lzfse /opt/homebrew/bin
./lzfse -test > debug/lzfse-test.txt
# lldb -- /opt/homebrew/bin/lzfse-debug -encode -i ../sample_wix.tar -o sample_wix.lzfse -algo other2