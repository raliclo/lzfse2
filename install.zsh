#!/usr/bin/env zsh
# install.zsh [<X.Y.Z>] [--prefix DIR] [--musl] | --help -- install an lzfse release for this os/arch from GitHub.
# install.zsh [<X.Y.Z>] [--prefix DIR] [--musl] | --help —— 從 GitHub 下載並安裝符合本機 os/arch 的 lzfse release。
#   zsh install.zsh                     the latest release into ~/.local/bin / 最新 release 裝到 ~/.local/bin
#   zsh install.zsh 0.2.0               release v0.2.0 / 指定 v0.2.0
#   zsh install.zsh --prefix /usr/local into /usr/local/bin / 裝到 /usr/local/bin
#   zsh install.zsh --musl              accepted and ignored: Linux is always the static musl build
#                                       接受但不作用：Linux 一律是靜態 musl 版
# Picks lzfse-<version>-<plat>.tar.zst for linux-{x86_64,aarch64}-musl (fully static; Linux ships musl only, as
# swift_tar), macos-{x86_64,arm64} or windows-{x86_64,arm64}, checks it against its .sha256, and copies lzfse (and, on
# Windows, the Swift runtime DLLs) into <prefix>/bin. No Swift is needed. The executables are stripped.
# 依 linux-{x86_64,aarch64}-musl（完全靜態；Linux 只出 musl 版，與 swift_tar 相同）、macos-{x86_64,arm64} 或
# windows-{x86_64,arm64} 挑選 lzfse-<版本>-<平台>.tar.zst，以其 .sha256 驗證，再把 lzfse（Windows 上連同 Swift runtime
# DLL）複製到 <prefix>/bin。不需要 Swift。執行檔皆已 strip。
# Needs curl, zstd and tar on PATH; the repository is public, so no login is needed.
# 需要 PATH 上有 curl、zstd 與 tar；本 repository 是 public，不需要登入。

# -h / --help: print the comment block above and exit; skipped when sourced.
# -h／--help：印出上方的註解區塊後結束；被 source 時略過。
if [[ $ZSH_EVAL_CONTEXT == toplevel && ( ${1:-} == -h || ${1:-} == --help ) ]]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${0:A}"
  exit 0
fi

emulate -L zsh
setopt no_unset pipe_fail err_exit

REPO=raliclo/lzfse2
die() { print -u2 -r -- "$1"; [[ -n ${2:-} ]] && print -u2 -r -- "$2"; exit 1 }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 -- "$1" | cut -d' ' -f1
  else openssl dgst -sha256 -r "$1" | cut -d' ' -f1; fi
}

VERSION= prefix=$HOME/.local musl=0
while (( $# )); do
  case $1 in
    # Kept so earlier calls still work; Linux is musl either way.
    # 保留，讓先前的呼叫照常可用；Linux 無論如何都是 musl。
    --musl) musl=1 ;;
    --prefix) (( $# >= 2 )) || die "--prefix needs a directory / --prefix 需要目錄"; prefix=$2; shift ;;
    [0-9]*) [[ $1 =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "the version must be X.Y.Z (got: $1) / 版本必須是 X.Y.Z（收到：$1）"
            VERSION=$1 ;;
    *) die "unknown argument: $1 (see --help) / 未知的引數：$1（見 --help）" ;;
  esac
  shift
done

for tool in curl zstd tar; do command -v $tool >/dev/null 2>&1 || die "$tool is not on PATH / PATH 上沒有 $tool"; done

# The OS from uname -s; the arch on Windows from the processor the OS reports, because an x64-emulated MSYS2 shell
# on arm64 says x86_64 in uname -m.
# OS 取自 uname -s；Windows 的架構取自作業系統回報的處理器，因為 arm64 上以 x64 模擬的 MSYS2 shell，uname -m 會說 x86_64。
exe=
case $(uname -s) in
  Darwin) os=macos; arch=$(uname -m)
          # Rosetta: an x86_64 shell on Apple silicon still wants the arm64 build.
          # Rosetta：Apple silicon 上的 x86_64 shell 仍應安裝 arm64 版本。
          # The key does not exist on Intel Macs, so its error there is expected. / Intel Mac 沒有這個鍵，那裡的錯誤是預期的。
          [[ $(sysctl -n sysctl.proc_translated 2>/dev/null) == 1 ]] && arch=arm64 ;;
  Linux)  os=linux; arch=$(uname -m) ;;
  MINGW*|MSYS*|CYGWIN*)
          os=windows exe=.exe
          arch=$(powershell.exe -NoProfile -Command '[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture' | tr -d '\r') ;;
  *) die "unsupported OS: $(uname -s) / 不支援的作業系統：$(uname -s)" ;;
esac
case $os-$arch in
  linux-x86_64|linux-amd64)   plat=linux-x86_64-musl ;;
  linux-aarch64|linux-arm64)  plat=linux-aarch64-musl ;;
  macos-x86_64)               plat=macos-x86_64 ;;
  macos-arm64)                plat=macos-arm64 ;;
  windows-X64|windows-x86_64) plat=windows-x86_64 ;;
  windows-Arm64|windows-arm64) plat=windows-arm64 ;;
  *) die "no release for $os-$arch (x86-32 is not built; Swift has no toolchain for it)" \
         "沒有 $os-$arch 的 release（不建 x86-32；Swift 沒有它的工具鏈）" ;;
esac
[[ $os == linux ]] || (( ! musl )) || die "--musl is for Linux only / --musl 只適用於 Linux"

# The latest release: GitHub redirects /releases/latest to /releases/tag/v<X.Y.Z>.
# 最新 release：GitHub 會把 /releases/latest 轉址到 /releases/tag/v<X.Y.Z>。
if [[ -z $VERSION ]]; then
  url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
    || die "cannot reach https://github.com/$REPO/releases/latest / 連不到 https://github.com/$REPO/releases/latest"
  VERSION=${url##*/tag/v}
  [[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "no release found in $REPO (got: $url) / $REPO 沒有任何 release（得到：$url）"
fi
base=lzfse-$VERSION-$plat.tar.zst
stem=${base%.tar.zst}
print -r -- "lzfse $VERSION for $plat -> $prefix/bin / 安裝 lzfse $VERSION（$plat）到 $prefix/bin"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lzfse-install.XXXXXX")
trap 'rm -rf -- "${tmp:?}"' EXIT
for f in $base $base.sha256; do
  curl -fsSL -o "$tmp/$f" "https://github.com/$REPO/releases/download/v$VERSION/$f" \
    || die "cannot download $f from v$VERSION / 無法從 v$VERSION 下載 $f"
done
h=$(sha256_of "$tmp/$base")
[[ $h == $(cut -d' ' -f1 < "$tmp/$base.sha256") ]] || die "$base: sha256 $h does not match its .sha256" "$base：sha256 $h 與 .sha256 不符"
zstd -dqc -- "$tmp/$base" | tar -xf - -C "$tmp"
[[ -x $tmp/$stem/lzfse$exe ]] || die "$base has no $stem/lzfse$exe / $base 裡沒有 $stem/lzfse$exe"

mkdir -p -- "$prefix/bin"
cp -f -- "$tmp/$stem/lzfse$exe" $tmp/$stem/*.dll(N) "$prefix/bin/"
line=$("$prefix/bin/lzfse$exe" -version | tr -d '\r')
[[ $line == "lzfse $VERSION "* ]] || die "the installed lzfse reports [$line], not $VERSION" "安裝的 lzfse 回報 [$line]，不是 $VERSION"
print -r -- "$line"
[[ ":$PATH:" == *":$prefix/bin:"* ]] || print -r -- "Add $prefix/bin to PATH. / 請把 $prefix/bin 加入 PATH。"
