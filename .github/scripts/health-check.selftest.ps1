<#
.SYNOPSIS
    health-check.ps1 の回帰テスト。リンク切れとハッシュの不一致を、失敗として記録できることを固定する。
.DESCRIPTION
    一時ディレクトリに、失敗するマニフェスト（a-broken）と、正常なマニフェスト（b-good。実物の clp2cfg）を並べて置き、
    一括で実行させる。ケースごとに確認すること:
      - a-broken が ok: false で、原因を示すメッセージつきで記録される
      - 後続の b-good が処理され、ok: true で記録される（失敗に巻き込まれない）
      - マニフェストが書き換えられない（検査は読み取りだけ）
      - スクリプト自体は終了コード 0 で終わる（成否の判定と通知は後続のステップが行う）
    Scoop の checkurls / checkhashes は、失敗しても終了コード 0 で終わる。そのため、「出力の形」で判定している
    health-check.ps1 が、実物の出力で失敗を見逃さないことを、ここで固定する。
    実際のリリース資産にアクセスする（clp2cfg の資産をダウンロードする）。
.PARAMETER ScoopRoot
    Scoop 本体のリポジトリのパス（setup-scoop が取得した ./scoop）。
.PARAMETER RepoRoot
    リポジトリのルート（bucket/clp2cfg.json と fixture を参照する）。
#>
param(
    [Parameter(Mandatory)][string] $ScoopRoot,
    [string] $RepoRoot = (Join-Path $PSScriptRoot '../..')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$checkScript = Join-Path $PSScriptRoot 'health-check.ps1'
$realManifest = Join-Path $RepoRoot 'bucket/clp2cfg.json'

# Fixture: 失敗させるマニフェストのファイル（リポジトリのルートからの相対パス）/ Content: 代わりに、この文字列をそのまま内容にする
# Expect: 失敗のメッセージに含まれるべき文字列
$cases = @(
    @{ Name = 'bad-hash';   Fixture = '.github/verify-fixtures/bad-hash.json';  Expect = 'ハッシュの不一致' }
    @{ Name = 'broken-url'; Fixture = '.github/health-fixtures/broken-url.json'; Expect = 'リンク切れ' }
    @{ Name = 'invalid-json'; Content = '{invalid';                             Expect = 'JSON として読めない' }
    @{ Name = 'no-url';     Content = '{"version":"1.0.0"}';                    Expect = 'URL が無い' }
)

function Test-Case {
    param($Case)
    $work = Join-Path ([IO.Path]::GetTempPath()) "health-selftest-$([guid]::NewGuid())"
    # 結果の JSON はマニフェストのディレクトリの外に置く（中に置くと、次の実行でマニフェストとして列挙される）
    $resultPath = "$work.result.json"
    New-Item -ItemType Directory $work | Out-Null
    try {
        # 名前順で、失敗するものが先になるようにする（a-broken < b-good）。先に失敗すると後続が処理されない不具合を再現できる
        $broken = if ($Case.ContainsKey('Content')) { $Case.Content } else { Get-Content (Join-Path $RepoRoot $Case.Fixture) -Raw }
        [IO.File]::WriteAllText((Join-Path $work 'a-broken.json'), $broken)
        Copy-Item $realManifest (Join-Path $work 'b-good.json')
        $before = @{
            broken = [IO.File]::ReadAllText((Join-Path $work 'a-broken.json'))
            good   = [IO.File]::ReadAllText((Join-Path $work 'b-good.json'))
        }

        & pwsh -NoProfile -File $checkScript -ScoopRoot $ScoopRoot -BucketDir $work -ResultPath $resultPath | Out-Host
        $exitCode = $LASTEXITCODE

        $failed = @()
        if ($exitCode -ne 0) { $failed += "スクリプトが失敗した（終了コード $exitCode。常に 0 で終わるはず）" }
        # 結果が無いと、後続の通知が何もできない。例外で止まらず、明確な失敗として返す
        if (-not (Test-Path $resultPath)) { return $failed + '結果の JSON が生成されなかった' }

        $results = @(Get-Content $resultPath -Raw | ConvertFrom-Json)
        $byName = @{}
        foreach ($r in $results) { $byName[$r.name] = $r }

        if ($results.Count -ne 2) { $failed += "結果が 2 件ではない（$($results.Count) 件）" }
        if (-not $byName.ContainsKey('a-broken') -or $byName['a-broken'].ok) { $failed += 'a-broken が失敗として記録されていない' }
        elseif ($byName['a-broken'].message -notlike "*$($Case.Expect)*") { $failed += "a-broken の失敗に、原因（$($Case.Expect)）が示されていない: $($byName['a-broken'].message)" }
        if (-not $byName.ContainsKey('b-good') -or -not $byName['b-good'].ok) { $failed += 'b-good（後続）が処理されていない / 成功として記録されていない' }
        if ([IO.File]::ReadAllText((Join-Path $work 'a-broken.json')) -cne $before.broken) { $failed += 'a-broken が書き換えられた（検査は読み取りだけのはず）' }
        if ([IO.File]::ReadAllText((Join-Path $work 'b-good.json')) -cne $before.good) { $failed += 'b-good が書き換えられた（検査は読み取りだけのはず）' }
        return $failed
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
    }
}

$allFailed = @()
foreach ($case in $cases) {
    Write-Host "::group::health selftest: $($case.Name)"
    $failures = @(Test-Case $case)
    Write-Host '::endgroup::'
    if ($failures.Count -gt 0) {
        $allFailed += $failures | ForEach-Object { "$($case.Name): $_" }
    } else {
        Write-Host "OK: $($case.Name) は失敗として記録され、後続が処理された"
    }
}

if ($allFailed.Count -gt 0) {
    foreach ($f in $allFailed) { Write-Host "::error title=health-check selftest::$f" }
    exit 1
}
Write-Host "OK: health-check の回帰テストがすべて通った（$($cases.Count) ケース）"
exit 0
