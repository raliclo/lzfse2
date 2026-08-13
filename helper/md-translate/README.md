# md-translate

`md-translate` 使用 Apple `Translation` framework，將 Markdown 由繁體中文翻譯
成英文，同時保留 fenced code block、inline code 與 README 語言切換連結。

`md-translate` uses Apple's `Translation` framework to translate Markdown from
Traditional Chinese to English while preserving fenced code blocks, inline
code, and README language-switch links.

## 目錄 / Layout

| 路徑 | 用途 |
|---|---|
| `md-translate.swift` | translator source / 翻譯器 source |
| `bin/md-translate` | macOS arm64 binary, intentionally committed — see below / macOS arm64 執行檔，刻意入版控，見下 |
| `build-mac.sh` | macOS build entrypoint / macOS 建置入口 |
| `md-translate-mac.sh` | rebuild and translate project Markdown / 重建並翻譯專案 Markdown |
| `clean_zh.py` | remove duplicated English prose from bilingual optimization notes / 清理雙語 optimization 記錄中的重複英文 |
| `translate_status.txt` | ignored runtime log / 已忽略的執行紀錄 |

## macOS 建置 / macOS Build

需要 macOS 15 或更新版本、Swift compiler，以及已安裝的來源與目標翻譯語言。

Requires macOS 15 or later, a Swift compiler, and installed source and target
translation languages.

```sh
./helper/md-translate/build-mac.sh
```

建置結果為 `helper/md-translate/bin/md-translate`。

The output is `helper/md-translate/bin/md-translate`.

## 執行 / Run

```sh
helper/md-translate/bin/md-translate \
  -i OPTIMIZATION.md -o OPTIMIZATION-en.md \
  -from zh-Hant -to en
```

完整專案翻譯流程：

Full project translation flow:

```sh
./helper/md-translate/md-translate-mac.sh
```

執行紀錄寫入本目錄的 `translate_status.txt`，build 與 pipeline 狀態仍追加至
專案根目錄的 `round_status.txt`。

The runtime log is written to `translate_status.txt` in this directory; build
and pipeline status continues to append to the repository's `round_status.txt`.

每個 translation batch 遇到暫時錯誤時最多重試三次。若最終翻譯行數不完整，
工具會以非零狀態碼結束且不覆寫輸出檔。

Each translation batch is retried up to three times after transient failures.
If the final translated-line count is incomplete, the tool exits nonzero and
does not overwrite the output file.

每次 retry 會先在 batch-local buffer 完成所有 response，成功後才提交至最終
輸出。任一文件翻譯失敗時，wrapper 與 benchmark pipeline 都會傳回非零狀態碼。

Each retry completes all responses in a batch-local buffer before committing
them to the final output. If either document fails, both the wrapper and the
benchmark pipeline return a nonzero status.

此工具只支援 macOS；Windows 專用 wrapper 與偽裝成 `.exe` 的 Mach-O binary
均不再保留。

This tool supports macOS only. Windows-specific wrappers and Mach-O binaries
disguised with an `.exe` suffix are no longer retained.

## 入版控的 binary：明確例外 / Committed binary: a deliberate exception

本專案一般不把編譯產物納入版控——`swift_tar` 甚至為此改寫過歷史以清除已入版的
binary，`release/`、`helper_windows/release/` 也都列在 `.gitignore`。
`bin/md-translate` 是這條規則的**唯一例外**，且為刻意如此。

This repository does not normally track build output — `swift_tar` even had its
history rewritten to purge committed binaries, and `release/` and
`helper_windows/release/` are both gitignored. `bin/md-translate` is the **one
deliberate exception** to that rule.

例外的範圍限定如下，逾越即應重新檢討：

The exception is scoped as follows; anything beyond this warrants revisiting it:

- 僅此一個檔案，且僅 macOS arm64。/ This one file only, macOS arm64 only.
- 必須能由 `build-mac.sh` 從 `md-translate.swift` 完整重建；binary 不是唯一
  來源。/ It must remain fully reproducible from `md-translate.swift` via
  `build-mac.sh`; the binary is never the only source of truth.
- 改動 `md-translate.swift` 後應一併重建並提交 binary，避免兩者不同步。/ When
  `md-translate.swift` changes, rebuild and commit the binary in the same change
  so the two do not drift apart.
- 這不是放寬對其他編譯產物的政策；`release/` 等目錄仍維持不入版控。/ This does
  not relax the policy for any other build output; `release/` and friends stay
  untracked.
