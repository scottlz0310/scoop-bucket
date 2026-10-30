<#
.SYNOPSIS
    マニフェストを検証する。verify.yml から呼ばれる。
.DESCRIPTION
    指定したマニフェストごとに、次を順に検査し、1 つでも失敗したら終了コード 1 で終わる。
      1. 整形: Scoop 標準の formatjson で差分が出ないこと
      2. autoupdate: 現在の版で checkver を強制実行しても、URL とハッシュが現行値と一致すること
      3. インストール: 隔離した Scoop 環境で scoop install が通ること（URL の取得とハッシュの一致も検証される）
      4. 動作確認: verify.json に定義したコマンドが通ること（since 以上の版のときだけ）
      5. アンインストール
    checkurls / checkhashes は、失敗しても終了コードが 0 でマニフェストを書き換えるため、判定に使わない。
.PARAMETER ScoopRoot
    Scoop 本体のリポジトリのパス（setup-scoop が取得した ./scoop）。
.PARAMETER Name
    検証するマニフェスト名（拡張子なし）。
#>
param(
    [Parameter(Mandatory)][string] $ScoopRoot,
    [Parameter(Mandatory)][string[]] $Name,
    [string] $BucketDir = 'bucket',
    [string] $VerifyConfig = '.github/verify.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScoopRoot = Convert-Path $ScoopRoot
$BucketDir = Convert-Path $BucketDir
$verify = if (Test-Path $VerifyConfig) { Get-Content $VerifyConfig -Raw | ConvertFrom-Json } else { $null }

# 実環境の Scoop を汚さないよう、一時ディレクトリを SCOOP にする。
# Scoop は shim の実行ファイルを $SCOOP/apps/scoop/current から複製するため、Scoop 本体をそこへコピーして使う
# （リンクにすると、後始末の再帰削除が本体まで消す恐れがある）。
$scoopHome = Join-Path ([IO.Path]::GetTempPath()) "scoop-verify-$([guid]::NewGuid())"
$env:SCOOP = $scoopHome
$scoopCurrent = Join-Path $scoopHome 'apps/scoop/current'
New-Item -ItemType Directory -Force (Split-Path $scoopCurrent), (Join-Path $scoopHome 'buckets'), (Join-Path $scoopHome 'shims') | Out-Null
Copy-Item $ScoopRoot $scoopCurrent -Recurse
$ScoopRoot = $scoopCurrent

function Invoke-ScoopScript {
    # Scoop のスクリプトは exit で終わるため、子プロセスで実行して終了コードを受け取る。
    # 出力は画面へ流しつつ、出力の内容でも判定できるよう、終了コードと一緒に返す。
    param([string] $Script, [string[]] $Arguments)
    $lines = @(& pwsh -NoProfile -File (Join-Path $ScoopRoot "bin/$Script.ps1") @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    $lines | Out-Host
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($lines -join "`n") }
}

function Get-ManifestUrlsAndHashes {
    param([string] $Path)
    $manifest = Get-Content $Path -Raw | ConvertFrom-Json
    $result = [ordered]@{}
    foreach ($arch in $manifest.architecture.PSObject.Properties) {
        $result["$($arch.Name).url"] = ($arch.Value.url -join ',')
        $result["$($arch.Name).hash"] = ($arch.Value.hash -join ',')
    }
    return $result
}

function Test-Manifest {
    param([string] $AppName)
    $file = Join-Path $BucketDir "$AppName.json"
    $manifest = Get-Content $file -Raw | ConvertFrom-Json
    $failures = @()

    # Scoop のスクリプト（formatjson / checkver）はマニフェストを書き換える。呼ぶたびに元の内容へ戻す。
    # git checkout は、手元の未コミットの編集まで捨てるため使わない。
    $original = [IO.File]::ReadAllText($file)

    # 1. 整形（改行コードの違いは無視する。リポジトリは LF に固定している）
    if ((Invoke-ScoopScript 'formatjson' @('-App', $AppName, '-Dir', $BucketDir)).ExitCode -ne 0) {
        $failures += 'formatjson の実行に失敗'
    } else {
        $formatted = [IO.File]::ReadAllText($file)
        if (($formatted -replace "`r`n", "`n") -cne ($original -replace "`r`n", "`n")) {
            $failures += 'Scoop 標準の書式と異なる（formatjson を実行してコミットする）'
            $formattedFile = Join-Path $scoopHome "formatted-$AppName.json"
            [IO.File]::WriteAllText($formattedFile, $formatted)
            git --no-pager diff --no-index --ignore-space-at-eol -- $file $formattedFile | Out-Host
        }
    }
    [IO.File]::WriteAllText($file, $original)

    # 2. autoupdate が現在の URL とハッシュを再現するか
    if ($manifest.PSObject.Properties.Name -contains 'autoupdate') {
        $before = Get-ManifestUrlsAndHashes $file
        # -ThrowError が無いと、checkver は更新中の例外を表示するだけで終了コード 0 を返し、失敗を見逃す
        $checkver = Invoke-ScoopScript 'checkver' @($AppName, $BucketDir, '-ForceUpdate', '-Version', $manifest.version, '-ThrowError')
        $after = Get-ManifestUrlsAndHashes $file
        [IO.File]::WriteAllText($file, $original)
        if ($checkver.ExitCode -ne 0) {
            $failures += "checkver の実行に失敗（終了コード $($checkver.ExitCode)）"
        } else {
            foreach ($key in $before.Keys) {
                if ($before[$key] -ne $after[$key]) {
                    $failures += "autoupdate が現行値を再現しない: $key（現行: $($before[$key]) / 再現: $($after[$key])）"
                }
            }
            # hash.url から取得できないと、Scoop は黙ってダウンロードして計算する代替に落ち、結果が同じになって見逃す
            if ($checkver.Output -match 'Could not find hash in') {
                $failures += 'autoupdate のハッシュ取得先（hash.url）から取得できない（ダウンロードして計算する代替に落ちた）'
            }
        }
    }

    # 3. インストール（失敗したら、以降の検査は意味がない）。
    # scoop install は、ハッシュの検証に失敗しても終了コード 0 を返す。そのため終了コードに加えて、
    # インストールの完了時に作られる apps/<名前>/current の有無で判定する。
    $install = Invoke-ScoopScript 'scoop' @('install', $file)
    if ($install.ExitCode -ne 0 -or -not (Test-Path (Join-Path $scoopHome "apps/$AppName/current"))) {
        return $failures + "scoop install に失敗（終了コード $($install.ExitCode)。ハッシュの不一致や URL の取得失敗などで、current が作られなかった）"
    }

    # 4. 動作確認
    $commands = @()
    if ($null -ne $verify -and $verify.PSObject.Properties.Name -contains $AppName) {
        $commands = @($verify.$AppName.commands)
    }
    foreach ($entry in $commands) {
        if ([version] $manifest.version -lt [version] $entry.since) {
            Write-Host "skip: $($entry.command)（$($entry.since) 以上のみ。現在 $($manifest.version)）"
            continue
        }
        $shim = Get-ChildItem (Join-Path $scoopHome 'shims') -Filter "$($entry.command).exe" -ErrorAction SilentlyContinue
        if (-not $shim) {
            $failures += "shim が無い: $($entry.command)（bin に含まれていない）"
            continue
        }
        & $shim.FullName @($entry.args) | Out-Host
        if ($LASTEXITCODE -ne 0) {
            $failures += "コマンドが失敗: $($entry.command) $($entry.args -join ' ')（終了コード $LASTEXITCODE）"
        }
    }

    # 5. アンインストール
    if ((Invoke-ScoopScript 'scoop' @('uninstall', $AppName)).ExitCode -ne 0) {
        $failures += 'scoop uninstall に失敗'
    }
    return $failures
}

$allFailures = [ordered]@{}
try {
    foreach ($app in $Name) {
        Write-Host "::group::$app"
        $failures = @(Test-Manifest $app)
        Write-Host '::endgroup::'
        if ($failures.Count -gt 0) {
            $allFailures[$app] = $failures
            foreach ($f in $failures) { Write-Host "::error title=$app::$f" }
        } else {
            Write-Host "OK: $app"
        }
    }
} finally {
    # Scoop は shim のディレクトリを、ユーザーの PATH（永続）へ追加する。実環境を汚さないよう、
    # 今回の一時ディレクトリの項目だけを戻す（CI の runner は使い捨てだが、手元で実行したときのため）
    $shimDir = Join-Path $scoopHome 'shims'
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (($userPath -split ';') -contains $shimDir) {
        $restored = ($userPath -split ';') | Where-Object { $_ -ne $shimDir }
        [Environment]::SetEnvironmentVariable('PATH', ($restored -join ';'), 'User')
    }
    Remove-Item $scoopHome -Recurse -Force -ErrorAction SilentlyContinue
}

if ($allFailures.Count -gt 0) {
    Write-Host "検証に失敗したマニフェスト: $($allFailures.Keys -join ', ')"
    exit 1
}
