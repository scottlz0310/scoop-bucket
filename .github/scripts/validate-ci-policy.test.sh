#!/usr/bin/env bash
# validate-ci-policy.sh の回帰テスト。ケースを表で定義し、終了コードと、違反のメッセージの一部を確認する。
# 表の形式: 名前 | 内容 | 期待する終了コード | 出力に含まれるべき文字列（空なら確認しない）
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/validate-ci-policy.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
run_case() {
  local name="$1" content="$2" want_code="$3" want_text="$4"
  printf '%s' "$content" > "$work/policy.json"
  local code=0 output
  output="$(bash "$script" "$work/policy.json" 2>&1)" || code=$?
  if [ "$code" -ne "$want_code" ]; then
    echo "NG: $name（終了コード $code。期待: $want_code）"
    echo "    $output"
    fail=1
  elif [ -n "$want_text" ] && [[ "$output" != *"$want_text"* ]]; then
    echo "NG: $name（出力に「$want_text」が無い）"
    echo "    $output"
    fail=1
  else
    echo "OK: $name"
  fi
}

# 通る宣言
run_case "1 件" '{"version":1,"allowedSkippedChecks":["report"]}' 0 "OK:"
run_case "複数（空白を含む名前も可。名前の中の空白は許す）" '{"version":1,"allowedSkippedChecks":["report","Go CLI チェック"]}' 0 "OK:"

# 通らない宣言（終了コード 1 = 規則違反）
run_case "JSON ではない" '{invalid' 1 "JSON として読めない"
run_case "オブジェクトではない" '["report"]' 1 "オブジェクトではない"
run_case "未知のキー" '{"version":1,"allowedSkippedChecks":["report"],"extra":1}' 1 "未知のキー"
run_case "version が無い" '{"allowedSkippedChecks":["report"]}' 1 "未知のキー"
run_case "version が 2" '{"version":2,"allowedSkippedChecks":["report"]}' 1 "version は 1"
run_case "version が文字列" '{"version":"1","allowedSkippedChecks":["report"]}' 1 "version は 1"
run_case "空の配列" '{"version":1,"allowedSkippedChecks":[]}' 1 "1 件以上"
run_case "配列ではない" '{"version":1,"allowedSkippedChecks":"report"}' 1 "1 件以上の配列"
run_case "文字列以外の要素" '{"version":1,"allowedSkippedChecks":["report",1]}' 1 "すべて文字列"
run_case "空の名前" '{"version":1,"allowedSkippedChecks":[""]}' 1 "空にしない"
run_case "空白だけの名前" '{"version":1,"allowedSkippedChecks":[" "]}' 1 "空にしない"
run_case "前に空白のある名前" '{"version":1,"allowedSkippedChecks":[" report"]}' 1 "前後に空白"
run_case "後ろに空白のある名前" '{"version":1,"allowedSkippedChecks":["report "]}' 1 "前後に空白"
run_case "重複した名前" '{"version":1,"allowedSkippedChecks":["report","report"]}' 1 "重複"

exit "$fail"
