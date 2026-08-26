# lzfse2 TODO

工具與腳本層面的待辦。效能量測的待辦仍記在 [OPTIMIZATION.md](./OPTIMIZATION.md)
的各輪「待辦」章節。
Tooling and script-level items. Performance measurement TODOs stay in the
per-round sections of [OPTIMIZATION.md](./OPTIMIZATION.md).

---

## 1. ✅ 已完成（2026-08-26）：把 benchmark 函式移出 zshrc.zsh / Split the benchmark functions out of zshrc.zsh

**動機**：`zshrc.zsh` 要與 `~/proj/fastZsh` 共用，而量測程式碼不該進入共用的 shell
設定。
**Why**: `zshrc.zsh` is to be shared with `~/proj/fastZsh`, and measurement code
does not belong in a shared shell profile.

**結果**：`zshrc.zsh` 1374 → **635 行**；新增 `lz4bench.zsh` **762 行**。四個 source
點（`benchmark.zsh`、`benchmark2.zsh`、`develop.command`、`helper/check.zsh`）改為兩行。

**先前的分析有兩處是錯的，記在這裡以免重蹈 / Two errors in the earlier analysis:**

1. **「零反向相依」不成立。** 該結論寫於 2026-08-15，實測時已經失效：`extract()`
   （在區塊之前，原本要留下）呼叫 `memProbe` 8 次、`benchmarkTgzTar` 3 次、
   `benchmarkZstdDecode` 1 次。而且 `benchmarkTgzTar` 不只在量測路徑上——`*.tgz)`
   的一般解壓就走它。照原計畫搬完，`zshrc.zsh` 單獨載入時解 `.tgz` 會壞。
   The "no reverse dependency" finding was already false by the time it was
   acted on: `extract()` calls three of the functions that were to move, and
   `benchmarkTgzTar` sits on the ordinary `.tgz` path, not only the benchmark's.

   **修法**：`extract()` 一併搬走。它已經不是通用函式——帶有純為量測而生的
   `probe` 模式與兩個後端閘門。`~/proj/fastZsh/zshrc` 自有一份較早、未長出這些閘門
   的 `extract()`（第 366 行），故搬走不會使那邊失去該功能。**fastZsh 未被改動。**
   `extract()` moved too; fastZsh keeps its own earlier copy and was not touched.

2. **函式數與行號全部過期。** 分析時記的是 12 個函式、664–1134 行、全檔 1204 行。
   實際是 **20 個函式、674–1303 行、全檔 1374 行**——`473a247`（解壓一致性改用
   manifest 比對）在其間新增了 8 個 `benchStat*` / `benchManifest*` 函式。區塊仍
   連續，兩側鄰居仍是 `ffilter` 與 `claudeCodeEnv`。
   The counts and line numbers had drifted: 20 functions over 674-1303, not 12
   over 664-1134, because a later commit added eight more into the same block.

**唯一跨界相依**：`lz4bench.zsh` → `nanoTimeElapsed`（12 處），後者留在
`zshrc.zsh`，由載入順序保證可用。反向為零。
The single cross-file edge is `lz4bench.zsh` -> `nanoTimeElapsed`; nothing goes
the other way.

**驗證**：兩檔 `zsh -n` 通過；`zshrc.zsh` 對已搬走的函式零殘留參照；載入兩檔後 24
個函式全部就位，只載入 `zshrc.zsh` 時 benchmark 函式全部不存在；實跑
`benchAlgoName`、`diskcheck`、`nanoTimeElapsed`，以及 `extract <archive> probe` 的
native 與 external 兩支分支（10.8 MB / 2.1 MB，與分離前量到的相同）。
Verified: both files pass `zsh -n`, all 24 functions resolve with both sourced
and none of the benchmark ones leak with only `zshrc.zsh`, and the probe path
reports the same figures as before the split.

**時機**：第 3 條原本要求「先跑完整一輪再搬」，本次由使用者指示提前執行。因此下一輪
的數字若與 R48-Mac 有出入，**載入路徑的改變是需要先排除的因素之一**。
Sequencing note: item 3 asked for this to wait until after a round; it was done
first at the user's direction, so a change in the next round's numbers has the
load path as one candidate cause to rule out.

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

## 3. ~~第 1 項的時機~~（已不適用 / no longer applicable）

原文：先跑完整一輪拿到資料，再做第 1 項的搬移；它會改變 benchmark 的載入路徑，若與
量測混在一起，之後就分不清數字的變動來自程式碼還是重構。

2026-08-26 由使用者指示提前執行。這條的顧慮並未消失，只是轉為第 1 項末尾記下的
「排除因素」：下一輪若數字有出入，載入路徑是候選原因之一。
Superseded on 2026-08-26 at the user's direction. The concern did not go away;
it became a note in item 1 about what to rule out if the next round's numbers
move.

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
