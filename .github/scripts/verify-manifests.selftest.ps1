<#
.SYNOPSIS
    verify-manifests.ps1 の回帰テスト。壊れた fixture を検証させ、失敗を検出できることを確認する。
.DESCRIPTION
    検証スクリプトが「失敗を成功扱いにする」不具合は、通常の CI（正しいマニフェストを検証する）では見えない。
    そのため、意図的に壊した fixture（.github/verify-fixtures）を検証させ、終了コード 1 と、
    期待する理由のメッセージの両方が出ることを確認する。
    固定している不具合（いずれも、Scoop が失敗を終了コード 0 で隠す）:
      - broken-autoupdate-url: checkver に -ThrowError が無いと、autoupdate.url のダウンロード失敗が終了コード 0 になる
      - broken-autoupdate-hash: hash.url から取得できなくても、Scoop はダウンロードして計算する代替に落ちて成功する
      - bad-hash: scoop install がハッシュ不一致でも終了コード 0 を返す（current の有無で判定する）
.PARAMETER ScoopRoot
    Scoop 本体のリポジトリのパス（setup-scoop が取得した ./scoop）。
#>
param(
    [Parameter(Mandatory)][string] $ScoopRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$verifyScript = Join-Path $PSScriptRoot 'verify-manifests.ps1'
$fixtures = Join-Path $PSScriptRoot '../verify-fixtures'

# 名前: fixture の名前 / Expect: 失敗の理由として出力に含まれるべき文字列
$cases = @(
    @{ Name = 'broken-autoupdate-url';  Expect = 'checkver の実行に失敗' }
    @{ Name = 'broken-autoupdate-hash'; Expect = 'ハッシュ取得先（hash.url）から取得できない' }
    @{ Name = 'bad-hash';               Expect = 'scoop install に失敗' }
    @{ Name = 'bad-format';             Expect = 'Scoop 標準の書式と異なる' }
    @{ Name = 'missing-shim';           Expect = 'shim が無い' }
)

$failed = @()
foreach ($case in $cases) {
    Write-Host "::group::selftest: $($case.Name)"
    $output = & pwsh -NoProfile -File $verifyScript -ScoopRoot $ScoopRoot -BucketDir $fixtures `
        -VerifyConfig (Join-Path $fixtures 'verify.json') -Name $case.Name 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    # 子プロセスの ::error などが、そのままワークフローのコマンドとして解釈され、期待どおりの失敗が
    # PR のエラー注釈に出てしまう。行頭の :: を無害化して表示する
    Write-Host ($output -replace '(?m)^::', '> ::')
    Write-Host '::endgroup::'

    if ($exitCode -ne 1) {
        $failed += "$($case.Name): 失敗を検出できなかった（終了コード $exitCode。期待: 1）"
    } elseif (-not $output.Contains($case.Expect)) {
        $failed += "$($case.Name): 失敗の理由が違う（期待するメッセージ「$($case.Expect)」が出力に無い）"
    } else {
        Write-Host "OK: $($case.Name) は期待どおり失敗した"
    }
}

if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host "::error title=selftest::$_" }
    exit 1
}

# 最後に実行した子プロセスは「失敗するはず」のもの。Actions の pwsh ステップは、スクリプトの終了時に
# $LASTEXITCODE が非 0 だとステップを失敗にするため、成功は明示的に 0 で終える
exit 0
