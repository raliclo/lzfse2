# Scoop bucket

本目錄是一個標準 scoop bucket，可直接加入使用：

This directory is a standard scoop bucket and can be added directly:

```sh
scoop bucket add raliclo https://github.com/raliclo/lzfse2
scoop install raliclo/lzfse
scoop install raliclo/swift_tar
```

## Manifest

| 檔案 / File | 套件 / Package | 發佈來源 repo / Published from |
|---|---|---|
| `lzfse.json` | `lzfse` | `raliclo/lzfse2` |
| `swift_tar.json` | `swift_tar` | `raliclo/swift_tar` |

兩個 manifest 都放在本 repo 的根目錄 `bucket/`，即使 `swift_tar` 的 binary 由另一個
repo 發佈也一樣——scoop bucket 只需要 manifest 集中在一處。

Both manifests live in this repo's root `bucket/`, even though the `swift_tar`
binary is published from a different repo: a scoop bucket only needs the
manifests gathered in one place.

## zip 由 GitHub Releases 提供，不入版控 / Zips come from GitHub Releases, not version control

本專案不追蹤編譯產物（`helper_windows/release/` 與 `swift_tar/release/` 皆列於
`.gitignore`），因此 manifest 的下載 URL 指向 GitHub Release 附件，而非 repo 內的
檔案路徑：

This project does not track build output (`helper_windows/release/` and
`swift_tar/release/` are both gitignored), so the manifests' download URLs point
at GitHub Release assets rather than at paths inside the repo:

```
https://github.com/raliclo/lzfse2/releases/download/v<version>/lzfse-cli.zip
https://github.com/raliclo/swift_tar/releases/download/v<version>/swift_tar_win.zip
```

曾有一段時間 URL 指向 `raw.githubusercontent.com/.../release/*.zip`，但該路徑下的
檔案從未入版控，任何 `scoop install` 都會 404。改用 Release 附件即可在不把 binary
放進版控的前提下提供下載。

For a while these URLs pointed at `raw.githubusercontent.com/.../release/*.zip`,
but nothing was ever tracked at those paths, so any `scoop install` would 404.
Release assets provide a download without putting binaries into version control.

## 發佈流程 / Release procedure

各套件由其所屬 repo 的 `scoop_release.bat` 發佈：

Each package is published by the `scoop_release.bat` in its own repo:

| 套件 / Package | 腳本 / Script |
|---|---|
| `lzfse` | `helper_windows/scoop/scoop_release.bat` |
| `swift_tar` | `swift_tar/scoop_release.bat` |

腳本依序執行：

Each script performs, in order:

1. 重建 zip / rebuild the zip
2. 讀取對應 manifest 的 `version` 欄位，導出 tag `v<version>` / read the matching
   manifest's `version` field and derive the tag `v<version>`
3. 該 release 不存在則以 `gh release create` 建立 / create the release with
   `gh release create` if it does not exist yet
4. 以 `gh release upload --clobber` 上傳 zip / upload the zip with
   `gh release upload --clobber`
5. 以 `update_scoop_manifest.ps1` 將 manifest 的 `hash` 更新為該 zip 的雜湊 /
   refresh the manifest's `hash` for that zip via `update_scoop_manifest.ps1`

需要 `gh` CLI 且已完成認證；未安裝時腳本會在任何發佈動作前中止。

The `gh` CLI must be installed and authenticated; without it the script aborts
before any publishing step.

### 版本升級只需改 manifest / Bump the version in the manifest only

tag 由 manifest 的 `version` 欄位導出，而非寫死在腳本中，因此 manifest 指向的
release 與腳本實際發佈的 release 不可能不一致。升級版本時只改 manifest 的
`version`，腳本會自動跟上。

The tag is derived from the manifest's `version` field rather than hardcoded in
the script, so the release a manifest points at and the release the script
publishes cannot drift apart. To bump a version, edit only the manifest's
`version`; the script follows.

若 manifest 讀不到或缺少 `version`，腳本會回報錯誤並以非零狀態碼結束，不會建立或
上傳任何 release。

If the manifest cannot be read or has no `version`, the script reports the error
and exits nonzero without creating or uploading anything.

### hash 的時序 / When the hash is valid

`hash` 由步驟 5 依實際上傳的 zip 計算。因此在某個版本第一次跑完發佈流程之前，
manifest 中的 `hash` 並不對應任何可下載的檔案，該版本尚不可安裝——這是尚未發佈的
正常狀態，而非設定錯誤。

The `hash` is computed in step 5 from the zip that was actually uploaded. Until a
version has been through the release procedure once, its `hash` does not
correspond to any downloadable file and that version is not installable yet —
this is the normal not-yet-released state, not a misconfiguration.
