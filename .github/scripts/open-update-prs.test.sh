#!/usr/bin/env bash
# open-update-prs.sh の回帰テスト。ベアリポジトリとモックの gh を使い、外部サービスに触れない。
# ケース: 通常（PR 作成 + 自動マージ有効化） / open PR が自動マージ未設定 → 復旧して有効化
#         / 既存 PR（自動マージ済みまたは closed）→ スキップ / 複数マニフェスト更新
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/open-update-prs.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/gh" << 'MOCK'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG"
case "$2" in
  list)
    if [[ " $* " == *" --state open "* ]]; then
      printf '%s' "${MOCK_OPEN_PR:-}"
    else
      printf '%s' "${MOCK_PRLIST:-}"
    fi
    ;;
  create)
    if [ "${MOCK_FAIL_CREATE:-0}" = 1 ]; then echo "gh: HTTP 502" >&2; exit 1; fi
    printf 'https://github.com/o/r/pull/42\n'
    ;;
  merge)
    if [ "${MOCK_FAIL_MERGE:-0}" = 1 ]; then echo "gh: auto-merge rejected" >&2; exit 1; fi
    ;;
esac
MOCK
chmod +x "$work/bin/gh"

fail=0
new_work_clone() {
  rm -rf "$work/clone"
  git clone -q "$work/remote.git" "$work/clone" 2>/dev/null
  (
    cd "$work/clone"
    git config user.name t && git config user.email t@t
    mkdir -p bucket
    printf '%s' '{"version":"1.2.3","homepage":"https://github.com/o/app"}' > bucket/app.json
    if [ "${1:-single}" = "multi" ]; then
      printf '%s' '{"version":"2.0.0","homepage":"https://github.com/o/tool"}' > bucket/tool.json
    fi
  )
}

reset_remote() {
  rm -rf "$work/remote.git" "$work/seed"
  git init -q --bare -b main "$work/remote.git"
  git init -q -b main "$work/seed"
  (
    cd "$work/seed"
    git config user.name t && git config user.email t@t
    mkdir -p bucket
    printf '%s' '{"version":"1.0.0","homepage":"https://github.com/o/app"}' > bucket/app.json
    printf '%s' '{"version":"1.0.0","homepage":"https://github.com/o/tool"}' > bucket/tool.json
    git add . && git commit -qm init && git remote add origin "$work/remote.git" && git push -q origin main
  )
}

run() {
  : > "$work/log.txt"
  local code=0
  (
    cd "$work/clone"
    PATH="$work/bin:$PATH" MOCK_LOG="$work/log.txt" GH_TOKEN=dummy APP_SLUG=bot REPOSITORY=o/r BASE_BRANCH=main \
      bash "$script" > "$work/out.txt" 2>&1
  ) || code=$?
  echo "$code"
}
remote_branches() { git -C "$work/remote.git" branch --list 'update/*' | tr -d ' *'; }
creates() { grep -c "^gh pr create" "$work/log.txt" || true; }
auto_merges() { grep -c "^gh pr merge --auto --squash" "$work/log.txt" || true; }

check() {
  if [ "$2" = "$3" ]; then echo "OK: $1"; else echo "NG: $1（期待: $2 / 実際: $3）"; fail=1; fi
}

# 1. 通常: ブランチ作成・push・PR 作成・auto-merge 有効化
reset_remote; new_work_clone single
export MOCK_FAIL_CREATE=0 MOCK_FAIL_MERGE=0 MOCK_PRLIST="" MOCK_OPEN_PR=""
code="$(run)"
check "通常: 終了コード 0" "0" "$code"
check "通常: ブランチ update/app-1.2.3 を push した" "update/app-1.2.3" "$(remote_branches)"
check "通常: PR を 1 件作った" "1" "$(creates)"
check "通常: auto-merge を 1 回呼んだ" "1" "$(auto_merges)"
check "通常: auto-merge に作成 URL を渡した" "1" "$(grep -c '^gh pr merge --auto --squash --repo o/r https://github.com/o/r/pull/42$' "$work/log.txt")"

# 2. PR 作成後の auto-merge 失敗 → 再実行で open PR に auto-merge を設定し復旧
reset_remote; new_work_clone single
export MOCK_FAIL_MERGE=1
code="$(run)"
check "auto-merge 失敗: 終了コード 非 0" "1" "$([ "$code" != 0 ] && echo 1 || echo 0)"
new_work_clone single
export MOCK_FAIL_MERGE=0 MOCK_PRLIST="42" MOCK_OPEN_PR=$'42\tfalse'
code="$(run)"
check "再実行(未設定): 終了コード 0" "0" "$code"
check "再実行(未設定): PR を作り直さない" "0" "$(creates)"
check "再実行(未設定): 既存 PR #42 に auto-merge を設定する" "1" "$(grep -c '^gh pr merge --auto --squash --repo o/r 42$' "$work/log.txt")"
check "再実行(未設定): ローカルの変更を元に戻す" "" "$(git -C "$work/clone" diff --name-only -- bucket)"

# 3. 既に auto-merge 設定済みの open PR がある場合はスキップ
new_work_clone single
export MOCK_PRLIST="42" MOCK_OPEN_PR=$'42\ttrue'
code="$(run)"
check "設定済み PR: 終了コード 0" "0" "$code"
check "設定済み PR: PR も auto-merge も呼ばない" "0" "$(($(creates) + $(auto_merges)))"
check "設定済み PR: ローカルの変更を元に戻す" "" "$(git -C "$work/clone" diff --name-only -- bucket)"

# 4. 複数マニフェスト同時更新
reset_remote; new_work_clone multi
export MOCK_PRLIST="" MOCK_OPEN_PR=""
code="$(run)"
check "複数更新: 終了コード 0" "0" "$code"
check "複数更新: PR を 2 件作った" "2" "$(creates)"
check "複数更新: auto-merge を 2 回呼んだ" "2" "$(auto_merges)"

exit "$fail"
