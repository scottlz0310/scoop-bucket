#!/usr/bin/env bash
# notify-failures.sh の回帰テスト。gh をモックに差し替え、呼ばれたコマンドを検証する（外部サービスに触れない）。
# ケースは表で定義する: 名前 | 結果の JSON | 開いている Issue（JSON）| 期待する gh の呼び出し（1 行ずつ、順不同）。種別は kind 変数で切り替える
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/notify-failures.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# モックの gh: issue list は MOCK_OPEN_ISSUES を返し、それ以外は呼び出しを記録する（タイトルだけを残す）
mkdir -p "$work/bin"
cat > "$work/bin/gh" << 'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "issue list" ]; then printf '%s' "$MOCK_OPEN_ISSUES"; exit 0; fi
title=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--title" ]; then title="${args[$((i + 1))]}"; fi
done
number=""
[ "$2" = "close" ] || [ "$2" = "edit" ] && number="$3"
echo "$1 $2 ${number}${title}" >> "$MOCK_CALLS"
EOF
chmod +x "$work/bin/gh"

fail=0
kind=update
run_case() {
  local name="$1" result="$2" issues="$3" expected="$4"
  printf '%s' "$result" > "$work/result.json"
  : > "$work/calls.txt"
  PATH="$work/bin:$PATH" MOCK_OPEN_ISSUES="$issues" MOCK_CALLS="$work/calls.txt" \
    GH_TOKEN=dummy REPOSITORY=o/r RUN_URL=https://example.invalid/run/1 \
    bash "$script" "$work/result.json" "$kind" > /dev/null
  local actual
  actual="$(sort "$work/calls.txt")"
  expected="$(printf '%s' "$expected" | sort)"
  if [ "$actual" = "$expected" ]; then
    echo "OK: $name"
  else
    echo "NG: $name"
    echo "  期待: ${expected:-（なし）}"
    echo "  実際: ${actual:-（なし）}"
    fail=1
  fi
}

# 出力に ``` を含むケース（コードブロックを壊さないこと）。バッククォートはそのまま使いたいので単引用符にする
# shellcheck disable=SC2016
failing='[{"name":"foo","ok":false,"message":"boom ```x```"}]'
passing='[{"name":"foo","ok":true,"message":""}]'
open_foo='[{"number":7,"title":"update: foo の自動更新に失敗している"}]'
open_other='[{"number":9,"title":"update: foo の自動更新に失敗していない別の Issue"}]'

run_case "失敗 / Issue なし → 起票する" "$failing" '[]' \
  "issue create update: foo の自動更新に失敗している"
run_case "失敗 / Issue あり → 本文を更新する（重複して起票しない）" "$failing" "$open_foo" \
  "issue edit 7"
run_case "失敗 / 似たタイトルの別 Issue だけ → 完全一致しないので起票する" "$failing" "$open_other" \
  "issue create update: foo の自動更新に失敗している"
run_case "成功 / Issue あり → 復旧として閉じる" "$passing" "$open_foo" \
  "issue close 7"
run_case "成功 / Issue なし → 何もしない" "$passing" '[]' \
  ""
run_case "複数: 失敗は起票、成功は閉じる（互いに巻き込まない）" \
  '[{"name":"foo","ok":false,"message":"x"},{"name":"bar","ok":true,"message":""}]' \
  '[{"number":3,"title":"update: bar の自動更新に失敗している"}]' \
  "$(printf 'issue create update: foo の自動更新に失敗している\nissue close 3')"

# 種別 health: タイトルが種別ごとに分かれ、update の Issue と混ざらない。_run は検査の実行自体の成否
kind=health
open_health_foo='[{"number":7,"title":"health: foo のリンク切れまたはハッシュ不一致を検出した"}]'
open_update_foo='[{"number":8,"title":"update: foo の自動更新に失敗している"}]'
open_health_run='[{"number":9,"title":"health: 週次の検査の実行に失敗している"}]'
run_case "health 失敗 / Issue なし → 起票する" "$failing" '[]' \
  "issue create health: foo のリンク切れまたはハッシュ不一致を検出した"
run_case "health 失敗 / health の Issue あり → 本文を更新する" "$failing" "$open_health_foo" \
  "issue edit 7"
run_case "health 失敗 / update の Issue だけ → 種別が違うので起票する（混ざらない）" "$failing" "$open_update_foo" \
  "issue create health: foo のリンク切れまたはハッシュ不一致を検出した"
run_case "health 成功 / update の Issue だけ → 閉じない" "$passing" "$open_update_foo" \
  ""
run_case "health 成功 / health の Issue あり → 復旧として閉じる" "$passing" "$open_health_foo" \
  "issue close 7"
run_case "health _run 失敗 / Issue なし → 実行の失敗として起票する" \
  '[{"name":"_run","ok":false,"message":"結果が得られなかった"}]' '[]' \
  "issue create health: 週次の検査の実行に失敗している"
run_case "health _run 成功 / Issue あり → 復旧として閉じる" \
  '[{"name":"foo","ok":true,"message":""},{"name":"_run","ok":true,"message":""}]' "$open_health_run" \
  "issue close 9"
run_case "health 複数: 失敗は起票、_run が成功なら実行の Issue も閉じる" \
  '[{"name":"foo","ok":false,"message":"x"},{"name":"_run","ok":true,"message":""}]' "$open_health_run" \
  "$(printf 'issue create health: foo のリンク切れまたはハッシュ不一致を検出した\nissue close 9')"

# 不明な種別は、通知せずに失敗する（誤った種別のまま黙って動かない）
if PATH="$work/bin:$PATH" MOCK_OPEN_ISSUES='[]' MOCK_CALLS="$work/calls.txt" GH_TOKEN=dummy REPOSITORY=o/r RUN_URL=x \
  bash "$script" "$work/result.json" unknown > /dev/null 2>&1; then
  echo "NG: 不明な種別は失敗するはず"; fail=1
else
  echo "OK: 不明な種別は失敗する"
fi

exit "$fail"
