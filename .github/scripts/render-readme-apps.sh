#!/usr/bin/env bash
# README の登録アプリ一覧を、bucket/*.json の description と homepage から生成する。
# 生成するのは、README のマーカー（<!-- apps:begin --> と <!-- apps:end -->）で囲んだ範囲だけ。
# マニフェストを正とする（手書きの説明とずれるため）。説明は、マニフェストの description をそのまま使う。
#
# 使い方: render-readme-apps.sh [--check] [README のパス] [bucket のパス]
#   引数なし: README を書き換える。
#   --check:  書き換えない。最新でなければ、差分を出して失敗する（CI 用）。
set -euo pipefail

check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
readme="${1:-README.md}"
bucket="${2:-bucket}"

begin='<!-- apps:begin -->'
end='<!-- apps:end -->'

# マーカーは 1 組だけ、begin が先でなければならない。曖昧なまま書き換えると、README の別の範囲を壊す
# CRLF の作業ツリー（Windows の autocrlf）でも同じ結果にするため、CR を除いた内容で扱う
content="$(tr -d '\r' < "$readme")"
begins="$(grep -cxF "$begin" <<< "$content" || true)"
ends="$(grep -cxF "$end" <<< "$content" || true)"
if [ "$begins" != 1 ] || [ "$ends" != 1 ]; then
  echo "$readme: マーカー（$begin / $end）が 1 組ずつ必要です（begin=$begins, end=$ends）" >&2
  exit 1
fi
if [ "$(grep -nxF "$begin" <<< "$content" | cut -d: -f1)" -ge "$(grep -nxF "$end" <<< "$content" | cut -d: -f1)" ]; then
  echo "$readme: $begin は $end より前に置いてください" >&2
  exit 1
fi

manifests="$(printf '%s\n' "$bucket"/*.json | LC_ALL=C sort)"
if [ "$manifests" = "$bucket/*.json" ]; then
  echo "$bucket にマニフェストがありません" >&2
  exit 1
fi

table="$(printf '%s\n%s' '| アプリケーション | 説明 |' '|---|---|')"
while IFS= read -r file; do
  name="$(basename "$file" .json)"
  # 表のセルを壊す文字（| と改行）を無害にする。jq の出力の CR は、Windows の jq 対策
  row="$(jq -r --arg name "$name" '
    if (.homepage | type) != "string" or .homepage == "" then error("homepage がありません")
    elif (.description | type) != "string" or .description == "" then error("description がありません")
    else (.description | gsub("[\\s]+"; " ") | gsub("[|]"; "\\|")) as $d
      | "| [**\($name)**](\(.homepage)) | \($d) |"
    end' "$file" | tr -d '\r')" || { echo "$file: 表の行を生成できません" >&2; exit 1; }
  table="$table"$'\n'"$row"
done <<< "$manifests"

# awk -v はバックスラッシュを解釈してしまうので、環境変数で渡す
generated="$(TABLE="$table" awk -v begin="$begin" -v end="$end" '
  $0 == begin { print; print ENVIRON["TABLE"]; skipping = 1; next }
  $0 == end   { skipping = 0 }
  !skipping   { print }
' <<< "$content")"

if [ "$check" = 1 ]; then
  if [ "$generated" = "$content" ]; then
    echo "README の登録アプリ一覧は最新です"
    exit 0
  fi
  diff -u <(printf '%s\n' "$content") <(printf '%s\n' "$generated") || true
  echo "README の登録アプリ一覧が、マニフェストとずれています。.github/scripts/render-readme-apps.sh を実行して、README を更新してください" >&2
  exit 1
fi

printf '%s\n' "$generated" > "$readme"
