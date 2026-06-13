#!/bin/zsh
rm -rf xbenchTest
rm -rf llama.cpp.*
rm -rf claw-code.*
git gc --prune=now --aggressive >> round_status.txt 2>&1

source ./zshrc.sh
source ./compile.sh
sleep 60

# Pre-check storage before benchmarking. Stop if available space is less than 25GB.
diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; exit 1; }
lz4bench claw-code > lz4bench-claw-code.txt 2>&1
rm -rf claw-code.*
rm -rf xbenchTest
rm -rf llama.cpp.*

git gc --prune=now --aggressive >> round_status.txt 2>&1

sleep 60
# Second disk check before llama.cpp section
diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; exit 1; }
lz4bench llama.cpp > lz4bench-llama.cpp.txt 2>&1

rm -rf xbenchTest
rm -rf llama.cpp.*
rm -rf claw-code.*
git gc --prune=now --aggressive >> round_status.txt 2>&1

echo "Done."
