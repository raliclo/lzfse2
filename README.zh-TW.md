# lzfse2

[English](README.md) | 繁體中文

`lzfse2` 是以 Swift 實作的 LZFSE 命令列壓縮／解壓工具。它包含位元相容、多核心的編碼器與解碼器，也提供可選的私有 `bvx3` 格式以換取更高壓縮率。

## 功能

- `other3` 是預設引擎，輸出標準 LZFSE 串流，可由 Apple Compression 與本工具解碼。
- `apple` 在可用時使用 Apple `COMPRESSION_LZFSE` 實作。
- `bvx3` 使用私有擴充區塊，具備較大的視窗與字母表。壓縮率可能更好，但只有本工具能解碼。
- 解碼器接受所有支援的區塊型別，包含 Apple 產生的 LZFSE 串流。
- 支援檔案、stdin/stdout 串流，以及內建往返與相容性測試。

## 建置

直接使用 Swift 編譯：

```sh
swiftc -O lzfse-cli.swift -o lzfse
```

`-O` 旗標啟用優化，包含 `@inline(__always)` 指令，改善熱點路徑效能（FSE 編碼、位元組序列化、解碼）。詳見 [OPTIMIZATION.md](OPTIMIZATION.md)。

或執行輔助腳本：

```sh
./compile.sh
```

`compile.sh` 也會將二進位檔複製到 `/opt/homebrew/bin`，因此該步驟可能需要本機寫入權限。

## 用法

```sh
./lzfse -h
```

```text
Usage: lzfse -encode|-decode [-algo apple|other3|bvx3] [-si|-i input] [-so|-o output] [-test] [-h]
```

使用預設 `other3` 引擎壓縮檔案：

```sh
./lzfse -encode -i input_file -o output_file.lzfse
```

指定引擎壓縮：

```sh
./lzfse -encode -algo apple -i input_file -o output_file.lzfse.apple
./lzfse -encode -algo bvx3 -i input_file -o output_file.lzfse.bvx3
```

解壓檔案：

```sh
./lzfse -decode -i input_file.lzfse -o output_file
```

透過 stdin/stdout 串流處理：

```sh
cat input_file | ./lzfse -encode -si -so > output_file.lzfse
./lzfse -decode -i input_file.lzfse -so > output_file
```

執行內建測試：

```sh
./lzfse -test
```

## 引擎

| 引擎 | 輸出相容性 | 說明 |
| --- | --- | --- |
| `other3` | 標準 LZFSE | 預設。多核心、lazy matching，輸出可由 Apple 解碼。 |
| `apple` | 標準 LZFSE | 使用 Apple Compression framework。 |
| `bvx3` | 本工具私有格式 | 較大的視窗與字母表可提升壓縮率；Apple 無法解碼。 |


## zsh 輔助函式

此儲存庫包含一段 `zshrc` 範例，可將目錄先打包為 `tar` 串流，再交給本工具壓縮。

```zsh
# 解壓常見封存格式。
extract () {
    if [ -f "$1" ] ; then
        case "$1" in
            *.lzfse.bvx3)      echo "lzfse -decode -i $1 -so -algo bvx3   | tar -xf - " ; lzfse -decode -i $1 -so -algo bvx3   | tar -xf -  ;;
            *.lzfse.other3)    echo "lzfse -decode -i $1 -so -algo other3 | tar -xf - " ; lzfse -decode -i $1 -so -algo other3 | tar -xf -  ;;
            *.lzfse.apple)     echo "lzfse -decode -i $1 -so -algo apple  | tar -xf - " ; lzfse -decode -i $1 -so -algo apple  | tar -xf -  ;;
            *.tar.lz4)         lz4 -T0 -d -q -c "$1" | tar -xf - ;;
            *.zst)             zstd -d -c "$1" | tar -xf - ;;
            *.tar.xz)          tar xf "$1" ;;
            *.tar.bz2)         tar xjf "$1" ;;
            *.tar.gz|*.tgz)    tar xzf "$1" ;;
            *.bz2)             bunzip2 "$1" ;;
            *.rar)             unrar e "$1" ;;
            *.gz)              gunzip "$1" ;;
            *.tar)             tar xf "$1" ;;
            *.tbz2)            tar xjf "$1" ;;
            *.zip)             unzip "$1" ;;
            *.Z)               uncompress "$1" ;;
            *.xz)              xz -d "$1" ;;
            *.7z)              7z x "$1" ;;
            *.lz4)             unlz4 "$1" ;;
            *.lzma)            tar --lzma -xvf "$1" ;;
            *.lz4a)            unlz4a "$1" ;;
            *)                 echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# 將檔案或目錄打成 tar 串流後，以 LZFSE 壓縮。
lzfseX() {
    if [[ -z "$1" ]]; then
        echo "Usage: lzfseX <file-or-directory> [apple|other3|bvx3]"
        return 1
    fi

    local algo="${2:-other3}"
    local extension="lzfse.other3"
    [[ "$algo" == "apple" ]] && extension="lzfse.apple"
    [[ "$algo" == "bvx3" ]] && extension="lzfse.bvx3"
    [[ "$algo" == "other3" ]] && extension="lzfse.other3"

    echo tar -cf - "$1" "|" lzfse -encode -si -o "$1.$extension" -algo "$algo"
    tar -cf - "$1" | lzfse -encode -si -o "$1.$extension" -algo "$algo"

    echo "--- 壓縮資訊 ---"
    du -sh "$1"
    du -sh "$1.$extension"
}
```

編輯後重新載入 shell：

```sh
source ~/.zshrc
```
## powermetrics

修改步驟
開啟 visudo：
```
sudo visudo
```

新增一行如下：
```
raliclo ALL=(ALL) NOPASSWD: /usr/bin/powermetrics, /usr/bin/true
```

儲存並離開（同樣按下 Ctrl + O -> Enter -> Ctrl + X）。

## 基準測試

`BenchMarkResult.csv` 包含兩組資料集的基準測試結果：`llama.cpp`（1200M）與 `claw-code`（1200M 來源）。測試機器為 Mac mini，配備 Apple M4 10 核心 CPU、16 GB 記憶體與 256 GB 儲存空間。

### 效能指標

| 資料集 | 格式 | 原始 (M) | 壓縮後 (M) | 壓縮時間 (秒) | 解壓時間 (秒) | 壓縮 MB/s | 解壓 MB/s | 相對 TGZ 壓縮比 | 壓縮時間比 | 解壓時間比 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| llama.cpp | TGZ | 1200 | 593 | 23.84 | 3.96 | 50.34 | 303.03 | 1.0000 | 1.00 | 1.00 |
| llama.cpp | LZFSE (Other3) | 1200 | 592 | 6.76 | 4.26 | 177.51 | 281.69 | 0.9983 | 0.28 | 1.08 |
| llama.cpp | LZFSE (Lazy2) | 1200 | 572 | 6.81 | 4.87 | 176.21 | 246.41 | 0.9646 | 0.29 | 1.23 |
| llama.cpp | LZFSE (BVX3) | 1200 | 572 | 6.77 | 5.99 | 177.25 | 200.33 | 0.9646 | 0.28 | 1.51 |
| llama.cpp | LZFSE (Apple) | 1200 | 585 | 11.16 | 5.50 | 107.53 | 218.18 | 0.9865 | 0.47 | 1.39 |
| llama.cpp | TLZ4 | 1200 | 622 | 3.90 | 5.09 | 307.69 | 235.76 | 1.0489 | 0.16 | 1.29 |
| llama.cpp | ZSTD | 1200 | 537 | 2.79 | 6.16 | 430.11 | 194.81 | 0.9056 | 0.12 | 1.56 |
| claw-code | TGZ | 1200 | 433 | 25.69 | 2.21 | 46.71 | 542.99 | 1.0000 | 1.00 | 1.00 |
| claw-code | LZFSE (Other3) | 1200 | 428 | 1.98 | 2.34 | 606.06 | 512.82 | 0.9885 | 0.08 | 1.06 |
| claw-code | LZFSE (Lazy2) | 1200 | 419 | 2.00 | 3.28 | 600.00 | 365.85 | 0.9677 | 0.08 | 1.48 |
| claw-code | LZFSE (BVX3) | 1200 | 423 | 1.99 | 3.59 | 603.02 | 334.26 | 0.9769 | 0.08 | 1.62 |
| claw-code | LZFSE (Apple) | 1200 | 435 | 8.13 | 5.21 | 147.60 | 230.33 | 1.0046 | 0.32 | 2.36 |
| claw-code | TLZ4 | 1200 | 516 | 2.03 | 4.05 | 591.13 | 296.30 | 1.1917 | 0.08 | 1.83 |
| claw-code | ZSTD | 1200 | 368 | 2.73 | 5.71 | 439.56 | 210.16 | 0.8499 | 0.11 | 2.58 |

### 測試結果

`lzfse-test.txt` 展示了各種資料型態的往返與相容性測試：
- **高度重複資料**：壓縮至 ~1–2%（從 19.2 KB 縮至 222–235 bytes）
- **低熵資料**：壓縮至 0.3–0.4%
- **隨機（不可壓）**：~100% 大小（略微膨脹）
- **結構化資料**：8.5–16.5% 壓縮比（Lazy2 更佳）
- **交錯距離模式**：0.7–0.8% 壓縮比
- **文字大樣本**：25.9–26.7% 壓縮比（Lazy2 改進）

所有格式皆保持相容性：`other3` 與 `bvx3` 的輸出可由本工具解碼，Apple Compression framework 可解碼 `other3` 串流。

這些數字僅作為範例。正式比較效能前，請以具代表性的資料與硬體重新測試。

## 授權

請參閱儲存庫授權資訊。`lzfse-cli.swift` 中的實作註解說明了源自 Apple LZFSE 參考格式定義的 BSD-3-Clause 脈絡。
