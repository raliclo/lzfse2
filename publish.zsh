#!/usr/bin/env zsh
# publish.zsh --local | --github <X.Y.Z> [--yes] | --help -- build or publish an lzfse release for every os/arch.
# publish.zsh --local | --github <X.Y.Z> [--yes] | --help —— 建置或發布涵蓋所有 os/arch 的 lzfse release。
#   zsh publish.zsh --local          build, strip, verify and package THIS machine's os/arch (release.zsh); no upload
#                                    建置、strip、驗證並打包**本機**的 os/arch（release.zsh）；不上傳
#   zsh publish.zsh --github 0.2.0   formal: VERSION must say 0.2.0; ask, push tag v0.2.0, let CI
#                                    (.github/workflows/release.yml) build all eight targets, wait for it, download and
#                                    verify its artifacts, create the release AS YOU (your gh login) with
#                                    release-notes/v0.2.0.md, verify every asset again from its public URL, then rewrite
#                                    bucket/lzfse.json, commit, push. Re-running it on a released tag only re-verifies
#                                    and refreshes the notes and the manifest.
#                                    正式：VERSION 必須是 0.2.0；詢問後推送 tag v0.2.0，由 CI（.github/workflows/release.yml）
#                                    建置全部八個目標，等它完成，下載並驗證它的 artifact，以**你**（你的 gh 登入）的身分
#                                    帶 release-notes/v0.2.0.md 建立 release，再從公開網址重新驗證每個資產，最後改寫
#                                    bucket/lzfse.json、提交並推送。對已發布的 tag 重跑時只會重新驗證並更新 notes 與 manifest。
#   --yes   (--github) do not ask / 不詢問
# Targets: {linux (glibc), linux (musl), macos, windows} x {x86_64,arm64}; Linux arm64 is named aarch64 (uname -m).
# 目標：{linux (glibc), linux (musl), macos, windows} x {x86_64,arm64}；Linux arm64 命名為 aarch64（uname -m）。
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
PLATFORMS=(linux-x86_64-glibc linux-aarch64-glibc linux-x86_64-musl linux-aarch64-musl macos-x86_64 macos-arm64 windows-x86_64 windows-arm64)

say() { print -r -- "$1" }
die() { print -u2 -r -- "$1"; [[ -n ${2:-} ]] && print -u2 -r -- "$2"; exit 1 }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 -- "$1" | cut -d' ' -f1
  else openssl dgst -sha256 -r "$1" | cut -d' ' -f1; fi
}

# check_archive <dir> <plat>: <dir>/lzfse-<version>-<plat>.tar.zst agrees with its .sha256, holds one directory with
# the executable, and that executable carries `v<X.Y.Z> / <commit8>` for the tag's commit. Sets REPLY to the sha256.
# Used twice: on CI's artifacts before the release exists, and on the public downloads after.
# check_archive <目錄> <平台>：<目錄>/lzfse-<版本>-<平台>.tar.zst 與其 .sha256 相符、裡面是一個含執行檔的目錄，且該
# 執行檔帶著 tag 那個 commit 的 `v<X.Y.Z> / <commit 前 8 碼>`。REPLY 設為 sha256。用兩次：release 建立前對 CI 的
# artifact，建立後對公開網址下載的檔案。
check_archive() {
  local dir=$1 plat=$2 exe= base=lzfse-$VERSION-$2.tar.zst stem=lzfse-$VERSION-$2 h hits
  [[ $plat == windows-* ]] && exe=.exe
  [[ -f $dir/$base && -f $dir/$base.sha256 ]] || die "$base or its .sha256 is missing in $dir / $dir 裡缺少 $base 或其 .sha256"
  h=$(sha256_of "$dir/$base")
  [[ $h == $(cut -d' ' -f1 < "$dir/$base.sha256") ]] || die "$base: .sha256 disagrees with $h" "$base：.sha256 與 $h 不符"
  rm -rf -- "$dir/x-$plat"; mkdir -p -- "$dir/x-$plat"
  zstd -dqc -- "$dir/$base" | tar -xf - -C "$dir/x-$plat"
  [[ -f $dir/x-$plat/$stem/lzfse$exe ]] || die "$base has no $stem/lzfse$exe / $base 裡沒有 $stem/lzfse$exe"
  # `grep -a`: without it a binary yields one "Binary file matches" line. `|| true`: a count of zero exits 1 and is
  # answered by the die below. No parentheses: the binary holds the build id literal alone; lzfseVersionLine adds
  # "(…)" at run time.
  # `grep -a`：少了它，二進位檔只會得到一行「Binary file matches」。`|| true`：計數為零時以 1 結束，由下方的 die
  # 回答。不含括號：執行檔裡只有 build id 字面值本身；外圍的「(…)」是 lzfseVersionLine 在執行時才加上的。
  hits=$(LC_ALL=C grep -a -c -F -- "$TAG / ${TAG_SHA[1,8]}" "$dir/x-$plat/$stem/lzfse$exe" || true)
  [[ $hits != 0 ]] || die "$base does not carry [$TAG / ${TAG_SHA[1,8]}]; built from another commit?" \
                          "$base 裡沒有 [$TAG / ${TAG_SHA[1,8]}]；是從別的 commit 建的嗎？"
  say "    $base  $h"
  REPLY=$h
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
# The release notes are written by a person before publishing, in the shape of csv2's: what ships, what was
# checked per platform, what changed, then the same in Traditional Chinese. Steps 3 and 5 put them on the release.
# release notes 由人在發布前寫好，形式同 csv2：出貨內容、各平台檢查、變更，再附繁體中文。第 3、5 步把它放上 release。
NOTES=release-notes/$TAG.md
[[ -s $NOTES ]] || die "$NOTES is missing; write the release notes first (see release-notes/)" \
                       "缺少 $NOTES；請先寫好 release notes（見 release-notes/）"
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
# HEAD may be past an existing tag only by commits that change nothing the archives are built from -- the files
# release.yml's path filter names: the bucket commit a previous run left, release notes, this script.
# HEAD 只可以因為「不影響封存建置內容」的 commit 而越過既有的 tag——也就是 release.yml 路徑過濾所列的檔案以外的變更：
# 上一次執行留下的 bucket commit、release notes、本腳本。
if [[ -n $TAG_SHA && $TAG_SHA != $HEAD_SHA ]]; then
  extra=$(git diff --name-only "$TAG_SHA" HEAD -- lzfse-cli.swift release.zsh VERSION .github/workflows/release.yml)
  [[ -z $extra ]] || die "$TAG exists at ${TAG_SHA[1,8]} and HEAD changes what it was built from: ${extra//$'\n'/ }" \
                         "$TAG 已存在於 ${TAG_SHA[1,8]}，且 HEAD 改動了建置來源：${extra//$'\n'/ }"
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
    # -s: signed with git's configured key (gpg.format, user.signingkey), so GitHub shows the tag as Verified.
    # -s：以 git 設定的金鑰（gpg.format、user.signingkey）簽章，GitHub 才會把這個 tag 標成 Verified。
    git tag -s "$TAG" -m "lzfse $VERSION"
    TAG_SHA=$HEAD_SHA
  fi
  git push -q origin "$TAG"
  say "  pushed / 已推送：$TAG"
  run_id=
  for i in {1..30}; do
    # --commit as well as --branch: a tag deleted and pushed again keeps its name, and the run for the old commit
    # would be taken for this one.
    # 除了 --branch 也要 --commit：刪除後重推的 tag 名稱不變，否則會把舊 commit 的那次執行當成這一次。
    run_id=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --branch "$TAG" --commit "$TAG_SHA" --limit 1 --json databaseId -q '.[0].databaseId // empty')
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

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lzfse-publish.XXXXXX")
trap 'rm -rf -- "${tmp:?}"' EXIT

# ---------------------------------------------------------------------
# --github 3. Create the release AS YOU. CI only builds (its artifacts, one per platform); the release is created
#    here with your gh login, so GitHub shows you as the one who released it, not github-actions. Every artifact is
#    checked first, so a release never exists with a bad archive in it, and the notes go on at creation.
# --github 3. 以**你**的身分建立 release。CI 只負責建置（每個平台一個 artifact）；release 在這裡以你的 gh 登入建立，
#    GitHub 才會顯示是你發布的，而不是 github-actions。每個 artifact 都先檢查，所以不會有一個含壞封存的 release
#    存在過；notes 在建立時一併放上。
# ---------------------------------------------------------------------
if (( ! released )); then
  say "  CI artifacts / CI 的 artifact："
  gh run download "$run_id" -R "$REPO" -D "$tmp/ci" || die "cannot download the artifacts of run $run_id / 無法下載 run $run_id 的 artifact"
  typeset -a assets=()
  for plat in $PLATFORMS; do
    check_archive "$tmp/ci/lzfse-$plat" "$plat"
    assets+=("$tmp/ci/lzfse-$plat/lzfse-$VERSION-$plat.tar.zst" "$tmp/ci/lzfse-$plat/lzfse-$VERSION-$plat.tar.zst.sha256")
  done
  gh release create "$TAG" -R "$REPO" --verify-tag --title "lzfse $VERSION" --notes-file "$NOTES" "${assets[@]}" >/dev/null \
    || die "gh release create failed / gh release create 失敗"
  say "  created / 已建立：https://github.com/$REPO/releases/tag/$TAG ($(gh api "repos/$REPO/releases/tags/$TAG" --jq .author.login))"
fi

# ---------------------------------------------------------------------
# --github 4. Download every asset again from the public URL an installer uses, and check it the same way: what was
#    uploaded is what an installer gets.
# --github 4. 從安裝者會用的公開網址重新下載每個資產並以同樣方式檢查：上傳的就是安裝者拿到的。
# ---------------------------------------------------------------------
typeset -A HASH URL
say "  public downloads / 公開下載："
mkdir -p -- "$tmp/pub"
for plat in $PLATFORMS; do
  base=lzfse-$VERSION-$plat.tar.zst
  URL[$plat]=https://github.com/$REPO/releases/download/$TAG/$base
  curl -fsSL -o "$tmp/pub/$base" "$URL[$plat]" && curl -fsSL -o "$tmp/pub/$base.sha256" "$URL[$plat].sha256" \
    || die "cannot download $URL[$plat] / 無法下載 $URL[$plat]"
  check_archive "$tmp/pub" "$plat"
  HASH[$plat]=$REPLY
done

# ---------------------------------------------------------------------
# --github 5. The release notes, read back; on a re-run for a released tag this is what refreshes them. REST, as
#    everywhere here; -F body=@file sends the file's contents.
# --github 5. release notes，讀回比對；對已發布的 tag 重跑時，由這一步更新它。與這裡其他地方一樣用 REST；
#    -F body=@file 送出檔案內容。
# ---------------------------------------------------------------------
release_id=$(gh api "repos/$REPO/releases/tags/$TAG" --jq .id)
gh api -X PATCH "repos/$REPO/releases/$release_id" -F body=@"$NOTES" >/dev/null
[[ $(gh api "repos/$REPO/releases/$release_id" --jq .body) == $(<$NOTES) ]] \
  || die "the release body does not read back as $NOTES" "release 本文讀回後與 $NOTES 不同"
say "    release notes: $NOTES / 已放上 release notes"

# ---------------------------------------------------------------------
# --github 6. The scoop manifest, GENERATED whole from the values above rather than edited in place, then read back.
# --github 6. scoop manifest，整份由上面的值**產生**而不是就地修改，然後讀回確認。
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
