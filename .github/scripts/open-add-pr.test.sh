#!/usr/bin/env bash
# open-add-pr.sh の回帰テスト。ベアリポジトリと、モックの gh を使い、外部サービスに触れない。
# ケース: 通常 / push 後に PR 作成が失敗 → 再実行で復旧（push せず PR だけ作る） / 既存の PR（スキップ）
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/open-add-pr.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/gh" << 'MOCK'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG"
case "$2" in
  list) printf '%s' "${MOCK_PRLIST:-}" ;;
  create) if [ "${MOCK_FAIL_CREATE:-0}" = 1 ]; then echo "gh: HTTP 502" >&2; exit 1; fi ;;
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
  )
}
reset_remote() {
  rm -rf "$work/remote.git" "$work/seed"
  git init -q --bare -b main "$work/remote.git"
  git init -q -b main "$work/seed"
  (cd "$work/seed" && git config user.name t && git config user.email t@t && echo x > README && git add . && git commit -qm init && git remote add origin "$work/remote.git" && git push -q origin main)
}

# 実行して、終了コードと、gh の呼び出し（pr list 以外）を返す
run() {
  : > "$work/log.txt"
  local code=0
  (
    cd "$work/clone"
    PATH="$work/bin:$PATH" MOCK_LOG="$work/log.txt" GH_TOKEN=dummy APP_SLUG=bot REPOSITORY=o/r BASE_BRANCH=main \
      MANIFEST=bucket/app.json SOURCE_REPOSITORY=o/app bash "$script" > "$work/out.txt" 2>&1
  ) || code=$?
  echo "$code"
}
remote_branch() { git -C "$work/remote.git" branch --list 'add/*' | tr -d ' *\n'; }
creates() { grep -c "^gh pr create" "$work/log.txt" || true; }

check() { # 名前 / 期待 / 実際
  if [ "$2" = "$3" ]; then echo "OK: $1"; else echo "NG: $1（期待: $2 / 実際: $3）"; fail=1; fi
}

reset_remote; new_work_clone
export MOCK_FAIL_CREATE=0 MOCK_PRLIST=""
code="$(run)"
check "通常: 終了コード 0" "0" "$code"
check "通常: ブランチ add/app を push した" "add/app" "$(remote_branch)"
check "通常: PR を 1 件作った" "1" "$(creates)"
check "通常: タイトルに名前と版" "1" "$(grep -c 'feat(app): マニフェストを追加 (v1.2.3)' "$work/log.txt")"
check "通常: マニフェストをコミットした" "bucket/app.json" "$(git -C "$work/remote.git" show --name-only --format= add/app | tr -d '\n')"

reset_remote; new_work_clone
export MOCK_FAIL_CREATE=1
code="$(run)"
check "PR 作成の失敗: 終了コード 非 0" "1" "$([ "$code" != 0 ] && echo 1 || echo 0)"
check "PR 作成の失敗: ブランチは残る" "add/app" "$(remote_branch)"
sha_before="$(git -C "$work/remote.git" rev-parse add/app)"
new_work_clone
export MOCK_FAIL_CREATE=0
code="$(run)"
check "再実行: 終了コード 0（non-fast-forward で拒否されない）" "0" "$code"
check "再実行: ブランチの先頭を変えない（push しない）" "$sha_before" "$(git -C "$work/remote.git" rev-parse add/app)"
check "再実行: PR だけを作る" "1" "$(creates)"

reset_remote; new_work_clone
export MOCK_PRLIST="7"
code="$(run)"
check "既存の PR: 終了コード 0" "0" "$code"
check "既存の PR: ブランチを作らない" "" "$(remote_branch)"
check "既存の PR: PR を作らない" "0" "$(creates)"

exit "$fail"
