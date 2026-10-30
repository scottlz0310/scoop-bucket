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

<!-- 次の一覧は .github/scripts/render-readme-apps.sh が bucket/*.json から生成する。直接編集しない -->
<!-- apps:begin -->
| アプリケーション | 説明 |
|---|---|
| [**agent-statusline**](https://github.com/scottlz0310/agent-statusline) | カスタムステータスライン対応の各種CLI(claude-code copilot-cli antigravity-cli)等のプロンプト表示を超高速化するRust製ステータスライン。TUI設定機能・レートリミット監視・自動配布対応。 |
| [**clp2cfg**](https://github.com/scottlz0310/clp2cfg) | コピーしたMCP設定スニペットを自動正規化し、各種AIクライアントの設定へ安全に差分マージする超軽量デスクトップGUIツール |
<!-- apps:end -->

## マニフェストの自動更新

`checkver` / `autoupdate` を持つマニフェストは、GitHub Actions（`Update Manifests`）が毎日 1 回新しいリリースを確認し、更新があれば更新 PR を作ります。`main` への直接 push はできないため、PR のマージは手動です。

リリース直後に反映したいときは、Actions の「Update Manifests」から「Run workflow」で手動起動できます。

## 新しいアプリの追加

Actions の「Add Manifest」から「Run workflow」で `owner/repo` を入力すると、その repo の最新リリースから、標準形のマニフェスト（`checkver` / `autoupdate` / `.sha256` からのハッシュ取得）を生成する PR が作られます。PR には「Verify Manifests」（隔離した Scoop へのインストール）が走ります。マージは手動です。

- **前提**: Scoop が配るのはビルド済みのバイナリです。リリースに、Windows 用の ZIP（既定は `{repo 名}-x86_64-pc-windows-msvc.zip`）と、その `.sha256` が必要です。PyPI・npm・crates.io・Go だけで配っているプロジェクトは、先にリリースで ZIP と `.sha256` を出してください。
- **対象**: このバケットと同じ owner の repo だけです。`persist` / `pre_install` などが要るアプリは、足場の対象外（手書きにします）。
- **ライセンスの指定**: GitHub は二重ライセンス（`MIT OR Apache-2.0` など）を認識しません。その場合は `license` を指定してください。
- 生成と PR の作成は `.github/scripts/new-manifest.ps1` と `open-add-pr.sh` です。
- 上の「登録アプリケーション一覧」も同じ PR で更新されます。

## 登録アプリケーション一覧の自動生成

一覧は、`bucket/*.json` の `description` と `homepage` から `.github/scripts/render-readme-apps.sh` が生成します。生成範囲は README の `<!-- apps:begin -->` と `<!-- apps:end -->` の間だけで、直接編集しません。説明は日本語で書きます（このバケットのアプリは作者自身のツールで、一覧と `scoop info` の表示を揃えるため）。変えたいときは、マニフェストの `description` を変えて、スクリプトを実行します。PR では `Check README` が、一覧がマニフェストと一致していることを検査します。

## レビュー対応の CI 判定（`.review-raven/ci-policy.json`）

`Update Manifests` の `report` ジョブは、PR では Issue を作らない設計のため、必ず `skipped` になります。レビュー対応の完了記録の検証（`mcp-docker reviewgate validate`）は、`skipped` を一律には許さず、リポジトリが名前を明示した check だけを成功として扱います。その宣言が `.review-raven/ci-policy.json` です。

- 宣言は、**PR の HEAD ではなく、base ref（`main`）のファイルだけ**が読まれます。PR 自身が、自分の skip を許可することはできません。このファイルを追加・変更する PR は、その PR のレビューには反映されません。
- 許可するのは、名前が完全一致する `skipped` だけです。本来動くべき check（`verify` など）が黙って `skipped` になった場合は、許可されず、失敗として扱われます。
- 形式は `.review-raven/validate-ci-policy.sh` が検証します。

## ライセンス

[CC0 1.0 Universal](LICENSE) または [MIT License](LICENSE-MIT)
