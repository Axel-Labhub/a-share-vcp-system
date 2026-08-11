$ErrorActionPreference = 'Stop'
$html = Get-Content -Raw -Encoding UTF8 'C:\Users\viggo.wu\.qwenworkcn\workspace\msodv1ody7wi9dlr\wx_article.html'

# Extract js_content div
$start = $html.IndexOf('id="js_content"')
if ($start -lt 0) { Write-Output 'NO_JS_CONTENT'; exit 1 }
$start = $html.IndexOf('>', $start) + 1
$end = $html.IndexOf('id="js_tags_preview_toast"')
if ($end -lt 0) { $end = $html.IndexOf('<script', $start) }
$body = $html.Substring($start, $end - $start)

# Convert tags to newlines for block elements
$body = $body -replace '<br\s*/?>', "`n"
$body = $body -replace '</p>', "`n"
$body = $body -replace '</(section|div|h1|h2|h3|h4|li|tr)>', "`n"
# Strip remaining tags
$text = $body -replace '<[^>]+>', ''
# Decode entities
$text = $text -replace '&nbsp;?', ' '
$text = $text -replace '&amp;', '&'
$text = $text -replace '&lt;', '<'
$text = $text -replace '&gt;', '>'
$text = $text -replace '&quot;', '"'
$text = $text -replace '&#39;', "'"
# Collapse blank lines
$text = [regex]::Replace($text, '(\r?\n[ \t]*){3,}', "`n`n")
$text = $text.Trim()

$out = 'C:\Users\viggo.wu\.qwenworkcn\workspace\msodv1ody7wi9dlr\wx_article.txt'
[System.IO.File]::WriteAllText($out, $text, [System.Text.Encoding]::UTF8)
Write-Output ("EXTRACTED " + $text.Length + " chars")
