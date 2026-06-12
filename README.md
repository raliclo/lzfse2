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

`BenchMarkResult.csv` contains benchmark summaries for two datasets, `llama.cpp` and `claw-code`. `benchmark.log` is the raw run log for the same test set, including timing output and content-integrity checks. The raw `claw-code` source tree used in the log was `938M` before compression. The test machine was a Mac mini with an Apple M4 10-core CPU, 16 GB memory, and 256 GB storage.

| Dataset | Format | Original size (MB) | Compressed size (MB) | Compress time (s) | Decompress time (s) | Compression ratio vs TGZ | Compress time ratio vs TGZ | Decompress time ratio vs TGZ |
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

Treat these numbers as sample results only. Re-run benchmarks on representative data and hardware before making performance claims.

## License

See the repository license information. The implementation notes in `lzfse-cli.swift` describe the BSD-3-Clause lineage from Apple's LZFSE reference format definitions.
