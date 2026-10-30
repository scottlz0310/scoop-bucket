#!/usr/bin/env bash
# .review-raven/ci-policy.json が、reviewgate（Mcp-Docker の mcp-docker reviewgate validate）の契約に合う形か検証する。
#
# このファイルは、PR では skipped になる設計の check（Update Manifests の report ジョブなど）を、
# レビュー対応の完了記録で成功として扱ってよい、という repository の宣言である。形が不正だと、
# レビュー側は許可を推測せずに止まる（CI: unknown）。不正な宣言を、マージ前に検出する。
# 規則は reviewed-side skill の references/ci-check.md（手順 2a）と同じ。
#
# jq は、レビュー側が読む厳密な JSON パーサーより受理する入力が広い。検証器を通った宣言が、読む側で
# 拒否されないよう、次を明示的に拒否する: 複数の JSON 文書（jq は連結を受理し、-e は最後の結果で判定する）、
# 重複キー（jq は後勝ちで受理する）、UTF-8 BOM。
#
# 使い方: validate-ci-policy.sh <ci-policy.json>
set -euo pipefail

file="${1:?検証するファイルのパスを指定する}"

fail() {
  echo "::error file=${file}::$1"
  exit 1
}

# check <違反のときのメッセージ> <jq の引数（フラグと式）...>
# jq -e は、式が false / null のとき 1、式自体が不正なときは 3 以上で終わる。後者を「規則違反」と
# 誤報告しないよう、終了コード 1 のときだけを規則違反として扱い、それ以外はスクリプトの不具合として止める。
check() {
  local message="$1"
  shift
  local code=0
  jq -e "$@" "$file" > /dev/null 2>&1 || code=$?
  case "$code" in
    0) ;;
    1) fail "$message" ;;
    *) echo "::error::検証スクリプトの不具合（jq の式が不正）: $*"; exit 2 ;;
  esac
}

[ -r "$file" ] || fail "ファイルを読めない"
[ "$(head -c 3 "$file" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ] || fail "UTF-8 BOM がある（BOM なしの UTF-8 にする）"
jq -e . "$file" > /dev/null 2>&1 || fail "JSON として読めない"
check "JSON の文書が 1 個ではない（複数を連結したファイルは使えない）" -s 'length == 1'
check "JSON のオブジェクトではない" 'type == "object"'
check "キーは version と allowedSkippedChecks だけにする（未知のキーは使えない）" '(keys | sort) == ["allowedSkippedChecks", "version"]'
# 重複キー: ストリーム形式の、トップレベルのキーの出現を数える（version は 1 回、allowedSkippedChecks は
# 空配列の 1 件、または先頭の要素の 1 件のどちらかが 1 回）。2 回以上現れたら、重複している
# （$p は jq の変数で、シェルの展開ではない）
# shellcheck disable=SC2016
check "version または allowedSkippedChecks のキーが重複している" -n --stream \
  '[inputs | select(length == 2) | .[0] | select(. == ["version"] or . == ["allowedSkippedChecks"] or . == ["allowedSkippedChecks", 0])] as $p
   | ($p | map(select(. == ["version"])) | length) == 1 and ($p | map(select(. != ["version"])) | length) == 1'
check "version は 1 にする" '.version == 1'
check "allowedSkippedChecks は、1 件以上の配列にする（許可しないなら、ファイルごと置かない）" '.allowedSkippedChecks | type == "array" and length > 0'
check "allowedSkippedChecks の要素は、すべて文字列にする" '.allowedSkippedChecks | all(.[]; type == "string")'
check "allowedSkippedChecks の名前は、空にしない。前後に空白を付けない" '.allowedSkippedChecks | all(.[]; length > 0 and . == (sub("^\\s+"; "") | sub("\\s+$"; "")))'
check "allowedSkippedChecks に、重複した名前がある" '.allowedSkippedChecks | length == (unique | length)'

echo "OK: $file"
