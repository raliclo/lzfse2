#!/usr/bin/env zsh
# release.zsh | --help -- build, strip, verify and package THIS machine's lzfse release as one .tar.zst.
# release.zsh | --help —— 為**本機**的 os/arch 建置、strip、驗證並打包 lzfse 正式版成一份 .tar.zst。
#   zsh release.zsh      release/dist/<os>-<arch>/lzfse-<X.Y.Z>-<os>-<arch>.tar.zst (+ .sha256)
# Platforms: linux-{x86_64,aarch64} (static musl, needs the Swift Static Linux SDK), macos-{x86_64,arm64},
# windows-{x86_64,arm64} (MSYS2 zsh; the Swift runtime DLLs ride along). The version is VERSION; the build id is
# `git describe` of a clean tree, so on tag v<X.Y.Z> it reads `v<X.Y.Z> / <commit8>`. Every shipped executable is
# stripped (only the staged copy; release/lzfse keeps its symbols). Uploading is publish.zsh's and CI's job.
# 平台：linux-{x86_64,aarch64}（靜態 musl，需要 Swift Static Linux SDK）、macos-{x86_64,arm64}、windows-{x86_64,arm64}
# （MSYS2 zsh；Swift runtime DLL 一併帶上）。版本取自 VERSION；build id 是乾淨工作樹的 `git describe`，所以在 tag
# v<X.Y.Z> 上它是 `v<X.Y.Z> / <commit 前 8 碼>`。每個出貨的執行檔都 strip（只處理暫存區副本；release/lzfse 保留符號）。
# 上傳是 publish.zsh 與 CI 的事。
# Env: SWIFT_STATIC_SDK (Linux: the swift-linux-musl directory), SWIFT_RUNTIME_DIR (Windows: …/Runtimes/<v>/usr/bin).
# 環境變數：SWIFT_STATIC_SDK（Linux：swift-linux-musl 目錄）、SWIFT_RUNTIME_DIR（Windows：…/Runtimes/<v>/usr/bin）。

# -h / --help: print the comment block above and exit, before anything is built.
# -h／--help：在建置任何東西之前，印出上方的註解區塊後結束。
case ${1:-} in
  '') ;;
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${0:A}"; exit 0 ;;
  *) print -ru2 -- "release.zsh takes no argument (got: $1); see --help / release.zsh 不收引數（收到：$1），請見 --help"; exit 2 ;;
esac

emulate -L zsh
setopt no_unset pipe_fail err_exit

HERE=${0:A:h}
cd -- "$HERE"

# A refusal after packing removes what this run packed: a failed archive left under the release's own name is one
# upload away from being published. Only this run's file: it was checked not to exist before packing.
# 打包之後的拒絕會刪掉這次打出的東西：沒通過檢查、卻以正式名稱留著的封存，離被發布只差一次上傳。只刪這次的
# 檔案：打包前已確認它原本不存在。
PACKED=
die() {
  print -ru2 -- "$1"; [[ -z ${2:-} ]] || print -ru2 -- "$2"
  [[ -z $PACKED ]] || rm -f -- "$PACKED" "$PACKED.sha256"
  exit 1
}
TRAPZERR() {
  print -u2 -- "release.zsh: a command failed; nothing this run left in release/dist should be trusted"
  print -u2 -- "release.zsh：某個命令失敗；這次執行在 release/dist 留下的東西一律不可信"
  [[ -z ${PACKED:-} ]] || rm -f -- "$PACKED" "$PACKED.sha256"
}
sha256_of() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum -- "$1")
  elif command -v shasum >/dev/null 2>&1; then h=$(shasum -a 256 -- "$1")
  else h=$(openssl dgst -sha256 -r "$1"); fi
  h=${h%% *}
  [[ $h =~ '^[0-9a-f]{64}$' ]] || die "the sha256 of $1 came out as [$h] / $1 的 sha256 算出來是 [$h]"
  print -r -- $h
}

VERSION=$(<VERSION)
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "VERSION must hold X.Y.Z (got: $VERSION) / VERSION 必須是 X.Y.Z（收到：$VERSION）"

exe=
case $(uname -s) in
  Darwin) os=macos ;;
  Linux)  os=linux ;;
  MINGW*|MSYS*|CYGWIN*) os=windows exe=.exe ;;
  *) die "unsupported OS: $(uname -s) / 不支援的作業系統：$(uname -s)" ;;
esac
for tool in swiftc zstd tar git; do command -v $tool >/dev/null 2>&1 || die "$tool is not on PATH / PATH 上沒有 $tool"; done

# ---------------------------------------------------------------------
# Build id. A dirty tree would carry an id that names some other state.
# Build id。不乾淨的工作樹會帶著一個指向別的狀態的 id。
# ---------------------------------------------------------------------
dirty=$(git status --porcelain --untracked-files=no)
[[ -z $dirty ]] || { print -ru2 -- "$dirty"; die "the working tree is not clean; commit first" "工作樹不乾淨；請先提交"; }
commit=$(git rev-parse HEAD)
describe=$(git describe --tags --always --match 'v[0-9]*' --abbrev=12)
# On a release tag, the tag must be VERSION's: otherwise the archive says one version outside and another inside.
# 在 release tag 上，tag 必須是 VERSION 的那一個：否則封存外面寫一個版本、裡面是另一個。
# Untagged HEAD is the normal case for a branch build: describe then exits 128 with "no tag exactly matches",
# which is the answer, not an error, so that exit and message are expected here.
# 分支建置時 HEAD 沒有 tag 是常態：describe 會以 128 結束並印出 "no tag exactly matches"，那就是答案而不是錯誤，
# 所以這裡預期那個退出碼與訊息。
exact=$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)
[[ -z $exact || $exact == v$VERSION ]] || die "HEAD is tagged $exact but VERSION says $VERSION" "HEAD 的 tag 是 $exact，VERSION 卻是 $VERSION"
build_id="$describe / ${commit[1,8]}"

# ---------------------------------------------------------------------
# Compile: lzfse-cli.swift without its top-level runCLI(), plus a generated main.swift that carries the version
# and calls it. Relative paths throughout: on Windows swiftc is a native program.
# 編譯：去掉頂層 runCLI() 的 lzfse-cli.swift，加上一份帶版本並呼叫它的 main.swift。全程用相對路徑：Windows 上的
# swiftc 是原生程式。
# ---------------------------------------------------------------------
B=release/build
rm -rf -- "$B"
mkdir -p -- "$B"
# `|| true`: grep -c prints 0 and exits 1 when nothing matches; the count is checked on the next line.
# `|| true`：沒有符合時 grep -c 印出 0 並以 1 結束；計數在下一行檢查。
removed=$(grep -c '^runCLI()$' lzfse-cli.swift || true)
[[ $removed == 1 ]] || die "lzfse-cli.swift must have exactly one top-level runCLI() line (found $removed)" \
                           "lzfse-cli.swift 必須恰好有一行頂層 runCLI()（找到 $removed 行）"
grep -v '^runCLI()$' lzfse-cli.swift > "$B/lzfse-cli.swift"
cat > "$B/main.swift" <<EOF
// Generated by release.zsh; not committed. / 由 release.zsh 產生，不納入版控。
let lzfseReleaseVersion = "$VERSION"
let lzfseReleaseBuildID = "$build_id"
runCLI()
EOF

typeset -a target=()
if [[ $os == linux ]]; then
  # Every Linux release is a static musl executable, as in swift_tar and multissh: no Swift runtime and no glibc
  # needed. The SDK must match swiftc exactly, so its name comes from swiftc's own version.
  # 每份 Linux 正式版都是靜態 musl 執行檔，與 swift_tar、multissh 相同：不需要 Swift runtime，也不挑 glibc。SDK 必須
  # 與 swiftc 完全相符，所以名稱取自 swiftc 自己的版本。
  arch=$(uname -m); [[ $arch == arm64 ]] && arch=aarch64
  # With SWIFT_STATIC_SDK the sysroot is found by its own name, musl-*.sdk/<arch>, at any depth below it, since
  # the directories between a bundle and its sysroot differ between SDK releases.
  # 設定 SWIFT_STATIC_SDK 時，sysroot 以它自己的名稱 musl-*.sdk/<arch> 在其下任意深度尋找，因為 bundle 與 sysroot
  # 之間的目錄層次隨 SDK 版本不同。
  typeset -a sysroots=()
  if [[ -n ${SWIFT_STATIC_SDK:-} ]]; then
    sysroots=( $SWIFT_STATIC_SDK/**/musl-*.sdk/$arch(N/) )
  else
    swift_ver=$(swiftc --version 2>&1 | sed -n 's/.*(swift-\([0-9][0-9.]*\)-RELEASE).*/\1/p' | head -1)
    [[ -n $swift_ver ]] || die "cannot read a release version from swiftc --version / 讀不出 swiftc 的版本"
    [[ $swift_ver == *.*.* ]] || swift_ver=$swift_ver.0
    # Ask SwiftPM where it installed the SDK rather than guess a directory: in the CI container it was not under
    # $HOME at all (CI run 41818672332), as SwiftPM takes the home directory from the user account, not $HOME.
    # 直接問 SwiftPM 把 SDK 裝在哪，而不是猜目錄：在 CI 容器裡它根本不在 $HOME 底下（CI 執行 41818672332），因為
    # SwiftPM 的家目錄取自使用者帳號，而不是 $HOME。
    sdk_id=$(swift sdk list | grep -x "swift-$swift_ver-RELEASE_static-linux-[0-9.]*" | head -1)
    [[ -n $sdk_id ]] || die "no Static Linux SDK for Swift $swift_ver in swift sdk list; install it (swift sdk install) or set SWIFT_STATIC_SDK" \
                            "swift sdk list 裡沒有 Swift $swift_ver 的 Static Linux SDK；請安裝（swift sdk install）或設定 SWIFT_STATIC_SDK"
    root=$(swift sdk configure --show-configuration "$sdk_id" "$arch-swift-linux-musl" | sed -n 's/^sdkRootPath: //p')
    [[ -d $root ]] && sysroots=( $root )
  fi
  (( ${#sysroots} == 1 )) || die "need exactly one Static Linux SDK sysroot musl-*.sdk/$arch for swiftc ${swift_ver:-}, found ${#sysroots}: ${sysroots[*]}; install it (swift sdk install) or set SWIFT_STATIC_SDK" \
                                 "需要恰好一個 musl-*.sdk/$arch（swiftc ${swift_ver:-}），找到 ${#sysroots} 個：${sysroots[*]}；請安裝（swift sdk install）或設定 SWIFT_STATIC_SDK"
  sysroot=${sysroots[1]}
  target=(-target $arch-swift-linux-musl -sdk "$sysroot" -resource-dir "$sysroot/usr/lib/swift_static"
          -static-executable -static-stdlib
          -Xclang-linker -resource-dir -Xclang-linker "$sysroot/usr/lib/swift/clang")
fi
print -r -- "building lzfse $VERSION ($build_id) / 建置中"
swiftc -O -wmo -swift-version 6 -D LZFSE_RELEASE "${target[@]}" "$B/lzfse-cli.swift" "$B/main.swift" -o "release/lzfse$exe"

# The name comes from what the BINARY says, never from this script: an archive named from anywhere else can carry
# one version on the outside and another inside. A Windows binary ends the line with CR.
# 名稱取自**執行檔**自己說的，不取自本腳本：從別處取名的封存，外面寫一個版本、裡面可能是另一個。Windows 執行檔
# 的輸出行以 CR 結尾。
line=$("release/lzfse$exe" -version | tr -d '\r')
plat=${line##* }
[[ $line == "lzfse $VERSION ($build_id) $plat" && $plat == $os-* && $plat != *unknown* ]] \
  || die "release/lzfse$exe reports [$line], expected [lzfse $VERSION ($build_id) $os-<arch>]" \
         "release/lzfse$exe 回報 [$line]，預期 [lzfse $VERSION ($build_id) $os-<arch>]"
if [[ $os == linux ]]; then
  ! readelf -lW "release/lzfse" | grep -q 'program interpreter' && ! readelf -dW "release/lzfse" | grep -q NEEDED \
    || die "release/lzfse is not a static executable / release/lzfse 不是靜態執行檔"
fi

# ---------------------------------------------------------------------
# Stage: one top-level directory, so extracting cannot scatter files into the caller's cwd.
# 暫存：只有一個頂層目錄，解開時不會把檔案灑進呼叫端的目前目錄。
# ---------------------------------------------------------------------
stem=lzfse-$VERSION-$plat
out=release/dist/$plat
archive=$out/$stem.tar.zst
mkdir -p -- "$out"
[[ ! -e $archive ]] || die "$archive already exists; remove it first if you mean to replace it" \
                           "$archive 已經存在；若真要取代它，請先自行刪除"
stage=$out/$stem
rm -rf -- "$stage"
mkdir -p -- "$stage"
cp -- "release/lzfse$exe" "$stage/"
cp -- LICENSE README.md README.zh-TW.md "$stage/"

# Strip the staged copy. macOS: strip invalidates the linker's ad-hoc signature and an arm64 binary without a
# valid one is killed on launch, so it is signed again. The Swift runtime DLLs are not ours and ship as they come.
# strip 暫存區的副本。macOS：strip 會讓連結器的 ad-hoc 簽章失效，沒有有效簽章的 arm64 執行檔一啟動就被終止，
# 所以重新簽章。Swift runtime DLL 不是我們的，照原樣出貨。
staged=$stage/lzfse$exe
case $os in
  macos)   strip "$staged" && codesign -s - -f "$staged" ;;
  linux)   strip --strip-all "$staged" ;;
  windows) command -v llvm-strip >/dev/null 2>&1 || die "llvm-strip is not on PATH / PATH 上沒有 llvm-strip"
           llvm-strip --strip-all "$staged" ;;
esac
print -r -- "stripped / 已 strip：$(wc -c < "release/lzfse$exe" | tr -d ' ') -> $(wc -c < "$staged" | tr -d ' ') bytes"

if [[ $os == windows ]]; then
  # The Swift runtime DLLs, resolved transitively from the PE imports: lzfse.exe imports Foundation.dll, which in
  # turn pulls in FoundationEssentials, _FoundationICU, dispatch and more that a one-level scan never sees. Only
  # what the runtime directory provides ships; everything else is a Windows system DLL.
  # Swift runtime DLL，順著 PE import 遞移解析：lzfse.exe 匯入 Foundation.dll，它又拉進 FoundationEssentials、
  # _FoundationICU、dispatch 等單層掃描看不到的 DLL。只帶 runtime 目錄裡有的；其餘都是 Windows 系統 DLL。
  rt=${SWIFT_RUNTIME_DIR:-}
  if [[ -z $rt ]]; then
    swift_root=${$(command -v swiftc):h}; swift_root=${swift_root%/Toolchains/*}
    rt=( $swift_root/Runtimes/*/usr/bin(N/On) ); rt=${rt[1]:-}
  fi
  [[ -n $rt && -f $rt/swiftCore.dll ]] || die "no Swift runtime (swiftCore.dll); set SWIFT_RUNTIME_DIR" "找不到 Swift runtime（swiftCore.dll）；請設定 SWIFT_RUNTIME_DIR"
  # `|| true`: neither tool present is answered by the die on the next line, with a message that names them.
  # `|| true`：兩個工具都不在時，由下一行的 die 以點名它們的訊息回答。
  objdump_bin=$(command -v llvm-objdump || command -v objdump || true)
  [[ -n $objdump_bin ]] || die "no llvm-objdump or objdump on PATH / PATH 上沒有 llvm-objdump 或 objdump"
  typeset -A seen=()
  typeset -a queue=("release/lzfse.exe")
  while (( ${#queue} )); do
    current=${queue[1]}; shift queue
    deps=$("$objdump_bin" -p "$current" | awk '/DLL Name:/ { print $3 }')
    for dep in ${(f)deps}; do
      [[ -n $dep && -z ${seen[$dep]:-} && -f $rt/$dep ]] || continue
      seen[$dep]=1
      cp -- "$rt/$dep" "$stage/"
      queue+=("$rt/$dep")
    done
  done
  [[ -n ${seen[swiftCore.dll]:-} ]] || die "the PE imports of lzfse.exe never reach swiftCore.dll in $rt" \
                                           "lzfse.exe 的 PE import 一路下來都沒有用到 $rt 裡的 swiftCore.dll"
  print -r -- "bundled Swift runtime DLLs / 已收錄 Swift runtime DLL：${#seen}"
fi

# ---------------------------------------------------------------------
# Verify the STRIPPED copy, from inside the stage: it reports what release/ reports and round-trips data with
# both engines, so a strip that broke it fails here rather than on a user's machine. On Windows it runs with only
# the system directories on PATH, so every DLL it loads must come from the stage itself.
# 驗證 **strip 後**的副本，從暫存區裡執行：它回報的與 release/ 相同，且兩種引擎都能完成往返，所以 strip 若弄壞了
# 它，會在這裡失敗而不是在使用者的機器上。Windows 上以只含系統目錄的 PATH 執行，它載入的每個 DLL 都必須來自暫存區。
# ---------------------------------------------------------------------
run_path=$PATH
[[ $os == windows ]] && run_path=/c/Windows/System32:/c/Windows
got=$(cd -- "$stage" && PATH=$run_path "./lzfse$exe" -version | tr -d '\r')
[[ $got == "$line" ]] || die "the stripped copy reports [$got], release/ reports [$line]" "strip 後的副本回報 [$got]，release/ 回報 [$line]"
probe=$B/probe
mkdir -p -- "$probe"
seq 1 200000 > "$probe/in.txt"
for algo in other3 bvx3; do
  ( cd -- "$probe" && PATH=$run_path "../../../$staged" -encode -algo $algo -i in.txt -o in.$algo.lzfse \
                   && PATH=$run_path "../../../$staged" -decode -algo $algo -i in.$algo.lzfse -o out.$algo.txt ) \
    || die "the stripped copy failed to encode/decode with $algo" "strip 後的副本無法以 $algo 壓縮／解壓縮"
  cmp -s "$probe/in.txt" "$probe/out.$algo.txt" || die "$algo round trip differs from the input" "$algo 往返結果與輸入不同"
done
print -r -- "verified the stripped copy: -version, other3 and bvx3 round trips / 已驗證 strip 後的副本：-version、other3 與 bvx3 往返"

# ---------------------------------------------------------------------
# Pack, then extract and compare. macOS's bsdtar stores xattrs/ACLs/flags as pax headers by default, which other
# tars report as unknown keywords, so those are turned off there.
# 打包，再解開比對。macOS 的 bsdtar 預設把 xattr／ACL／flags 存成 pax 標頭，別的 tar 會報不認得的關鍵字，所以在
# 那裡關掉。
# ---------------------------------------------------------------------
typeset -a tar_opts=()
[[ $os == macos ]] && tar_opts=(--no-mac-metadata --no-xattrs --no-acls --no-fflags)
PACKED=$archive
( cd -- "$out" && COPYFILE_DISABLE=1 tar "${tar_opts[@]}" -cf - "$stem" | zstd -19 -q -o "$stem.tar.zst" )
check=$B/extract
mkdir -p -- "$check"
zstd -dqc -- "$archive" | tar -xf - -C "$check"
top=( $check/*(N) )
(( ${#top} == 1 )) && [[ ${top[1]:t} == $stem ]] || die "the archive does not hold exactly one directory $stem" "封存裡不是恰好一個 $stem 目錄"
cmp -s "$check/$stem/lzfse$exe" "$staged" || die "the extracted binary differs from the verified one" "解開後的執行檔與驗證過的不同"
rm -rf -- "$stage"
print -r -- "$(sha256_of "$archive")  $stem.tar.zst" > "$archive.sha256"

print -r -- "$archive"
cat -- "$archive.sha256"
print -r -- "$line"
