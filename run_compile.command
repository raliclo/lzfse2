#!/bin/zsh
# 只編譯 + 測試（不跑 benchmark）/ Compile + test only
cd /Users/raliclo/proj/lzfse2 || exit 1
rm -f ./lzfse
./compile.sh
