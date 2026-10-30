<#
.SYNOPSIS
    すべてのマニフェストを checkver で更新し、マニフェストごとの成否を JSON に記録する。update.yml から呼ばれる。
.DESCRIPTION
    checkver.ps1 を -Dir で一括実行すると、1 つのマニフェストでエラーが出た時点で全体が止まり、
    他のアプリの更新が巻き込まれる。そのため、マニフェストごとに子プロセスで実行し、失敗しても続行する。
    失敗したマニフェストは、半端な書き換えが残らないよう元の内容へ戻す。
    このスクリプトは、失敗しても終了コード 0 で終わる。成否の判定と通知は、記録した JSON を読む後続のステップが行う。
.PARAMETER ScoopRoot
    Scoop 本体のリポジトリのパス（setup-scoop が取得した ./scoop）。
.PARAMETER ResultPath
    結果を書き出す JSON のパス。[{ name, ok, message }] の配列。
#>
param(
    [Parameter(Mandatory)][string] $ScoopRoot,
    [Parameter(Mandatory)][string] $ResultPath,
    [string] $BucketDir = 'bucket'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScoopRoot = Convert-Path $ScoopRoot
$BucketDir = Convert-Path $BucketDir

$results = foreach ($file in Get-ChildItem $BucketDir -Filter '*.json' | Sort-Object Name) {
    $name = $file.BaseName
    $original = [IO.File]::ReadAllText($file.FullName)

    Write-Host "::group::$name"
    # -ThrowError が無いと、checkver は更新中の例外を表示するだけで終了コード 0 を返し、失敗を見逃す
    $lines = @(& pwsh -NoProfile -File (Join-Path $ScoopRoot 'bin/checkver.ps1') $name $BucketDir -Update -ThrowError 2>&1 |
        ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $lines | Out-Host
    Write-Host '::endgroup::'

    # 終了コードが 0 でも、最新版を確認できたとは限らない。checkver は、最新版の取得先に届かない、
    # 正規表現が一致しないといった失敗を、エラーを表示するだけで次へ進み（-ThrowError が効くのは
    # autoupdate の例外だけ）、終了コード 0 で終わる。成功なら、「<名前>: <版>」の行（更新があれば
    # 「 (scoop version is …)」が続く）を出力するので、それが出たかも見る。エラーの文には、数字を含まない
    # 1 語の文があり得るため、版は数字を含む語とする。
    $manifest = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $hasCheckver = $manifest.PSObject.Properties.Name -contains 'checkver'
    $versionLine = "^$([regex]::Escape($name)): (?=\S*\d)\S+( \(scoop version is [^)]*\).*)?$"
    $reportedVersion = @($lines | ForEach-Object { ($_ -replace '\x1b\[[0-9;]*m', '').Trim() } | Where-Object { $_ -match $versionLine })

    $reason = $null
    if ($exitCode -ne 0) {
        $reason = "checkver が失敗した（終了コード $exitCode）"
    } elseif ($hasCheckver -and $reportedVersion.Count -eq 0) {
        $reason = '最新版を確認できなかった（checkver が版を報告しなかった。取得先に届かない、または正規表現が一致しない）'
    }

    if ($null -eq $reason) {
        [pscustomobject]@{ name = $name; ok = $true; message = '' }
    } else {
        [IO.File]::WriteAllText($file.FullName, $original)
        # 通知に載せるのは末尾だけ（長い出力で Issue を埋めない）
        $message = "$reason`n" + (($lines | Select-Object -Last 15) -join "`n")
        if ($message.Length -gt 2000) { $message = $message.Substring($message.Length - 2000) }
        [pscustomobject]@{ name = $name; ok = $false; message = $message }
    }
}

# 結果が 1 件でも 0 件でも、配列として書き出す。
# -InputObject に配列を渡して -AsArray を付けると二重の配列になるため、パイプラインで渡す
if (@($results).Count -eq 0) {
    Set-Content -Path $ResultPath -Value '[]' -Encoding utf8
} else {
    @($results) | ConvertTo-Json -AsArray -Depth 3 | Set-Content -Path $ResultPath -Encoding utf8
}
Write-Host "結果: $(@($results | Where-Object { $_.ok }).Count) 件成功 / $(@($results | Where-Object { -not $_.ok }).Count) 件失敗"
exit 0
