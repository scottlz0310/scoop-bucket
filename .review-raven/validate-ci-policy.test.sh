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

# jq は、読む側の厳密な JSON パーサーより広く受理する入力。検証器を通った宣言が、読む側で拒否されないようにする。
# 複数の JSON 文書（jq は連結を受理し、-e は最後の結果で判定する。先頭の不正な文書が、後続の正常な文書の陰で通る）
run_case "複数文書: 不正（version 2）+ 正常" $'{"version":2,"allowedSkippedChecks":["verify"]}\n{"version":1,"allowedSkippedChecks":["report"]}' 1 "文書が 1 個ではない"
run_case "複数文書: 正常 + 正常" $'{"version":1,"allowedSkippedChecks":["a"]}\n{"version":1,"allowedSkippedChecks":["b"]}' 1 "文書が 1 個ではない"
run_case "複数文書: 正常 + 不正" $'{"version":1,"allowedSkippedChecks":["report"]}\n{"version":2,"allowedSkippedChecks":["x"]}' 1 "文書が 1 個ではない"
# 重複キー（jq は後勝ちで受理する）
run_case "重複キー: version" '{"version":1,"version":1,"allowedSkippedChecks":["a"]}' 1 "キーが重複"
run_case "重複キー: 配列（どちらも非空）" '{"version":1,"allowedSkippedChecks":["a"],"allowedSkippedChecks":["b"]}' 1 "キーが重複"
run_case "重複キー: 空配列のあとに非空配列（後勝ちで通る）" '{"version":1,"allowedSkippedChecks":[],"allowedSkippedChecks":["a"]}' 1 "キーが重複"
run_case "重複キー: 非空配列のあとに空配列" '{"version":1,"allowedSkippedChecks":["a"],"allowedSkippedChecks":[]}' 1 "キーが重複"
# UTF-8 BOM（厳密なパーサーは拒否する）
run_case "UTF-8 BOM つき" $'\xef\xbb\xbf{"version":1,"allowedSkippedChecks":["report"]}' 1 "BOM"
# 末尾の改行や空白は問題ない（エディタが付ける）
run_case "末尾に改行" $'{"version":1,"allowedSkippedChecks":["report"]}\n' 0 "OK:"
run_case "整形された JSON（複数行）" $'{\n  "version": 1,\n  "allowedSkippedChecks": [\n    "report"\n  ]\n}\n' 0 "OK:"

exit "$fail"
