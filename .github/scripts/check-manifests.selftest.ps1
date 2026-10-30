<#
.SYNOPSIS
    check-manifests.ps1 の回帰テスト。「1 つのマニフェストの失敗が、他のマニフェストの更新を巻き込まない」ことを固定する。
.DESCRIPTION
    一時ディレクトリに、更新できるマニフェストと、更新で失敗するマニフェストを並べて置き、一括で実行させる。
    確認すること:
      - 失敗するマニフェストがあっても、他のマニフェストが処理される（結果に ok: true として残る）
      - 失敗したマニフェストは ok: false で記録され、元の内容に戻される
      - スクリプト自体は終了コード 0 で終わる（成否の判定は後続のステップが行う）
    失敗するマニフェストの名前を先頭（アルファベット順で先）に置くのは、「先に失敗すると、後続が処理されない」
    という元の不具合（checkver -Dir の一括実行）を再現するため。
.PARAMETER ScoopRoot
    Scoop 本体のリポジトリのパス（setup-scoop が取得した ./scoop）。
#>
param(
    [Parameter(Mandatory)][string] $ScoopRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checkScript = Join-Path $PSScriptRoot 'check-manifests.ps1'
$fixtures = Join-Path $PSScriptRoot '../verify-fixtures'
$work = Join-Path ([IO.Path]::GetTempPath()) "check-selftest-$([guid]::NewGuid())"
New-Item -ItemType Directory $work | Out-Null

try {
    # 名前順で、失敗するものが先になるようにする（a-broken < b-good）。
    # checkver -Update は、最新版と現在の版が同じだと autoupdate を実行しない。失敗させるため、版を古くして更新を発生させる
    $broken = (Get-Content (Join-Path $fixtures 'broken-autoupdate-url.json') -Raw).Replace('"version": "0.1.0"', '"version": "0.0.1"')
    [IO.File]::WriteAllText((Join-Path $work 'a-broken.json'), $broken)
    Copy-Item (Join-Path $fixtures 'bad-format.json') (Join-Path $work 'b-good.json')
    $brokenBefore = [IO.File]::ReadAllText((Join-Path $work 'a-broken.json'))
    $resultPath = Join-Path $work 'result.json'

    & pwsh -NoProfile -File $checkScript -ScoopRoot $ScoopRoot -BucketDir $work -ResultPath $resultPath | Out-Host
    $exitCode = $LASTEXITCODE

    $failed = @()
    if ($exitCode -ne 0) { $failed += "スクリプトが失敗した（終了コード $exitCode。常に 0 で終わるはず）" }

    $results = @(Get-Content $resultPath -Raw | ConvertFrom-Json)
    $byName = @{}
    foreach ($r in $results) { $byName[$r.name] = $r }

    if ($results.Count -ne 2) { $failed += "結果が 2 件ではない（$($results.Count) 件）" }
    if (-not $byName.ContainsKey('a-broken') -or $byName['a-broken'].ok) { $failed += 'a-broken が失敗として記録されていない' }
    elseif (-not $byName['a-broken'].message) { $failed += 'a-broken の失敗に、メッセージが無い' }
    if (-not $byName.ContainsKey('b-good') -or -not $byName['b-good'].ok) { $failed += 'b-good（後続）が処理されていない / 成功として記録されていない' }
    if ([IO.File]::ReadAllText((Join-Path $work 'a-broken.json')) -cne $brokenBefore) { $failed += '失敗した a-broken が、元の内容に戻されていない' }

    if ($failed.Count -gt 0) {
        $failed | ForEach-Object { Write-Host "::error title=check selftest::$_" }
        exit 1
    }
    Write-Host 'OK: 失敗するマニフェストが先にあっても、後続が処理され、失敗は記録され、元の内容に戻された'
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# 最後に実行した子プロセスの $LASTEXITCODE を、Actions の pwsh ステップに引き継がない
exit 0
