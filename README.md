# lzfse2

English | [繁體中文](README.zh-TW.md)

`lzfse2` is a Swift command-line compressor/decompressor for LZFSE streams. It includes a bit-compatible, multi-core encoder/decoder plus an optional private `bvx3` format for higher compression ratios.

## Features

- `other3` is the default engine. It writes standard LZFSE streams that Apple Compression and this tool can decode.
- `apple` uses Apple's `COMPRESSION_LZFSE` implementation when the Compression framework is available.
- `bvx3` uses private extension blocks with a larger window and larger alphabets. It can improve ratio, but only this tool can decode it.
- Decoding accepts all supported block types, including Apple-produced LZFSE streams.
- Supports files, stdin/stdout streaming, and built-in round-trip/compatibility tests.

## Build

Build directly with Swift:

```sh
swiftc -O lzfse-cli.swift -o lzfse
```

The `-O` flag enables optimizations including `@inline(__always)` directives that improve performance on hot paths (FSE encoding, byte serialization, and decoding).

Or run the helper script:

```sh
./compile.sh
```

`compile.sh` also copies the binary to `/opt/homebrew/bin`, so that step may require local write permission.

## Usage

```sh
./lzfse -h
```

```text
Usage: lzfse -encode|-decode [-algo apple|other3|bvx3] [-si|-i input] [-so|-o output] [-test] [-h]
```

Compress a file with the default `other3` engine:

```sh
./lzfse -encode -i input_file -o output_file.lzfse
```

Compress with a specific engine:

```sh
./lzfse -encode -algo apple -i input_file -o output_file.lzfse.apple
./lzfse -encode -algo bvx3 -i input_file -o output_file.lzfse.bvx3
```

Decompress a file:

```sh
./lzfse -decode -i input_file.lzfse -o output_file
```

Stream through stdin/stdout:

```sh
cat input_file | ./lzfse -encode -si -so > output_file.lzfse
./lzfse -decode -i input_file.lzfse -so > output_file
```

Run built-in tests:

```sh
./lzfse -test
```

## Engines

| Engine | Output compatibility | Notes |
| --- | --- | --- |
| `other3` | Standard LZFSE | Default. Multi-core, lazy matching, Apple-decodable output. |
| `apple` | Standard LZFSE | Uses Apple's Compression framework. |
| `bvx3` | Private to this tool | Larger window and alphabets for better ratio; not Apple-decodable. |

## zsh Helpers

The repository includes a `zshrc` excerpt with helpers for packaging directories through `tar` and this `lzfse` binary.

```zsh
# Decompress common archive types.
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

# Compress a file or directory into a tar stream, then LZFSE-encode it.
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

    echo "--- Compression info ---"
    du -sh "$1"
    du -sh "$1.$extension"
}
```

Reload your shell after editing:

```sh
source ~/.zshrc
```

## Benchmark

`BenchMarkResult.csv` contains benchmark results for two datasets: `llama.cpp` (1200M) and `claw-code` (1200M source). The test machine was a Mac mini with an Apple M4 10-core CPU, 16 GB memory, and 256 GB storage.

### Performance Metrics

| Dataset | Format | Original (M) | Compressed (M) | Compress (s) | Decompress (s) | Compress MB/s | Decompress MB/s | Ratio vs TGZ | Time ratio (compress) | Time ratio (decompress) |
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

### Test Results

The `lzfse-test.txt` shows round-trip and compatibility tests across various data types:
- **Highly repetitive data**: Compresses to ~1–2% (222–235 bytes from 19.2 KB)
- **Low entropy**: Compresses to 0.3–0.4%
- **Random (incompressible)**: ~100% size (expands slightly)
- **Structured data**: 8.5–16.5% compression (better with Lazy2)
- **Alternating patterns**: 0.7–0.8% compression
- **Text (large samples)**: 25.9–26.7% compression (improved with Lazy2)

All formats maintain compatibility: `other3` and `bvx3` outputs are decodable by the tool, and Apple's Compression framework can decode `other3` streams.

Treat these numbers as sample results only. Re-run benchmarks on representative data and hardware before making performance claims.

## License

See the repository license information. The implementation notes in `lzfse-cli.swift` describe the BSD-3-Clause lineage from Apple's LZFSE reference format definitions.
