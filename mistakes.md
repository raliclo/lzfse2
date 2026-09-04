# 容易犯的錯誤 / Mistakes That Are Easy to Make

本檔只收錄**在這棵樹上實際發生過**的錯誤，且每一條都符合同一個條件：

**它們都沒有讓任何工具報錯。** 每一條都產生了一個看起來完全合理的結果。

沒有實際踩過的事情不要加進來——一份靠想像維護的清單會與它所描述的程式反向漂移，而沒有
任何東西會回報這件漂移。加入一條時請一併寫出**當初是什麼症狀**，因為下一個人是先看到症狀
才找到這裡的。

**每一條都記錄重複次數。** 重複六次的錯誤與只發生一次的錯誤，需要的不是同一種防範：前者
說明「知道」不足以避免它，得靠工具或流程擋下。

This file records only mistakes that actually happened in this tree, and every one shares a
property: none of them made any tool report an error. Each produced a result that looked
entirely reasonable. Every entry carries a repeat count, because a mistake made six times
needs a different defence from one made once -- knowing about it evidently is not enough.

**本檔是這棵樹的紀錄；可攜的那一份是 skill `mistakes_prevention`**
（`~/.claude/skills/mistakes_prevention/`）。它把本檔的八條整理成四個關口——判定成敗、
下效能結論、寫過濾器——並附上 `run_checked.zsh` 與 `counter.zsh`。在別的樹上工作時用那一份；
**次數與條目本文仍以本檔及 `mistakes_counter.csv2` 為準**，skill 不重複記錄次數。

This file is this tree's log. The portable form is the `mistakes_prevention` skill, which
carries the rules and the tools; the counts stay here.

---

## 計數表 / The counter

次數的權威來源是 [`mistakes_counter.csv2`](./mistakes_counter.csv2)，不是本文。以 `csv2`
讀寫，理由與全域 CLAUDE.md 相同——這張表會被逐格更新，而逗號切割在此正是會靜默寫錯的那種
操作。

```sh
csv2 -r -t -md --pretty -i mistakes_counter.csv2        # 出表
csv2 -get 2:3 -i mistakes_counter.csv2                  # 讀第 2 條的總次數
csv2 -update 2:3 7 -i mistakes_counter.csv2 --in-place  # 第 2 條再犯一次
```

The counts live in `mistakes_counter.csv2`, not in this prose. It is read and written
through `csv2` for the reason the global CLAUDE.md gives: the table is updated cell by cell,
and splitting on commas is exactly the operation that goes wrong in silence there.

| # | 標題 | 總次數 | 單日最多 | 發生天數 | 矯正措施 |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | 自己的過濾器把失敗藏起來 | **6** | 4 | **3** | `helper/run_checked.zsh` |
| 2 | 未交錯、次數不足就相信效能差異 | **6** | **6** | 1 | `verifications/zstd_decode_gap.zsh` |
| 3 | zsh MULTIOS 在管線中洩漏 stdout | 1 | 1 | 1 | — |
| 4 | `${array[(r)pat]}` 在 `set -u` 下無命中即中止 | 2 | 2 | 1 | — |
| 5 | 以 Python heredoc 代替編輯器 | 1 | 1 | 1 | — |
| 6 | `{1..$(…)}` 遇帶空白的輸出靜默不展開 | 1 | 1 | 1 | — |
| 7 | 驗證的範圍不含會失敗的平台 | 1 | 1 | 1 | — |
| 8 | zsh 綁定參數：命名為 `path` 等於覆寫 `PATH` | 1 | 1 | 1 | — |
| | **合計** | **19** | | | |

### `corrective` 欄的規則

**總次數超過 5 次時，`corrective` 不得為空。** 到那個數字，「知道」與「寫成規則」都已被
證明不足——必須有一個**工具或流程**擋在前面，而不是再寫一次提醒。

規則可機器檢查，不必靠人記得：

```sh
~/.claude/skills/mistakes_prevention/scripts/counter.zsh -i mistakes_counter.csv2 check
```

它逐格 `csv2 -get`，**不切逗號**。`corrective`、`shape`、`guard` 三欄都含引號內的逗號，
`awk -F,` 會靜默切錯並讓其右每一欄左移一格——本檔的主題正是這種不報錯的失敗，不該由本檔的
檢查腳本示範一次。

```zsh
# `wc -l` 的輸出帶前導空白，而 `{1..   5}` 不是合法的範圍——zsh 會原樣留下它，再依 IFS
# 切成 `{1..` 與 `5}` 兩個詞。迴圈照跑、不報錯，只是一格都沒讀到。`tr -d ' '` 是必要的。
# `wc -l` pads with spaces and `{1..   5}` is not a valid range, so zsh leaves it literal
# and splits it in two. The loop runs, reports nothing, and reads no cells.
for r in {1..$(csv2 -r -i mistakes_counter.csv2 | wc -l | tr -d ' ')}; do
  total=$(csv2 -get $r:3 -i mistakes_counter.csv2)
  corr=$(csv2 -get $r:9 -i mistakes_counter.csv2)
  (( total > 5 )) && [[ -z "$corr" ]] && print "✗ #$r total=$total 但 corrective 為空"
done
```

目前兩條已填，且**兩條的矯正方式不同**——因為第 1 條與第 2 條的分布不同（見下）：

| # | 分布 | 為何是這個矯正 |
| ---: | --- | --- |
| 1 | 6 次 / 3 天 | 知道之後仍然再犯，且每次換一種偽裝。**必須是強制檢查**：`run_checked.zsh` 讓摘要樣式成為附加、失敗掃描成為強制，`--want` 永不取代掃描 |
| 2 | 6 次 / 1 天 | 同一個下午沒有意識到。**只需把正確做法固化**：`zstd_decode_gap.zsh` 把交錯、取最小值、RAM disk、user/sys 拆解全部內建 |

`corrective` must not be empty once `total` exceeds five: at that point neither knowing nor
writing a rule has worked, and something must stand in the way. The two filled entries take
different forms because their distributions differ -- one recurred across days in new
disguises and needs a mandatory check, the other happened in a single afternoon and only
needed the right method made reusable.

### 為什麼「單日最多」與「發生天數」要分開記

總次數把兩種完全不同的情況混為一談，而它們需要的防範不同：

**第 2 條：6 次全在同一天，只跨 1 天。** 那是「同一個下午反覆踩」——當下沒有意識到，而不是
知道了仍然犯。這種靠**工具**擋得住：把正確的量測方式寫成腳本（`zstd_decode_gap.zsh`），
下次就不必重新想起交錯與取最小值。

**第 1 條：6 次分布在 3 天。** 那才是嚴重的——**知道之後仍然再犯**。2026-08-27 踩過並寫進
CLAUDE.md，08-28 與 08-29 又各犯一次，而且每次換一個形式（`2>/dev/null`、
`grep … | tail -1`、`grep -cE ':(error|warning):'`、`grep -c … || print 0`）。規則寫在檔案
裡不足以擋下它，因為每次的偽裝都不一樣。

**跨日重複的只有第 1 條**（`days_seen > 1`）。若要投入心力做工具防範，它是唯一有依據的
候選——其餘七條目前都只有「同日多次」的紀錄，尚不足以說明規則無效。

Total alone conflates two different situations. Six occurrences in one afternoon (entry 2)
means it was not noticed at the time, and a script fixes that. Six occurrences across three
days (entry 1) means it recurred *after* being written into CLAUDE.md, each time in a
different disguise -- a rule in a file is not enough to stop that. Entry 1 is the only one
with `days_seen > 1`, and so the only one with evidence that tooling is warranted.

---

## 1. 自己的過濾器把失敗藏起來 — **已發生 6 次（2026-08-27 至 08-29）**

**症狀**：指令「成功」了，但實際上什麼都沒做；或測試「通過」了，而摘要行下面就是失敗。

**六次的實際形式**（第 5、6 次在下方單獨說明，都發生在為了防這條而做的事情裡）：

| # | 寫法 | 藏起了什麼 |
| --- | --- | --- |
| 1 | `sudo -n kill … 2>/dev/null` | `sudo: a password is required`。連續三輪 kill 全部沒送出，而我回報「已送出 SIGINT」 |
| 2 | `test.zsh \| grep -E 'PASS\|通過' \| tail -1` | 結尾的 `失敗 / FAIL: 2 checks`——grep 取到較早的成功行 |
| 3 | `compile_tar.zsh \| grep -cE ': (error\|warning):'` | `permission denied: version-mac.txt`。那是 shell 層級的失敗，不符合編譯器診斷的樣式，於是「診斷數 0」被當成建置成功，接著花三輪查一個不存在的解析問題 |
| 4 | `grep -c … \|\| print 0` | `grep -c` 零命中時印 `0` 但退出碼為 1，於是 `0` 被印兩次，算術以 bad math expression 失敗，**一輪乾淨的執行被判定為失敗** |

**共同結構**：過濾器是為了讓輸出好讀而寫的，而它的樣式只涵蓋了預期中的那一種訊息。非預期
的訊息不符合樣式，於是消失——而消失與「沒有問題」在畫面上完全一樣。

**第 4 條的方向是相反的**（把成功說成失敗），但成因相同，且同樣讓判定失去意義。

**現在怎麼防**：用 [`helper/run_checked.zsh`](./helper/run_checked.zsh) 執行建置與測試。

```sh
helper/run_checked.zsh --want '通過|PASS:' -- swift_tar/test/test_exclude.zsh
helper/run_checked.zsh --quiet -- ./compile_tar.zsh
```

它的核心設計就是針對這條的共同結構：**摘要樣式是附加的，失敗掃描是強制的。** `--want`
指定你想看的行，但不會取代掃描；兩者並存，掃描永遠先跑。指令以 0 結束而輸出含失敗訊號時
——也就是本條六次中的四次——它會明講：

```
run_checked: FAILED / 失敗
  exit    : 0
  failures: 1 行符合 shell 層級的失敗樣式
  注意：指令以 0 結束，但輸出中有失敗訊號——正是 mistakes.md 第 1 條的形狀。
```

### 第 5 次與第 6 次：都發生在為了防這條而做的事情裡

**第 5 次——寫這支腳本時。** 第一版的失敗樣式有 `FAILED` 與 `[FAIL]`，卻漏掉
`失敗 / FAIL: 2 check(s)`——那是本樹測試腳本的標準失敗行。**同一個錯誤的第五種偽裝，出現
在為了防它而寫的東西裡。** 修補時另有一個陷阱：計數必須是「非零」而非「存在」，否則摘要行
`PASS: 139  FAIL: 0` 會讓每一次成功都被判成失敗——那是本條第 4 例的反向形式。

驗證：五種歷史偽裝逐一重現，全部攔下（rc≠0）；`PASS: 139  FAIL: 0` 與 `通過 / PASS: exclude`
不誤判（rc=0）；真實的 `test_exclude.zsh` 與 `compile_tar.zsh` 皆正確通過。

**第 6 次——驗證本檔的檢查片段時，而且手上就有工具卻沒用。** 上一節那段 `{1..$(…)}` 的
迴圈（見第 6 條）因 `wc -l` 的前導空白而一格都沒讀到，`csv2` 把四行錯誤印在 stderr 上。我
沒有用 `run_checked.zsh`，而是自己下了一行摘要：

```
inline loop rc=1 (no ✗ lines above = 通過)
```

`rc=1` 來自迴圈末尾那個為假的 `(( total > 5 ))`，與檢查結果無關；「沒有 ✗」是因為迴圈根本
沒跑，不是因為通過。**錯誤訊息就在同一畫面上，而我的摘要說它通過**，並據此提交。事後補測：
把壞掉的版本交給 `run_checked.zsh`，rc=1，立刻攔下。

**這一次的教訓不是「再多一種樣式」，而是工具存在不等於用了它。** 第 1、3 次是樣式太窄，
第 6 次是根本沒走那個關口——三個關口要在**下判斷之前**進入，不是回頭補。

The sixth happened while verifying this file's own check, with the tool sitting right there
unused. The loop read no cells and csv2 printed four errors to stderr; I wrote my own summary
line saying it passed and committed on it. Handing the broken version to `run_checked.zsh`
afterwards catches it immediately. The lesson is not another pattern -- it is that having the
tool is not the same as going through it.

仍然適用的手動規則（`run_checked.zsh` 涵蓋不到的地方）：
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

---

## 6. `{1..$(…)}` 遇到帶空白的輸出會靜默不展開 — **已發生 1 次**

**症狀**：一個 `for` 迴圈跑完、退出 0、**一行都沒印**，而它應該印五行。看起來像「沒有東西
符合條件」，實際上是「一格都沒讀」。

**實際狀況**：

```zsh
for r in {1..$(csv2 -r -i f.csv2 | wc -l)}; do …   # wc -l 印出 "       5"
```

zsh 的花括號展開在命令替換**之後**，所以它拿到的是 `{1..       5}`——那不是合法的範圍，於是
**原樣留下**，再依 IFS 切成 `{1..` 與 `5}` 兩個詞。迴圈確實跑了兩輪，`csv2 -get {1..:3` 與
`csv2 -get 5}:3` 都被拒絕，錯誤進 stderr，而迴圈本身的退出碼與該檔內容無關。

**沒有任何一步失敗**：`for` 沒錯、展開沒錯（`{1..   5}` 本來就該原樣留下）、`csv2` 正確地
大聲拒絕了畸形的位址。只有結果是錯的。

**現在怎麼防**：

```zsh
for r in {1..$(csv2 -r -i f.csv2 | wc -l | tr -d ' ')}; do …
```

- 命令替換餵給 `{1..N}` 時**一律 `tr -d ' '`**——`wc`、`grep -c` 在多數平台上都會補空白。
- **迴圈至少要印一行**（哪怕是計數），這樣「零行輸出」就是可見的失敗而不是安靜的成功。
- 這種形狀交給 `run_checked.zsh` 會被抓到（stderr 的 `expected r:c` 命中 `error|Error:`），
  但前提是真的走了那個關口——第 1 條第 6 次就是沒走。

zsh expands braces after command substitution, so `wc -l`'s padding makes `{1..   5}` an
invalid range: it is left literal and split into two words. Nothing fails; only the result is
wrong. Strip the whitespace, and make the loop print at least one line so zero output is a
visible failure.

---

## 7. 驗證的範圍不含會失敗的那個平台 — **已發生 1 次（2026-08-28 至 09-04，七天未被發現）**

**症狀**：三個平台的節點全綠、測試全過、審查通過，而第四個平台**連二進位都產不出來**——
且沒有任何東西會說出這件事。

**實際狀況**：`2c88ada`（2026-08-28）加入 `--exclude`，用 `fnmatch` 做樣式比對。`fnmatch`
屬於 POSIX，**Windows 沒有**。同一份程式碼還有第二個只在 Windows 成立的錯誤：`backend` 在
`#if os(Windows)` 之下宣告一次，數行後又無條件宣告一次，其他平台只看得到後者。

```
swift_tar.swift:2504  invalid redeclaration of 'backend'
swift_tar.swift:2834  cannot find 'fnmatch' in scope
```

**該功能一落地就讓 Windows 無法建置，而這件事過了七天才被人問出來。**

**當時的驗證並不草率**，這正是這一條的重點。行為逐項對齊 bsdtar 而非憑假設、涵蓋 GNU tar
並記載兩者分歧、依使用者要求加了平台偵測測試。**每一項都做在 macOS 上。** 驗證的範圍裡沒有
Windows，而範圍之外看起來與通過完全相同。

**與第 1 條的關係**：同構，機制不同。第 1 條是過濾器的樣式太窄，非預期的訊息消失；這一條是
**根本沒有在那個平台叫起編譯器**。前者可以靠加樣式修，後者不行——沒有任何樣式涵蓋得到一台
沒有被執行的機器。

**我對成因的假設也錯了，一併記下。** 被問到「Windows 為何可能建不起來」時，我指認
`import Synchronization` 無條件出現在 `swift_tar.swift:48` 與 `crypto.swift:28`，推論該工具鏈
可能沒有那個模組。**那個模組在 Windows 上有，不是問題。** 對的只有一件事：先問「現在還建得
起來嗎」，而不是先把 `-swift-version 6` 加上去。**順序對，理由錯**——而順序對就足以問出真相，
因為那個問題是交給有那台機器的人去回答的，不是我在這裡推理出來的。

**現在怎麼防**：

- 加入平台相依的 API 之前，先問它在**四個平台上是否都存在**（macOS / Linux / WSL / Windows）。
  `fnmatch`、`lutimes`、`utimensat`、`AT_SYMLINK_NOFOLLOW` 都屬於這一類。
- 「在我的平台上通過」要寫成「在我的平台上通過」，不要寫成「通過」。
- **問，不要推理。** 別的平台上有 session 在跑；一次詢問比任何靜態分析都準——本條的成因就是
  這樣問出來的，而我的靜態分析指錯了地方。
- `verifications/release_matrix.csv2` 的 win 與 linux 兩列一旦補齊，「這個平台上次成功建置
  是什麼時候」才第一次有答案。目前只有 mac 兩列，所以這個問題現在仍然答不出來。

Three platforms green, tests passing, review clean -- and the fourth could not produce a
binary at all, for seven days, with nothing to say so. `--exclude` used `fnmatch`, which is
POSIX and absent on Windows. The verification was not careless: behaviour was aligned to
bsdtar by measurement, GNU tar was covered, a platform-detection test was added. All of it
on macOS. Same structure as entry 1, different mechanism: no pattern covers a machine that
was never asked. My guess at the cause was wrong too -- `import Synchronization` is available
on Windows. Only the ordering was right: ask whether it still builds before adding the flag.
Asking beat analysing, because the question went to whoever had the machine.

---

## 8. zsh 的綁定參數：把變數命名為 `path` 等於覆寫 `PATH` — **已發生 1 次（2026-09-04）**

**症狀**：一支量測腳本跑完、退出 0、印出格式完整的結果表，**而表中每一格都是 0**。讀起來
像「這台機器沒有 page fault」，實際上是「每一個外部指令都不存在」。

**實際狀況**：語料迴圈裡有一行旗標賦值：

```zsh
path=$(( mib <= 4 ? 1 : 0 ))     # 想記的是「這個語料走不走緩衝路徑」
```

zsh 把小寫的 `path` 陣列與 `PATH` **綁定**，於是這一行把 `PATH` 換成了 `1`：

```
$ zsh -fc 'path=1; print -r -- "[$PATH]"; ls /'
[1]
zsh:1: command not found: ls
```

其後的 `grep`、`awk`、`head`、`rm`、`mkdir` 全部消失。**迴圈本身沒有失敗**——它照跑完所有
輪次，把每次取到的空值當成 0 累加，最後印出一張欄位齊全的表，退出碼 0。

**綁定的不只 `path`。** zsh 5.9 在 `zsh -f`（不載入任何設定）之下共有九對，用
`typeset -T` 可以列出：

```
PATH/path            CDPATH/cdpath        FPATH/fpath
MANPATH/manpath      MAILPATH/mailpath    MODULE_PATH/module_path
FIGNORE/fignore      PSVAR/psvar          ZSH_EVAL_CONTEXT/zsh_eval_context
```

`fignore` 與 `psvar` 尤其危險——它們不長得像環境變數，卻同樣會被綁定。

**與第 1、3 條的關係**：`command not found` 其實有印在 stderr 上，所以嚴格說「有工具報錯」。
但**腳本自己的摘要表蓋過了它**：一張欄位齊全、退出碼 0 的表，讀起來比幾行雜訊有份量。這與
第 3 條「計時函式回傳空值時要大聲失敗，不要讓它靜默變成 0」是同一件事，而我在寫那支腳本時
沒有實作那條規則。

**現在怎麼防**：

- 變數名避開那九個綁定名。不確定就 `typeset -T` 看一眼。
- **量測函式取到空值或 0，一律中止並印出原始輸出**，不要讓它變成表格裡的一格。
  `page_fault_attribution.zsh` 現在有這道防護，就是這次補上的：

  ```zsh
  if [[ -z ${faults:-} || ${faults:-0} -eq 0 || -z ${real:-} ]]; then
      print -ru2 -- "量測失敗 / measurement failed for '$n'"
      sed 's/^/    /' "$ERR" >&2
      exit 1
  fi
  ```
- 一張「每一格都是同一個值」的結果表，先當成量測壞了，不要當成發現。

zsh ties nine lowercase array parameters to their uppercase environment counterparts, `path`
to `PATH` among them, so using one as an ordinary variable replaces the environment variable.
Every external command afterwards is not found, while the loop runs to completion and prints
a full table of zeros with exit status 0. `command not found` did reach stderr -- but the
script's own summary table outweighed it, which is entry 3's lesson (a measurement returning
nothing must fail loudly rather than becoming a silent 0) unimplemented in the script that
needed it. `fignore` and `psvar` are the dangerous ones: they do not look like environment
variables. Run `typeset -T` when unsure.
