#!/bin/zsh
set -euo pipefail

# Integrate CPU power/energy and TGZ-relative energy ratios into benchmark CSVs.
# 將 powerResults/power_summary.csv 的 CPU 功率、能耗與 TGZ 相對能耗比整合進 benchmark CSV。

cd /Users/raliclo/proj/lzfse2
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

POWER_CSV="${POWER_CSV:-powerResults/power_summary.csv}"
BENCHMARK_CSV="${BENCHMARK_RESULT_CSV:-BenchMarkResult.csv}"
BEST_POINTS_CSV="${BEST_POINTS_CSV:-best_points/best_points.csv}"
BEST_POINTS_MD="${BEST_POINTS_MD:-best_points/best_points.md}"

python3 - <<'PY' "$POWER_CSV" "$BENCHMARK_CSV" "$BEST_POINTS_CSV" "$BEST_POINTS_MD"
import csv
import sys
from pathlib import Path

power_csv = Path(sys.argv[1])
benchmark_csv = Path(sys.argv[2])
best_points_csv = Path(sys.argv[3])
best_points_md = Path(sys.argv[4])

FORMAT_TO_ALGO = {
    "TGZ": "tgz",
    "LZFSE (Other3)": "other3",
    "LZFSE (Optimal3)": "optimal3",
    "LZFSE (Lazy2)": "lazy2",
    "LZFSE (Optimal)": "optimal",
    "LZFSE (BVX3)": "bvx3",
    "LZFSE (Apple)": "apple",
    "TLZ4": "tar.lz4",
    "ZSTD": "zstd",
}

BEST_TO_BENCH_FORMAT = {
    "TGZ": "TGZ",
    "Other3": "LZFSE (Other3)",
    "Optimal3": "LZFSE (Optimal3)",
    "Lazy2": "LZFSE (Lazy2)",
    "Optimal": "LZFSE (Optimal)",
    "BVX3": "LZFSE (BVX3)",
    "Apple": "LZFSE (Apple)",
    "TLZ4": "TLZ4",
    "ZSTD": "ZSTD",
}

LOG_ONLY_FORMATS = {"TGZ", "LZFSE (Apple)", "TLZ4", "ZSTD"}
DATASETS = ("claw-code", "llama.cpp")
EXTERNAL_ALGOS = {"tgz", "tar.lz4", "zstd"}

BENCH_POWER_FIELDS = [
    "Encode CPU Power(mW)",
    "Decode CPU Power(mW)",
    "Encode CPU Energy(J)",
    "Decode CPU Energy(J)",
    "Encode CPU Energy Ratio (TGZ=1)",
    "Decode CPU Energy Ratio (TGZ=1)",
]

BENCH_FIELD_ENGLISH = {
    "資料夾": "dataset",
    "N": "n",
    "格式": "format",
    "原始大小(M)": "raw_size_mib",
    "壓縮後(M)": "compressed_size_mib",
    "壓縮耗時(秒)": "encode_seconds",
    "解壓耗時(秒)": "decode_seconds",
    "壓縮 MB/s": "encode_mb_s",
    "解壓 MB/s": "decode_mb_s",
    "壓縮比": "compression_ratio",
    "壓縮時間比": "encode_time_ratio",
    "解壓時間比": "decode_time_ratio",
    "Encode RSS(MB)": "encode_rss_mb",
    "Decode RSS(MB)": "decode_rss_mb",
    "Trace wall time(秒)": "trace_wall_seconds",
    "Trace timeout": "trace_timeout",
    "Trace target seen": "trace_target_seen",
    "CPU Symbol Status": "cpu_symbol_status",
    "CPU Top Symbol": "cpu_top_symbol",
    "CPU Top Count": "cpu_top_count",
    "CPU Top Category": "cpu_top_category",
    "CPU Parse Hits": "cpu_parse_hits",
    "CPU Encode Hits": "cpu_encode_hits",
    "CPU FSE Hits": "cpu_fse_hits",
    "CPU Swift Array Hits": "cpu_swift_array_hits",
    "Encode CPU Power(mW)": "encode_cpu_power_mw",
    "Decode CPU Power(mW)": "decode_cpu_power_mw",
    "Encode CPU Energy(J)": "encode_cpu_energy_j",
    "Decode CPU Energy(J)": "decode_cpu_energy_j",
    "Encode CPU Energy Ratio (TGZ=1)": "encode_cpu_energy_ratio_tgz",
    "Decode CPU Energy Ratio (TGZ=1)": "decode_cpu_energy_ratio_tgz",
}

BEST_POWER_FIELDS = [
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

BEST_FIELD_ENGLISH = {
    "資料夾": "dataset",
    "格式": "format",
    "最佳壓縮比": "best_ratio",
    "最佳壓縮比來源": "best_ratio_source",
    "最佳壓縮 MB/s": "best_encode_mb_s",
    "最佳壓縮來源": "best_encode_source",
    "最差壓縮 MB/s": "worst_encode_mb_s",
    "最差壓縮來源": "worst_encode_source",
    "最佳解壓 MB/s": "best_decode_mb_s",
    "最佳解壓來源": "best_decode_source",
    "最差解壓 MB/s": "worst_decode_mb_s",
    "最差解壓來源": "worst_decode_source",
    "最低 Encode RSS": "min_encode_rss_mb",
    "最低 Encode RSS 來源": "min_encode_rss_source",
    "最高 Encode RSS": "max_encode_rss_mb",
    "最高 Encode RSS 來源": "max_encode_rss_source",
    "最低 Decode RSS": "min_decode_rss_mb",
    "最低 Decode RSS 來源": "min_decode_rss_source",
    "最高 Decode RSS": "max_decode_rss_mb",
    "最高 Decode RSS 來源": "max_decode_rss_source",
    "最低 Encode CPU Power(mW)": "min_encode_cpu_power_mw",
    "最低 Encode CPU Power 來源": "min_encode_cpu_power_source",
    "最高 Encode CPU Power(mW)": "max_encode_cpu_power_mw",
    "最高 Encode CPU Power 來源": "max_encode_cpu_power_source",
    "最低 Decode CPU Power(mW)": "min_decode_cpu_power_mw",
    "最低 Decode CPU Power 來源": "min_decode_cpu_power_source",
    "最高 Decode CPU Power(mW)": "max_decode_cpu_power_mw",
    "最高 Decode CPU Power 來源": "max_decode_cpu_power_source",
    "最低 Encode CPU Energy(J)": "min_encode_cpu_energy_j",
    "最低 Encode CPU Energy 來源": "min_encode_cpu_energy_source",
    "最高 Encode CPU Energy(J)": "max_encode_cpu_energy_j",
    "最高 Encode CPU Energy 來源": "max_encode_cpu_energy_source",
    "最低 Decode CPU Energy(J)": "min_decode_cpu_energy_j",
    "最低 Decode CPU Energy 來源": "min_decode_cpu_energy_source",
    "最高 Decode CPU Energy(J)": "max_decode_cpu_energy_j",
    "最高 Decode CPU Energy 來源": "max_decode_cpu_energy_source",
    "最低 Encode CPU Energy Ratio (TGZ=1)": "min_encode_cpu_energy_ratio_tgz",
    "最高 Encode CPU Energy Ratio (TGZ=1)": "max_encode_cpu_energy_ratio_tgz",
    "最低 Decode CPU Energy Ratio (TGZ=1)": "min_decode_cpu_energy_ratio_tgz",
    "最高 Decode CPU Energy Ratio (TGZ=1)": "max_decode_cpu_energy_ratio_tgz",
}


def read_csv_rows(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        raw_rows = list(csv.reader(handle))
    if not raw_rows:
        return [], []
    raw_rows[0][0] = raw_rows[0][0].lstrip("\ufeff")
    if len(raw_rows) >= 2 and raw_rows[0][0] == "dataset" and raw_rows[1] and raw_rows[1][0] == "資料夾":
        fieldnames = raw_rows[1]
        data_rows = raw_rows[2:]
    else:
        fieldnames = raw_rows[0]
        data_rows = raw_rows[1:]
    rows = [dict(zip(fieldnames, [*row, *([""] * (len(fieldnames) - len(row)))][:len(fieldnames)])) for row in data_rows if row]
    return fieldnames, rows


def write_csv_rows(path: Path, fieldnames: list[str], rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        if path == best_points_csv:
            writer.writerow([BEST_FIELD_ENGLISH.get(field, field) for field in fieldnames])
            writer.writerow(fieldnames)
        elif path == benchmark_csv:
            writer.writerow([BENCH_FIELD_ENGLISH.get(field, field) for field in fieldnames])
            writer.writerow(fieldnames)
        else:
            writer.writerow(fieldnames)
        for row in rows:
            writer.writerow([row.get(field, "") for field in fieldnames])


def split_power_algorithm(value: str) -> tuple[str, str] | None:
    for dataset in DATASETS:
        prefix = f"{dataset}-"
        if value.startswith(prefix):
            return dataset, value[len(prefix):]
    return None


def load_power() -> dict[tuple[str, str, str, str], dict[str, str]]:
    if not power_csv.exists():
        raise SystemExit(f"missing power summary: {power_csv}")

    with power_csv.open(encoding="utf-8-sig", newline="") as handle:
        raw_rows = list(csv.reader(handle))
    if not raw_rows:
        raise SystemExit(f"empty power summary: {power_csv}")

    header = raw_rows[0]
    if header:
        header[0] = header[0].lstrip("\ufeff")

    records: list[dict[str, str]] = []
    index = 1
    while index < len(raw_rows):
        row = raw_rows[index]
        if not row or row[0] in ("演算法", "algorithm"):
            index += 1
            continue

        # Older power_benchmark.command wrote the quoted algorithm and the rest
        # of the row on separate lines. Repair that shape so existing partial
        # results can still be integrated.
        if len(row) == 1 and index + 1 < len(raw_rows):
            next_row = raw_rows[index + 1]
            if next_row and next_row[0] == "":
                row = [row[0], *next_row[1:]]
                index += 2
            else:
                index += 1
        else:
            index += 1

        if len(row) < len(header):
            row = [*row, *([""] * (len(header) - len(row)))]
        record = dict(zip(header, row[:len(header)]))
        if record.get("algorithm") == "演算法":
            continue
        records.append(record)

    power: dict[tuple[str, str, str, str], dict[str, str]] = {}
    for record in records:
        algorithm = record.get("algorithm", "")
        split = split_power_algorithm(algorithm)
        if not split:
            continue
        dataset, algo = split
        phase = record.get("encode_decode", "")
        n_value = record.get("n", "")
        if algo in EXTERNAL_ALGOS:
            n_value = ""
        if phase not in ("encode", "decode"):
            continue
        cpu = record.get("cpu_power_mw", "")
        cpu_energy = record.get("cpu_energy_j", "")
        if not cpu_energy and cpu:
            duration_ns = record.get("duration_ns", "")
            try:
                cpu_energy = f"{float(duration_ns) / 1e9 * float(cpu) / 1000.0:.6f}"
            except ValueError:
                cpu_energy = ""
        status = record.get("status", "")
        power[(dataset, algo, n_value, phase)] = {
            "cpu_power_mw": cpu,
            "cpu_energy_j": cpu_energy,
            "status": status,
        }
    return power


def lookup_power(power: dict[tuple[str, str, str, str], dict[str, str]], dataset: str, algo: str, n_value: str, phase: str) -> dict[str, str]:
    key_n = "" if algo in EXTERNAL_ALGOS else n_value
    return power.get((dataset, algo, key_n, phase), {})


def source_label(row: dict[str, str]) -> str:
    prefix = "log n" if row["格式"] in LOG_ONLY_FORMATS else "n"
    return f"{prefix}{row['N']}"


def integrate_benchmark(power: dict[tuple[str, str, str, str], dict[str, str]]) -> list[dict[str, str]]:
    fieldnames, rows = read_csv_rows(benchmark_csv)
    if not rows:
        raise SystemExit(f"no rows in {benchmark_csv}")
    fieldnames = [field for field in fieldnames if field not in ("Encode Power Status", "Decode Power Status")]
    for field in BENCH_POWER_FIELDS:
        if field not in fieldnames:
            fieldnames.append(field)

    for row in rows:
        dataset = row.get("資料夾", "")
        algo = FORMAT_TO_ALGO.get(row.get("格式", ""))
        n_value = row.get("N", "")
        if not dataset or not algo:
            continue
        encode = lookup_power(power, dataset, algo, n_value, "encode")
        decode = lookup_power(power, dataset, algo, n_value, "decode")
        row["Encode CPU Power(mW)"] = encode.get("cpu_power_mw", "")
        row["Decode CPU Power(mW)"] = decode.get("cpu_power_mw", "")
        row["Encode CPU Energy(J)"] = encode.get("cpu_energy_j", "")
        row["Decode CPU Energy(J)"] = decode.get("cpu_energy_j", "")
        row.pop("Encode Power Status", None)
        row.pop("Decode Power Status", None)

    tgz_energy: dict[tuple[str, str], tuple[float, float]] = {}
    for row in rows:
        if row.get("格式") != "TGZ":
            continue
        try:
            tgz_energy[(row.get("資料夾", ""), row.get("N", ""))] = (
                float(row["Encode CPU Energy(J)"]),
                float(row["Decode CPU Energy(J)"]),
            )
        except (KeyError, ValueError):
            continue

    for row in rows:
        row["Encode CPU Energy Ratio (TGZ=1)"] = ""
        row["Decode CPU Energy Ratio (TGZ=1)"] = ""
        baseline = tgz_energy.get((row.get("資料夾", ""), row.get("N", "")))
        if not baseline:
            continue
        for value_field, ratio_field, baseline_value in (
            ("Encode CPU Energy(J)", "Encode CPU Energy Ratio (TGZ=1)", baseline[0]),
            ("Decode CPU Energy(J)", "Decode CPU Energy Ratio (TGZ=1)", baseline[1]),
        ):
            try:
                if baseline_value > 0:
                    row[ratio_field] = f"{float(row[value_field]) / baseline_value:.4f}"
            except (KeyError, ValueError):
                pass

    write_csv_rows(benchmark_csv, fieldnames, rows)
    return rows


def value_rows(rows: list[dict[str, str]], key: str) -> list[dict[str, str]]:
    return [row for row in rows if row.get(key, "") != ""]


def power_cell(row: dict[str, str], key: str) -> str:
    return row.get(key, "")


def integrate_best_points(benchmark_rows: list[dict[str, str]]) -> None:
    if not best_points_csv.exists():
        print(f"[Info] best_points.csv not found, skipping best-points integration: {best_points_csv}", file=sys.stderr)
        return

    fieldnames, rows = read_csv_rows(best_points_csv)
    if not rows:
        raise SystemExit(f"no rows in {best_points_csv}")
    for field in BEST_POWER_FIELDS:
        if field not in fieldnames:
            fieldnames.append(field)

    groups: dict[tuple[str, str], list[dict[str, str]]] = {}
    for row in benchmark_rows:
        groups.setdefault((row.get("資料夾", ""), row.get("格式", "")), []).append(row)

    for row in rows:
        dataset = row.get("資料夾", "")
        bench_format = BEST_TO_BENCH_FORMAT.get(row.get("格式", ""))
        group = groups.get((dataset, bench_format), [])
        encode_rows = value_rows(group, "Encode CPU Power(mW)")
        decode_rows = value_rows(group, "Decode CPU Power(mW)")
        encode_energy_rows = value_rows(group, "Encode CPU Energy(J)")
        decode_energy_rows = value_rows(group, "Decode CPU Energy(J)")
        encode_energy_ratio_rows = value_rows(group, "Encode CPU Energy Ratio (TGZ=1)")
        decode_energy_ratio_rows = value_rows(group, "Decode CPU Energy Ratio (TGZ=1)")

        if encode_rows:
            min_encode = min(encode_rows, key=lambda item: float(item["Encode CPU Power(mW)"]))
            max_encode = max(encode_rows, key=lambda item: float(item["Encode CPU Power(mW)"]))
            row["最低 Encode CPU Power(mW)"] = power_cell(min_encode, "Encode CPU Power(mW)")
            row["最低 Encode CPU Power 來源"] = source_label(min_encode)
            row["最高 Encode CPU Power(mW)"] = power_cell(max_encode, "Encode CPU Power(mW)")
            row["最高 Encode CPU Power 來源"] = source_label(max_encode)

        if decode_rows:
            min_decode = min(decode_rows, key=lambda item: float(item["Decode CPU Power(mW)"]))
            max_decode = max(decode_rows, key=lambda item: float(item["Decode CPU Power(mW)"]))
            row["最低 Decode CPU Power(mW)"] = power_cell(min_decode, "Decode CPU Power(mW)")
            row["最低 Decode CPU Power 來源"] = source_label(min_decode)
            row["最高 Decode CPU Power(mW)"] = power_cell(max_decode, "Decode CPU Power(mW)")
            row["最高 Decode CPU Power 來源"] = source_label(max_decode)

        if encode_energy_rows:
            min_encode_energy = min(encode_energy_rows, key=lambda item: float(item["Encode CPU Energy(J)"]))
            max_encode_energy = max(encode_energy_rows, key=lambda item: float(item["Encode CPU Energy(J)"]))
            row["最低 Encode CPU Energy(J)"] = power_cell(min_encode_energy, "Encode CPU Energy(J)")
            row["最低 Encode CPU Energy 來源"] = source_label(min_encode_energy)
            row["最高 Encode CPU Energy(J)"] = power_cell(max_encode_energy, "Encode CPU Energy(J)")
            row["最高 Encode CPU Energy 來源"] = source_label(max_encode_energy)

        if decode_energy_rows:
            min_decode_energy = min(decode_energy_rows, key=lambda item: float(item["Decode CPU Energy(J)"]))
            max_decode_energy = max(decode_energy_rows, key=lambda item: float(item["Decode CPU Energy(J)"]))
            row["最低 Decode CPU Energy(J)"] = power_cell(min_decode_energy, "Decode CPU Energy(J)")
            row["最低 Decode CPU Energy 來源"] = source_label(min_decode_energy)
            row["最高 Decode CPU Energy(J)"] = power_cell(max_decode_energy, "Decode CPU Energy(J)")
            row["最高 Decode CPU Energy 來源"] = source_label(max_decode_energy)

        if encode_energy_ratio_rows:
            min_encode_ratio = min(
                encode_energy_ratio_rows,
                key=lambda item: float(item["Encode CPU Energy Ratio (TGZ=1)"]),
            )
            max_encode_ratio = max(
                encode_energy_ratio_rows,
                key=lambda item: float(item["Encode CPU Energy Ratio (TGZ=1)"]),
            )
            row["最低 Encode CPU Energy Ratio (TGZ=1)"] = power_cell(
                min_encode_ratio, "Encode CPU Energy Ratio (TGZ=1)"
            ) + f" ({source_label(min_encode_ratio)})"
            row["最高 Encode CPU Energy Ratio (TGZ=1)"] = power_cell(
                max_encode_ratio, "Encode CPU Energy Ratio (TGZ=1)"
            ) + f" ({source_label(max_encode_ratio)})"

        if decode_energy_ratio_rows:
            min_decode_ratio = min(
                decode_energy_ratio_rows,
                key=lambda item: float(item["Decode CPU Energy Ratio (TGZ=1)"]),
            )
            max_decode_ratio = max(
                decode_energy_ratio_rows,
                key=lambda item: float(item["Decode CPU Energy Ratio (TGZ=1)"]),
            )
            row["最低 Decode CPU Energy Ratio (TGZ=1)"] = power_cell(
                min_decode_ratio, "Decode CPU Energy Ratio (TGZ=1)"
            ) + f" ({source_label(min_decode_ratio)})"
            row["最高 Decode CPU Energy Ratio (TGZ=1)"] = power_cell(
                max_decode_ratio, "Decode CPU Energy Ratio (TGZ=1)"
            ) + f" ({source_label(max_decode_ratio)})"

    write_csv_rows(best_points_csv, fieldnames, rows)
    write_best_points_md(rows)


def md_cell(record: dict[str, str], value_key: str, source_key: str, suffix: str = "") -> str:
    value = record.get(value_key, "")
    source = record.get(source_key, "")
    if not value:
        return ""
    suffix_text = f" {suffix}" if suffix else ""
    return f"{value}{suffix_text} (`{source}`)" if source else f"{value}{suffix_text}"


def md_ratio_cell(record: dict[str, str], key: str) -> str:
    value = record.get(key, "")
    if value.endswith(")") and " (" in value:
        ratio, source = value.rsplit(" (", 1)
        return f"{ratio} (`{source[:-1]}`)"
    return value


def write_best_points_md(records: list[dict[str, str]]) -> None:
    datasets = sorted({row["資料夾"] for row in records}, key=lambda x: {"claw-code": 0, "llama.cpp": 1}.get(x, 99))
    lines: list[str] = []
    lines.append("# Best Points Analysis / 最佳點分析")
    lines.append("")
    lines.append("Source: `best_points/best_points.csv`")
    lines.append("")
    lines.append("> TGZ / Apple / TLZ4 / ZSTD use `log nX` only as the source log batch. `-n` does not affect those algorithms. / TGZ、Apple、TLZ4、ZSTD 的 `log nX` 只代表來源 log 批次，`-n` 不影響這些演算法。")
    lines.append("")

    for dataset in datasets:
        lines.append(f"## {dataset}")
        lines.append("")
        lines.append("| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最差壓縮 MB/s | 最佳解壓 MB/s | 最差解壓 MB/s | 最低 Encode RSS | 最高 Encode RSS | 最低 Decode RSS | 最高 Decode RSS | 最低 Encode CPU Power | 最高 Encode CPU Power | 最低 Decode CPU Power | 最高 Decode CPU Power | 最低 Encode CPU Energy | 最高 Encode CPU Energy | 最低 Decode CPU Energy | 最高 Decode CPU Energy | 最低 Encode Energy Ratio | 最高 Encode Energy Ratio | 最低 Decode Energy Ratio | 最高 Decode Energy Ratio |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for record in [row for row in records if row["資料夾"] == dataset]:
            lines.append(
                "| {fmt} | {best_ratio} (`{best_ratio_src}`) | "
                "{best_enc} (`{best_enc_src}`) | {worst_enc} (`{worst_enc_src}`) | "
                "{best_dec} (`{best_dec_src}`) | {worst_dec} (`{worst_dec_src}`) | "
                "{min_enc_rss} MB (`{min_enc_rss_src}`) | {max_enc_rss} MB (`{max_enc_rss_src}`) | "
                "{min_dec_rss} MB (`{min_dec_rss_src}`) | {max_dec_rss} MB (`{max_dec_rss_src}`) | "
                "{min_enc_power} | {max_enc_power} | {min_dec_power} | {max_dec_power} | "
                "{min_enc_energy} | {max_enc_energy} | {min_dec_energy} | {max_dec_energy} | "
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
                    min_enc_rss=record["最低 Encode RSS"],
                    min_enc_rss_src=record["最低 Encode RSS 來源"],
                    max_enc_rss=record["最高 Encode RSS"],
                    max_enc_rss_src=record["最高 Encode RSS 來源"],
                    min_dec_rss=record["最低 Decode RSS"],
                    min_dec_rss_src=record["最低 Decode RSS 來源"],
                    max_dec_rss=record["最高 Decode RSS"],
                    max_dec_rss_src=record["最高 Decode RSS 來源"],
                    min_enc_power=md_cell(record, "最低 Encode CPU Power(mW)", "最低 Encode CPU Power 來源", "mW"),
                    max_enc_power=md_cell(record, "最高 Encode CPU Power(mW)", "最高 Encode CPU Power 來源", "mW"),
                    min_dec_power=md_cell(record, "最低 Decode CPU Power(mW)", "最低 Decode CPU Power 來源", "mW"),
                    max_dec_power=md_cell(record, "最高 Decode CPU Power(mW)", "最高 Decode CPU Power 來源", "mW"),
                    min_enc_energy=md_cell(record, "最低 Encode CPU Energy(J)", "最低 Encode CPU Energy 來源", "J"),
                    max_enc_energy=md_cell(record, "最高 Encode CPU Energy(J)", "最高 Encode CPU Energy 來源", "J"),
                    min_dec_energy=md_cell(record, "最低 Decode CPU Energy(J)", "最低 Decode CPU Energy 來源", "J"),
                    max_dec_energy=md_cell(record, "最高 Decode CPU Energy(J)", "最高 Decode CPU Energy 來源", "J"),
                    min_enc_energy_ratio=md_ratio_cell(record, "最低 Encode CPU Energy Ratio (TGZ=1)"),
                    max_enc_energy_ratio=md_ratio_cell(record, "最高 Encode CPU Energy Ratio (TGZ=1)"),
                    min_dec_energy_ratio=md_ratio_cell(record, "最低 Decode CPU Energy Ratio (TGZ=1)"),
                    max_dec_energy_ratio=md_ratio_cell(record, "最高 Decode CPU Energy Ratio (TGZ=1)"),
                )
            )
        lines.append("")

    best_points_md.write_text("\n".join(lines), encoding="utf-8")


power = load_power()
benchmark_rows = integrate_benchmark(power)
integrate_best_points(benchmark_rows)
print(f"[Info] integrated CPU power/energy and TGZ energy ratios into {benchmark_csv}")
print(f"[Info] integrated CPU power/energy extrema and TGZ energy ratios into {best_points_csv}")
print(f"[Info] wrote {best_points_md}")
PY
