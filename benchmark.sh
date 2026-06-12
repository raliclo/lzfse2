#!/bin/zsh
source ./zshrc.sh
lz4bench claw-code > lz4bench-claw-code.txt 2>&1
rm -rf claw-code.*
rm -rf xbenchTest
sleep 60
lz4bench llama.cpp > lz4bench-llama.cpp.txt 2>&1
rm -rf llama.cpp.*
rm -rf xbenchTest
echo "Done."