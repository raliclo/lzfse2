#!/usr/bin/env zsh
# publish.zsh --local | --github <X.Y.Z> [--yes] | --help -- build or publish an lzfse release for every os/arch.
# publish.zsh --local | --github <X.Y.Z> [--yes] | --help —— 建置或發布涵蓋所有 os/arch 的 lzfse release。
#   zsh publish.zsh --local          build, strip, verify and package THIS machine's os/arch (release.zsh); no upload
#                                    建置、strip、驗證並打包**本機**的 os/arch（release.zsh）；不上傳
#   zsh publish.zsh --github 0.2.0   formal: VERSION must say 0.2.0; ask, push tag v0.2.0, let CI
#                                    (.github/workflows/release.yml) build all six targets and create the release, wait
#                                    for it, download and verify every asset, then rewrite bucket/lzfse.json, commit, push
#                                    正式：VERSION 必須是 0.2.0；詢問後推送 tag v0.2.0，由 CI（.github/workflows/release.yml）
#                                    建置全部六個目標並建立 release，等它完成，下載並驗證每個資產，再改寫
#                                    bucket/lzfse.json、提交並推送
#   --yes   (--github) do not ask / 不詢問
# Targets: {linux,macos,windows} x {x86_64,arm64}; Linux arm64 is named linux-aarch64 (uname -m).
# 目標：{linux,macos,windows} x {x86_64,arm64}；Linux arm64 命名為 linux-aarch64（uname -m）。
# Install: zsh install.zsh [<X.Y.Z>], or scoop install raliclo/lzfse. / 安裝：zsh install.zsh [<版本>]，或 scoop。

# -h / --help: print the comment block above and exit; skipped when sourced.
# -h／--help：印出上方的註解區塊後結束；被 source 時略過。
if [[ $ZSH_EVAL_CONTEXT == toplevel && ( ${1:-} == -h || ${1:-} == --help ) ]]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${0:A}"
  exit 0
fi

emulate -L zsh
setopt no_unset pipe_fail err_exit

HERE=${0:A:h}
cd -- "$HERE"

REPO=raliclo/lzfse2
WORKFLOW=release.yml
PLATFORMS=(linux-x86_64 linux-aarch64 macos-x86_64 macos-arm64 windows-x86_64 windows-arm64)

say() { print -r -- "$1" }
die() { print -u2 -r -- "$1"; [[ -n ${2:-} ]] && print -u2 -r -- "$2"; exit 1 }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 -- "$1" | cut -d' ' -f1
  else openssl dgst -sha256 -r "$1" | cut -d' ' -f1; fi
}

MODE= VERSION= yes=0
for arg in "$@"; do
  case $arg in
    --local|--github) [[ -z $MODE ]] || die "one mode at a time / 一次只能一種模式"; MODE=${arg#--} ;;
    --yes) yes=1 ;;
    [0-9]*) [[ $arg =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "the version must be X.Y.Z (got: $arg) / 版本必須是 X.Y.Z（收到：$arg）"
            VERSION=$arg ;;
    *) die "unknown argument: $arg (see --help) / 未知的引數：$arg（見 --help）" ;;
  esac
done
[[ -n $MODE ]] || die "usage: zsh publish.zsh --local|--github <X.Y.Z> (see --help)" "用法：zsh publish.zsh --local|--github <版本>（見 --help）"
[[ $MODE == local || -n $VERSION ]] || die "--github needs a version, e.g. 0.2.0 / --github 需要版本號，例如 0.2.0"
command -v zstd >/dev/null 2>&1 || die "zstd is not on PATH / PATH 上沒有 zstd"

# ---------------------------------------------------------------------
# --local: this machine only. Nothing leaves it.
# --local：只有本機。不會有任何東西離開這台機器。
# ---------------------------------------------------------------------
if [[ $MODE == local ]]; then
  zsh release.zsh
  say ""
  say "--github <X.Y.Z> would: push tag v<X.Y.Z>; CI builds ${PLATFORMS[*]}; create the release; verify every asset; rewrite bucket/lzfse.json"
  say "--github <X.Y.Z> 會：推送 tag v<X.Y.Z>；CI 建置 ${PLATFORMS[*]}；建立 release；驗證每個資產；改寫 bucket/lzfse.json"
  say "Nothing was uploaded. / 沒有上傳任何東西。"
  exit 0
fi

TAG=v$VERSION
# ---------------------------------------------------------------------
# --github 1. Refuse before anything outward-facing.
# --github 1. 在任何對外動作之前先拒絕。
# ---------------------------------------------------------------------
[[ $(<VERSION) == $VERSION ]] || die "VERSION says $(<VERSION), not $VERSION; commit the new VERSION first" \
                                     "VERSION 是 $(<VERSION)，不是 $VERSION；請先提交新的 VERSION"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "the working tree is not clean; a tag would name a state nobody can fetch" \
                                                                 "工作樹不乾淨；tag 會指向一個沒有人抓得到的狀態"
command -v gh >/dev/null 2>&1 || die "gh is not on PATH / PATH 上沒有 gh"
# REST calls only (gh api), here and below: they work wherever gh can reach GitHub, while gh auth status and
# gh release view (GraphQL) fail behind a proxy that holds the token, as in a Claude Code cloud session.
# 這裡與下方只用 REST（gh api）：只要 gh 連得到 GitHub 就能用；gh auth status 與 gh release view（GraphQL）在代管
# token 的 proxy 後面會失敗，例如 Claude Code 雲端 session。
gh api "repos/$REPO" >/dev/null || die "gh cannot reach $REPO; run gh auth login / gh 連不到 $REPO；請執行 gh auth login"
git fetch -q --tags origin
[[ -z "$(git rev-list @{upstream}..HEAD)" ]] || die "HEAD is ahead of origin; git push first" "HEAD 領先 origin；請先 git push"

HEAD_SHA=$(git rev-parse HEAD) TAG_SHA=
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && TAG_SHA=$(git rev-parse "$TAG^{commit}")
# HEAD may be past an existing tag only by the bucket commit a previous run left.
# HEAD 只可以因為上一次執行留下的 bucket commit 而越過既有的 tag。
if [[ -n $TAG_SHA && $TAG_SHA != $HEAD_SHA ]]; then
  # `|| true`: grep -v exits 1 when every changed path is under bucket/, which is the allowed case.
  # `|| true`：所有變更都在 bucket/ 底下時 grep -v 以 1 結束，那正是允許的情況。
  extra=$(git diff --name-only "$TAG_SHA" HEAD | grep -v '^bucket/' || true)
  [[ -z $extra ]] || die "$TAG exists at ${TAG_SHA[1,8]} and HEAD has other changes past it: ${extra//$'\n'/ }" \
                         "$TAG 已存在於 ${TAG_SHA[1,8]}，且 HEAD 之後有其他變更：${extra//$'\n'/ }"
fi
released=0
# A 404 here means "not released yet", the expected answer on a first run, so its message is not shown.
# 這裡的 404 代表「尚未發布」，是第一次執行時預期的答案，所以不顯示它的訊息。
gh api "repos/$REPO/releases/tags/$TAG" >/dev/null 2>&1 && released=1

say "lzfse $VERSION as $TAG in $REPO / 將 lzfse $VERSION 以 $TAG 發布到 $REPO"
say "  HEAD : ${HEAD_SHA[1,8]}"
if (( released )); then
  say "  $TAG is already released: verify it and rewrite bucket/lzfse.json / 已發布：只驗證並改寫 bucket/lzfse.json"
else
  say "  CI builds / CI 建置：${PLATFORMS[*]}"
fi
if (( ! yes )); then
  printf '%s' "Go on? / 要繼續嗎？[y/N] "
  read -r answer
  [[ $answer == (y|Y) ]] || { say "Nothing was changed. / 什麼都沒有改動。"; exit 0 }
fi

# ---------------------------------------------------------------------
# --github 2. Tag, then wait for the CI run the tag push started.
# --github 2. 打 tag，再等那次 tag 推送所啟動的 CI。
# ---------------------------------------------------------------------
if (( ! released )); then
  if [[ -z $TAG_SHA ]]; then
    git tag -a "$TAG" -m "lzfse $VERSION"
    TAG_SHA=$HEAD_SHA
  fi
  git push -q origin "$TAG"
  say "  pushed / 已推送：$TAG"
  run_id=
  for i in {1..30}; do
    run_id=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --branch "$TAG" --limit 1 --json databaseId -q '.[0].databaseId // empty')
    [[ -n $run_id ]] && break
    sleep 5
  done
  [[ -n $run_id ]] || die "no $WORKFLOW run for $TAG after 150 s; see https://github.com/$REPO/actions" \
                          "150 秒後仍沒有 $TAG 的 $WORKFLOW 執行；請看 https://github.com/$REPO/actions"
  say "  waiting for CI / 等待 CI：https://github.com/$REPO/actions/runs/$run_id"
  gh run watch "$run_id" -R "$REPO" --exit-status --interval 30 >/dev/null || \
    die "CI failed: https://github.com/$REPO/actions/runs/$run_id; fix, delete the tag and re-run" \
        "CI 失敗：https://github.com/$REPO/actions/runs/$run_id；修正後刪除 tag 再執行"
fi

# ---------------------------------------------------------------------
# --github 3. Download every asset from the public URL an installer uses, and verify it against the tag: its
#    .sha256 agrees, it holds one directory with the executable, and that executable carries
#    `lzfse <X.Y.Z> (v<X.Y.Z> / <commit8>)` for the tag's commit.
# --github 3. 從安裝者會用的公開網址下載每個資產並對照 tag 驗證：.sha256 相符、裡面是一個含執行檔的目錄，且該執行檔
#    帶著 tag 那個 commit 的 `lzfse <X.Y.Z> (v<X.Y.Z> / <commit 前 8 碼>)`。
# ---------------------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lzfse-publish.XXXXXX")
trap 'rm -rf -- "${tmp:?}"' EXIT
typeset -A HASH URL
want_id="lzfse $VERSION ($TAG / ${TAG_SHA[1,8]})"
say "  archives / 封存："
for plat in $PLATFORMS; do
  exe=; [[ $plat == windows-* ]] && exe=.exe
  base=lzfse-$VERSION-$plat.tar.zst stem=lzfse-$VERSION-$plat
  URL[$plat]=https://github.com/$REPO/releases/download/$TAG/$base
  curl -fsSL -o "$tmp/$base" "$URL[$plat]" && curl -fsSL -o "$tmp/$base.sha256" "$URL[$plat].sha256" \
    || die "cannot download $URL[$plat] / 無法下載 $URL[$plat]"
  HASH[$plat]=$(sha256_of "$tmp/$base")
  [[ $HASH[$plat] == $(cut -d' ' -f1 < "$tmp/$base.sha256") ]] || die "$base: .sha256 disagrees with $HASH[$plat]" "$base：.sha256 與 $HASH[$plat] 不符"
  mkdir -p -- "$tmp/$plat"
  zstd -dqc -- "$tmp/$base" | tar -xf - -C "$tmp/$plat"
  [[ -f $tmp/$plat/$stem/lzfse$exe ]] || die "$base has no $stem/lzfse$exe / $base 裡沒有 $stem/lzfse$exe"
  # `grep -a`: without it a binary yields one "Binary file matches" line. `|| true`: a count of zero exits 1 and is
  # answered by the die below.
  # `grep -a`：少了它，二進位檔只會得到一行「Binary file matches」。`|| true`：計數為零時以 1 結束，由下方的 die 回答。
  hits=$(LC_ALL=C grep -a -c -F -- "($TAG / ${TAG_SHA[1,8]})" "$tmp/$plat/$stem/lzfse$exe" || true)
  [[ $hits != 0 ]] || die "$base does not carry [$want_id]; built from another commit?" "$base 裡沒有 [$want_id]；是從別的 commit 建的嗎？"
  say "    $base  $HASH[$plat]"
done

# ---------------------------------------------------------------------
# --github 4. The scoop manifest, GENERATED whole from the values above rather than edited in place, then read back.
# --github 4. scoop manifest，整份由上面的值**產生**而不是就地修改，然後讀回確認。
# ---------------------------------------------------------------------
cat > bucket/lzfse.json <<EOF
{
    "version": "$VERSION",
    "description": "Multi-core LZFSE/LZFSE2 compression CLI (other3/bvx3), Apple-compatible and self-contained",
    "homepage": "https://github.com/$REPO",
    "license": "BSD-3-Clause",
    "notes": "Generated by publish.zsh for $TAG; do not edit by hand.",
    "architecture": {
        "64bit": {
            "url": "$URL[windows-x86_64]",
            "hash": "$HASH[windows-x86_64]",
            "extract_dir": "lzfse-$VERSION-windows-x86_64"
        },
        "arm64": {
            "url": "$URL[windows-arm64]",
            "hash": "$HASH[windows-arm64]",
            "extract_dir": "lzfse-$VERSION-windows-arm64"
        }
    },
    "bin": "lzfse.exe"
}
EOF
for plat in windows-x86_64 windows-arm64; do
  grep -qF -- "$HASH[$plat]" bucket/lzfse.json && grep -qF -- "$URL[$plat]" bucket/lzfse.json \
    || die "bucket/lzfse.json lacks the url or hash of $plat / bucket/lzfse.json 缺少 $plat 的 url 或 hash"
done
# `|| true`: grep -vxF exits 1 when no other version is left, which is the case wanted.
# `|| true`：沒有留下其他版本時 grep -vxF 以 1 結束，那正是要的情況。
stale=$(LC_ALL=C grep -oE '[0-9]+\.[0-9]+\.[0-9]+' bucket/lzfse.json | sort -u | grep -vxF -- "$VERSION" || true)
[[ -z $stale ]] || die "bucket/lzfse.json carries other versions: ${stale//$'\n'/ } / bucket/lzfse.json 帶有其他版本"

git add bucket/lzfse.json
if git diff --cached --quiet; then
  say "    bucket/lzfse.json unchanged / 沒有變動"
else
  git commit -q -m "scoop：lzfse $VERSION（$TAG 的 Windows 封存）/ scoop: lzfse $VERSION, the Windows archives published at $TAG"
  git push -q origin HEAD
fi
say ""
say "published / 已發布：https://github.com/$REPO/releases/tag/$TAG"
say "install / 安裝：zsh install.zsh $VERSION   (Windows: scoop install raliclo/lzfse)"
