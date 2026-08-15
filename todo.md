# lzfse2 TODO

工具與腳本層面的待辦。效能量測的待辦仍記在 [OPTIMIZATION.md](./OPTIMIZATION.md)
的各輪「待辦」章節。
Tooling and script-level items. Performance measurement TODOs stay in the
per-round sections of [OPTIMIZATION.md](./OPTIMIZATION.md).

---

## 1. 把 lz4bench 相關函式移出 zshrc.zsh / Split the lz4bench functions out of zshrc.zsh

**動機**：`zshrc.zsh` 要與 `~/proj/fastZsh` 共用，而 lz4bench 是 lzfse2 專屬的
量測程式碼，不該進入共用的 shell 設定。
**Why**: `zshrc.zsh` is to be shared with `~/proj/fastZsh`, and the lz4bench
functions are lzfse2-specific measurement code that does not belong in a shared
shell profile.

**現況調查（2026-08-15，勿重做）/ Findings, so this is not re-derived:**

- 分界線乾淨：benchmark 函式集中在 **zshrc.zsh 的 664–1134 行**，12 個函式、
  約 470 行、佔全檔 1204 行的 39%，且為**連續區塊**——前面是 `ffilter`(652)、
  後面是 `claudeCodeEnv`(1135)，兩者皆為通用函式，不需東拼西湊。
  The block is contiguous: lines 664–1134, 12 functions, ~470 of 1204 lines,
  bracketed by general-purpose functions on both sides.
- **零反向相依**：沒有任何通用函式呼叫 benchmark 函式，故 `zshrc.zsh` 移除該區塊
  後不會壞。
  No general-purpose function calls a benchmark one, so removing the block
  cannot break the remainder.
- **唯一跨界相依**：`lz4bench` → `nanoTimeElapsed`（zshrc.zsh:606）。後者是通用的
  計時包裝器（`nanoTimeElapsed <command>`），且 **fastZsh 已有它**（19 處），
  故應留在 `zshrc.zsh`，由載入順序保證可用。
  The only edge is `lz4bench` → `nanoTimeElapsed`, a general-purpose timing
  wrapper that fastZsh already carries, so it stays put.

**移出的 12 個函式 / The 12 to move:**
`benchmarkTgzTar`、`benchmarkZstdDecode`、`getar`、`getzstd`、`tlz4`、`lzfseX`、
`diskcheck`、`benchStatus`、`benchAlgoName`、`memProbe`、`archiveMemProbe`、
`lz4bench`

**留下的 / What stays:**
`START_UP@BEGIN`／`@END`、`zshCompletions`、`setcc`、`cheditor`、`cd`、
`makeram`、`nanoTimeElapsed`、`ffilter`、`claudeCodeEnv`、`gemma4`

**做法 / Approach:**

```zsh
# lzfse2/lz4bench.zsh  ← 新檔，放專案根目錄（benchmark.zsh 用相對路徑 source）
# benchmark.zsh / benchmark2.zsh 的第 5 行 `source ./zshrc.zsh` 改為兩行：
source ./zshrc.zsh      # 通用，提供 nanoTimeElapsed
source ./lz4bench.zsh  # benchmark 專用
```

**驗證 / Verify:** 兩檔各跑 `zsh -n`；再確認 `diskcheck`、`benchAlgoName` 這類
純函式在 source 後可用，最後跑一次 benchmark 的最短路徑確認載入順序正確。

**注意 / Caveat:** `fastZsh/zshrc` 目前是 677 行（2026-06-12），lzfse2 版本已
1204 行，兩者相異 790 行。共用之前需要先決定同步方向；本項只負責把 lzfse2 這側
切乾淨，不處理兩邊的合併。fastZsh 自身已含 2 個 benchmark 函式，是否一併清掉屬
另一個決定。
`fastZsh/zshrc` is 677 lines from 2026-06-12 against lzfse2's 1204, diverging by
790 lines. Reconciling the two is a separate decision; this item only makes the
lzfse2 side cleanly separable.

---

## 2. ✅ 已完成（26aa779）：benchmark.zsh／benchmark2.zsh 中斷時的清理

`benchmark.zsh` 有 9 處 `rm`，但 **0 個 `trap`**——只在正常流程的節點清理。
Ctrl-C，或 diskcheck 以外的失敗，會留下 `xbenchTest`（解壓樹，約等於語料大小
1.4 GB）與各格式封存。在可用空間僅 28 GB 時，一次中斷可能殘留數 GB。
`benchmark.zsh` has nine `rm` calls and no `trap`, so it only cleans at the happy
path's checkpoints. A Ctrl-C, or any failure other than the diskcheck one,
leaves `xbenchTest` (~1.4 GB) and the per-format archives behind.

對照：swift_tar 的 14 支測試腳本中有 13 支採 `mktemp` + `trap ... EXIT`；唯一
例外 `streaming_budget_benchmark.zsh` 不產生暫存檔，因此無需清理。
For contrast, 13 of swift_tar's 14 test scripts pair `mktemp` with
`trap ... EXIT`; the one exception writes no temporaries.

**結果**：預期的卡點不存在。外層本就有 `cleanTempFiles()`，且涵蓋範圍比迴圈內的
`cleanup_bench_artifacts` 更廣（兩個資料集皆清），故不需提升巢狀函式，直接
`trap 'cleanTempFiles' EXIT INT TERM` 即可。結果檔位於 `$LZ4BENCH_LOG_DIR` 與
`BenchMarkResult.csv`，皆在其範圍之外。
實測：建立 `xbenchTest`／`claw-code.*`／`llama.cpp.*` 後送 SIGINT——殘留 0 個，
結果檔 2/2 保留。
The anticipated blocker did not exist: `cleanTempFiles()` was already top-level
and covers more than the loop-local helper, so a plain trap sufficed. Verified
with SIGINT: zero leftovers, both result files intact.

---

## 3. 第 1 項的時機 / Sequencing for item 1

**先跑完整一輪拿到資料，再做第 1 項的搬移。** 它會改變 benchmark 的載入路徑；若與量測混在一起，之後就分不清數字的變動來自程式碼還是重構。
Run the full round first, then do item 1. It changes the benchmark's load path;
interleaving that with a measurement round makes any change in the numbers
impossible to attribute.

---

## 4. ✅ 已完成（26aa779）/ Done

- `claude_test_sample_script.zsh`：完整一輪的無人值守啟動範本，含 caffeinate／
  磁碟／語料／工作區四項前置檢查與 sudo keep-alive。`--check` 實測 5/5 通過。
  背景說明：本機無 NOPASSWD 設定（2026-08-15 確認），而
  `run_round.command:134` 的 `sudo ./benchmark2.zsh` 位於耗時約 38 分鐘的
  `benchmark.zsh` 之後，屆時 5 分鐘的 sudo timestamp 早已過期，整輪會**靜默卡住
  等待密碼**——不是失敗，是無限等待。keep-alive 每 50 秒刷新即可避免。
  A launcher for the full round with four preflight checks and a sudo
  keep-alive. There is no NOPASSWD rule on this machine, and the round's `sudo`
  call sits after a ~38-minute step, by which time the 5-minute timestamp has
  expired and the round waits forever rather than failing.
