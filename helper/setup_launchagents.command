#!/bin/zsh
# 建立四個 LaunchAgent（登入自動執行）：
#   1) caffeinate -d         —— 防止睡眠
#   2) open -a Claude        —— 重開機後自動開啟 Claude
#   3) open -a ChatGpt       —— 重開機後自動開啟 ChatGpt
#   4) sleep 30; osascript -e 'tell application "Terminal" to do script "cd ~/proj/lzfse2; ./check.zsh"' —— 重開機後 30 秒自動在 Terminal 執行 check.zsh
# 本腳本刻意保留於 lzfse2，可重複執行（idempotent）。
LA="$HOME/Library/LaunchAgents"
out=/Users/raliclo/proj/lzfse2/_la_verify.txt
mkdir -p "$LA"

cat > "$LA/com.raliclo.caffeinate.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.raliclo.caffeinate</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-d</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST

cat > "$LA/com.raliclo.openclaude.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.raliclo.openclaude</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>Claude</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

cat > "$LA/com.raliclo.openchatgpt.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.raliclo.openchatgpt</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>ChatGpt</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

cat > "$LA/com.raliclo.checksh.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.raliclo.checksh</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>sleep 30; /usr/bin/osascript -e 'tell application "Finder" to set sb to bounds of window of desktop' -e 'set sw to item 3 of sb' -e 'set sh to item 4 of sb' -e 'set ww to (sw / 4) as integer' -e 'set wh to (sh / 4) as integer' -e 'set x1 to 0' -e 'set y1 to (sh - wh - 200)' -e 'set x2 to (x1 + ww)' -e 'set y2 to (sh - 200)' -e 'tell application "Terminal"' -e '    activate' -e '    do script "source ~/proj/lzfse2/helper/check.zsh"' -e '    delay 0.5' -e '    set bounds of window 1 to {x1, y1, x2, y2}' -e 'end tell'</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

{
echo "=== plutil -lint ==="
for p in caffeinate openclaude openchatgpt checksh; do plutil -lint "$LA/com.raliclo.$p.plist"; done
echo "=== reload (idempotent) ==="
for p in caffeinate openclaude openchatgpt checksh; do
  launchctl unload "$LA/com.raliclo.$p.plist" 2>/dev/null
  launchctl load -w "$LA/com.raliclo.$p.plist" 2>&1 && echo "$p loaded"
done
echo "=== launchctl list | grep raliclo ==="
launchctl list | grep raliclo
echo "=== plist 檔案 ==="
ls -la "$LA"/com.raliclo.*.plist
echo "DONE"
} > "$out" 2>&1
