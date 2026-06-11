# swiftc lzfse2.swift -o lzfse2
# swiftc lzfse.swift -o lzfse
swiftc -O lzfse-cli.swift -o lzfse
# swiftc -g lzfse-cli.swift -o lzfse
cp ./lzfse /opt/homebrew/bin
# lldb -- ./lzfse -encode -i ../sample_wix.tar -o sample_wix.lzfse -algo other2