<#
.SYNOPSIS
    すべてのマニフェストの URL のリンク切れと、ハッシュの不一致を検査し、マニフェストごとの成否を JSON に記録する。health.yml から呼ばれる。
.DESCRIPTION
    Scoop 標準の checkurls.ps1（URL に届くか）と checkhashes.ps1（資産をダウンロードして、マニフェストのハッシュと比べる）を使う。
    どちらも、1 つのマニフェストで例外が出ると全体が止まるうえ、失敗しても終了コード 0 で終わる。そのため、
    マニフェストごと・検査ごとに子プロセスで実行し、終了コードではなく出力の形で成否を判定する:
      - checkurls:   "[<URL 数>][<届いた数>][<届かなかった数>] <名前>" の行が出て、全部届いている。
      - checkhashes: "<名前>: OK" の行が出る（不一致なら "Mismatch found"、ダウンロードの例外ならこの行が出ない）。
    どちらの行も出なかったとき（スクリプトの異常終了など）は、成功とみなさず失敗として記録する。
    検査はマニフェストを書き換えない（checkhashes の -Update は使わない）。
    このスクリプトは、失敗しても終了コード 0 で終わる。成否の判定と通知は、記録した JSON を読む後続のステップが行う。
    Scoop のキャッシュは一時ディレクトリに隔離する（実行した環境の Scoop に触れない）。
.PARAMETER ScoopRoot
    Scoop 本体のリポジトリのパス（setup-scoop が取得した ./scoop）。
.PARAMETER ResultPath
    結果を書き出す JSON のパス。[{ name, ok, message }] の配列。
.PARAMETER BucketDir
    マニフェストのあるディレクトリ。
.PARAMETER UrlTimeoutSec
    checkurls の、1 つの URL あたりのタイムアウト（秒）。既定の 5 秒は GitHub のリダイレクト先には短い。
#>
param(
    [Parameter(Mandatory)][string] $ScoopRoot,
    [Parameter(Mandatory)][string] $ResultPath,
    [string] $BucketDir = 'bucket',
    [int] $UrlTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScoopRoot = Convert-Path $ScoopRoot
$BucketDir = Convert-Path $BucketDir

function ConvertTo-PlainLines {
    param([object[]] $Output)
    @($Output | ForEach-Object { ($_.ToString() -replace '\x1b\[[0-9;]*m', '').TrimEnd() })
}

# 子プロセスで Scoop のスクリプトを実行し、出力の行を返す。終了コードは信用しないので返さない
function Invoke-ScoopCheck {
    param([string] $Script, [string[]] $Arguments)
    ConvertTo-PlainLines (& pwsh -NoProfile -File (Join-Path $ScoopRoot "bin/$Script") @Arguments 2>&1)
}

# 失敗の理由を 1 件返す。成功なら $null
function Test-Urls {
    param([string] $Name, [string[]] $Lines)
    $summary = @($Lines | Where-Object { $_ -match "^\[(\d+)\]\[(\d+)\]\[(\d+)\] $([regex]::Escape($Name))$" })
    if ($summary.Count -eq 0) { return 'URL の検査結果を得られなかった（checkurls が結果の行を出さなかった）' }
    $null = $summary[0] -match '^\[(\d+)\]\[(\d+)\]\[(\d+)\]'
    $total = [int] $Matches[1]; $reached = [int] $Matches[2]; $failed = [int] $Matches[3]
    if ($total -eq 0) { return 'マニフェストに URL が無い' }
    if ($failed -gt 0 -or $reached -ne $total) { return "リンク切れ: $total 件中 $failed 件の URL に届かなかった" }
    return $null
}

function Test-Hashes {
    param([string] $Name, [string[]] $Lines)
    if (@($Lines | Where-Object { $_ -eq "${Name}: OK" }).Count -gt 0) { return $null }
    if (@($Lines | Where-Object { $_ -eq "${Name}: Mismatch found" }).Count -gt 0) {
        return 'ハッシュの不一致: リリース資産が、マニフェストのハッシュと合わなくなっている（差し替えられた可能性）'
    }
    return 'ハッシュを検査できなかった（資産をダウンロードできない、または checkhashes が結果の行を出さなかった）'
}

function New-Result {
    param([string] $Name, [string[]] $Reasons = @(), [string[]] $Lines = @())
    if ($Reasons.Count -eq 0) { return [pscustomobject]@{ name = $Name; ok = $true; message = '' } }
    # 通知に載せるのは末尾だけ（長い出力で Issue を埋めない）
    $message = ($Reasons -join "`n") + "`n`n" + (($Lines | Select-Object -Last 20) -join "`n")
    if ($message.Length -gt 2000) { $message = $message.Substring($message.Length - 2000) }
    return [pscustomobject]@{ name = $Name; ok = $false; message = $message }
}

function Test-OneManifest {
    param([System.IO.FileInfo] $File)
    $name = $File.BaseName
    # このマニフェストで起きた例外が、他のマニフェストの検査を止めないよう、ここで受ける
    try {
        try {
            $null = [IO.File]::ReadAllText($File.FullName) | ConvertFrom-Json
        } catch {
            return New-Result $name @("マニフェストを JSON として読めない: $($_.Exception.Message)")
        }

        Write-Host "::group::$name"
        $urlLines = Invoke-ScoopCheck 'checkurls.ps1' @($name, $BucketDir, '-Timeout', $UrlTimeoutSec)
        $hashLines = Invoke-ScoopCheck 'checkhashes.ps1' @($name, $BucketDir)
        $urlLines | Out-Host
        $hashLines | Out-Host
        Write-Host '::endgroup::'

        $reasons = @()
        $urlReason = Test-Urls $name $urlLines
        $hashReason = Test-Hashes $name $hashLines
        if ($urlReason) { $reasons += $urlReason }
        if ($hashReason) { $reasons += $hashReason }

        $lines = @()
        if ($urlReason) { $lines += $urlLines }
        if ($hashReason) { $lines += $hashLines }
        return New-Result $name $reasons $lines
    } catch {
        return New-Result $name @("想定外のエラー: $($_.Exception.Message)")
    }
}

# Scoop のキャッシュ（checkhashes がダウンロードする先）を、一時ディレクトリに隔離する
$isolated = Join-Path ([IO.Path]::GetTempPath()) "scoop-health-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path (Join-Path $isolated 'cache') -Force | Out-Null
$previousScoop = $env:SCOOP
$env:SCOOP = $isolated
try {
    $results = foreach ($file in Get-ChildItem $BucketDir -Filter '*.json' | Sort-Object Name) {
        Test-OneManifest $file
    }
} finally {
    $env:SCOOP = $previousScoop
    if (Test-Path $isolated) { Remove-Item $isolated -Recurse -Force }
}

# 結果が 1 件でも 0 件でも、配列として書き出す（パイプラインで渡す理由は check-manifests.ps1 と同じ）
if (@($results).Count -eq 0) {
    Set-Content -Path $ResultPath -Value '[]' -Encoding utf8
} else {
    @($results) | ConvertTo-Json -AsArray -Depth 3 | Set-Content -Path $ResultPath -Encoding utf8
}
Write-Host "結果: $(@($results | Where-Object { $_.ok }).Count) 件成功 / $(@($results | Where-Object { -not $_.ok }).Count) 件失敗"
exit 0
