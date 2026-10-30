#!/usr/bin/env bash
# check-manifests.ps1 / health-check.ps1 が書き出した結果（JSON）から、失敗を Issue で通知する。
# update.yml（種別 update）と health.yml（種別 health）の report ジョブから呼ばれる。
#
# - 失敗したマニフェストごとに、Issue を 1 件だけ起票する。すでに開いていれば本文を更新する（コメントは足さない。
#   繰り返しの実行で通知を増やさないため）。
# - 成功したマニフェストに、開いている失敗の Issue があれば、復旧したとして閉じる。
# - 種別 health では、名前 _run を、検査の実行自体の成否として扱う（検査の結果が得られなかったときに、workflow が渡す）。
#
# 使い方: notify-failures.sh <結果の JSON> <種別: update | health>
# 必要な環境変数: GH_TOKEN（issues: write）, REPOSITORY（owner/repo）, RUN_URL（実行のログの URL）
set -euo pipefail

result="${1:?結果の JSON のパスを指定する}"
kind="${2:?種別（update | health）を指定する}"
: "${GH_TOKEN:?}" "${REPOSITORY:?}" "${RUN_URL:?}"

# Issue のタイトルと、本文の書き出し。種別ごとの違いは、ここだけに置く
issue_title() { # 名前
  case "$kind:$1" in
    update:*) echo "update: ${1} の自動更新に失敗している" ;;
    health:_run) echo "health: 週次の検査の実行に失敗している" ;;
    health:*) echo "health: ${1} のリンク切れまたはハッシュ不一致を検出した" ;;
    *) echo "不明な種別: $kind" >&2; return 1 ;;
  esac
}
issue_lead() { # 名前
  case "$kind:$1" in
    update:*) echo "\`${1}\` の自動更新（\`Update Manifests\`）が失敗している。" ;;
    health:_run) echo "週次の検査（\`Health Check\`）の実行自体が失敗している。検査の結果が得られていない。" ;;
    health:*) echo "\`${1}\` の週次の検査（\`Health Check\`）で、リンク切れまたはハッシュ不一致を検出した。" ;;
  esac
}

open_issues="$(gh issue list --repo "$REPOSITORY" --state open --limit 200 --json number,title)"

while read -r row; do
  name="$(jq -r '.name' <<< "$row")"
  ok="$(jq -r '.ok' <<< "$row")"
  title="$(issue_title "$name")"
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
    "$(issue_lead "$name")" \
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
