#!/bin/zsh
# swiftc lzfse2.swift -o lzfse2
# swiftc lzfse.swift -o lzfse
swiftc -O -swift-version 6 lzfse-cli.swift -o lzfse
swiftc -g lzfse-cli.swift -o /opt/homebrew/bin/lzfse-debug
cp ./lzfse /opt/homebrew/bin
./lzfse -test > debug/lzfse-test.txt
# lldb -- /opt/homebrew/bin/lzfse-debug -encode -i ../sample_wix.tar -o sample_wix.lzfse -algo other2