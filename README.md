# scoop-bucket

Personal Scoop bucket for tools created by [@scottlz0310](https://github.com/scottlz0310).

## 使い方 / How to Use

### 1. バケットの追加

```powershell
scoop bucket add scottlz0310 https://github.com/scottlz0310/scoop-bucket
```

### 2. アプリケーションのインストール

```powershell
scoop install <app>
```

## 登録アプリケーション一覧

| アプリケーション | 説明 |
|---|---|
| [**clp2cfg**](https://github.com/scottlz0310/clp2cfg) | コピーしたMCP設定スニペットを自動正規化し、各種AIクライアントの設定へ安全に差分マージする超軽量デスクトップGUIツール |

## マニフェストの自動更新

`checkver` / `autoupdate` を持つマニフェストは、GitHub Actions（`Update Manifests`）が毎日 1 回新しいリリースを確認し、更新があれば更新 PR を作ります。`main` への直接 push はできないため、PR のマージは手動です。

リリース直後に反映したいときは、Actions の「Update Manifests」から「Run workflow」で手動起動できます。

## レビュー対応の CI 判定（`.review-raven/ci-policy.json`）

`Update Manifests` の `report` ジョブは、PR では Issue を作らない設計のため、必ず `skipped` になります。レビュー対応の完了記録の検証（`mcp-docker reviewgate validate`）は、`skipped` を一律には許さず、リポジトリが名前を明示した check だけを成功として扱います。その宣言が `.review-raven/ci-policy.json` です。

- 宣言は、**PR の HEAD ではなく、base ref（`main`）のファイルだけ**が読まれます。PR 自身が、自分の skip を許可することはできません。このファイルを追加・変更する PR は、その PR のレビューには反映されません。
- 許可するのは、名前が完全一致する `skipped` だけです。本来動くべき check（`verify` など）が黙って `skipped` になった場合は、許可されず、失敗として扱われます。
- 形式は `.github/scripts/validate-ci-policy.sh` が検証します。

## ライセンス

[CC0 1.0 Universal](LICENSE) または [MIT License](LICENSE-MIT)
