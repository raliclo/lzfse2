# CPU Call Tree Analysis

- 來源：`trace/analysis/cpu_call_tree/time-profile` 與 `time-sample`。
- `time-profile` 會產出 symbol occurrence 統計；這不是精確 CPU 百分比。
- `time-sample` 是 raw kperf address table，目前只記錄 row count 與 target 狀態，不納入 symbol 熱點排名。
- `hot_symbols_global.csv` 預設只保留全域前 500 名；可用 `CPU_CALL_TREE_GLOBAL_TOP_N` 調整。
- 分析前先看 `trace_summary.csv`，確認 `target_seen=yes`，並確認來源 trace 是否 timeout。
- timeout trace 可用來判斷 hotspot 方向，但不能拿來計算 MB/s 或完整執行時間。

產出檔案：
- `cpu_call_tree_summary.csv`
- `hot_symbols_by_file.csv`
- `hot_symbols_global.csv`
