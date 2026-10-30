#!/usr/bin/env bash
# render-readme-apps.sh の回帰テスト。一時ディレクトリの README と bucket を使い、実際のファイルには触れない。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/render-readme-apps.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
check() { # 名前 / 期待 / 実際
  if [ "$2" = "$3" ]; then echo "OK: $1"; else printf 'NG: %s\n  期待: %s\n  実際: %s\n' "$1" "$2" "$3"; fail=1; fi
}

readme="$work/README.md"
bucket="$work/bucket"
head_lines=('# t' '' '前の文' '<!-- apps:begin -->')
tail_lines=('<!-- apps:end -->' '後ろの文')

make_readme() { # マーカー内の本文を渡す（空でもよい）
  printf '%s\n' "${head_lines[@]}" "$1" "${tail_lines[@]}" > "$readme"
}
make_bucket() { rm -rf "$bucket"; mkdir "$bucket"; }
manifest() { printf '%s' "$2" > "$bucket/$1.json"; } # 名前 / JSON

# 実行して終了コードを返す（出力は $work/out.txt）
run() {
  local code=0
  bash "$script" "$@" > "$work/out.txt" 2>&1 || code=$?
  echo "$code"
}
expected_readme() { # 表の行（0 件以上）を渡す
  printf '%s\n' "${head_lines[@]}" '| アプリケーション | 説明 |' '|---|---|' "$@" "${tail_lines[@]}"
}

app_a='{"description":"Tool A","homepage":"https://github.com/o/a"}'
app_b='{"description":"Tool B","homepage":"https://github.com/o/b"}'
row_a='| [**a**](https://github.com/o/a) | Tool A |'
row_b='| [**b**](https://github.com/o/b) | Tool B |'

# 生成: 名前順に並べる（作成順ではない）。マーカーの外は変えない。古い手書きの本文は置き換わる
make_bucket; manifest b "$app_b"; manifest a "$app_a"; make_readme '| 手書きの古い行 | 消える |'
check "生成: 終了コード 0" "0" "$(run "$readme" "$bucket")"
check "生成: 名前順の表に置き換わり、マーカーの外は同じ" "$(expected_readme "$row_a" "$row_b")" "$(cat "$readme")"
cp "$readme" "$work/first.md"
run "$readme" "$bucket" > /dev/null
check "冪等: 2 回目で変わらない" "$(cat "$work/first.md")" "$(cat "$readme")"

# --check: 最新なら 0、ずれていれば 1 で README を書き換えない
check "--check 最新: 終了コード 0" "0" "$(run --check "$readme" "$bucket")"
manifest a '{"description":"Tool A v2","homepage":"https://github.com/o/a"}'
before="$(cat "$readme")"
check "--check ずれ: 終了コード 1" "1" "$(run --check "$readme" "$bucket")"
check "--check ずれ: 案内を出す" "1" "$(grep -c 'ずれています' "$work/out.txt")"
check "--check ずれ: README を書き換えない" "$before" "$(cat "$readme")"

# CRLF の README（Windows の autocrlf）でも、同じ判定になる
make_bucket; manifest a "$app_a"; make_readme ''
run "$readme" "$bucket" > /dev/null
sed -i 's/$/\r/' "$readme"
check "CRLF: --check は最新と判定する" "0" "$(run --check "$readme" "$bucket")"

# 表のセルを壊す文字は無害にする
make_bucket
manifest a '{"description":"x | y","homepage":"https://github.com/o/a"}'
manifest b '{"description":"line1\n  line2","homepage":"https://github.com/o/b"}'
make_readme ''
run "$readme" "$bucket" > /dev/null
check "縦棒をエスケープする" '| [**a**](https://github.com/o/a) | x \| y |' "$(grep '^| \[\*\*a' "$readme")"
check "改行と連続空白を 1 つの空白にする" '| [**b**](https://github.com/o/b) | line1 line2 |' "$(grep '^| \[\*\*b' "$readme")"

# 失敗する入力: 終了コード 1、メッセージに原因、README は書き換えない
fail_case() { # 名前 / 期待するメッセージの断片
  local name="$1" fragment="$2"
  before="$(cat "$readme")"
  check "$name: 終了コード 1" "1" "$(run "$readme" "$bucket")"
  check "$name: 原因を示す" "yes" "$(grep -q -- "$fragment" "$work/out.txt" && echo yes || echo no)"
  check "$name: README を書き換えない" "$before" "$(cat "$readme")"
}
make_bucket; manifest a '{"homepage":"https://github.com/o/a"}'; make_readme ''
fail_case "description なし" 'a.json'
make_bucket; manifest a '{"description":"","homepage":"https://github.com/o/a"}'; make_readme ''
fail_case "description が空" 'a.json'
make_bucket; manifest a '{"description":"Tool A"}'; make_readme ''
fail_case "homepage なし" 'a.json'
make_bucket; manifest a '{"description":"Tool A","homepage":"https://github.com/o/a"}'
printf '%s\n' '# t' '表だけ' > "$readme"
fail_case "マーカーなし" 'マーカー'
printf '%s\n' "${head_lines[@]}" "${tail_lines[@]}" "${head_lines[@]}" "${tail_lines[@]}" > "$readme"
fail_case "マーカーが 2 組" 'マーカー'
printf '%s\n' '<!-- apps:end -->' '<!-- apps:begin -->' > "$readme"
fail_case "end が begin より前" '前に置いて'
make_bucket; make_readme ''
fail_case "マニフェストが 0 件" 'マニフェストがありません'

exit "$fail"
