#!/bin/zsh
# 強制重啟：不詢問、不彈框。強制 kill -9 Claude 與所有使用者 GUI App
# （僅保留 Terminal 執行本腳本與 Finder），確保沒有任何 App 能否決重啟。
# 重啟後 LaunchAgent 自動重開 Claude / check.sh / caffeinate。
# 本腳本刻意保留於 lzfse2，不自我刪除。

osascript -e 'display notification "5 秒後強制重啟：強制關閉所有 App（不會詢問、不會保存）" with title "lzfse2 reboot" subtitle "請立即停手…" sound name "Submarine"' 2>/dev/null
sleep 5

# 1) 強制關閉 Claude（無法被否決）
killall -9 Claude 2>/dev/null
pkill -9 -i claude 2>/dev/null

# 2) 強制關閉其他所有使用者 GUI App（排除 Terminal 本身與 Finder）
apps=$(osascript -e 'tell application "System Events" to get name of (every process whose background only is false)' 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
print -r -- "$apps" | while IFS= read -r app; do
  [[ -z "$app" ]] && continue
  case "$app" in
    'Google Chrome') ;;   # Chrome 作後援重啟（不會詢問是否關閉分頁）
    Code) ;;              # Code 跑本腳本
    Finder) ;;            # Finder 作後援重啟
    *) killall -9 "$app" 2>/dev/null ;;
  esac
done

sleep 2

# 3) 觸發重啟（已無 App 可否決；多重後援，皆無對話框）
osascript -e 'tell application "loginwindow" to «event aevtrrst»' 2>/dev/null \
  || osascript -e 'tell application "System Events" to restart' 2>/dev/null \
  || osascript -e 'tell application "Finder" to restart' 2>/dev/null
