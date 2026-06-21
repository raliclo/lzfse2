# swiftc -O md-translate.swift -o md-translate >> round_status.txt 2>&1
if [[ -x ./md-translate ]]; then
    ./md-translate -i OPTIMIZATION.md -o OPTIMIZATION-en.md >> translate_status.txt 2>&1
    # ./md-translate -i LPDDR_power_estimation/LPDDR_power_info.md \
                    # -o LPDDR_power_estimation/LPDDR_power_info-en.md >> translate_status.txt 2>&1
    # README.zh-TW.md 繁體中文 -> 英文 （覆寫 README.md）
    ./md-translate -i README.zh-TW.md -o README.md >> translate_status.txt 2>&1
    
    echo "TRANSLATE_DONE $(date +%H:%M:%S)" >> round_status.txt
else
    echo "TRANSLATE_SKIPPED (md-translate.swift build failed) $(date +%H:%M:%S)" >> round_status.txt
fi