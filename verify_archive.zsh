#!/usr/bin/env zsh
# verify_archive.zsh <lzfse-X.Y.Z-PLATFORM.tar.zst> [PLATFORM] | --help -- check a release archive on a machine that never built it.
# verify_archive.zsh <封存> [平台] | --help —— 在一台從沒建置過它的機器上檢查正式版封存。
#   zsh verify_archive.zsh release/dist/windows-x86_64/lzfse-0.2.0-windows-x86_64.tar.zst windows-x86_64
#   zsh verify_archive.zsh --help
# Checks: the .sha256 beside it matches; the archive holds exactly one directory; the binary reports PLATFORM (when
# given); `lzfse -test` prints at least one ✓ and no ✗; other3 and bvx3 round-trip 1.3 MB of text. On Windows the
# binary runs with only System32 and the Windows directory on PATH, and the archive must hold no Swift runtime DLL.
# 檢查：旁邊的 .sha256 相符；封存裡恰好一個目錄；執行檔回報 PLATFORM（有給時）；`lzfse -test` 至少印出一個 ✓、
# 沒有任何 ✗；other3 與 bvx3 對 1.3 MB 文字往返一致。Windows 上執行檔以只含 System32 與 Windows 目錄的 PATH 執行，
# 且封存裡不得有 Swift runtime DLL。
#
# Why a second script: release.zsh verifies on the machine that built the archive, where Swift (and on Windows its
# runtime) is installed. The CI job `verify` runs this on a fresh runner with no Swift at all, which is what a
# user's machine is (modelled on csv2, whose release.zsh runs the EXTRACTED copy with a system-only PATH). It does
# not prove a Windows without the VC++ redistributable: GitHub's Windows images ship it. That case rests on the
# loader preferring the application directory -- measured 2026-11-11 with PATH=System32: the running lzfse.exe had
# loaded VCRUNTIME140, VCRUNTIME140_1 and MSVCP140 from its own directory, although System32 holds all three.
# 為何另寫一支：release.zsh 在建出封存的那台機器上驗證，那裡裝著 Swift（Windows 上還有它的 runtime）。CI 的 `verify`
# job 在一台完全沒有 Swift 的新 runner 上執行本腳本，那才是使用者的機器（仿 csv2：它的 release.zsh 以只含系統目錄的
# PATH 執行**解開後**的副本）。它證明不了「沒裝 VC++ 可轉散發套件的 Windows」：GitHub 的 Windows 映像裝了它。那個情況
# 靠的是載入器優先使用執行檔所在目錄——2026-11-11 以 PATH=System32 實測：執行中的 lzfse.exe 從自己的目錄載入了
# VCRUNTIME140、VCRUNTIME140_1 與 MSVCP140，儘管 System32 三個都有。
#
# `lzfse -test` exits 0 even when a case fails (lzfse-cli.swift runs runLZFSEv1Tests() then exit(0)), so its
# output is counted instead: each case prints "✓" or "✗ 失敗".
# `lzfse -test` 即使有案例失敗也以 0 結束（lzfse-cli.swift 執行 runLZFSEv1Tests() 後 exit(0)），所以改數它的輸出：
# 每個案例印出 "✓" 或 "✗ 失敗"。
set -euo pipefail
script_path="${0:A}"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,28p' "$script_path" | sed 's/^# \{0,1\}//'
  exit 0
fi
(( $# == 1 || $# == 2 )) || { printf 'usage: %s <archive.tar.zst> [PLATFORM]  (--help)\n' "${script_path:t}" >&2; exit 2 }

die() { printf 'FAIL: %s\n' "$@" >&2; exit 1 }
archive=${1:A}
want_platform=${2:-}
[[ -f $archive ]] || die "no such archive: $archive / 沒有這份封存：$archive"
for tool in zstd tar seq cmp; do whence -p $tool >/dev/null || die "$tool is not on PATH / PATH 上沒有 $tool"; done

# sha256: the file holds "<hex>  <name>", as release.zsh writes it. The tool falls back as release.zsh's sha256_of
# does: macOS has shasum, not sha256sum.
# sha256：檔案內容是「<hex>  <檔名>」，與 release.zsh 寫的相同。工具的後備與 release.zsh 的 sha256_of 相同：
# macOS 有 shasum 而沒有 sha256sum。
[[ -f $archive.sha256 ]] || die "no ${archive:t}.sha256 beside the archive / 封存旁沒有 .sha256"
# Two steps: in ${$(<f)%% *} the substitution is split into words first, so the file name stayed attached (measured
# 2026-11-11, the first run refused a good archive). / 分兩步：${$(<f)%% *} 會先把替換結果切成字詞，檔名因此留著
# （2026-11-11 實測，第一次執行拒絕了一份正確的封存）。
want_sum=$(<$archive.sha256)
want_sum=${want_sum%% *}
if whence -p sha256sum >/dev/null; then got_sum=$(sha256sum -- "$archive")
elif whence -p shasum >/dev/null; then got_sum=$(shasum -a 256 -- "$archive")
else got_sum=$(openssl dgst -sha256 -r "$archive"); fi
got_sum=${got_sum%% *}
[[ $got_sum =~ '^[0-9a-f]{64}$' ]] || die "the sha256 came out as [$got_sum] / sha256 算出來是 [$got_sum]"
[[ $got_sum == $want_sum ]] || die "sha256 is $got_sum, ${archive:t}.sha256 says $want_sum"
printf 'ok: sha256 %s\n' "$got_sum"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
zstd -dqc -- "$archive" | tar -xf - -C "$work"
top=( $work/*(N) )
(( ${#top} == 1 )) && [[ -d ${top[1]} ]] || die "the archive does not hold exactly one directory / 封存裡不是恰好一個目錄"
dir=${top[1]}

exe=
run_path=$PATH
case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*) exe=.exe; run_path=/c/Windows/System32:/c/Windows ;;
esac
[[ -f $dir/lzfse$exe ]] || die "the archive has no lzfse$exe / 封存裡沒有 lzfse$exe"

if [[ -n $exe ]]; then
  dlls=( $dir/*.dll(N:t) )
  for d in $dlls; do
    case ${d:l} in
      swift*.dll|foundation*.dll|_foundation*.dll|dispatch.dll|blocksruntime.dll)
        die "the archive ships the Swift runtime DLL $d; the build is not static / 封存附了 Swift runtime DLL $d，建置不是靜態的" ;;
    esac
  done
  printf 'ok: no Swift runtime DLL; bundled: %s\n' "${dlls[*]:-none}"
fi

# Run from inside the directory with relative names: on Windows lzfse.exe is a native program and gets no MSYS
# path conversion of its arguments.
# 從目錄裡以相對名稱執行：Windows 上 lzfse.exe 是原生程式，它的引數不會經過 MSYS 的路徑轉換。
run() { ( cd -- "$dir" && PATH=$run_path "./lzfse$exe" "$@" ) }

line=$(run -version | tr -d '\r') || die "lzfse -version exited non-zero / lzfse -version 以非零結束"
[[ -n $line ]] || die "lzfse -version printed nothing / lzfse -version 沒有輸出"
if [[ -n $want_platform && $line != *" $want_platform" ]]; then
  die "the binary reports [$line], not platform $want_platform / 執行檔回報 [$line]，不是 $want_platform"
fi
printf 'ok: %s\n' "$line"

run -test > "$work/selftest.txt" 2>&1 || die "lzfse -test exited non-zero / lzfse -test 以非零結束"
# `|| true`: grep -c prints 0 and exits 1 when nothing matches; that 0 is the answer, read on the next line.
# `|| true`：沒有符合時 grep -c 印出 0 並以 1 結束；那個 0 就是答案，下一行會讀它。
n_ok=$(grep -a -c '✓' "$work/selftest.txt" || true)
n_bad=$(grep -a -c '✗' "$work/selftest.txt" || true)
if (( n_bad > 0 || n_ok == 0 )); then
  # `|| true`: with n_ok == 0 there may be no ✗ line to show; the die below reports the counts either way.
  # `|| true`：n_ok == 0 時可能沒有 ✗ 行可列；下面的 die 都會回報兩個數字。
  grep -a '✗' "$work/selftest.txt" >&2 || true
  die "lzfse -test: $n_ok passed, $n_bad failed / 通過 $n_ok、失敗 $n_bad"
fi
printf 'ok: lzfse -test, %s cases, none failed\n' "$n_ok"

seq 1 200000 > "$dir/in.txt"
for algo in other3 bvx3; do
  run -encode -algo $algo -i in.txt -o in.$algo.lzfse || die "$algo encode failed / $algo 壓縮失敗"
  run -decode -algo $algo -i in.$algo.lzfse -o out.$algo.txt || die "$algo decode failed / $algo 解壓縮失敗"
  cmp -s "$dir/in.txt" "$dir/out.$algo.txt" || die "$algo round trip differs from the input / $algo 往返結果與輸入不同"
done
printf 'ok: other3 and bvx3 round trips\n'
printf 'verified / 已驗證：%s\n' "${archive:t}"
