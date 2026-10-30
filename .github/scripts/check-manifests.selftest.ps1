<#
.SYNOPSIS
    check-manifests.ps1 の回帰テスト。「1 つのマニフェストの失敗が、他のマニフェストの更新を巻き込まない」ことと、
    「最新版を確認できなかった失敗を、成功と記録しない」ことを固定する。
.DESCRIPTION
    一時ディレクトリに、失敗するマニフェストと、正常なマニフェストを並べて置き、一括で実行させる。
    ケースごとに確認すること:
      - 失敗するマニフェストが、ok: false で、メッセージつきで記録される
      - 失敗したマニフェストが、元の内容に戻される
      - 後続の正常なマニフェストが処理され、ok: true で記録される（失敗に巻き込まれない）
      - スクリプト自体は終了コード 0 で終わる（成否の判定は後続のステップが行う）
    失敗するマニフェストの名前を先頭（アルファベット順で先）に置くのは、「先に失敗すると、後続が処理されない」
    という元の不具合（checkver -Dir の一括実行）を再現するため。
    固定している不具合:
      - autoupdate-url: autoupdate の例外（-ThrowError で終了コードに反映される）
      - checkver-url / checkver-regex: 最新版の取得先に届かない / 正規表現が一致しない。checkver はエラーを
        表示するだけで終了コード 0 になり、-ThrowError も効かない。「版を報告したか」まで見ないと成功と誤記録される
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

# Fixture: 失敗させる fixture の名前 / Version: 指定すると、マニフェストの版をこの値に書き換える
# （checkver -Update は、最新版と現在の版が同じだと autoupdate を実行しないため、autoupdate の失敗を起こすには版を古くする）
$cases = @(
    @{ Name = 'autoupdate-url'; Fixture = 'broken-autoupdate-url'; Version = '0.0.1' }
    @{ Name = 'checkver-url';   Fixture = 'broken-checkver-url' }
    @{ Name = 'checkver-regex'; Fixture = 'broken-checkver-regex' }
)

function Test-Case {
    param($Case)
    $work = Join-Path ([IO.Path]::GetTempPath()) "check-selftest-$([guid]::NewGuid())"
    # 結果の JSON はマニフェストのディレクトリの外に置く（中に置くと、次の実行でマニフェストとして列挙される）
    $resultPath = "$work.result.json"
    New-Item -ItemType Directory $work | Out-Null
    try {
        # 名前順で、失敗するものが先になるようにする（a-broken < b-good）
        $broken = Get-Content (Join-Path $fixtures "$($Case.Fixture).json") -Raw
        if ($Case.ContainsKey('Version')) { $broken = $broken.Replace('"version": "0.1.0"', "`"version`": `"$($Case.Version)`"") }
        [IO.File]::WriteAllText((Join-Path $work 'a-broken.json'), $broken)
        Copy-Item (Join-Path $fixtures 'bad-format.json') (Join-Path $work 'b-good.json')
        $brokenBefore = [IO.File]::ReadAllText((Join-Path $work 'a-broken.json'))

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
        return $failed
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
    }
}

$allFailed = @()
foreach ($case in $cases) {
    Write-Host "::group::check selftest: $($case.Name)"
    $failures = @(Test-Case $case)
    Write-Host '::endgroup::'
    if ($failures.Count -gt 0) {
        $allFailed += $failures | ForEach-Object { "$($case.Name): $_" }
    } else {
        Write-Host "OK: $($case.Name) は失敗として記録され、後続が処理され、元の内容に戻された"
    }
}

if ($allFailed.Count -gt 0) {
    $allFailed | ForEach-Object { Write-Host "::error title=check selftest::$_" }
    exit 1
}

# 最後に実行した子プロセスの $LASTEXITCODE を、Actions の pwsh ステップに引き継がない
exit 0
