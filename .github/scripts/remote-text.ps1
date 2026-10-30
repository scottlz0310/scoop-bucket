# URL の内容を文字列で返す関数 Get-RemoteText。new-manifest.ps1 と、そのテストが、ドットソースして使う。
#
# GitHub は .sha256 を application/octet-stream で返すため、Invoke-WebRequest の Content はバイト配列になる。
# バイト配列をそのまま文字列化すると 'System.Byte[]' になり、スクリプトブロックから byte[] を返すと、
# パイプラインで要素ごとに展開されて受け取り側は Object[] になる（-is [byte[]] も偽になる）。
# そのため、ここで UTF-8 の文字列に復号して返し、戻り値は常に文字列とする。
function Get-RemoteText {
    param([string] $Url)
    $content = (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return [string] $content
}
