#!/bin/zsh
rm -rf xbenchTest
source ./zshrc.sh
# Pre-check storage before benchmarking. Stop if available space is less than 25GB.
diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; exit 1; }
source ./compile.sh
lz4bench claw-code > lz4bench-claw-code.txt 2>&1
rm -rf claw-code.*
rm -rf xbenchTest
# Clean up any residual llama.cpp compressed artifacts from previous runs
rm -rf llama.cpp.*
sleep 60
# Second disk check before llama.cpp section
diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; exit 1; }
lz4bench llama.cpp > lz4bench-llama.cpp.txt 2>&1
rm -rf llama.cpp.*
rm -rf xbenchTest
echo "Done."