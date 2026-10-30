#!/usr/bin/env bash
# new-manifest.ps1 が生成した新規マニフェストを、PR にする。add-manifest.yml から呼ばれる。
#
# 必要な環境変数: GH_TOKEN（書き込み権限つき）, APP_SLUG, REPOSITORY（owner/repo）, BASE_BRANCH,
#                MANIFEST（生成したマニフェストのパス。bucket/<name>.json）, SOURCE_REPOSITORY（載せる repo の owner/repo）
#
# push のあとで PR 作成が失敗しても、次回の実行で復旧できる（open-update-prs.sh と同じ方針）。リモートにブランチだけが
# 残っている場合は、同名ブランチへ新しいコミットを push（non-fast-forward で拒否される）せず、そのブランチを再利用して
# PR 作成だけをやり直す。すでに PR がある場合は、何もしない。
set -euo pipefail

: "${GH_TOKEN:?}" "${APP_SLUG:?}" "${REPOSITORY:?}" "${BASE_BRANCH:?}" "${MANIFEST:?}" "${SOURCE_REPOSITORY:?}"

auth="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
git_remote() {
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth}" "$@"
}

git config user.name "${APP_SLUG}[bot]"
git config user.email "${APP_SLUG}[bot]@users.noreply.github.com"

name="$(basename "$MANIFEST" .json)"
version="$(jq -r '.version' "$MANIFEST")"
homepage="$(jq -r '.homepage' "$MANIFEST")"
branch="add/${name}"
title="feat(${name}): マニフェストを追加 (v${version})"
start="$(git rev-parse HEAD)"

if [ -n "$(gh pr list --repo "$REPOSITORY" --head "$branch" --state all --json number --jq '.[].number')" ]; then
  echo "$branch の PR はすでにあります。スキップします"
  exit 0
fi

if git_remote ls-remote --exit-code --heads origin "$branch" > /dev/null; then
  echo "$branch はリモートに残っています（前回の PR 作成が失敗した可能性）。再利用して PR を作成します"
else
  git switch -c "$branch"
  git add "$MANIFEST" README.md
  git commit -m "$title"
  git_remote push origin "$branch"
  git switch --detach "$start"
fi

gh pr create --repo "$REPOSITORY" --base "$BASE_BRANCH" --head "$branch" \
  --title "$title" \
  --body "$(printf '%s\n' \
    "\`${SOURCE_REPOSITORY}\` の最新リリース（v${version}）から、足場（\`add-manifest.yml\`）が生成した新規マニフェスト。" \
    "" \
    "- リリース: ${homepage}/releases/tag/v${version}" \
    "- ハッシュは、リリースに添付された \`.sha256\` から取得している。更新は \`checkver\` / \`autoupdate\` が追従する。" \
    "" \
    "### マージ前に確認すること" \
    "- [ ] \`Verify Manifests\`（隔離した Scoop へのインストール）が成功している" \
    "- [ ] \`description\` / \`license\` / \`bin\` / \`shortcuts\` が、アプリの実際の内容と合っている" \
    "- [ ] ヘッドレスで確認できるコマンド（\`--version\` など）があれば、\`.github/verify.json\` に追加する" \
    "- [ ] \`persist\` / \`pre_install\` などが要るアプリではないこと（足場は、これらを生成しない）")"
