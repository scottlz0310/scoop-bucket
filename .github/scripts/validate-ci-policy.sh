#!/usr/bin/env bash
# .review-raven/ci-policy.json が、reviewgate（Mcp-Docker の mcp-docker reviewgate validate）の契約に合う形か検証する。
#
# このファイルは、PR では skipped になる設計の check（Update Manifests の report ジョブなど）を、
# レビュー対応の完了記録で成功として扱ってよい、という repository の宣言である。形が不正だと、
# レビュー側は許可を推測せずに止まる（CI: unknown）。不正な宣言を、マージ前に検出する。
# 規則は reviewed-side skill の references/ci-check.md（手順 2a）と同じ。
#
# 使い方: validate-ci-policy.sh <ci-policy.json>
set -euo pipefail

file="${1:?検証するファイルのパスを指定する}"

fail() {
  echo "::error file=${file}::$1"
  exit 1
}

# check <jq の式> <違反のときのメッセージ>
# jq -e は、式が false / null のとき 1、式自体が不正なときは 3 以上で終わる。後者を「規則違反」と
# 誤報告しないよう、終了コード 1 のときだけを規則違反として扱い、それ以外はスクリプトの不具合として止める。
check() {
  local code=0
  jq -e "$1" "$file" > /dev/null 2>&1 || code=$?
  case "$code" in
    0) ;;
    1) fail "$2" ;;
    *) echo "::error::検証スクリプトの不具合（jq の式が不正）: $1"; exit 2 ;;
  esac
}

jq -e . "$file" > /dev/null 2>&1 || fail "JSON として読めない"
check 'type == "object"' "JSON のオブジェクトではない"
check '(keys | sort) == ["allowedSkippedChecks", "version"]' "キーは version と allowedSkippedChecks だけにする（未知のキーは使えない）"
check '.version == 1' "version は 1 にする"
check '.allowedSkippedChecks | type == "array" and length > 0' "allowedSkippedChecks は、1 件以上の配列にする（許可しないなら、ファイルごと置かない）"
check '.allowedSkippedChecks | all(.[]; type == "string")' "allowedSkippedChecks の要素は、すべて文字列にする"
check '.allowedSkippedChecks | all(.[]; length > 0 and . == (sub("^\\s+"; "") | sub("\\s+$"; "")))' "allowedSkippedChecks の名前は、空にしない。前後に空白を付けない"
check '.allowedSkippedChecks | length == (unique | length)' "allowedSkippedChecks に、重複した名前がある"

echo "OK: $file"
