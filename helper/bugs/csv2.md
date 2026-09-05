# csv2 更新請求 / csv2 change request

對象版本 / Version under test: **csv2 0.1.0 (3ef6166)**
測試環境 / Environment: Windows 11, MINGW64_NT-10.0-26200, zsh 5.9.999.3-test
提出日期 / Filed: 2026-09-06

兩項請求，皆附可重現的指令與實測輸出。第 2 項比第 1 項要緊，因為它**不會失敗**——
它回報一個看起來合理的錯誤答案。

Two requests, each with a reproduction and measured output. The second matters more than
the first: it does not fail. It returns a plausible wrong answer.

---

## 1. `--headers 0` 的行為與其自身說明不符 / `--headers 0` does not behave as documented

### 說明怎麼寫的 / What the help text promises

`csv2 --help` 對該旗標的描述：

> `--headers 0|1|2` … 0 is the **line-oriented format — one field per line, bytes
> verbatim** — which until now could only be had by having no suffix, so stdin could not
> ask for it and neither could a prose `.md`.

「one field per line, bytes verbatim」讀起來是明確的承諾：在此模式下，**一行就是一欄**，
不再依逗號切分。

### 實際行為 / What happens

```sh
$ printf 'plain line\nline, with comma\n' > a.txt
$ od -c a.txt
0000000   p   l   a   i   n       l   i   n   e  \n   l   i   n   e   ,
0000020       w   i   t   h       c   o   m   m   a  \n

$ csv2 -r --headers 0 -i a.txt
csv2: record 2 (line 2) has 2 fields but the header has 1; csv2 will not pad or truncate to fit
csv2：record 2 (line 2) 有 2 欄，標頭有 1 欄；csv2 不會補空或截斷來湊合
$ echo $?
1
```

第 2 行仍被依逗號切成兩欄，與「one field per line」相反。

The line is still split on its comma, which is the opposite of "one field per line".

### 為什麼會撞到這個 / How we hit it

我們想確認 `csv2` 能否用來讀寫 **shell 腳本**（本專案有 64 個 `.zsh`）。逗號在 shell 裡
到處都是——`sed -n '2,16p'`、`tr -d ' ,'`、`${arr[1,3]}`、字串裡的標點——所以幾乎每個腳本
的第一行逗號就會中止讀取。

### 請求 / Request

**要嘛讓 `--headers 0` 真的逐位元組、不切欄；要嘛修正說明文字。** 兩者都可接受，但目前
這種「文件承諾 A、實作做 B」的狀態最糟：它會讓人依文件寫出一個看似正確的用法。

若選擇修正實作，這個模式會變得相當有用——它讓 `csv2` 能作為「會大聲失敗的 `sed -i`」，
對任何逐行文字檔做定址編輯，而那正是本專案禁用 `sed`/`awk`/`python` 改檔之後所缺的工具。

Either make `--headers 0` genuinely byte-verbatim with no field splitting, or correct the
help text. The current state — documentation promising one thing, implementation doing
another — is the worst of the three, because it leads people to write a usage that looks
right by the documentation.

---

## 2. CR 在讀取時被吃掉，因此 `csv2` 無法用來檢查行尾 / CR is consumed on read

這一項是**無聲的**。它不報錯，只是回答錯的東西。

### 重現 / Reproduction

```sh
$ printf 'alpha\r\nbravo\r\n' > b.txt

# 真相：這是一個逐行 CRLF 的檔案
$ od -c b.txt
0000000   a   l   p   h   a  \r  \n   b   r   a   v   o  \r  \n

$ tr -dc '\r' < b.txt | wc -c
2

# csv2 讀出來
$ csv2 -get 1:1 --headers 0 -i b.txt | od -c
0000000   a   l   p   h   a  \n
```

`\r` 不在回傳值裡。以 `csv2` 檢查一個 CRLF 檔案，會得到「乾淨的 LF」。

The `\r` is not in the returned value. Inspecting a CRLF file through `csv2` reports it as
clean LF.

### 為什麼這比第 1 項嚴重 / Why this is worse than the first

第 1 項會**失敗**（rc=1、有訊息），失敗是可以處理的。第 2 項會**成功**，並回傳一個
看起來完全正常的字串。

本專案的規約已經記載：在此平台上 `grep`、`sed`、`awk` 都看不到 CR——MSYS/Cygwin 建置以
文字模式讀檔，在正規表達式跑之前就把 CR 去掉了。實測 `awk '{print length($0)}'` 對一行
`alpha\r\n` 回報 **5** 而非 6。因此規約規定：**只有 `tr -dc '\r' | wc -c`、`od`、`cmp`、
`wc -c` 可信**。

這次的量測把 **`csv2` 也歸進了「看不到 CR」那一類**。這值得你們知道，因為 `csv2` 的定位
是「會大聲失敗的解析器」，使用者（包括我們）會傾向信任它多於信任 `grep`。在行尾這件事
上，那份信任目前是沒有根據的。

Entry 1 fails loudly, and a failure can be handled. Entry 2 succeeds and returns a
perfectly ordinary-looking string. This project already documents that `grep`/`sed`/`awk`
cannot see CR on this platform — MSYS/Cygwin builds read in text mode and strip CR before
the regex runs. This measurement puts `csv2` in the same category. That is worth knowing
precisely because `csv2` is positioned as the parser that fails loudly, so users trust it
more than they trust `grep` — and on line endings that trust is currently unearned.

### 請求 / Request

擇一即可，不必全做：

1. **保留 CR 作為欄位值的一部分**（`--headers 0` 下尤其應該，既然它自稱 bytes verbatim）。
2. 若基於相容性不能保留，**在 `--help` 與 README 明講「CR 會被去除，本工具不可用於檢查
   行尾」**。一句話就能防止一次假陰性。
3. 或提供一個 `--raw` / `--keep-cr` 旗標，讓需要的人明確要求。

我們的偏好是 (1)＋(2)：預設保留，並在文件裡說明。最低限度是 (2)——因為目前**沒有任何
跡象**告訴使用者這件事正在發生。

Any one of these suffices. Our preference is (1) plus (2). The minimum acceptable is (2),
because at present nothing signals to the user that this is happening.

---

## 我們目前的因應 / What we do today

在此兩項處理之前，本專案的分工是：

| 對象 | 工具 | 理由 |
|---|---|---|
| 表格資料（`.csv2`、markdown 表） | `csv2` | 欄位含引號內逗號時，`awk -F,` 會靜默切錯並讓右側每欄左移一格 |
| 原始碼與腳本 | `Edit` 工具 | 以**內容**定址；比對不到就失敗。行號定址在多處插入後會位移，而位移不會報錯 |
| 行尾／CR 檢測 | `tr -dc '\r' \| wc -c`、`od`、`cmp` | 唯一真正看得到 CR 的工具 |

`csv2` 在第一列是無可取代的，這份請求不改變那件事。這裡要問的只是：第二、三列能不能
也交給它。

`csv2` is irreplaceable in the first row and this request does not change that. The
question is only whether rows two and three could be handed to it as well.
