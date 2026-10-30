#!/usr/bin/env bash
# checkver が書き換えたマニフェストごとに、更新 PR を作る。update.yml から呼ばれる。
#
# 必要な環境変数: GH_TOKEN（書き込み権限つき）, APP_SLUG, REPOSITORY（owner/repo）, BASE_BRANCH（PR のベース）
#
# push のあとで PR 作成が失敗しても、次回の実行で復旧できるようにする。
# リモートにブランチだけが残っている場合は、同名ブランチへ新しいコミットを push（non-fast-forward で
# 拒否される）せず、そのブランチを再利用して PR 作成だけをやり直す。
set -euo pipefail

: "${GH_TOKEN:?}" "${APP_SLUG:?}" "${REPOSITORY:?}" "${BASE_BRANCH:?}"

auth="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
git_remote() {
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth}" "$@"
}

git config user.name "${APP_SLUG}[bot]"
git config user.email "${APP_SLUG}[bot]@users.noreply.github.com"

start="$(git rev-parse HEAD)"

for manifest in $(git diff --name-only -- bucket); do
  name="$(basename "$manifest" .json)"
  version="$(jq -r '.version' "$manifest")"
  homepage="$(jq -r '.homepage' "$manifest")"
  branch="update/${name}-${version}"

  if [ -n "$(gh pr list --repo "$REPOSITORY" --head "$branch" --state all --json number --jq '.[].number')" ]; then
    echo "$branch の PR はすでにあります。スキップします"
    git checkout -- "$manifest"
    continue
  fi

  if git_remote ls-remote --exit-code --heads origin "$branch" > /dev/null; then
    echo "$branch はリモートに残っています（前回の PR 作成が失敗した可能性）。再利用して PR を作成します"
    git checkout -- "$manifest"
  else
    git switch -c "$branch"
    git add "$manifest"
    git commit -m "chore($name): v${version} に更新"
    git_remote push origin "$branch"
    git switch --detach "$start"
  fi

  gh pr create --repo "$REPOSITORY" --base "$BASE_BRANCH" --head "$branch" \
    --title "chore($name): v${version} に更新" \
    --body "$(printf '%s\n' \
      "checkver / autoupdate による自動更新です。" \
      "" \
      "- リリース: ${homepage}/releases/tag/v${version}" \
      "- ハッシュは、リリースに添付された \`.sha256\` から取得しています。" \
      "" \
      "マージ前に、差分（版・URL・ハッシュ・\`bin\`）がリリースの内容と一致することを確認してください。")"
done
