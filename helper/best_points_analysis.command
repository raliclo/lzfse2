#!/bin/zsh
set -euo pipefail

# Generate best-point analysis from BenchMarkResult.csv2.
# 從 BenchMarkResult.csv2 產生最佳點分析。

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR/.."
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

OUT_DIR="${BEST_POINTS_DIR:-best_points}"
CSV_IN="${BENCHMARK_RESULT_CSV:-BenchMarkResult.csv2}"
MD_OUT="$OUT_DIR/best_points.md"
CSV_OUT="$OUT_DIR/best_points.csv2"

mkdir -p "$OUT_DIR"

python3 - <<'PY' "$CSV_IN" "$MD_OUT" "$CSV_OUT"
import csv
import sys
from collections import defaultdict
from pathlib import Path

csv_in = Path(sys.argv[1])
md_out = Path(sys.argv[2])
csv_out = Path(sys.argv[3])

FORMATS = [
    "TGZ",
    "LZFSE (Other3)",
    "LZFSE (Optimal3)",
    "LZFSE (BVX3)",
    "LZFSE (Lazy2)",
    "LZFSE (Optimal)",
    "LZFSE (Apple)",
    "TLZ4",
    "ZSTD",
]

DISPLAY_NAME = {
    "TGZ": "TGZ",
    "LZFSE (Other3)": "Other3",
    "LZFSE (Optimal3)": "Optimal3",
    "LZFSE (BVX3)": "BVX3",
    "LZFSE (Lazy2)": "Lazy2",
    "LZFSE (Optimal)": "Optimal",
    "LZFSE (Apple)": "Apple",
    "TLZ4": "TLZ4",
    "ZSTD": "ZSTD",
}

LOG_ONLY_FORMATS = {"TGZ", "LZFSE (Apple)", "TLZ4", "ZSTD"}

FIELDS = [
    "資料夾",
    "格式",
    "最佳壓縮比",
    "最佳壓縮比來源",
    "最佳壓縮 MB/s",
    "最佳壓縮來源",
    "最差壓縮 MB/s",
    "最差壓縮來源",
    "最佳解壓 MB/s",
    "最佳解壓來源",
    "最差解壓 MB/s",
    "最差解壓來源",
    "最低 Encode RSS",
    "最低 Encode RSS 來源",
    "最高 Encode RSS",
    "最高 Encode RSS 來源",
    "最低 Decode RSS",
    "最低 Decode RSS 來源",
    "最高 Decode RSS",
    "最高 Decode RSS 來源",
    "最低 Encode CPU Power(mW)",
    "最低 Encode CPU Power 來源",
    "最高 Encode CPU Power(mW)",
    "最高 Encode CPU Power 來源",
    "最低 Decode CPU Power(mW)",
    "最低 Decode CPU Power 來源",
    "最高 Decode CPU Power(mW)",
    "最高 Decode CPU Power 來源",
    "最低 Encode CPU Energy(J)",
    "最低 Encode CPU Energy 來源",
    "最高 Encode CPU Energy(J)",
    "最高 Encode CPU Energy 來源",
    "最低 Decode CPU Energy(J)",
    "最低 Decode CPU Energy 來源",
    "最高 Decode CPU Energy(J)",
    "最高 Decode CPU Energy 來源",
    "最低 Encode CPU Energy Ratio (TGZ=1)",
    "最高 Encode CPU Energy Ratio (TGZ=1)",
    "最低 Decode CPU Energy Ratio (TGZ=1)",
    "最高 Decode CPU Energy Ratio (TGZ=1)",
]

EN_FIELDS = [
    "dataset",
    "format",
    "best_ratio",
    "best_ratio_source",
    "best_encode_mb_s",
    "best_encode_source",
    "worst_encode_mb_s",
    "worst_encode_source",
    "best_decode_mb_s",
    "best_decode_source",
    "worst_decode_mb_s",
    "worst_decode_source",
    "min_encode_rss_mb",
    "min_encode_rss_source",
    "max_encode_rss_mb",
    "max_encode_rss_source",
    "min_decode_rss_mb",
    "min_decode_rss_source",
    "max_decode_rss_mb",
    "max_decode_rss_source",
    "min_encode_cpu_power_mw",
    "min_encode_cpu_power_source",
    "max_encode_cpu_power_mw",
    "max_encode_cpu_power_source",
    "min_decode_cpu_power_mw",
    "min_decode_cpu_power_source",
    "max_decode_cpu_power_mw",
    "max_decode_cpu_power_source",
    "min_encode_cpu_energy_j",
    "min_encode_cpu_energy_source",
    "max_encode_cpu_energy_j",
    "max_encode_cpu_energy_source",
    "min_decode_cpu_energy_j",
    "min_decode_cpu_energy_source",
    "max_decode_cpu_energy_j",
    "max_decode_cpu_energy_source",
    "min_encode_cpu_energy_ratio_tgz",
    "max_encode_cpu_energy_ratio_tgz",
    "min_decode_cpu_energy_ratio_tgz",
    "max_decode_cpu_energy_ratio_tgz",
]


def fnum(row: dict[str, str], key: str) -> float:
    value = row.get(key, "")
    if value == "":
        raise ValueError(f"missing numeric value for {key}: {row}")
    return float(value)


def source_label(row: dict[str, str]) -> str:
    prefix = "log n" if row["格式"] in LOG_ONLY_FORMATS else "n"
    return f"{prefix}{row['N']}"


def metric_cell(row: dict[str, str], metric: str, suffix: str) -> str:
    return f"{row[metric]} {suffix} (`{source_label(row)}`)"


with csv_in.open(encoding="utf-8-sig", newline="") as handle:
    raw_rows = list(csv.reader(handle))
if len(raw_rows) >= 2 and raw_rows[0] and raw_rows[0][0].lstrip("\ufeff") == "dataset" and raw_rows[1] and raw_rows[1][0] == "資料夾":
    rows = [dict(zip(raw_rows[1], row)) for row in raw_rows[2:] if row]
else:
    rows = list(csv.DictReader(csv_in.open(encoding="utf-8-sig", newline="")))
if not rows:
    raise SystemExit(f"no rows in {csv_in}")

by_dataset_format: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
for row in rows:
    by_dataset_format[(row["資料夾"], row["格式"])].append(row)

datasets = sorted({row["資料夾"] for row in rows}, key=lambda x: {"claw-code": 0, "llama.cpp": 1}.get(x, 99))
records: list[dict[str, str]] = []

for dataset in datasets:
    for fmt in FORMATS:
        group = by_dataset_format.get((dataset, fmt), [])
        if not group:
            continue

        best_ratio = min(group, key=lambda row: fnum(row, "壓縮比"))
        best_encode = max(group, key=lambda row: fnum(row, "壓縮 MB/s"))
        worst_encode = min(group, key=lambda row: fnum(row, "壓縮 MB/s"))
        best_decode = max(group, key=lambda row: fnum(row, "解壓 MB/s"))
        worst_decode = min(group, key=lambda row: fnum(row, "解壓 MB/s"))
        encode_rss_rows = [row for row in group if row.get("Encode RSS(MB)", "")]
        decode_rss_rows = [row for row in group if row.get("Decode RSS(MB)", "")]
        min_encode_rss = min(encode_rss_rows, key=lambda row: fnum(row, "Encode RSS(MB)"))
        max_encode_rss = max(encode_rss_rows, key=lambda row: fnum(row, "Encode RSS(MB)"))
        min_decode_rss = min(decode_rss_rows, key=lambda row: fnum(row, "Decode RSS(MB)"))
        max_decode_rss = max(decode_rss_rows, key=lambda row: fnum(row, "Decode RSS(MB)"))
        min_encode_power = min(group, key=lambda row: fnum(row, "Encode CPU Power(mW)"))
        max_encode_power = max(group, key=lambda row: fnum(row, "Encode CPU Power(mW)"))
        min_decode_power = min(group, key=lambda row: fnum(row, "Decode CPU Power(mW)"))
        max_decode_power = max(group, key=lambda row: fnum(row, "Decode CPU Power(mW)"))
        min_encode_energy = min(group, key=lambda row: fnum(row, "Encode CPU Energy(J)"))
        max_encode_energy = max(group, key=lambda row: fnum(row, "Encode CPU Energy(J)"))
        min_decode_energy = min(group, key=lambda row: fnum(row, "Decode CPU Energy(J)"))
        max_decode_energy = max(group, key=lambda row: fnum(row, "Decode CPU Energy(J)"))
        min_encode_energy_ratio = min(group, key=lambda row: fnum(row, "Encode CPU Energy Ratio (TGZ=1)"))
        max_encode_energy_ratio = max(group, key=lambda row: fnum(row, "Encode CPU Energy Ratio (TGZ=1)"))
        min_decode_energy_ratio = min(group, key=lambda row: fnum(row, "Decode CPU Energy Ratio (TGZ=1)"))
        max_decode_energy_ratio = max(group, key=lambda row: fnum(row, "Decode CPU Energy Ratio (TGZ=1)"))

        records.append({
            "資料夾": dataset,
            "格式": DISPLAY_NAME[fmt],
            "最佳壓縮比": best_ratio["壓縮比"],
            "最佳壓縮比來源": source_label(best_ratio),
            "最佳壓縮 MB/s": best_encode["壓縮 MB/s"],
            "最佳壓縮來源": source_label(best_encode),
            "最差壓縮 MB/s": worst_encode["壓縮 MB/s"],
            "最差壓縮來源": source_label(worst_encode),
            "最佳解壓 MB/s": best_decode["解壓 MB/s"],
            "最佳解壓來源": source_label(best_decode),
            "最差解壓 MB/s": worst_decode["解壓 MB/s"],
            "最差解壓來源": source_label(worst_decode),
            "最低 Encode RSS": min_encode_rss["Encode RSS(MB)"],
            "最低 Encode RSS 來源": source_label(min_encode_rss),
            "最高 Encode RSS": max_encode_rss["Encode RSS(MB)"],
            "最高 Encode RSS 來源": source_label(max_encode_rss),
            "最低 Decode RSS": min_decode_rss["Decode RSS(MB)"],
            "最低 Decode RSS 來源": source_label(min_decode_rss),
            "最高 Decode RSS": max_decode_rss["Decode RSS(MB)"],
            "最高 Decode RSS 來源": source_label(max_decode_rss),
            "最低 Encode CPU Power(mW)": min_encode_power["Encode CPU Power(mW)"],
            "最低 Encode CPU Power 來源": source_label(min_encode_power),
            "最高 Encode CPU Power(mW)": max_encode_power["Encode CPU Power(mW)"],
            "最高 Encode CPU Power 來源": source_label(max_encode_power),
            "最低 Decode CPU Power(mW)": min_decode_power["Decode CPU Power(mW)"],
            "最低 Decode CPU Power 來源": source_label(min_decode_power),
            "最高 Decode CPU Power(mW)": max_decode_power["Decode CPU Power(mW)"],
            "最高 Decode CPU Power 來源": source_label(max_decode_power),
            "最低 Encode CPU Energy(J)": min_encode_energy["Encode CPU Energy(J)"],
            "最低 Encode CPU Energy 來源": source_label(min_encode_energy),
            "最高 Encode CPU Energy(J)": max_encode_energy["Encode CPU Energy(J)"],
            "最高 Encode CPU Energy 來源": source_label(max_encode_energy),
            "最低 Decode CPU Energy(J)": min_decode_energy["Decode CPU Energy(J)"],
            "最低 Decode CPU Energy 來源": source_label(min_decode_energy),
            "最高 Decode CPU Energy(J)": max_decode_energy["Decode CPU Energy(J)"],
            "最高 Decode CPU Energy 來源": source_label(max_decode_energy),
            "最低 Encode CPU Energy Ratio (TGZ=1)": f'{min_encode_energy_ratio["Encode CPU Energy Ratio (TGZ=1)"]} ({source_label(min_encode_energy_ratio)})',
            "最高 Encode CPU Energy Ratio (TGZ=1)": f'{max_encode_energy_ratio["Encode CPU Energy Ratio (TGZ=1)"]} ({source_label(max_encode_energy_ratio)})',
            "最低 Decode CPU Energy Ratio (TGZ=1)": f'{min_decode_energy_ratio["Decode CPU Energy Ratio (TGZ=1)"]} ({source_label(min_decode_energy_ratio)})',
            "最高 Decode CPU Energy Ratio (TGZ=1)": f'{max_decode_energy_ratio["Decode CPU Energy Ratio (TGZ=1)"]} ({source_label(max_decode_energy_ratio)})',
        })

with csv_out.open("w", encoding="utf-8-sig", newline="") as handle:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(EN_FIELDS)
    writer.writerow(FIELDS)
    for record in records:
        writer.writerow([record.get(field, "") for field in FIELDS])

lines: list[str] = []
lines.append("# Best Points Analysis / 最佳點分析")
lines.append("")
lines.append("Source: `BenchMarkResult.csv2`")
lines.append("")
lines.append("> TGZ / Apple / TLZ4 / ZSTD use `log nX` only as the source log batch. `-n` does not affect those algorithms. / TGZ、Apple、TLZ4、ZSTD 的 `log nX` 只代表來源 log 批次，`-n` 不影響這些演算法。")
lines.append("")

for dataset in datasets:
    lines.append(f"## {dataset}")
    lines.append("")
    lines.append("| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最差壓縮 MB/s | 最佳解壓 MB/s | 最差解壓 MB/s | 最低 Encode RSS | 最高 Encode RSS | 最低 Decode RSS | 最高 Decode RSS | 最低 Encode CPU Power | 最高 Encode CPU Power | 最低 Decode CPU Power | 最高 Decode CPU Power | 最低 Encode CPU Energy | 最高 Encode CPU Energy | 最低 Decode CPU Energy | 最高 Decode CPU Energy | 最低 Encode Energy Ratio | 最高 Encode Energy Ratio | 最低 Decode Energy Ratio | 最高 Decode Energy Ratio |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for record in [r for r in records if r["資料夾"] == dataset]:
        lines.append(
            "| {fmt} | {best_ratio} (`{best_ratio_src}`) | "
            "{best_enc} (`{best_enc_src}`) | {worst_enc} (`{worst_enc_src}`) | "
            "{best_dec} (`{best_dec_src}`) | {worst_dec} (`{worst_dec_src}`) | "
            "{min_enc} MB (`{min_enc_src}`) | {max_enc} MB (`{max_enc_src}`) | "
            "{min_dec} MB (`{min_dec_src}`) | {max_dec} MB (`{max_dec_src}`) | "
            "{min_enc_power} mW (`{min_enc_power_src}`) | {max_enc_power} mW (`{max_enc_power_src}`) | "
            "{min_dec_power} mW (`{min_dec_power_src}`) | {max_dec_power} mW (`{max_dec_power_src}`) | "
            "{min_enc_energy} J (`{min_enc_energy_src}`) | {max_enc_energy} J (`{max_enc_energy_src}`) | "
            "{min_dec_energy} J (`{min_dec_energy_src}`) | {max_dec_energy} J (`{max_dec_energy_src}`) | "
            "{min_enc_energy_ratio} | {max_enc_energy_ratio} | "
            "{min_dec_energy_ratio} | {max_dec_energy_ratio} |".format(
                fmt=record["格式"],
                best_ratio=record["最佳壓縮比"],
                best_ratio_src=record["最佳壓縮比來源"],
                best_enc=record["最佳壓縮 MB/s"],
                best_enc_src=record["最佳壓縮來源"],
                worst_enc=record["最差壓縮 MB/s"],
                worst_enc_src=record["最差壓縮來源"],
                best_dec=record["最佳解壓 MB/s"],
                best_dec_src=record["最佳解壓來源"],
                worst_dec=record["最差解壓 MB/s"],
                worst_dec_src=record["最差解壓來源"],
                min_enc=record["最低 Encode RSS"],
                min_enc_src=record["最低 Encode RSS 來源"],
                max_enc=record["最高 Encode RSS"],
                max_enc_src=record["最高 Encode RSS 來源"],
                min_dec=record["最低 Decode RSS"],
                min_dec_src=record["最低 Decode RSS 來源"],
                max_dec=record["最高 Decode RSS"],
                max_dec_src=record["最高 Decode RSS 來源"],
                min_enc_power=record["最低 Encode CPU Power(mW)"],
                min_enc_power_src=record["最低 Encode CPU Power 來源"],
                max_enc_power=record["最高 Encode CPU Power(mW)"],
                max_enc_power_src=record["最高 Encode CPU Power 來源"],
                min_dec_power=record["最低 Decode CPU Power(mW)"],
                min_dec_power_src=record["最低 Decode CPU Power 來源"],
                max_dec_power=record["最高 Decode CPU Power(mW)"],
                max_dec_power_src=record["最高 Decode CPU Power 來源"],
                min_enc_energy=record["最低 Encode CPU Energy(J)"],
                min_enc_energy_src=record["最低 Encode CPU Energy 來源"],
                max_enc_energy=record["最高 Encode CPU Energy(J)"],
                max_enc_energy_src=record["最高 Encode CPU Energy 來源"],
                min_dec_energy=record["最低 Decode CPU Energy(J)"],
                min_dec_energy_src=record["最低 Decode CPU Energy 來源"],
                max_dec_energy=record["最高 Decode CPU Energy(J)"],
                max_dec_energy_src=record["最高 Decode CPU Energy 來源"],
                min_enc_energy_ratio=record["最低 Encode CPU Energy Ratio (TGZ=1)"],
                max_enc_energy_ratio=record["最高 Encode CPU Energy Ratio (TGZ=1)"],
                min_dec_energy_ratio=record["最低 Decode CPU Energy Ratio (TGZ=1)"],
                max_dec_energy_ratio=record["最高 Decode CPU Energy Ratio (TGZ=1)"],
            )
        )
    lines.append("")

md_out.write_text("\n".join(lines), encoding="utf-8")
print(f"[Info] wrote {md_out}")
print(f"[Info] wrote {csv_out}")
PY
