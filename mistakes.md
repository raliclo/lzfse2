# 容易犯的錯誤 / Mistakes That Are Easy to Make

本檔只收錄**在這棵樹上實際發生過**的錯誤，且每一條都符合同一個條件：

**它們都沒有讓任何工具報錯。** 每一條都產生了一個看起來完全合理的結果。

沒有實際踩過的事情不要加進來——一份靠想像維護的清單會與它所描述的程式反向漂移，而沒有
任何東西會回報這件漂移。加入一條時請一併寫出**當初是什麼症狀**，因為下一個人是先看到症狀
才找到這裡的。

**每一條都記錄重複次數。** 重複四次的錯誤與只發生一次的錯誤，需要的不是同一種防範：前者
說明「知道」不足以避免它，得靠工具或流程擋下。

This file records only mistakes that actually happened in this tree, and every one shares a
property: none of them made any tool report an error. Each produced a result that looked
entirely reasonable. Every entry carries a repeat count, because a mistake made four times
needs a different defence from one made once -- knowing about it evidently is not enough.

---

## 計數表 / The counter

次數的權威來源是 [`mistakes_counter.csv2`](./mistakes_counter.csv2)，不是本文。以 `csv2`
讀寫，理由與全域 CLAUDE.md 相同——這張表會被逐格更新，而逗號切割在此正是會靜默寫錯的那種
操作。

```sh
csv2 -r -t -md --pretty -i mistakes_counter.csv2      # 出表
csv2 -get 2:3 -i mistakes_counter.csv2                # 讀第 2 條的次數
csv2 -update 2:3 7 -i mistakes_counter.csv2 --in-place  # 第 2 條再犯一次
```

The counts live in `mistakes_counter.csv2`, not in this prose. It is read and written
through `csv2` for the reason the global CLAUDE.md gives: the table is updated cell by cell,
and splitting on commas is exactly the operation that goes wrong in silence there.

| # | 標題 | 次數 | 首次 | 最近 |
| ---: | --- | ---: | --- | --- |
| 1 | 自己的過濾器把失敗藏起來 | **4** | 2026-08-27 | 2026-08-29 |
| 2 | 未交錯、次數不足就相信效能差異 | **6** | 2026-08-28 | 2026-08-28 |
| 3 | zsh MULTIOS 在管線中洩漏 stdout | 1 | 2026-08-29 | 2026-08-29 |
| 4 | `${array[(r)pat]}` 在 `set -u` 下無命中即中止 | 2 | 2026-08-29 | 2026-08-29 |
| 5 | 以 Python heredoc 代替編輯器 | 1 | 2026-08-28 | 2026-08-28 |
| | **合計** | **14** | | |

第 1 與第 2 條佔了 14 次中的 10 次，且兩者是同一件事的兩面：**一個看起來合理的結果，沒有
任何東西回報它是錯的。** 這也是本檔的收錄條件。

Entries 1 and 2 account for 10 of the 14 and are two faces of one thing: a plausible result
that nothing reports as wrong. That is also this file's admission criterion.

---

## 1. 自己的過濾器把失敗藏起來 — **已發生 4 次（2026-08-27 至 08-29）**

**症狀**：指令「成功」了，但實際上什麼都沒做；或測試「通過」了，而摘要行下面就是失敗。

**四次的實際形式**：

| # | 寫法 | 藏起了什麼 |
| --- | --- | --- |
| 1 | `sudo -n kill … 2>/dev/null` | `sudo: a password is required`。連續三輪 kill 全部沒送出，而我回報「已送出 SIGINT」 |
| 2 | `test.zsh \| grep -E 'PASS\|通過' \| tail -1` | 結尾的 `失敗 / FAIL: 2 checks`——grep 取到較早的成功行 |
| 3 | `compile_tar.zsh \| grep -cE ': (error\|warning):'` | `permission denied: version-mac.txt`。那是 shell 層級的失敗，不符合編譯器診斷的樣式，於是「診斷數 0」被當成建置成功，接著花三輪查一個不存在的解析問題 |
| 4 | `grep -c … \|\| print 0` | `grep -c` 零命中時印 `0` 但退出碼為 1，於是 `0` 被印兩次，算術以 bad math expression 失敗，**一輪乾淨的執行被判定為失敗** |

**共同結構**：過濾器是為了讓輸出好讀而寫的，而它的樣式只涵蓋了預期中的那一種訊息。非預期
的訊息不符合樣式，於是消失——而消失與「沒有問題」在畫面上完全一樣。

**第 4 條的方向是相反的**（把成功說成失敗），但成因相同，且同樣讓判定失去意義。

**現在怎麼防**：
- 過濾建置輸出時，一併涵蓋 `denied`、`No such file`、`command not found` 等 shell 層級的失敗，
  不要只涵蓋編譯器診斷的樣式。
- 讀測試結果時看**最後一行**與退出碼，不要 `grep … | tail -1`——那會取到較早的成功行。
- `grep -c` 已經會印 `0`，不要再加 `|| print 0`。
- 診斷訊息**永遠不要**用 `2>/dev/null` 丟掉。CLAUDE.md 已將此列為規則。

---

## 2. 在沒有交錯、次數不足的情況下相信一個效能差異 — **已發生 6 次（2026-08-28）**

**症狀**：量到一個看起來很大的差異（+81%、+36%、−21%……），而它有合理的解釋。

**六次**：BVX3 encode +81%、claw-code decode +21%、`--exclude` 開銷 +9.5%、加密建立 +13.6%、
R50 對 R48 的 decode「變快 10.7%」與「變慢 22.4%」。**六次全部在交錯複量後消失。**

**實際狀況**：這台機器單次量測的變異可達 2 倍以上。逐次數值長這樣：

```
舊 2.7529 2.0984 2.0816 2.0764 2.1399 2.1459 2.1114 2.0841 2.8626 3.1310
新 2.0760 2.1277 2.0982 2.1423 2.1101 2.1207 2.1727 2.1065 3.4081 2.3936
```

兩邊各有幾次跳到 2.7–3.4 秒。取平均會被它們主導；只跑三次則可能整組落在高端。

**還有一種更難察覺的形式**：反覆在內接碟上寫入 1.3 GB 會讓後續量測**單調劣化**
（1.74 → 3.08 → 5.45 → 5.99 秒）。此時連最小值都失效——它挑到的是序列早期的那一次，於是
「先量的那個設定」永遠看起來比較快。`-n 1` 就是這樣「贏」了兩輪，直到改用 RAM disk 才發現
六個 `-n` 值全在 ±1.8% 內。

**現在怎麼防**：
- **交錯**執行 A 與 B，不要跑完一組再跑另一組。
- **取最小值**，不要取平均。
- 次數不足時寧可不下結論。6 輪仍可能被離群值主導；關鍵結論用 10 輪。
- 涉及大量磁碟寫入時，解出目標用 **RAM disk**（`swift_tar/verifications/zstd_decode_gap.zsh`
  的 `--mode storage` 會同時跑兩者，好讓儲存層的影響顯形）。
- 看 **user 與 sys**，不只看 real。real 只說「誰比較慢」；user/sys 才說「慢在計算還是慢在
  系統呼叫」，而那兩者要改的東西完全不同。R50-Mac 第 3 節的頭兩版結論都是只看 real 寫的，
  兩次都被推翻。

---

## 3. zsh 的 MULTIOS 讓 `2>&1 >/dev/null` 在管線中洩漏 stdout — **已發生 1 次，但誤判過 1 次**

**症狀**：`timed()` 對 `--cat` 回傳空字串，而對 `-x` 正常。呼叫端的 `set -- $(timed …)` 於是
清空位置參數，那兩列的量測靜默變成 0——**而表格其餘各列仍有數字**，看起來像是「那兩列沒跑」
而不是「量測壞了」。

**實際狀況**：`cmd 2>&1 >/dev/null | grep …` 之下，`--cat` 的整條 1.4 GB tar 串流漏進管線，
grep 因而找不到 `real` 那一行。三種形狀對照：

```
zsh  「cmd 2>&1 >/dev/null | cat」        → ERR 與 OUT 皆出現   ← 洩漏
bash 同一形狀                              → 只有 ERR
zsh  同一形狀 + unsetopt multios           → 只有 ERR
zsh  「cmd 2>&1 >/dev/null」（無管線）      → 只有 ERR
```

成因是 **MULTIOS**（zsh 預設啟用），且**只在管線中**發生：stdout 本已接到管線，`>/dev/null`
被當成追加一個輸出而非取代。與平台無關，是 shell 差異——三個平台的 zsh 都一樣。

**誤判的那一次值得單獨記下。** 我第一次「驗證」時把重導寫在 `zsh -c '…'` **裡面**、管線在
**外面**：

```zsh
zsh -c 'sh -c "echo OUT; echo ERR >&2" 2>&1 >/dev/null' 2>&1 | sed …    # 只得到 ERR
```

那個形狀裡管線不在重導的作用域內，所以測不到洩漏。我據此宣稱「不是 MULTIOS」——**否定了
自己原本正確的診斷**，並把錯誤的解釋寫進了註解。原本的判斷對，中間的否定錯。

**現在怎麼防**：
- 需要「留 stderr、丟 stdout」時，**兩個串流各自導向檔案**，不要用 `2>&1 >…`：
  ```zsh
  /usr/bin/time -l "$@" >/dev/null 2>"$errfile"
  ```
- 驗證一個 shell 行為時，**重現的形狀必須與出問題的形狀相同**。把重導與管線分置於不同的
  shell 層級，測到的是另一件事。
- 計時或量測函式回傳空值時要**大聲失敗**，不要讓它靜默變成 0。

---

## 4. `${array[(r)pattern]}` 在 `set -u` 之下無命中即中止腳本 — **已發生 2 次（同一支腳本內）**

**症狀**：腳本在毫不相干的一行停住，訊息是 `MODES[(r)all]: parameter not set`。

**實際狀況**：zsh 的 `(r)` 下標是「回傳第一個相符的元素」，無相符時回傳未設定的值。在
`set -u` 之下，讀取未設定的值即為錯誤。`zsh -n` 的語法檢查不會發現——它是執行期行為。

同一支腳本內犯了兩次（`MODES[(r)all]` 與 `MODES[(r)storage]`），因為修好第一處時沒有搜尋
同樣的形式。

**現在怎麼防**：
```zsh
[[ "${MODES[(r)all]:-}" == all ]] && …
```
加上 `:-` 的預設值。修好一處之後，用 `grep -n 'MODES\[(r)'` 找出同檔中所有同形式的用法——
這類錯誤很少只出現一次。

---

## 5. 用 Python heredoc 代替編輯器，把跨行運算式攔腰截斷 — **已發生 1 次**

**症狀**：程式編譯通過、型別檢查通過、以 0 結束，而 `-p` 同時失去自己的效果並取得一個
無關的效果。

**實際狀況**：`tarRestorePermissions` 原是一個跨行運算式：

```swift
tarRestorePermissions = !args.contains("--no-same-permissions")
    || args.contains("-p") || args.contains("--same-permissions")
```

以 Python 的字串替換插入新的一行時，插在了兩行之間，於是續行 `|| args.contains("-p")`
**接到了新變數上**。

被 `test_same_permissions` 抓到，但當時我用 `grep -E 'PASS|通過' | tail -1` 讀結果（見第 1 條
第 2 例），失敗被藏住了。

**現在怎麼防**：改檔用 Edit／Write 工具，要腳本就用 zsh。CLAUDE.md 已將此列為規則。Python
的字串替換瞄準的是一段**看不見的**字面值；Edit 工具會呈現前後文，那類插入不會發生在看不見
的地方。
