<#
.SYNOPSIS
    GitHub の最新リリースから、標準形の Scoop マニフェストを生成する。add-manifest.yml から呼ばれる。
.DESCRIPTION
    バケットに新しいアプリを載せるときの足場。リリースの資産（ZIP と、その .sha256）から、
    checkver / autoupdate / ハッシュ取得（$url.sha256）まで揃った、clp2cfg と同じ形のマニフェストを作る。

    前提と限界:
      - Scoop が配るのは、ビルド済みのバイナリ。PyPI / npm / crates.io / Go だけで配るプロジェクトは、
        先にリリースで ZIP と .sha256 を出す必要がある（対象外）。
      - 資産名の規則が合わないと生成できない（-AssetPattern で指定する）。
      - persist / pre_install などのスクリプトを要るアプリは、自動生成の対象外（手書きにする）。
      - 信頼できる repo だけを対象にするため、-AllowedOwner と同じ owner の repo に限る。

    外部アクセス（GitHub API、.sha256 の取得）は、-GetRelease / -GetRepo / -GetText で差し替えられる
    （テストは、これらにオフラインの実装を渡す）。
.PARAMETER Repository
    owner/repo。
.PARAMETER AllowedOwner
    許可する owner。Repository の owner がこれと一致しなければ拒否する。
.PARAMETER AssetPattern
    Windows 用 ZIP の資産名。{name}（repo 名）と {version}（タグから v を除いた版）を使える。
.PARAMETER Bin
    shim を作る実行ファイル（カンマ区切り）。既定は {name}.exe。
.PARAMETER Shortcuts
    スタートメニューのショートカット（カンマ区切りの 実行ファイル=表示名）。GUI アプリのときに指定する。
.PARAMETER Description
    説明。省略すると、GitHub の repo の説明を使う。
.PARAMETER License
    ライセンス。省略すると、GitHub の判定（SPDX ID）を使う。GitHub は二重ライセンス（MIT OR Apache-2.0 など）を
    認識しないため、その場合は指定する。
.PARAMETER Name
    マニフェスト名。省略すると、repo 名を小文字にしたもの。
.PARAMETER OutputDir
    マニフェストを書き出すディレクトリ。
.PARAMETER ScoopRoot
    指定すると、Scoop 標準の formatjson で整形する（verify の整形検査に合わせる）。
.PARAMETER ThrowOnError
    失敗を、::error:: と exit 1 ではなく、例外として返す（テストが、インプロセスで実行するため）。
#>
param(
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $AllowedOwner,
    [Parameter(Mandatory)][string] $OutputDir,
    [string] $AssetPattern = '{name}-x86_64-pc-windows-msvc.zip',
    [string] $Bin = '',
    [string] $Shortcuts = '',
    [string] $Description = '',
    [string] $License = '',
    [string] $Name = '',
    [string] $ScoopRoot = '',
    [switch] $ThrowOnError,
    [scriptblock] $GetRelease = { param($repo) gh api "repos/$repo/releases/latest" | ConvertFrom-Json },
    [scriptblock] $GetRepo = { param($repo) gh api "repos/$repo" | ConvertFrom-Json },
    [scriptblock] $GetText = { param($url) Get-RemoteText $url }
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'remote-text.ps1')    # Get-RemoteText（.sha256 の octet-stream を文字列で返す）

function Test-Pattern {
    param([string] $Value, [string] $Pattern, [string] $What)
    if ($Value -cnotmatch $Pattern) { throw "$What の形式が不正: '$Value'（許可: $Pattern）" }
}

function New-ManifestObject {
    $parts = $Repository.Split('/')
    Test-Pattern $Repository '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' 'Repository（owner/repo）'
    $owner = $parts[0]
    $repoName = $parts[1]
    if ($owner -ne $AllowedOwner) {
        throw "owner '$owner' は許可されていない（このバケットは '$AllowedOwner' の repo だけを対象にする）"
    }

    $manifestName = if ($Name) { $Name } else { $repoName.ToLowerInvariant() }
    Test-Pattern $manifestName '^[a-z0-9][a-z0-9._-]*$' 'マニフェスト名'
    Test-Pattern $AssetPattern '^[A-Za-z0-9._{}-]+$' 'AssetPattern'
    if ($AssetPattern -cmatch '\{(?!name\}|version\})') { throw "AssetPattern で使えるプレースホルダーは {name} と {version} だけ: '$AssetPattern'" }

    # bin と shortcuts は、マニフェストに書き込む値。パスの脱出（..）や制御文字を拒否する
    $binList = @(($(if ($Bin) { $Bin } else { "$repoName.exe" }) -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($binList.Count -eq 0) { throw 'Bin が空' }
    foreach ($b in $binList) {
        Test-Pattern $b '^[A-Za-z0-9._][A-Za-z0-9._/\\-]*$' 'Bin'
        if ($b -match '(^|[\\/])\.\.([\\/]|$)') { throw "Bin に '..' は使えない: '$b'" }
    }
    $shortcutList = @()
    foreach ($s in @(($Shortcuts -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $pair = $s -split '=', 2
        if ($pair.Count -ne 2) { throw "Shortcuts は 実行ファイル=表示名 の形式: '$s'" }
        Test-Pattern $pair[0].Trim() '^[A-Za-z0-9._][A-Za-z0-9._/\\-]*$' 'Shortcuts の実行ファイル'
        Test-Pattern $pair[1].Trim() '^[A-Za-z0-9][A-Za-z0-9 ._-]*$' 'Shortcuts の表示名'
        if ($pair[0] -match '(^|[\\/])\.\.([\\/]|$)') { throw "Shortcuts に '..' は使えない: '$s'" }
        $shortcutList += , @($pair[0].Trim(), $pair[1].Trim())
    }

    $release = & $GetRelease $Repository
    if ($release.draft -or $release.prerelease) { throw "最新のリリース '$($release.tag_name)' は draft または prerelease" }
    $tag = [string] $release.tag_name
    if ($tag -cnotmatch '^v?(\d+\.\d+\.\d+[0-9A-Za-z.+-]*)$') { throw "タグ '$tag' が版の形式（[v]MAJOR.MINOR.PATCH）ではない" }
    $version = $Matches[1]

    $assetName = $AssetPattern.Replace('{name}', $repoName).Replace('{version}', $version)
    $assets = @($release.assets)
    $asset = @($assets | Where-Object { $_.name -ceq $assetName }) | Select-Object -First 1
    if (-not $asset) {
        throw "資産 '$assetName' がリリース '$tag' に無い（ある資産: $(($assets | ForEach-Object { $_.name }) -join ', ')）。-AssetPattern を確認する"
    }
    $shaAsset = @($assets | Where-Object { $_.name -ceq "$assetName.sha256" }) | Select-Object -First 1
    if (-not $shaAsset) {
        throw "チェックサムの資産 '$assetName.sha256' がリリース '$tag' に無い（リリースで ZIP と .sha256 を出す必要がある）"
    }

    # .sha256 は '<ハッシュ> *<ファイル名>' または '<ハッシュ>'。ファイル名があれば、資産名と一致することを確認する
    $shaTokens = @(([string] (& $GetText $shaAsset.browser_download_url)).Trim() -split '\s+')
    if ($shaTokens[0] -cnotmatch '^[0-9a-fA-F]{64}$') { throw "'$assetName.sha256' の先頭が SHA-256（64 桁の 16 進）ではない" }
    if ($shaTokens.Count -ge 2 -and $shaTokens[1].TrimStart('*') -cne $assetName) {
        throw "'$assetName.sha256' のファイル名 '$($shaTokens[1])' が、資産名 '$assetName' と一致しない"
    }
    $hash = $shaTokens[0].ToLowerInvariant()

    $repoInfo = & $GetRepo $Repository
    $desc = if ($Description) { $Description } else { [string] $repoInfo.description }
    $desc = ($desc -replace '[\r\n]+', ' ').Trim()
    if (-not $desc) { throw '説明が空。-Description を指定する（repo に説明が無い）' }
    if ($desc.Length -gt 300) { throw "説明が長すぎる（$($desc.Length) 文字。300 文字以内）" }

    $spdx = if ($License) { $License } elseif ($repoInfo.license -and $repoInfo.license.spdx_id) { [string] $repoInfo.license.spdx_id } else { '' }
    if (-not $spdx -or $spdx -eq 'NOASSERTION') {
        throw 'ライセンスを判定できない（GitHub は二重ライセンスなどを認識しない）。-License を指定する'
    }
    Test-Pattern $spdx '^[A-Za-z0-9][A-Za-z0-9 .()+-]*$' 'License'

    $url = [string] $asset.browser_download_url
    $urlTemplate = $url.Replace($version, '$version')
    if ($urlTemplate -ceq $url) { throw "URL に版 '$version' が含まれない。autoupdate の URL を作れない: $url" }

    $manifest = [ordered]@{
        version      = $version
        description  = $desc
        homepage     = [string] $repoInfo.html_url
        license      = $spdx
        architecture = [ordered]@{ '64bit' = [ordered]@{ url = $url; hash = $hash } }
        bin          = $(if ($binList.Count -eq 1) { $binList[0] } else { $binList })
    }
    if ($shortcutList.Count -gt 0) { $manifest['shortcuts'] = $shortcutList }
    $manifest['checkver'] = 'github'
    $manifest['autoupdate'] = [ordered]@{
        architecture = [ordered]@{ '64bit' = [ordered]@{ url = $urlTemplate; hash = [ordered]@{ url = '$url.sha256' } } }
    }
    return [pscustomobject]@{ Name = $manifestName; Version = $version; Manifest = $manifest }
}

try {
    $result = New-ManifestObject
    New-Item -ItemType Directory -Force $OutputDir | Out-Null
    $path = Join-Path $OutputDir "$($result.Name).json"
    if (Test-Path $path) { throw "マニフェスト '$path' がすでにある（新規追加の足場は、既存を上書きしない）" }
    $json = $result.Manifest | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($path, $json + "`n")

    if ($ScoopRoot) {
        & pwsh -NoProfile -File (Join-Path (Convert-Path $ScoopRoot) 'bin/formatjson.ps1') -App $result.Name -Dir (Convert-Path $OutputDir) | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'formatjson に失敗' }
    }

    Write-Host "生成: $path（$($result.Name) $($result.Version)）"
    if ($env:GITHUB_OUTPUT) {
        "name=$($result.Name)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        "version=$($result.Version)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
} catch {
    # テストは、スクリプトをインプロセスで実行する（スクリプトブロックを注入するため）。exit はテストのホストを終了させるので、
    # -ThrowOnError のときは例外として返す
    if ($ThrowOnError) { throw }
    Write-Host "::error::$($_.Exception.Message)"
    exit 1
}
if (-not $ThrowOnError) { exit 0 }
