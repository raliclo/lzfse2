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

## 基準測試

`BenchMarkResult.csv` 包含 `llama.cpp` 與 `claw-code` 兩組資料集的基準測試摘要。`benchmark.log` 則是同一組測試的原始執行紀錄，包含計時輸出與內容一致性檢查。log 中使用的 `claw-code` 原始資料夾大小為 `938M`（壓縮前）。測試機器為 Mac mini，配備 Apple M4 10 核心 CPU、16 GB 記憶體與 128 GB 儲存空間。

| 資料集 | 格式 | 原始檔案大小 (MB) | 壓縮後大小 (MB) | 壓縮耗時 (秒) | 解壓耗時 (秒) | 相對 TGZ 壓縮比 | 相對 TGZ 壓縮時間比 | 相對 TGZ 解壓時間比 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| llama.cpp | TGZ | 1100 | 544 | 21.65 | 3.95 | 1.0000 | 1.00 | 1.00 |
| llama.cpp | LZFSE (Other3) | 1100 | 539 | 7.00 | 5.09 | 0.9908 | 0.32 | 1.29 |
| llama.cpp | LZFSE (BVX3) | 1100 | 531 | 6.85 | 4.12 | 0.9761 | 0.32 | 1.04 |
| llama.cpp | LZFSE (Apple) | 1100 | 539 | 10.80 | 4.52 | 0.9908 | 0.50 | 1.14 |
| llama.cpp | TLZ4 | 1100 | 568 | 4.19 | 4.33 | 1.0441 | 0.19 | 1.10 |
| llama.cpp | ZSTD | 1100 | 505 | 3.06 | 5.56 | 0.9283 | 0.14 | 1.41 |
| claw-code | TGZ | 1200 | 433 | 25.59 | 2.21 | 1.0000 | 1.00 | 1.00 |
| claw-code | LZFSE (Other3) | 1200 | 433 | 1.96 | 1.91 | 1.0000 | 0.08 | 0.86 |
| claw-code | LZFSE (BVX3) | 1200 | 428 | 1.91 | 1.91 | 0.9885 | 0.07 | 0.86 |
| claw-code | LZFSE (Apple) | 1200 | 436 | 8.06 | 2.26 | 1.0069 | 0.31 | 1.02 |
| claw-code | TLZ4 | 1200 | 523 | 2.07 | 1.61 | 1.2079 | 0.08 | 0.73 |
| claw-code | ZSTD | 1200 | 372 | 2.75 | 2.90 | 0.8591 | 0.11 | 1.31 |

這些數字僅作為範例。正式比較效能前，請以具代表性的資料與硬體重新測試。

## 授權

請參閱儲存庫授權資訊。`lzfse-cli.swift` 中的實作註解說明了源自 Apple LZFSE 參考格式定義的 BSD-3-Clause 脈絡。
