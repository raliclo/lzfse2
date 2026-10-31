# GNU tar vs bsdtar vs swift_tar — flags and behaviour / 旗標與行為比較

## What was compared / 比較範圍

This document compares three tar implementations on one macOS machine: every flag
swift_tar accepts, the commonly used GNU tar / bsdtar flags that swift_tar does not
have, and a set of behaviours. **Behaviours were measured** by running the three
binaries in a scratch directory, not taken from man pages, unless a row says
"(H)" (from `--help`, man page or source only) or "untested".

本文件在同一台 macOS 機器上比較三個 tar 實作：swift_tar 接受的每一個旗標、swift_tar
所沒有的常用 GNU tar／bsdtar 旗標，以及一組行為。**行為皆為實測**——在暫存目錄中實際
執行三個執行檔所得，而非抄自 man page；例外的列會標明「(H)」（僅依 `--help`、man page
或原始碼）或「untested（未測）」。

| item / 項目 | value / 值 |
|---|---|
| date / 日期 | 2026-10-31 |
| GNU tar | `gtar --version` → `tar (GNU tar) 1.35` (Homebrew `gnu-tar 1.35_1`) |
| bsdtar | `bsdtar --version` → `bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8` (same binary as `/usr/bin/tar`) |
| swift_tar | `/opt/homebrew/bin/swift_tar --version` → `swift_tar 0.1.4 (v0.1.4 / 706c09bc) 20261030-150730` (installed release, public build without LZFSE) |
| platform / 平台 | `Darwin luoweishundeMac-mini.local 27.2.0 Darwin Kernel Version 27.2.0: Wed Oct 14 23:47:07 PDT 2026; root:xnu-13432.41.4~25/RELEASE_ARM64_T8132 arm64` |
| user / 身分 | non-root (uid 501), umask 022 unless a row says otherwise / 非 root，除非另註，umask 022 |
| GNU defaults / GNU 預設 | `gtar --show-defaults` → `--format=gnu -f- -b20 --quoting-style=escape` ; `TAPE` unset |

**Scope note / 範圍說明.** The swift_tar column is the released 0.1.4. Several rows
change on swift_tar master after the 2026-10-31 code review (not yet released): a second
`-C` is refused instead of ignored (M15); `--no-same-permissions` reaches directories,
files over 4 MiB and FIFOs (M8); `-t` and `-x` agree on which members carry data (M7).
Bugs 1 and 2 in §5 are tracked there as N2 and N3. See `swift_tar/todo/todo.md`,
"2026-10-31 whole-tree code review".

swift_tar 欄是已發布的 0.1.4。2026-10-31 程式碼審查之後，swift_tar master（尚未發布）上
有幾列已經不同：第二個 `-C` 改為拒絕而非忽略（M15）；`--no-same-permissions` 也作用於目錄、
大於 4 MiB 的檔案與 FIFO（M8）；`-t` 與 `-x` 對哪些成員帶資料的判斷一致（M7）。§5 的
Bug 1、2 在該處記為 N2、N3。見 `swift_tar/todo/todo.md` 的「2026-10-31 全樹程式碼審查」。

### Legend / 圖例

| mark | meaning / 意義 |
|---|---|
| ✅ | supported, same meaning / 支援，語意相同 |
| ⚠️ | accepted but behaves differently — see the cell / 接受但行為不同，見格內說明 |
| ❌ | not supported: rejected with an error / 不支援：報錯拒絕 |
| (M) | measured on this machine / 本機實測 |
| (H) | from `--help`, man page or source only / 僅依說明、man page 或原始碼 |

Exit codes quoted as `rc=N`. GNU tar rejects an unknown option with rc=64 and a
fatal error with rc=2; bsdtar uses rc=1; swift_tar uses rc=1 and prints
`unknown option X / 無法辨識的選項 X`.

退出碼以 `rc=N` 表示。GNU tar 對未知選項回 64、致命錯誤回 2；bsdtar 一律回 1；swift_tar
回 1 並印出 `unknown option X / 無法辨識的選項 X`。

> **GNU long-option abbreviation / GNU 長選項縮寫.** GNU tar accepts any unique
> prefix of a long option. So `gtar --cat` is `--catenate` and `gtar --force` is
> `--force-local` (both measured: `--force` rc=0, `--cat` "You may not specify more
> than one '-Acdtrux'"). A swift_tar command line moved to GNU tar can therefore
> silently mean something else. bsdtar and swift_tar require exact names.
>
> GNU tar 接受長選項的任何唯一前綴，所以 `gtar --cat` 等於 `--catenate`、`gtar --force`
> 等於 `--force-local`（皆實測）。把 swift_tar 的指令搬到 GNU tar 上，可能悄悄變成別的意思。
> bsdtar 與 swift_tar 要求完整名稱。

---

## 1. Every swift_tar flag / swift_tar 的所有旗標

Source of the list: `swift_tar --help` plus the `knownOptions` / `valueOptions` sets
in `swift_tar.swift` (which add `--exclude`, `--force`, `--strict`,
`--no-same-owner`, `--crypto-selftest`, `-no-checksum` and the `--write_*`
spellings that `--help` does not list). The GNU and bsdtar columns were measured by
passing each flag to `gtar -c <flag> -f q.tar -C fs a.txt` and the bsdtar equivalent.

清單來源：`swift_tar --help`，加上 `swift_tar.swift` 中的 `knownOptions`／`valueOptions`
（補上 `--help` 未列出的 `--exclude`、`--force`、`--strict`、`--no-same-owner`、
`--crypto-selftest`、`-no-checksum` 與 `--write_*` 寫法）。GNU 與 bsdtar 欄位皆以
`gtar -c <旗標> -f q.tar -C fs a.txt` 及對應的 bsdtar 指令實測。

### 1.1 Modes / 模式

| flag / 旗標 | meaning / 意義 | GNU tar 1.35 | bsdtar 3.5.3 | swift_tar 0.1.4 | notes / 備註 |
|---|---|---|---|---|---|
| `-c` | create / 建立 | ✅ (M) | ✅ (M) | ✅ (M) | Bundled forms `cvf x.tar dir`, `-cvf`, `czf` work in all three (M). / 三者皆接受合併寫法。 |
| `-x` | extract / 解出 | ✅ (M) | ✅ (M) | ⚠️ (M) | **swift_tar ignores member-name operands**: `-x -f a.tar b.log` extracts *every* member, rc=0; a name not in the archive is not an error. GNU/bsdtar extract only the named member, and a missing name is rc=2 / rc=1 ("Not found in archive"). / **swift_tar 忽略成員名稱參數**：會解出全部成員且 rc=0。 |
| `-t` | list / 列出 | ✅ (M) | ✅ (M) | ⚠️ (M) | Same operand issue as `-x`: `-t -f a.tar b.log` lists everything. `-tv` format differs — see §3. / 同上，列出全部。 |
| `-r` | append / 追加 | ✅ (M) | ✅ (M) | ✅ (M) | All three refuse a compressed archive (§3). / 三者皆拒絕壓縮封存。 |
| `-u` | append if newer / 較新才追加 | ✅ (M) | ✅ (M) | ⚠️ (M) | Same-second change: bsdtar appends (compares sub-second), GNU and swift_tar do not — swift_tar compares whole seconds although it *stores* nanoseconds. / 同一秒內的修改：bsdtar 會追加，GNU 與 swift_tar 不會。 |
| `--delete` | remove members in place / 就地刪除成員 | ✅ (M) | ❌ `Option --delete is not supported` (M) | ⚠️ (M) | Uncompressed tar only. Deleting a **directory** name: GNU removes `sub/` *and* `sub/c.txt`; swift_tar removes only the `sub/` entry and leaves `sub/c.txt` (README says it matches "by name"). Missing name: GNU rc=2, swift_tar rc=1. / 刪除目錄名時 GNU 連子項一起刪，swift_tar 只刪目錄項本身。 |
| `--identify` | print detected filter chain, no extraction / 只印出偵測到的壓縮鏈 | ❌ rc=64 (M) | ❌ (M) | ✅ (M) | e.g. `cz/t.Z: compress (.Z) → tar`, `fm/t.zip: zip`, `e.tzst: encrypted (ChaCha20-Poly1305)`. Closest equivalent: `file(1)`. |
| `--cat` | decompress filter chain to stdout (bsdcat) / 只解壓縮到 stdout | ⚠️ GNU reads it as `--catenate` (abbrev.) (M) | ❌ (M) | ✅ (M) | `--cat -f t.xz` output was byte-identical to the original tar (M). Equivalent: `bsdcat`, `xz -dc`. |
| `--encrypt-only` | encrypt a file as-is to stdout / 原樣加密檔案 | ❌ (M) | ❌ (M) | ✅ (M) | 4-byte file → 96 bytes. |
| `--decrypt-only` | strip only the encryption layer / 只剝除加密層 | ❌ (M) | ❌ (M) | ✅ (M) | Encrypted `.tar.zst` came back as a zstd stream (M). |
| `--rgb1-pack` / `--rgb1-info` / `--rgb1-raw` | RGB1 raw-image container / RGB1 影像容器 | ❌ (M) | ❌ (M) | ✅ (M) | Not tar-related. pack→info→raw round-trip of 12 bytes matched (M). |
| `-test` | self test against the platform tar / 自我測試 | ❌ (parsed as bundled `-t -e -s -t`) (M) | ❌ (M) | ✅ (M) | 16 checks, all ✓, rc=0, ran against `/usr/bin/tar`. Works in `$TMPDIR` (`/var/folders/...`), which it removed afterwards (M). |
| `-debug` | with `-test`, show tar-candidate search / 搭配 -test 顯示搜尋過程 | ❌ (M) | ❌ (M) | ⚠️ (M) | Used without `-test` it is split as a bundle and fails with `unknown option -d` — the message names the wrong token. / 單獨使用時被拆成合併旗標，錯誤訊息指向 `-d`。 |
| `--crypto-selftest` | RFC 8439 ChaCha20/Poly1305 vectors / 加密自我測試 | ❌ (M) | ❌ (M) | ✅ (M) | Undocumented in `--help`; prints `PASS:` lines, rc=0. |
| `--help` | help / 說明 | ✅ | ✅ | ✅ | |
| `--version` | version / 版本 | ✅ (M) | ✅ (M) | ✅ (M) | |

### 1.2 Codecs (create) / 壓縮引擎（建立）

Reading auto-detects in all three when the archive is a file; see §3 for stdin.
讀取時三者對「檔案」皆自動偵測；stdin 的情形見 §3。

| flag / 旗標 | meaning / 意義 | GNU tar | bsdtar | swift_tar | notes / 備註 |
|---|---|---|---|---|---|
| `-z`, `--gzip` | gzip | ✅ (M) | ✅ (M) | ✅ (M) | swift_tar writes one gzip member per 4 MiB chunk (pigz-style); stock gzip reads it. |
| `-j`, `--bzip2` | bzip2 | ✅ (M) | ✅ (M) | ✅ (M) | bsdtar also has `-y` for bzip2 (M); GNU rejects `-y`. |
| `-J`, `--xz` | xz | ✅ (M) | ✅ (M) | ✅ (M) | |
| `--lzip` | lzip | ✅ external `lzip` (M) | ✅ (M) | ✅ needs `lzip` CLI (H) (M worked here) | |
| `--zstd` | zstd | ✅ external `zstd` (M) | ✅ (M) | ✅ (M) | 20 MB text: GNU 1 frame, bsdtar 1 frame, swift_tar 5 frames (4 MiB chunks) (M). |
| `--zstd-parallel` | as `--zstd`; decode frames on `-n` cores / 多核解碼 | ❌ (M) | ❌ (M) | ✅ (M) | GNU: `-I 'zstd -T4'`; bsdtar: `--options zstd:threads=4` (M, accepted). |
| `--zstd-level N` | zstd level 1–22, default 9 | ❌ (M) | ❌ (M) | ✅ (M) | 0, 23 and `abc` rejected with rc=1 (M). GNU: `-I 'zstd -19'`; bsdtar: `--options zstd:compression-level=19` (both M). |
| `--lz4` | lz4 frames | ❌ `unrecognized option '--lz4'` (M) | ✅ (M) | ✅ (M) | GNU tar cannot read `.tar.lz4` either (§3). |
| `--zip` | real ZIP container (Deflate, auto ZIP64) | ❌ (M) | ❌ `--zip` (use `--format zip`) (M) | ✅ (M) | bsdtar: `--format zip`. |
| `--zip64` | ZIP with ZIP64 records forced | ❌ (M) | ❌ (M) | ✅ (M) | `unzip -l` reads it (M). |
| `--zip-unsorted` | ZIP members in filesystem order | ❌ (M) | ❌ (M) | ✅ (M) | Default is sorted; unsorted gave readdir order (M). |
| `--no-checksum`, `-no-checksum` | omit zstd/lz4/xz content checksum | ❌ (M) | ❌ (M) | ✅ (M) | `zstd -lv`: `Check: XXH64` default → `Check: None` (M). |
| `--skip-compressed` | single already-compressed input → write without codec | ❌ (M) | ❌ (M) | ✅ (M) | `-c -z --skip-compressed x.tgz` → plain tar + notice on stderr (M). |
| `--encrypt` | ChaCha20-Poly1305 encryption, passphrase from tty | ❌ (M) | ❌ `Option --encrypt is not supported` (M) | ✅ (M) | Read side auto-detects; GNU/bsdtar cannot read the result (M). |
| `--keyfile <path>` | key material from file (required off-tty) | ❌ (M) | ❌ (M) | ✅ (M) | Missing key off-tty → rc=1 "stdin is not a terminal"; wrong key → rc=1 "authentication failed on chunk 1" (M). bsdtar has `--passphrase` but only for ZIP/7z/RAR (H). |
| (none) / 無 | plain tar | ✅ | ✅ | ✅ | `-cf x.tar.gz` without `-z` writes **plain** tar in all three (M). |

### 1.3 Options / 選項

| flag / 旗標 | meaning / 意義 | GNU tar | bsdtar | swift_tar | notes / 備註 |
|---|---|---|---|---|---|
| `-f <path>` | archive path; `-` = stdio | ✅ (M) | ✅ (M) | ✅ (M) | Default without `-f`: all three use stdin/stdout here (M). GNU honours `TAPE`, bsdtar honours `TAPE`, **swift_tar ignores `TAPE`** (wrote to stdout) (M). |
| `-O`, `--to-stdout` | `-x` to stdout | ✅ (M) | ✅ (M) | ⚠️ (M) | swift_tar streams **all** members even when one is named (`-xO -f a.tar b.log` printed 4 files) — same root cause as §1.1. With `-c` swift_tar accepts `-O` and ignores it (wrote to `-f`) (M); bsdtar rejects `-O` in `-c` mode. |
| `-stream-in` | read archive from stdin (= `-f -`) | ❌ (bundled letters) (M) | ❌ (M) | ✅ (M) | |
| `-stream-out` | write archive to stdout; with `-x` acts as `-O` | ❌ (M) | ❌ (M) | ✅ (M) | |
| `-i`, `--ignore-zeros` | keep reading past zero blocks | ✅ (M) | ⚠️ `--ignore-zeros` ✅, short `-i` ❌ (Usage) (M) | ✅ (M) | Two concatenated tars: without `-i` 6 entries, with it 10, in all three (M). |
| `-o`, `--no-same-owner` | do not restore owner | ⚠️ (M) | ⚠️ (M) | ✅ no-op (M) | On **create**, GNU `-o` = `--old-archive` (wrote a V7 "tar archive", M); bsdtar `-c -o` wrote ustar (M). swift_tar never restores owners; `-o` is accepted for compatibility. |
| `-C <dir>` | change directory | ✅ positional (M) | ✅ positional (M) | ⚠️ (M) | swift_tar takes **one** `-C` (the first): `-C one f1 -C two f2` → `cannot stat 'f2'`, rc=1 (M). On `-x`, a **missing** `-C` dir is **created** by swift_tar (rc=0); GNU rc=2, bsdtar rc=1 (M). |
| `--strip-components N` (and `=N`) | drop N leading path parts on `-x` | ✅ (M) | ✅ (M) | ✅ (M) | Identical results (M). swift_tar rejects it on `-c` (GNU/bsdtar accept and ignore) and on ZIP extraction (H). |
| `--exclude PAT` (and `=PAT`) | skip matching paths | ✅ (M) | ✅ (M) | ⚠️ (M) | Matching rules differ — see §3 `--exclude` row. Not in `--help` option list. |
| `-n N` | parallel in-flight chunks (swift_tar) | ⚠️ GNU `-n` = `--seek` (H) | ⚠️ bsdtar `-n` = `--no-recursion` (H) | ✅ (M) | **Same letter, three meanings.** swift_tar output is byte-identical for `-n 1` and `-n 8` (M). |
| `-v` | verbose | ✅ (M) | ✅ (M) | ⚠️ (M) | Format differs; see §3. |
| `-m`, `--touch` | do not restore mtime on `-x` | ✅ (M) | ⚠️ `-m` ✅, `--touch` ❌ (M) | ✅ (M) | |
| `-p`, `--same-permissions` | restore mode bits exactly | ✅ (M) | ✅ (M) | ✅ default (M) | swift_tar's **default** is `-p` even for non-root (§3). GNU long spelling `--preserve-permissions` is ❌ in swift_tar (M). |
| `--no-same-permissions` | apply umask on `-x` | ✅ (M) | ✅ (M) | ⚠️ (M) | swift_tar applies the umask to **files only**: a `0777` directory stays `0777`, and a `4755` file becomes `4750` keeping **setuid**. GNU/bsdtar give `0750` and drop setuid (M). Looks like a bug — see §5. |
| `-h`, `--dereference` | follow symlinks on create | ✅ (M) | ✅ (M) | ✅ (M) | All stored the target's content (M). Note: GNU `-h` ≠ help. |
| `--strict` | non-zero exit if a member was skipped (default) | ❌ (M) | ❌ (M) | ✅ default (M) | |
| `--no-strict` | exit 0 even after skips | ❌ (M) | ❌ (M) | ✅ (M) | `..` member: default rc=1, `--no-strict` rc=0, still skipped (M). |
| `--no-links` | create no symlink/hardlink members on `-x` | ❌ (M) | ❌ (M) | ✅ (M) | Each link named on stderr: `skipping link './sym' (symlink -> a.txt)` (M). |
| `--force` | allow a case-only name collision on a case-insensitive FS | ⚠️ GNU reads it as `--force-local` (M) | ❌ (M) | ✅ (M) | Archive with `A.txt` then `a.txt` on APFS: GNU and bsdtar silently keep the later (`a.txt`, "lower"), rc=0; swift_tar rc=1 with an explanation; `--force` → rc=0 + warning (M). |
| `-write_ucrt`, `-write_foundation` (`--write_*`) | Windows extraction backend | ❌ (M) | ❌ (M) | ✅ Windows; accepted, no effect on macOS (M) | |
| `--width/--height/--lat/--lng/--height-m/--title/--country/--creator-email/--right/--created-ms/--tz-offset-min` | RGB1 header fields | ❌ (M) | ❌ (M) | ✅ (M) | Negative values like `--lat -33.8` accepted (M). |
| `--` | end of options | ✅ (M) | ✅ (M) | ✅ (M) | `-- -dash` archived the file `-dash` in all three (M). |
| `--bvx3-*`, `--other3-*` | LZFSE engines (private build only) | ❌ | ❌ | ❌ in the public 0.1.4 build (M) | Compiled only into the private build (H, source). |

---

## 2. GNU tar / bsdtar flags swift_tar does not have / swift_tar 沒有的 GNU tar／bsdtar 旗標

Every flag in this table was passed to all three tools (`<tar> -c <flag> -f q.tar -C fs a.txt`).
swift_tar rejected **every one** with `unknown option` and rc=1 — it never silently
ignores an option. "✅" in the GNU/bsdtar columns means the option was accepted
(rc=0) in that test, or (H) where the test could not show its effect.

本表每個旗標都對三個工具實際執行過。swift_tar **全部**以 `unknown option` 與 rc=1 拒絕——
它從不靜默忽略選項。GNU／bsdtar 欄的「✅」表示該測試中接受（rc=0），無法從測試看出效果者標 (H)。

| flag / 旗標 | meaning / 意義 | GNU tar | bsdtar | swift_tar | notes / 備註 |
|---|---|---|---|---|---|
| `--format=FMT`, `-H FMT` | archive format (ustar/pax/gnu/zip/…) | ✅ (M) | ✅ `--format`; `-H` = follow cmdline symlinks (M) | ❌ (M) | swift_tar always writes ustar + pax extensions; ZIP via `--zip`. |
| `--posix` | = `--format=posix` | ✅ (M) | ✅ accepted (M) | ❌ (M) | |
| `-P`, `--absolute-names` | keep leading `/` and `..` | ✅ (M) | ✅ `-P`; `--absolute-names` ❌ (M) | ❌ (M) | swift_tar has no way to write or extract absolute paths. |
| `--numeric-owner` | ids only | ✅ (M) | ✅ (M) | ❌ (M) | swift_tar always writes numeric ids with **empty** uname/gname (listing shows `501/0`) (M). |
| `--owner`, `--group` | override owner on create | ✅ (M) | ✅ (M) | ❌ (M) | |
| `--uname`, `--gname`, `--uid`, `--gid` | bsdtar owner override | ❌ (M) | ✅ (M) | ❌ (M) | |
| `--mode=` | override mode on create | ✅ (M) | ❌ (M) | ❌ (M) | |
| `--mtime=`, `--clamp-mtime` | override mtime (reproducible builds) | ✅ (M) | ❌ (M) | ❌ (M) | |
| `--sort=name` | sorted member order | ✅ (M) | ❌ (M) | ❌ (M) | swift_tar **always sorts** members on create (M). |
| `-T`, `--files-from`, `--null` | read names from a file | ✅ (H; test hit GNU's positional `-C` ordering) | ✅ (M) | ❌ (M) | |
| `-X`, `--exclude-from` | exclude patterns from a file | ✅ (M) | ✅ (M) | ❌ (M) | |
| `--exclude-vcs` | skip .git etc. | ✅ (M) | ✅ accepted (M) | ❌ (M) | |
| `--exclude-caches` | skip CACHEDIR.TAG dirs | ✅ (M) | ❌ (M) | ❌ (M) | |
| `--anchored`, `--ignore-case`, `--wildcards`, `--no-wildcards-match-slash` | pattern control | ✅ (M) | ❌ (M) | ❌ (M) | |
| `--transform=` / `-s` | rename members | ✅ `--transform`; `-s` = `--same-order` (M) | ✅ `-s /a/z/`; `--transform` ❌ (M) | ❌ (M) | |
| `-W`, `--verify` | verify after write | ✅ (M) | ❌ (M) | ❌ (M) | |
| `--acls`, `--xattrs`, `--no-xattrs` | ACL / xattr | ✅ accepted; "XATTR support is not available" on macOS (M) | ✅ (M) | ❌ (M) | swift_tar stores neither. |
| `--mac-metadata`, `--no-mac-metadata` | AppleDouble metadata | ❌ (M) | ✅ (M) | ❌ (M) | |
| `-S`, `--sparse`, `--hole-detection` | sparse files | ✅ (M) | ⚠️ `-S` ✅, `--sparse` ❌ (M) | ❌ (M) | |
| `-M` (multi-volume), `-L N`, `-V LABEL`, `--label` | tape volumes | ✅ (M) | ❌ (`-L` = follow symlinks) (M) | ❌ (M) | |
| `-g`, `--listed-incremental`, `--level` | incremental backups | ✅ (M) | ❌ (M) | ❌ (M) | |
| `-N DATE`, `--newer`, `--newer-mtime` | only newer files | ✅ (M) | ⚠️ long forms ✅, `-N` ❌ (M) | ❌ (M) | |
| `-a`, `--auto-compress` | codec from suffix | ✅ (M) | ✅ (M) | ❌ (M) | swift_tar never picks a codec from the suffix (M). |
| `-I PROG`, `--use-compress-program` | external compressor | ✅ (M) | ⚠️ `--use-compress-program` ✅; `-I` = `-T` (M) | ❌ (M) | |
| `--options` | libarchive module options | ❌ (M) | ✅ (e.g. `zstd:compression-level=19`) (M) | ❌ (M) | |
| `-Z`, `--compress` | Unix compress (.Z) on create | ✅ (M) | ✅ (M) | ❌ create; ✅ read (M) | |
| `--lzma` | lzma on create | ✅ (M) | ✅ (M) | ❌ create; ✅ read (M) | |
| `--lzop` | lzop | ⚠️ accepted, `lzop` not installed (M) | ⚠️ "Can't launch external program: lzop" (M) | ❌ (M) | swift_tar detects lzop on read but needs liblzo2 (H). |
| `--lrzip`, `--grzip` | | ❌ (M) | ⚠️ external program missing (M) | ❌ (M) | |
| `--b64encode`, `--uuencode` | encode output | ❌ (M) | ✅ (M) | ❌ create; ✅ read (H) | |
| `--one-file-system` | stay on one fs | ✅ (M) | ✅ (M) | ❌ (M) | |
| `--no-recursion`, `-n`, `--norecurse` | do not descend | ✅ `--no-recursion` (M) | ✅ all three spellings (M) | ❌; `-n` means parallelism (M) | |
| `-l`, `--check-links` | warn about missing hard links | ✅ (M) | ✅ (M) | ❌ (M) | |
| `--hard-dereference` | store hard links as files | ✅ (M) | ❌ (M) | ❌ (M) | |
| `-b N`, `--blocking-factor`, `--record-size` | record size | ✅ (M) | ⚠️ `-b` ✅, `--record-size` ❌ (M) | ❌ (M) | swift_tar does not pad to a 10 KiB record: one small file → 3072 bytes vs 10240 (M). |
| `-k`, `--keep-old-files` | do not overwrite on `-x` | ✅ rc=2 "File exists" (M) | ✅ rc=0, silently kept (M) | ❌ (M) | swift_tar always overwrites, like the others' default (M). |
| `--keep-newer-files`, `--skip-old-files`, `--overwrite`, `--no-overwrite-dir`, `--recursive-unlink` | overwrite policy | ✅ (M) | `--keep-newer-files` ✅, others ❌ (M) | ❌ (M) | |
| `-U`, `--unlink-first` | unlink before extracting | ✅ (M) | ✅ `-U` (x mode only) (M) | ❌ (M) | |
| `--same-owner` | restore owner (root) | ✅ (M) | ✅ (M) | ❌ (M) | |
| `--preserve-permissions` | GNU long form of `-p` | ✅ (M) | ✅ (M) | ❌ (M) | swift_tar spells it `--same-permissions`. |
| `--delay-directory-restore` | | ✅ (M) | ❌ (M) | ❌ (M) | |
| `--remove-files` | delete sources after archiving | ✅ — it really deleted `src/a.txt` during this test (M) | ❌ (M) | ❌ (M) | |
| `--totals` | print byte total | ✅ (M) | ✅ (M) | ❌ (M) | |
| `--checkpoint`, `--checkpoint-action` | progress | ✅ (M) | ❌ (M) | ❌ (M) | |
| `-w`, `--interactive` | confirm each file | ✅ (M) | ✅ `-w` (prompted) (M) | ❌ (M) | |
| `-q`, `--fast-read` | stop after first match | ❌ (M) | ✅ (x/t mode) (M) | ❌ (M) | |
| `--chroot`, `--safe-writes` | | ❌ (M) | ✅ (M) | ❌ (M) | |
| `--to-command=` | pipe each member to a command | ✅ (M) | ❌ (M) | ❌ (M) | |
| `-R`, `--block-number`, `--index-file`, `--show-transformed-names`, `--utc`, `--full-time`, `--warning=`, `--atime-preserve` | misc GNU | ✅ (M) | ❌ (M) | ❌ (M) | |
| `-A`, `--catenate` | append archives | ✅ (H) | ❌ (H) | ❌ (H) | |
| `-d`, `--diff`, `--compare` | compare archive with fs | ✅ (H) | ❌ (H) | ❌ (`-d` rejected, M) | |
| `--passphrase` | ZIP/7z/RAR password | ❌ (M) | ✅ (M) | ❌ (use `--encrypt`/`--keyfile`) (M) | |

---

## 3. Behaviour (measured) / 行為（實測）

All rows measured unless marked. Fixtures: a tree `src/` with `a.txt` (mode 754),
`b.log`, `sub/c.txt`, symlink `sym -> a.txt`, hard link `hard` = `a.txt`, a
non-ASCII name `日本.txt` and a 120-character name.

除另註外皆為實測。測試樹 `src/` 含 `a.txt`（mode 754）、`b.log`、`sub/c.txt`、
符號連結 `sym -> a.txt`、硬連結 `hard`＝`a.txt`、非 ASCII 檔名 `日本.txt` 與一個 120 字元的檔名。

| behaviour / 行為 | GNU tar | bsdtar | swift_tar | how measured / 量測方式 |
|---|---|---|---|---|
| **Exit status when a member is skipped on `-x`** / 解出時略過成員的退出碼 | rc=2 (`Member name contains '..'`) | rc=1 (`Path contains '..'`) | rc=1 by default (`--strict`); `--no-strict` → rc=0 | archive containing `../escape.txt` |
| **Exit status when a file is unreadable on `-c`** / 建立時檔案不可讀 | rc=2, the rest archived | rc=1, **every file after it in the walk is missing** (`./z ./a` kept, `b c y` lost) | rc=1, the rest archived, message `left out` | `chmod 000` one of five files |
| `-c` with a nonexistent operand / 不存在的參數 | rc=2, rest archived | rc=1 | rc=1, rest archived | |
| **Leading `/` on create** / 建立時開頭的 `/` | stripped, warns `Removing leading '/'` | stripped, warns | stripped, **no message** | `-cf x.tar /abs/path/f.txt` |
| **`..` on create** / 建立時的 `..` | `../` stripped, warns → `escape.txt` | stored as `../escape.txt` | stored as `../escape.txt` — an archive swift_tar itself then refuses to extract (rc=1) | `cd inner; -cf x.tar ../escape.txt` |
| **Leading `/` on extract** / 解出時的絕對路徑 | stripped, warns; written under `-C` | stripped, warns; under `-C` | stripped **silently**, under `-C`, rc=0 (README documents it; `--help` says "refuses absolute paths", which is inaccurate) | archive made with `gtar -P` |
| **`..` on extract** / 解出時的 `..` | skipped, rc=2 | skipped, rc=1 | skipped, rc=1 (`skipping unsafe path`) | |
| **Symlink planted then written through** (`l -> /outside`, then `l/x`) / 先放 symlink 再穿過它寫入 | refused: `l/x: Cannot open: Not a directory`, rc=2 | refused: `Cannot extract through symlink`, rc=1 | refused: `path passes through a symlink`, rc=1 | `outside/` stayed empty for all three; link `l` itself is created by all three |
| **Permissions restored by default (non-root)** / 非 root 時預設權限 | umask applied: 777→750, 4755→750 (setuid dropped) at umask 027 | same as GNU | **exact**: 777→777, 4755→**4755 (setuid kept)**, dir 777→777 | `-x` at umask 027 |
| `-p` (non-root) | exact, setuid kept | exact, setuid kept | exact (same as default) | |
| `--no-same-permissions` | files and dirs 750, setuid dropped | same as GNU | files 750 but **setuid kept** (4750); **dirs stay 777** | see §5 bug 2 |
| **mtime sub-second precision** / mtime 次秒精度 | whole seconds (gnu format); `--format=posix` keeps ns | whole seconds unless a pax header is needed anyway | **nanoseconds** (pax `mtime=` written whenever the mtime has a fraction); all three readers restore it | source mtime `…56.123456789`; 3×3 create/extract matrix |
| `./` prefix with `-C dir .` / `-C dir .` 的前綴 | `./`, `./a.txt` … | same | same | |
| **Member order on create** / 成員順序 | readdir order | readdir order | **sorted** by name | `-tf` listing |
| **Default format written** / 預設格式 | `gnu` (`ustar  ` magic, `././@LongLink` for long names) | `ustar`; pax header only for long or non-ASCII names (2 of 9) | `ustar` + pax header for long/non-ASCII names **and** for every entry with a fractional mtime (8 of 9 here) | `file`, `strings`, `od` at offset 257 |
| uname/gname / 擁有者名稱 | `raliclo/wheel` | `raliclo/wheel` | **empty**; numeric only (`501/0`) | `gtar -tvf` on each archive |
| Record padding / 記錄補齊 | 10240 bytes | 10240 bytes | 512-byte blocks only (3072 bytes for one small file) | `wc -c` |
| **No `-f`, reading** / 未給 `-f` 讀取 | stdin (`-f-` compiled default) | stdin | stdin | `tar -t < x.tar` |
| **`TAPE` env** | honoured | honoured | **ignored** | `TAPE=file tar -c …` |
| **Compression auto-detect, file** / 檔案自動偵測 | gz, bz2, xz, lzma, lzip, zstd, .Z ✅; **lz4 ❌** ("does not look like a tar archive") | all 8 ✅ | all 8 ✅ | 8 compressed copies of one tar |
| **Compression auto-detect, stdin** / stdin 自動偵測 | ❌ for all: rc=2 `Archive is compressed. Use -z option` | all 8 ✅ | all 8 ✅ | `tar -t < t.gz` |
| Codec needed on create? / 建立時須指定壓縮？ | yes, or `-a` | yes, or `-a` | yes; no `-a` | `-cf x.tar.gz` gave plain tar in all three |
| Bundled `tar cvf out.tar dir` / 傳統合併寫法 | ✅ | ✅ | ✅ (also `czf`, `-cvf`) | |
| **`-r`/`-u` on a compressed archive** | rc=2 `Cannot update compressed archives` | rc=1 `Cannot append to compressed archive` | rc=1 `cannot append to a gzip-compressed archive` | `.tgz`; archive unchanged in all three |
| **`--exclude 'sub'`** (bare name) | any component | any component | any component | identical results |
| `--exclude 'sub/'` (trailing `/`) | matches nothing | excludes every `sub` dir | matches nothing | |
| `--exclude './sub'` | matches nothing | excludes every `sub` | excludes every `sub` (`./` stripped first) | |
| `--exclude 'sub/*'` | excludes contents of every `sub`, keeps the dirs | excludes every `sub` dir | **matches nothing** | |
| `--exclude 'other/sub'` (pattern with `/`, not at root) | excludes `ex/other/sub` (matches a trailing part) | same | **matches nothing** — a pattern containing `/` must match the whole path | same on `-x` |
| `--exclude '*.log'`, `'su?'`, `'ex/sub'`, `'x.txt'` | | | all three agree | create and `-x` |
| **Hard links on create** / 建立時硬連結 | stored as link (`a.txt link to ./hard`, first one met is the file) | same | stored as link (sorted, so `hard link to ./a.txt`) | `-tvf` |
| Hard links on extract / 解出硬連結 | restored (nlink=2, same inode) | restored | restored | `stat -f %i` |
| Duplicate member names / 重複成員 | last wins | last wins | last wins | `gtar -r` the same name twice |
| Case-only collision (`A.txt` + `a.txt`, APFS) / 大小寫衝突 | silently keeps the later, rc=0 | same | **rc=1** with explanation; `--force` allows it | |
| `-x -C missing_dir` | rc=2 `Cannot open` | rc=1 `could not chdir` | **creates the dir**, rc=0 | |
| Multiple `-C` on create | positional ✅ | positional ✅ | only the first applies; later names fail `cannot stat`, rc=1 | `-C one f1 -C two f2` |
| Existing file on `-x` (no `-k`) / 既有檔案 | overwritten | overwritten | overwritten | |
| **ISO 9660 image** | rc=0, **lists nothing** | ✅ lists members | rc=0, **lists nothing** | `hdiutil makehybrid -iso`, `bsdtar --format iso9660` |
| ZIP | ❌ rc=2 | ✅ | ✅ (also creates it) | `zip -r` |
| 7-Zip | ❌ | ✅ | ❌ rc=1 `not an archive` | `bsdtar --format 7zip` |
| cpio (odc, newc, `.cpio.gz`) | ❌ | ✅ | ❌ rc=1 (`--cat` can unwrap the gzip layer) | `cpio -o`, `bsdtar --format newc` |
| ar | ❌ | ✅ | ❌ | `ar rc` |
| xar | ❌ | ✅ | ❌ | `xar -cf` |
| mtree, warc | ❌ | ✅ | ❌ | `bsdtar --format mtree/warc` |
| shar | ❌ | ❌ (write-only format) | ❌ | `bsdtar --format shar` |
| v7, ustar, pax, gnutar | ✅ | ✅ | ✅ | `bsdtar --format …` |
| RPM, RAR, CAB, LHA | untested (no `rpm`/`7z`/`rar` here) | untested | RPM wrapper: detected, use `--cat` for the cpio payload (H) | |
| uuencode / base64 input | untested | untested | read filter listed (H) | |
| **Encryption** / 加密 | none | none on tar (`--passphrase` for ZIP/7z only, H) | `--encrypt` / `--keyfile`, ChaCha20-Poly1305, auto-detected on read; wrong key → rc=1 | round-trip with a 64-byte random key |
| **Parallel compression** / 平行壓縮 | via `-I 'zstd -T4'` (external) | `--options zstd:threads=4` | built in: 4 MiB chunks, `-n N` workers; output identical for any N | `cmp` of `-n 1` vs `-n 8` |
| zstd level / zstd 等級 | `-I 'zstd -19'` | `--options zstd:compression-level=19` | `--zstd-level 19` (default 9) | 20 MB text: 1777 B (GNU, bsdtar at 19) vs 1907 B (swift_tar at 19, 5 frames) |
| **`--delete`** | ✅ (dir name removes children too) | ❌ | ✅ plain tar only (dir name removes only the dir entry) | |
| **`-O` / `--to-stdout`** | named members only | named members only | **all members**, member names ignored | `-xO -f a.tar b.log` |
| **`-v` on create** | names on **stdout** (`src/a.txt`) | `a src/a.txt` on **stderr** | `a src/a.txt` on **stderr** | |
| **`-v` on extract** | names on stdout | `x a.txt` on stderr | `x a.txt` on **stdout**; directories shown without trailing `/` (`x sub`); plus `compression format / 壓縮格式：none` on stderr | |
| **`-tv` listing** | `-rw-r--r-- raliclo/wheel 4 2020-01-02 12:34 ./b.log` | `-rw-r--r--  0 raliclo wheel 4 Jan  2  2020 ./b.log` (ls-style) | **names only** (same as `-t`), plus the compression-format line on stderr; no mode, owner, size, date or link target | |
| Self test / 自我測試 | none | none | `-test`: 16 round-trip checks against `/usr/bin/tar`, all ✓ | |

---

## 4. Summary of differences that bite / 最容易踩到的差異

1. **swift_tar ignores member names on `-x`, `-t` and `-xO`.** `swift_tar -x -f big.tar one/file`
   extracts the whole archive and exits 0; a misspelled name is not an error. Scripts
   written for GNU tar or bsdtar that extract one file will overwrite everything else
   under `-C`.
   **swift_tar 在 `-x`、`-t`、`-xO` 忽略成員名稱。** 指定單一檔案仍會解出整個封存並以 0
   結束；名稱打錯也不報錯。為 GNU tar／bsdtar 寫的「只取一個檔」腳本會覆寫 `-C` 下的其他檔案。

2. **Permissions: swift_tar defaults to `-p` and keeps setuid.** As non-root, GNU tar and
   bsdtar apply the umask and drop setuid; swift_tar restores `4755` exactly, and even
   `--no-same-permissions` keeps setuid and leaves directories at `0777`.
   **權限：swift_tar 預設即 `-p` 且保留 setuid。** 非 root 時 GNU 與 bsdtar 套用 umask 並
   去除 setuid；swift_tar 原樣還原，連 `--no-same-permissions` 都保留 setuid、目錄維持 `0777`。

3. **`--exclude` patterns are not portable.** `sub/`, `sub/*` and `other/sub` each give a
   different result in at least one tool; in swift_tar any pattern containing `/` must
   match the whole stored path.
   **`--exclude` 樣式不可攜。** `sub/`、`sub/*`、`other/sub` 在至少一個工具上結果不同；
   swift_tar 中含 `/` 的樣式必須比對完整路徑。

4. **GNU tar cannot auto-detect compression on stdin, and cannot read lz4 at all.** bsdtar
   and swift_tar detect all eight codecs tested, from a file or a pipe.
   **GNU tar 無法對 stdin 自動偵測壓縮，且完全不支援 lz4。** bsdtar 與 swift_tar 對檔案與
   管線皆能偵測八種格式。

5. **bsdtar 3.5.3 stops archiving a directory at the first unreadable file.** Everything
   after it in readdir order is missing from the archive (rc=1). GNU and swift_tar skip
   only the unreadable file.
   **bsdtar 3.5.3 遇到第一個不可讀檔案即停止該目錄的收錄**，其後的檔案全部缺漏（rc=1）。
   GNU 與 swift_tar 只略過不可讀的那一個。

6. **ISO images "succeed" empty in GNU tar and swift_tar.** Both exit 0 and list nothing,
   because the image starts with 32 KiB of zeros, which reads as end-of-archive. Only
   bsdtar reads ISO, 7z, cpio, ar, xar, mtree and warc.
   **ISO 映像在 GNU tar 與 swift_tar 上「成功」但為空**：兩者 rc=0、列不出任何東西。只有
   bsdtar 能讀 ISO、7z、cpio、ar、xar、mtree、warc。

7. **Same letter, different option.** `-n` (swift_tar: parallelism; bsdtar: no recursion;
   GNU: seek), `-o` on create (GNU: V7 format), `-s` (GNU: same-order; bsdtar: rename),
   `-L`, `-I`, `-H`, `-h` (GNU/bsdtar/swift_tar: dereference — not help). GNU also expands
   long-option prefixes, so `--cat` and `--force` mean something else there.
   **同一個字母，不同意思。** `-n`、`-o`、`-s`、`-L`、`-I`、`-H` 在各工具意義不同；GNU 還會
   展開長選項前綴，`--cat`、`--force` 在 GNU 是別的選項。

8. **Archive bytes differ by default.** GNU writes `gnu` format with names `raliclo/wheel`;
   bsdtar writes ustar; swift_tar writes ustar + pax with nanosecond mtimes, **no
   user/group names**, sorted members and no 10 KiB padding. Tools that compare archives
   byte-for-byte, or that restore ownership by name as root, will see the difference.
   **預設寫出的位元組不同。** swift_tar 寫 ustar＋pax（奈秒 mtime）、**不寫使用者／群組名稱**、
   成員排序、不補齊 10 KiB。逐位元組比對或以 root 依名稱還原擁有者時會有差異。

9. **Strict exits.** swift_tar exits non-zero for a skipped member by default, as GNU and
   bsdtar do; unlike them it also turns a case-only collision on APFS into rc=1
   (`--force` to allow), and it **creates** a missing `-C` directory where the others fail.
   **嚴格退出碼。** swift_tar 預設對略過成員回非 0（與另兩者一致）；另把 APFS 上的大小寫
   衝突視為 rc=1（`--force` 放行），而遺失的 `-C` 目錄會被**建立**，另兩者則報錯。

---

## 5. Suspected swift_tar bugs, with repro / 疑似 swift_tar 缺陷與重現步驟

All run with `/opt/homebrew/bin/swift_tar` 0.1.4 in the scratch directory.
皆以 `/opt/homebrew/bin/swift_tar` 0.1.4 於暫存目錄執行。

### Bug 1 — member-name operands ignored on `-x`, `-t`, `-xO` / 成員名稱參數被忽略

```console
$ swift_tar -cf t.tar -C src a.txt b.log sub; swift_tar -r -f t.tar -C src hard
                                                # members: a.txt b.log sub/ sub/c.txt hard
$ mkdir mf; swift_tar -x -f t.tar -C mf b.log; echo rc=$?
rc=0
$ cd mf; find . -type f
./b.log ./hard ./a.txt ./sub/c.txt              # everything, not just b.log
$ swift_tar -x -f t.tar -C mf nosuch; echo rc=$?
rc=0                                            # GNU: rc=2 "nosuch: Not found in archive"; bsdtar: rc=1
$ swift_tar -xO -f t.tar b.log
hello
log
deep
hello                                           # GNU/bsdtar print only "log"
```

### Bug 2 — `--no-same-permissions` skips directories and keeps setuid / 未套用到目錄且保留 setuid

```console
$ mkdir perm perm/d777; echo p > perm/m777; echo p > perm/m4755
$ chmod 777 perm/m777 perm/d777; chmod 4755 perm/m4755
$ gtar -cf perm.tar -C perm .
$ umask 027; mkdir r2; swift_tar -x --no-same-permissions -f perm.tar -C r2; ls -ld r2/*
drwxrwxrwx  2 raliclo  wheel  64 Oct 31 08:18 r2/d777      # GNU/bsdtar: drwxr-x---
-rwsr-x---  1 raliclo  wheel   2 Oct 31 08:18 r2/m4755     # GNU/bsdtar: -rwxr-x--- (setuid dropped)
-rwxr-x---  1 raliclo  wheel   2 Jan  2  2020 r2/m777      # agrees
```
Same result for a swift_tar-created archive. Separately, the **default** (`-p`) keeps
setuid for a non-root user, which GNU and bsdtar do only with an explicit `-p` — that
is documented, but worth knowing.
swift_tar 自己建立的封存結果相同。另外，預設（`-p`）在非 root 時也保留 setuid——此為
已文件化的行為，但值得注意。

### Bug 3 (minor) — `--delete <dir>` leaves the directory's members / 刪除目錄只刪目錄項

```console
$ swift_tar -cf d.tar -C src a.txt b.log sub; swift_tar -r -f d.tar -C src hard
$ swift_tar --delete -f d.tar sub; bsdtar -tf d.tar
a.txt b.log sub/c.txt hard                      # GNU --delete sub removes sub/c.txt as well
```
The README describes matching "by name", so this may be intended; it still differs
from GNU tar, the only other tool with `--delete`.
README 說明以「名稱」比對，可能是刻意的；但與唯一另一個有 `--delete` 的 GNU tar 不同。

### Bug 4 (minor) — `-u` compares whole seconds / `-u` 只比較到秒

```console
$ echo 1 > ux/f; touch -d 2020-01-01T00:00:00.100000000 ux/f
$ swift_tar -cf ux.tar -C ux f
$ touch -d 2020-01-01T00:00:00.900000000 ux/f
$ swift_tar -u -f ux.tar -C ux f; bsdtar -tf ux.tar
f                                               # bsdtar -u appends: "f f"
```
swift_tar stores nanosecond mtimes in the archive but does not use them for `-u`.
swift_tar 在封存中存了奈秒 mtime，`-u` 卻沒有使用。

### Minor / doc issues / 次要與文件問題

- `--help` says `-x` "refuses absolute paths"; measured, `/abs/path` is stripped to a
  relative path and extracted under `-C` with **no message** and rc=0 (the README table
  describes this correctly). GNU and bsdtar print a warning.
  `--help` 說 `-x`「拒絕絕對路徑」；實測為去掉 `/` 後解到 `-C` 之下、無任何訊息、rc=0
  （README 表格描述正確）。
- `-c` with `../x` stores `../x` without a warning, producing an archive swift_tar refuses
  to extract (rc=1). GNU strips `../` and warns.
  `-c ../x` 原樣存入 `../x` 且無警告，產生 swift_tar 自己拒絕解出的封存。
- `-debug` without `-test` reports `unknown option -d` (bundle expansion) instead of
  naming `-debug`.
  未搭配 `-test` 的 `-debug` 回報 `unknown option -d`，而非 `-debug`。
- `-c -O`, `-c -m`, `-c -p` are accepted and ignored (rc=0), although `--help` marks them
  `-x` only; `--strip-components` on `-c` is rejected. Inconsistent but harmless.
  `-c -O`、`-c -m`、`-c -p` 被接受並忽略，而 `--strip-components` 在 `-c` 會被拒絕，不一致但無害。
- `-tv` prints no long listing (mode/owner/size/date/link target), so it cannot replace
  `tar -tvf` in scripts that parse it.
  `-tv` 不印長格式，無法取代解析 `tar -tvf` 的腳本。

---

## 6. Not measured / 未量測項目

- RPM, RAR, CAB, LHA, uuencoded input: no `rpm`, `rar`, `7z` or `uuencode` fixtures
  were available on this machine; swift_tar's support is from `--help` only.
  RPM、RAR、CAB、LHA、uuencode 輸入：本機無可用工具產生測試檔，swift_tar 部分僅依 `--help`。
- lzop: neither `lzop` nor liblzo2 is installed, so no tool could create `.tar.lzo`.
  lzop：未安裝，無法產生測試檔。
- Root-only behaviour (`--same-owner`, owner restore, default `-p` for root): not run,
  per the no-`sudo` rule.
  需 root 的行為未測（不使用 `sudo`）。
- `--encrypt` with a terminal passphrase: only `--keyfile` was exercised (no tty).
  `--encrypt` 的終端機密語路徑未測，只測了 `--keyfile`。
- `-T`/`--files-from` on GNU: accepted, but the test placed `-T` before `-C`, so GNU
  resolved the names against the wrong directory; effect not confirmed.
  GNU 的 `-T`：選項被接受，但測試把 `-T` 放在 `-C` 之前，效果未確認。
- `-A`/`--catenate`, `-d`/`--diff` on GNU and bsdtar: from `--help` only.
  GNU／bsdtar 的 `-A`、`-d` 僅依說明。
- Windows-only swift_tar flags (`-write_ucrt`, `-write_foundation`): only that they are
  accepted on macOS.
  Windows 專用旗標僅確認在 macOS 上被接受。
