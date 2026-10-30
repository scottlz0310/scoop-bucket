<#
.SYNOPSIS
    new-manifest.ps1 の回帰テスト。外部アクセスを注入して、オフラインで検証する。
.DESCRIPTION
    ケースは表で定義する。生成が成功するケースは生成物の内容を、失敗するケースは例外のメッセージの一部を確認する。
    基準にするのは、実物の clp2cfg（v0.1.0）のリリースと、現在の bucket/clp2cfg.json。足場が生成するマニフェストは、
    autoupdate.bin（clp2cfg 固有の手書き部分）を除いて、bucket/clp2cfg.json と一致しなければならない。

    実物でしか見つからなかった不具合を固定している: GitHub は .sha256 を application/octet-stream で返すため、
    Invoke-WebRequest の Content はバイト配列になる。スクリプトブロックから byte[] をそのまま返すと、パイプラインで
    要素ごとに展開され、受け取り側は Object[] になる（-is [byte[]] も偽）。既定の GetText が文字列を返すことを、
    ローカルの HTTP サーバー（octet-stream を返す）に対して、実際の既定の実装で確認する。
.PARAMETER RepoRoot
    リポジトリのルート（bucket/clp2cfg.json を参照する）。
#>
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '../..')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script = Join-Path $PSScriptRoot 'new-manifest.ps1'
$hash = '7e9d51770955833e2ae993a8d01feba4e1cdb83e61f232b286c32794b924111f'
$base = 'https://github.com/scottlz0310/clp2cfg/releases/download'
$winZip = 'clp2cfg-x86_64-pc-windows-msvc.zip'

function New-Release {
    param([string] $Tag = 'v0.1.0', [string[]] $Assets = @($winZip, "$winZip.sha256"), [bool] $Draft = $false, [bool] $Prerelease = $false, [string] $Repo = 'scottlz0310/clp2cfg')
    [pscustomobject]@{
        tag_name = $Tag; draft = $Draft; prerelease = $Prerelease
        assets   = @($Assets | ForEach-Object { [pscustomobject]@{ name = $_; browser_download_url = "https://github.com/$Repo/releases/download/$Tag/$_" } })
    }
}
function New-RepoInfo {
    param([string] $Description = 'GitHub の説明', $License = [pscustomobject]@{ spdx_id = 'Apache-2.0' })
    [pscustomobject]@{ description = $Description; html_url = 'https://github.com/scottlz0310/clp2cfg'; license = $License }
}

# 1 件分を実行する。成功なら @{ Ok = $true; Json = <生成物のハッシュテーブル>; Name }、失敗なら @{ Ok = $false; Message }
function Invoke-Case {
    param([hashtable] $Case)
    $out = Join-Path ([IO.Path]::GetTempPath()) "newmanifest-$([guid]::NewGuid())"
    $release = if ($Case.ContainsKey('Release')) { $Case.Release } else { New-Release }
    $info = if ($Case.ContainsKey('RepoInfo')) { $Case.RepoInfo } else { New-RepoInfo }
    $text = if ($Case.ContainsKey('Sha')) { $Case.Sha } else { "$hash *$winZip`n" }
    $params = @{
        Repository   = $(if ($Case.ContainsKey('Repository')) { $Case.Repository } else { 'scottlz0310/clp2cfg' })
        AllowedOwner = 'scottlz0310'
        OutputDir    = $out
        ThrowOnError = $true
        GetRelease   = { param($r) $release }.GetNewClosure()
        GetRepo      = { param($r) $info }.GetNewClosure()
        GetText      = { param($u) $text }.GetNewClosure()
    }
    if ($Case.ContainsKey('Args')) { foreach ($k in $Case.Args.Keys) { $params[$k] = $Case.Args[$k] } }
    try {
        & $script @params | Out-Null
        $file = Get-ChildItem $out -Filter '*.json' | Select-Object -First 1
        return @{ Ok = $true; Json = (Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable); Name = $file.BaseName }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    } finally {
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    }
}

$clpArgs = @{
    # description は入力をそのまま通すだけなので、実物から読む（説明を直すたびに、このテストを直さなくて済む）
    Description = (Get-Content (Join-Path $RepoRoot 'bucket/clp2cfg.json') -Raw | ConvertFrom-Json).description
    License     = 'MIT OR Apache-2.0'
    Shortcuts   = 'clp2cfg.exe=clp2cfg'
}

# 失敗するケース: 名前 / 入力 / 例外のメッセージに含まれるべき文字列
$failCases = @(
    @{ Name = '他の owner の repo'; Case = @{ Repository = 'someone-else/tool' }; Expect = '許可されていない' }
    @{ Name = 'Repository の形式'; Case = @{ Repository = 'scottlz0310/clp2cfg; rm -rf /' }; Expect = 'Repository' }
    @{ Name = '資産が無い'; Case = @{ Release = (New-Release -Assets @('other.zip')) }; Expect = "資産 'clp2cfg-x86_64-pc-windows-msvc.zip'" }
    @{ Name = '.sha256 が無い'; Case = @{ Release = (New-Release -Assets @($winZip)) }; Expect = '.sha256' }
    @{ Name = '.sha256 のファイル名が資産名と違う'; Case = @{ Sha = "$hash *other.zip`n" }; Expect = '一致しない' }
    @{ Name = '.sha256 が SHA-256 ではない'; Case = @{ Sha = "not-a-hash *$winZip`n" }; Expect = 'SHA-256' }
    @{ Name = '.sha256 が短い'; Case = @{ Sha = "abc123 *$winZip`n" }; Expect = 'SHA-256' }
    @{ Name = 'draft のリリース'; Case = @{ Release = (New-Release -Draft $true) }; Expect = 'draft' }
    @{ Name = 'prerelease のリリース'; Case = @{ Release = (New-Release -Prerelease $true) }; Expect = 'prerelease' }
    @{ Name = '版ではないタグ'; Case = @{ Release = (New-Release -Tag 'nightly') }; Expect = '版の形式' }
    @{ Name = 'ライセンスを判定できない（NOASSERTION）'; Case = @{ RepoInfo = (New-RepoInfo -License ([pscustomobject]@{ spdx_id = 'NOASSERTION' })) }; Expect = 'ライセンス' }
    @{ Name = 'ライセンスが無い'; Case = @{ RepoInfo = (New-RepoInfo -License $null) }; Expect = 'ライセンス' }
    @{ Name = '説明が空'; Case = @{ RepoInfo = (New-RepoInfo -Description '') }; Expect = '説明が空' }
    @{ Name = '説明が長すぎる'; Case = @{ Args = @{ Description = ('a' * 301) } }; Expect = '長すぎる' }
    @{ Name = 'Bin にパスの脱出'; Case = @{ Args = @{ Bin = '..\evil.exe' } }; Expect = "'..'" }
    @{ Name = 'Bin に不正な文字'; Case = @{ Args = @{ Bin = 'a;b.exe' } }; Expect = 'Bin' }
    @{ Name = 'Shortcuts の形式'; Case = @{ Args = @{ Shortcuts = 'clp2cfg.exe' } }; Expect = '実行ファイル=表示名' }
    @{ Name = 'Shortcuts にパスの脱出'; Case = @{ Args = @{ Shortcuts = '..\x.exe=X' } }; Expect = "'..'" }
    @{ Name = 'AssetPattern に未知のプレースホルダー'; Case = @{ Args = @{ AssetPattern = '{foo}.zip' } }; Expect = 'プレースホルダー' }
    @{ Name = 'AssetPattern に不正な文字'; Case = @{ Args = @{ AssetPattern = 'a b.zip' } }; Expect = 'AssetPattern' }
    @{ Name = 'マニフェスト名が大文字'; Case = @{ Args = @{ Name = 'Clp2Cfg' } }; Expect = 'マニフェスト名' }
    @{ Name = 'License に不正な文字'; Case = @{ Args = @{ License = 'MIT; rm' } }; Expect = 'License' }
)

$failed = @()

# 1. 基準: 実物の clp2cfg のリリースから、bucket/clp2cfg.json と一致するマニフェストが生成される
$result = Invoke-Case @{ Args = $clpArgs }
if (-not $result.Ok) {
    $failed += "基準（clp2cfg）: 生成に失敗した: $($result.Message)"
} else {
    $real = Get-Content (Join-Path $RepoRoot 'bucket/clp2cfg.json') -Raw | ConvertFrom-Json -AsHashtable
    $real.autoupdate.Remove('bin')    # clp2cfg 固有の手書き部分（clp2cfg-cli.exe）は、足場の対象外
    $gen = $result.Json | ConvertTo-Json -Depth 10 -Compress
    $exp = $real | ConvertTo-Json -Depth 10 -Compress
    if ($result.Name -ne 'clp2cfg') { $failed += "基準（clp2cfg）: マニフェスト名が clp2cfg ではない: $($result.Name)" }
    if ($gen -cne $exp) { $failed += "基準（clp2cfg）: bucket/clp2cfg.json と一致しない`n  生成: $gen`n  正解: $exp" }
    else { Write-Host 'OK: 基準（clp2cfg）は bucket/clp2cfg.json と一致する（autoupdate.bin を除く）' }
}

# 2. 失敗するケース
foreach ($c in $failCases) {
    $r = Invoke-Case $c.Case
    if ($r.Ok) { $failed += "$($c.Name): 失敗するはずが、生成された" }
    elseif ($r.Message -cnotlike "*$($c.Expect)*") { $failed += "$($c.Name): 失敗の理由が違う（期待: 「$($c.Expect)」/ 実際: $($r.Message)）" }
    else { Write-Host "OK: $($c.Name) は拒否された" }
}

# 3. 成功するケースの内容（正解との比較ではなく、規則の確認）
$okCases = @(
    @{ Name = 'タグに v が無い → URL のテンプレートも v なし'
       Case = @{ Release = (New-Release -Tag '0.1.0'); Args = $clpArgs }
       Check = { param($j) $j.autoupdate.architecture.'64bit'.url -ceq "$base/`$version/$winZip" -and $j.version -ceq '0.1.0' } }
    @{ Name = '資産名に版を含む → テンプレートは、資産名の版も置き換える'
       Case = @{ Release = (New-Release -Tag 'v1.2.3' -Assets @('app-1.2.3-x64.zip', 'app-1.2.3-x64.zip.sha256')); Sha = "$hash *app-1.2.3-x64.zip"
                 Args = ($clpArgs + @{ AssetPattern = 'app-{version}-x64.zip' }) }
       Check = { param($j) $j.architecture.'64bit'.url -ceq "$base/v1.2.3/app-1.2.3-x64.zip" -and $j.autoupdate.architecture.'64bit'.url -ceq "$base/v`$version/app-`$version-x64.zip" } }
    @{ Name = '.sha256 がファイル名なしのハッシュだけ → 受け入れる'
       Case = @{ Sha = $hash; Args = $clpArgs }
       Check = { param($j) $j.architecture.'64bit'.hash -ceq $hash } }
    @{ Name = '.sha256 の 16 進が大文字 → 小文字にそろえる'
       Case = @{ Sha = "$($hash.ToUpperInvariant()) *$winZip"; Args = $clpArgs }
       Check = { param($j) $j.architecture.'64bit'.hash -ceq $hash } }
    @{ Name = 'Bin が複数 → 配列'
       Case = @{ Args = ($clpArgs + @{ Bin = 'clp2cfg.exe, clp2cfg-cli.exe' }) }
       Check = { param($j) ($j.bin -join ',') -ceq 'clp2cfg.exe,clp2cfg-cli.exe' } }
    @{ Name = 'Bin が 1 件 → 文字列（配列にしない）'
       Case = @{ Args = $clpArgs }
       Check = { param($j) $j.bin -is [string] -and $j.bin -ceq 'clp2cfg.exe' } }
    @{ Name = 'Shortcuts が無い（CLI ツール）→ shortcuts キーを出さない'
       Case = @{ Args = @{ Description = 'd'; License = 'MIT' } }
       Check = { param($j) -not $j.ContainsKey('shortcuts') } }
    @{ Name = '説明が無ければ GitHub の説明、ライセンスが無ければ GitHub の判定を使う'
       Case = @{ Args = @{} }
       Check = { param($j) $j.description -ceq 'GitHub の説明' -and $j.license -ceq 'Apache-2.0' } }
    @{ Name = '説明の改行は空白に直す'
       Case = @{ Args = @{ Description = "1 行目`n2 行目"; License = 'MIT' } }
       Check = { param($j) $j.description -ceq '1 行目 2 行目' } }
    @{ Name = 'ハッシュは常に checkver / autoupdate で .sha256 から取る'
       Case = @{ Args = $clpArgs }
       Check = { param($j) $j.checkver -ceq 'github' -and $j.autoupdate.architecture.'64bit'.hash.url -ceq '$url.sha256' } }
)

# 3b. autoupdate の URL のテンプレートを、次の版へ展開して、独立に組み立てた URL と比較する（性質ベース）。
# 現行の版へ展開して元の URL に戻ることしか見ないと、版と同じ文字列を含む repo 名や固定の資産名まで置換されても気づけない
# （repo 名 tool-1.2.3 の場合、次の 1.2.4 で別の repo tool-1.2.4 を指して、更新に失敗する）。
# 期待する URL は、置換ではなく、repo・タグ・資産名の部品から作る。
$urlCases = @(
    # 名前 / repo / 現行の版 / 次の版 / タグの接頭辞 / AssetPattern / 資産名の組み立て（{n}=版）
    @{ Name = '指摘の例: repo 名が現行の版を含む（tool-1.2.3）、既定の資産名'; Repo = 'tool-1.2.3'; Cur = '1.2.3'; Next = '1.2.4'; Prefix = 'v'; Pattern = '{name}-x86_64-pc-windows-msvc.zip'; Asset = { param($v) 'tool-1.2.3-x86_64-pc-windows-msvc.zip' } }
    @{ Name = 'repo 名が現行の版を含む、資産名に {version} も使う'; Repo = 'tool-1.2.3'; Cur = '1.2.3'; Next = '1.2.4'; Prefix = 'v'; Pattern = '{name}-{version}-x64.zip'; Asset = { param($v) "tool-1.2.3-$v-x64.zip" } }
    @{ Name = '固定の資産名が現行の版を含む（{version} を使わない）'; Repo = 'app'; Cur = '2.0.0'; Next = '2.0.1'; Prefix = 'v'; Pattern = 'app-2.0.0-fixed.zip'; Asset = { param($v) 'app-2.0.0-fixed.zip' } }
    @{ Name = 'タグに v が無い、資産名に {version}'; Repo = 'app'; Cur = '3.1.4'; Next = '3.1.5'; Prefix = ''; Pattern = '{name}-{version}.zip'; Asset = { param($v) "app-$v.zip" } }
    @{ Name = '版の桁が重なる（repo 名が 1.2、版が 1.2.3）'; Repo = 'lib-1.2'; Cur = '1.2.3'; Next = '1.2.10'; Prefix = 'v'; Pattern = '{name}-x64.zip'; Asset = { param($v) 'lib-1.2-x64.zip' } }
)
foreach ($u in $urlCases) {
    $curAsset = & $u.Asset $u.Cur
    $tag = "$($u.Prefix)$($u.Cur)"
    $case = @{
        Repository = "scottlz0310/$($u.Repo)"
        Release    = (New-Release -Tag $tag -Repo "scottlz0310/$($u.Repo)" -Assets @($curAsset, "$curAsset.sha256"))
        Sha        = "$hash *$curAsset"
        RepoInfo   = (New-RepoInfo)
        Args       = @{ Description = 'd'; License = 'MIT'; AssetPattern = $u.Pattern; Bin = 'x.exe' }
    }
    $r = Invoke-Case $case
    if (-not $r.Ok) { $failed += "URL: $($u.Name): 生成に失敗した: $($r.Message)"; continue }
    $template = $r.Json.autoupdate.architecture.'64bit'.url
    $expanded = $template.Replace('$version', $u.Next)
    $expected = "https://github.com/scottlz0310/$($u.Repo)/releases/download/$($u.Prefix)$($u.Next)/$(& $u.Asset $u.Next)"
    $current = $r.Json.architecture.'64bit'.url
    if ($current -cne "https://github.com/scottlz0310/$($u.Repo)/releases/download/$tag/$curAsset") { $failed += "URL: $($u.Name): 現行の URL が違う: $current" }
    elseif ($expanded -cne $expected) { $failed += "URL: $($u.Name): 次の版へ展開した URL が違う`n  展開: $expanded`n  期待: $expected" }
    else { Write-Host "OK: URL: $($u.Name) → 次の版へ展開すると期待どおり" }
}

foreach ($c in $okCases) {
    $r = Invoke-Case $c.Case
    if (-not $r.Ok) { $failed += "$($c.Name): 生成に失敗した: $($r.Message)" }
    elseif (-not (& $c.Check $r.Json)) { $failed += "$($c.Name): 生成物が期待と違う: $($r.Json | ConvertTo-Json -Depth 10 -Compress)" }
    else { Write-Host "OK: $($c.Name)" }
}

# 4. 既存のマニフェストは上書きしない
$existing = Join-Path ([IO.Path]::GetTempPath()) "newmanifest-existing-$([guid]::NewGuid())"
New-Item -ItemType Directory $existing | Out-Null
try {
    Set-Content (Join-Path $existing 'clp2cfg.json') '{"version":"9.9.9"}'
    $release = New-Release; $info = New-RepoInfo
    try {
        & $script -Repository scottlz0310/clp2cfg -AllowedOwner scottlz0310 -OutputDir $existing -ThrowOnError @clpArgs `
            -GetRelease { param($r) $release }.GetNewClosure() -GetRepo { param($r) $info }.GetNewClosure() -GetText { param($u) "$hash *$winZip" } | Out-Null
        $failed += '既存のマニフェスト: 上書きが拒否されなかった'
    } catch {
        if ($_.Exception.Message -notlike '*すでにある*') { $failed += "既存のマニフェスト: 理由が違う: $($_.Exception.Message)" }
        elseif ((Get-Content (Join-Path $existing 'clp2cfg.json') -Raw).Trim() -cne '{"version":"9.9.9"}') { $failed += '既存のマニフェスト: 内容が変わった' }
        else { Write-Host 'OK: 既存のマニフェストは上書きされない' }
    }
} finally { Remove-Item $existing -Recurse -Force }

# 5. 実物の挙動: Get-RemoteText が、octet-stream（バイト配列）の応答を、文字列として返す。
# ローカルの HTTP サーバーが、GitHub と同じ Content-Type: application/octet-stream で .sha256 を返す。
# （注入した GetText はこの挙動を通らないため、実際の関数に対して確認する）
. (Join-Path $PSScriptRoot 'remote-text.ps1')
$listener = [Net.HttpListener]::new()
$port = Get-Random -Minimum 20000 -Maximum 60000
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
try {
    $serve = Start-ThreadJob -ScriptBlock {
        param($l, $body)
        $ctx = $l.GetContext()
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.ContentType = 'application/octet-stream'
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
    } -ArgumentList $listener, "$hash *$winZip`n"
    $got = Get-RemoteText "http://127.0.0.1:$port/x.sha256"
    Wait-Job $serve -Timeout 10 | Out-Null
    Remove-Job $serve -Force
    if ($got -is [string] -and $got.StartsWith($hash)) { Write-Host 'OK: Get-RemoteText は、octet-stream の応答を文字列で返す（バイト配列を復号する）' }
    else { $failed += "Get-RemoteText: 文字列で返らない（型: $(if ($null -eq $got) { 'null' } else { $got.GetType().FullName })）" }
} finally { $listener.Stop() }

if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Host "::error title=new-manifest selftest::$_" }
    exit 1
}
exit 0
