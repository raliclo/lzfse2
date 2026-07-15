# tar_comparison

Controlled A/B comparing macOS system `tar` (`/usr/bin/tar`, single-threaded
gzip) against `swift_tar` (parallel chunk gzip + the R46 memory fixes) across
the four dimensions of concern: **encode time, decode time, peak RSS, CPU
energy**.

系統 `tar`（`/usr/bin/tar`，單執行緒 gzip）與 `swift_tar`（並行 chunk gzip +
R46 記憶體修正）的受控 A/B，涵蓋四個關注維度：**encode 時間、decode 時間、
peak RSS、CPU 能耗**。

## Files / 檔案

| File | Purpose |
| --- | --- |
| `tar_ab.sh` | Pass 1 — encode/decode wall time + peak RSS (`/usr/bin/time -l`, no sudo). |
| `tar_energy.sh` | Pass 2 — CPU energy per phase via `powermetrics` (needs sudo). |
| `results.txt` | Captured raw output + summary of the 2026-07-15 run. |

## Usage / 用法

```sh
# Pass 1: time + RSS (no sudo) / 時間 + RSS（免 sudo）
tar_comparison/tar_ab.sh            # defaults to the claw-code corpus

# Pass 2: energy (needs sudo) / 能耗（需 sudo）
sudo -v && tar_comparison/tar_energy.sh
```

Both scripts `cd` to the repo root and default to the `claw-code` corpus; pass a
different path as `$1`. `SWIFT_TAR_BIN` overrides the swift_tar binary
(`/opt/homebrew/bin/swift_tar` by default). Energy is
`energy_J = duration_s × avg_CPU_mW / 1000`.

## Results (claw-code 1.3GB, 2026-07-15, single run)

| Dimension | system `tar` | `swift_tar` | swift_tar vs tar |
| --- | ---: | ---: | ---: |
| Encode time | 29.5s | **4.42s** | **6.7× faster** |
| Decode time | 3.35s | **2.94s** | 1.14× faster |
| Encode RSS | 4.2 MB | 209.8 MB | 50× more |
| Decode RSS | 4.2 MB | 49.8 MB | 11.9× more |
| Encode energy | 172.19 J | **68.20 J** | **−60%** |
| Decode energy | 17.71 J | 15.63 J | −12% |

### Takeaways / 重點

- **Encode**: swift_tar trades RSS for parallelism and wins decisively. Its
  instantaneous CPU power is higher (15480 vs 5831 mW, multi-core vs
  single-core), but it finishes in 1/6.7 the time, so total energy is **−60%**
  ("race to idle"). / swift_tar 以 RSS 換並行大勝：瞬時功率更高但耗時只有
  1/6.7，總能耗因 race-to-idle 反而 −60%。
- **Decode**: roughly comparable (gzip inflate is largely serial); swift_tar is
  slightly faster and slightly cheaper, at ~12× the RSS. / decode 相近，
  swift_tar 略快略省，代價是 RSS 高一個量級。
- **Memory cost**: swift_tar encode RSS ≈ in-flight chunks × ~8MiB. Lower `-n`
  trades encode speed for memory (`n=4` ≈ 90MB; see
  `../swift_tar/verifications/README.md`). / swift_tar encode RSS ≈ 在途 chunk
  數 × ~8MiB；低記憶體環境可用 `-n` 調降（`n=4` ≈ 90MB）。

> Single-run, ad-hoc measurement (not the official benchmark pipeline). Numbers
> vary run-to-run; re-run both passes to refresh. / 單次量測、非官方 pipeline，
> 數值會有 run-to-run 浮動，重跑兩個 pass 即可更新。
