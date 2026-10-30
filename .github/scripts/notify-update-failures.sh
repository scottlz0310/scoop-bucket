#!/usr/bin/env bash
# check-manifests.ps1 が書き出した結果（JSON）から、更新の失敗を Issue で通知する。update.yml の report ジョブから呼ばれる。
#
# - 失敗したマニフェストごとに、Issue を 1 件だけ起票する。すでに開いていれば本文を更新する（コメントは足さない。
#   毎日の実行で通知を増やさないため）。
# - 成功したマニフェストに、開いている失敗の Issue があれば、復旧したとして閉じる。
#
# 使い方: notify-update-failures.sh <結果の JSON>
# 必要な環境変数: GH_TOKEN（issues: write）, REPOSITORY（owner/repo）, RUN_URL（実行のログの URL）
set -euo pipefail

result="${1:?結果の JSON のパスを指定する}"
: "${GH_TOKEN:?}" "${REPOSITORY:?}" "${RUN_URL:?}"

open_issues="$(gh issue list --repo "$REPOSITORY" --state open --limit 200 --json number,title)"

while read -r row; do
  name="$(jq -r '.name' <<< "$row")"
  ok="$(jq -r '.ok' <<< "$row")"
  title="update: ${name} の自動更新に失敗している"
  # 完全一致で探す（search は部分一致のため使わない）
  number="$(jq -r --arg t "$title" '[.[] | select(.title == $t)][0].number // empty' <<< "$open_issues")"

  if [ "$ok" = "true" ]; then
    if [ -n "$number" ]; then
      gh issue close "$number" --repo "$REPOSITORY" --reason completed \
        --comment "復旧した（実行: ${RUN_URL}）。" > /dev/null
      echo "closed #$number: $name"
    fi
    continue
  fi

  # 出力に ``` が含まれていても、コードブロックが壊れないようにする
  message="$(jq -r '.message' <<< "$row" | sed 's/```/ʼʼʼ/g')"
  body="$(printf '%s\n' \
    "\`${name}\` の自動更新（\`Update Manifests\`）が失敗している。" \
    "" \
    "- 最新の失敗: ${RUN_URL}" \
    "- 復旧すると、この Issue は自動で閉じる。" \
    "" \
    "### 出力の末尾" \
    "" \
    '```' \
    "$message" \
    '```')"

  if [ -n "$number" ]; then
    gh issue edit "$number" --repo "$REPOSITORY" --body "$body" > /dev/null
    echo "updated #$number: $name"
  else
    gh issue create --repo "$REPOSITORY" --title "$title" --body "$body" > /dev/null
    echo "created: $name"
  fi
done < <(jq -c '.[]' "$result")
