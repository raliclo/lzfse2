#!/usr/bin/env zsh
# Put the newest installed Swift for Windows on PATH, with its runtime and SDK. Source this.
# 把最新安裝的 Swift for Windows 連同其 runtime 與 SDK 放進 PATH。以 source 引入。
#
# Usage / 用法:
#   source "$root/helper_windows/swift_windows_env.zsh"   (release.zsh, helper_windows/build-cli-win.zsh)
#   zsh helper_windows/swift_windows_env.zsh --help
#
# Picks the newest toolchain under %LOCALAPPDATA%\Programs\Swift\Toolchains that
# has a runtime of the same version, drops every other Swift Toolchains/Runtimes
# entry from PATH, puts the chosen two first, and points SDKROOT at that version's
# Windows SDK. On success swift_windows_version, swift_windows_toolchain_bin and
# swift_windows_runtime_bin are left set for the caller. Does nothing off Windows,
# or when no matching pair is installed (PATH is then left as the caller had it).
# 在 %LOCALAPPDATA%\Programs\Swift\Toolchains 底下挑出「有相同版本 runtime」的最新工具鏈，
# 從 PATH 移除其他所有 Swift Toolchains/Runtimes 項目，把選中的兩個放到最前面，並讓 SDKROOT
# 指向該版本的 Windows SDK。成功時留下 swift_windows_version、swift_windows_toolchain_bin、
# swift_windows_runtime_bin 給呼叫者。不在 Windows 上、或找不到相配的組合時，什麼都不做。
#
# Why (2026-11-06): Swift went 6.4.1 -> 6.4.2 and the installer deleted 6.4.1; shells
# opened before that still held 6.4.1 in PATH and SDKROOT. build-cli-win.zsh took the
# runtime from `find Runtimes | head -1` and release.zsh from a name-sorted glob, so
# with two runtimes installed either could pick an older one than the swiftc that
# compiled (6.10.0 sorts before 6.4.2 by name). Ported from multissh's
# helper/swift_windows_env.zsh (1b56e5a, 80fd1c8), as swift-cross-ui did the same day.
# 為什麼（2026-11-06）：Swift 由 6.4.1 升到 6.4.2，安裝程式刪掉了 6.4.1；在那之前開的 shell
# 的 PATH 與 SDKROOT 仍指向 6.4.1。build-cli-win.zsh 以 `find Runtimes | head -1` 取 runtime，
# release.zsh 以依名稱排序的 glob 取，因此裝了兩版 runtime 時，兩者都可能挑到比編譯用的
# swiftc 舊的那一版（依名稱排序 6.10.0 會排在 6.4.2 前面）。移植自 multissh 的
# helper/swift_windows_env.zsh（1b56e5a、80fd1c8），swift-cross-ui 同日也做了同樣的移植。

if [[ $ZSH_EVAL_CONTEXT == toplevel && ( ${1:-} == -h || ${1:-} == --help ) ]]; then
  sed -n '2,30p' "${0:A}" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ $(uname -s) == *NT* ]]; then
  swift_windows_base="$(cygpath -u "${LOCALAPPDATA:-C:\\Users\\${USERNAME}\\AppData\\Local}")/Programs/Swift"
  # Numeric sort (glob qualifier n): 6.10.0 sorts after 6.4.2. Newest is tried first.
  # 數值排序（glob 限定詞 n）：6.10.0 排在 6.4.2 之後。先試最新的。
  typeset -a swift_windows_toolchains
  swift_windows_toolchains=("$swift_windows_base"/Toolchains/*(N/n))
  swift_windows_version=''
  for swift_windows_candidate in "${(Oa)swift_windows_toolchains[@]}"; do
    swift_windows_candidate_version=${${swift_windows_candidate:t}%%+*}
    if [[ -d $swift_windows_base/Runtimes/$swift_windows_candidate_version/usr/bin &&
          -d $swift_windows_candidate/usr/bin ]]; then
      swift_windows_version=$swift_windows_candidate_version
      swift_windows_toolchain_bin=$swift_windows_candidate/usr/bin
      break
    fi
  done
  if [[ -n $swift_windows_version ]]; then
    swift_windows_runtime_bin=$swift_windows_base/Runtimes/$swift_windows_version/usr/bin
    # Drop the other Swift entries in both spellings: a deleted version is dead
    # weight, and an older one still installed would load mismatched DLLs.
    # 兩種路徑寫法的其他 Swift 項目都移除：已刪除的版本是累贅，仍安裝著的舊版會載入不相符的 DLL。
    path=(${path:#*/Programs/Swift/(Runtimes|Toolchains)/*})
    path=(${path:#*\\Programs\\Swift\\(Runtimes|Toolchains)\\*})
    path=("$swift_windows_runtime_bin" "$swift_windows_toolchain_bin" $path)
    export PATH
    swift_windows_sdk=$swift_windows_base/Platforms/$swift_windows_version/Windows.platform/Developer/SDKs/Windows.sdk
    if [[ -d $swift_windows_sdk ]]; then
      export SDKROOT="$(cygpath -w "$swift_windows_sdk")\\"
    fi
  fi
  unset swift_windows_candidate swift_windows_candidate_version swift_windows_toolchains
fi
