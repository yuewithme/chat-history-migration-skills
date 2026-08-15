[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveRoot,
    [string]$OutputPath,
    [switch]$NoOpen,
    [string]$ApiToken,
    [string]$ServerUrl
)

$ErrorActionPreference = 'Stop'
if (-not $OutputPath) { $OutputPath = Join-Path $ArchiveRoot '_meta\reports\chat-overview.html' }

function Html([object]$Value) {
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-MessageAttachmentMap([object]$Chat) {
    $map = @{}
    $rawRelativePath = if ($Chat.raw_path) { [string]$Chat.raw_path } else { [string]$Chat.raw_json_path }
    if (-not $rawRelativePath) { return $map }
    $rawPath = Join-Path $ArchiveRoot ($rawRelativePath -replace '/', '\')
    $envelope = Read-Json $rawPath
    if (-not $envelope) { return $map }
    foreach ($message in @($envelope.data.messages)) {
        $content = [string]$message.content
        $key = $null
        $name = $null
        $type = [string]$message.msg_type
        if ($type -eq 'file') {
            $match = [regex]::Match($content, '<file\s+key="([^"]+)"\s+name="([^"]*)"')
            if ($match.Success) {
                $key = $match.Groups[1].Value
                $name = [System.Net.WebUtility]::HtmlDecode($match.Groups[2].Value)
            }
        }
        elseif ($type -eq 'image') {
            $match = [regex]::Match($content, '\[Image:\s*([^\]]+)\]')
            if ($match.Success) { $key = $match.Groups[1].Value }
        }
        if ($key) {
            $map[$key] = [pscustomobject]@{
                resource_key = $key
                original_name = $name
                message_id = [string]$message.message_id
                message_time = [string]$message.create_time
                sender_name = [string]$message.sender.name
                message_type = $type
            }
        }
    }
    return $map
}

function Get-AttachmentDetails([object]$Chat, [string]$AttachmentRoot, [object[]]$Files) {
    $map = Get-MessageAttachmentMap $Chat
    $details = foreach ($file in $Files) {
        $key = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $message = if ($map.ContainsKey($key)) { $map[$key] } else { $null }
        $relativePath = ($file.FullName.Substring($AttachmentRoot.Length + 1) -replace '\\', '/')
        [pscustomobject]@{
            resource_key = $key
            original_name = if ($message -and $message.original_name) { [string]$message.original_name } else { $file.Name }
            stored_name = $file.Name
            extension = $file.Extension.TrimStart('.').ToLowerInvariant()
            bytes = [long]$file.Length
            message_id = if ($message) { [string]$message.message_id } else { $null }
            message_time = if ($message) { [string]$message.message_time } else { $null }
            sender_name = if ($message) { [string]$message.sender_name } else { $null }
            message_type = if ($message) { [string]$message.message_type } else { $null }
            relative_path = $relativePath
        }
    }
    return @($details | Sort-Object bytes -Descending)
}

function Render-AttachmentDetails([object]$ChatRow, [string]$DetailsId) {
    $body = [System.Text.StringBuilder]::new()
    $index = 0
    foreach ($attachment in @($ChatRow.attachments)) {
        $index++
        $extraClass = if ($index -gt 20) { ' extra-attachment' } else { '' }
        $hidden = if ($index -gt 20) { ' hidden' } else { '' }
        [void]$body.AppendLine("<tr class='attachment-item$extraClass'$hidden><td>$(Html $attachment.message_time)</td><td>$(Html $attachment.original_name)<div class='stored'>$(Html $attachment.stored_name)</div></td><td>$(Html $attachment.extension)</td><td class='num'>$([math]::Round($attachment.bytes / 1MB, 2)) MiB</td><td>$(Html $attachment.sender_name)</td><td><button class='danger delete-attachment' data-chat='$(Html $ChatRow.chat_id)' data-path='$(Html $attachment.relative_path)' data-name='$(Html $attachment.original_name)'>&#21024;&#38500;</button></td></tr>")
    }
    $remaining = @($ChatRow.attachments).Count - 20
    $showMore = if ($remaining -gt 0) { "<button class='secondary show-all' data-details='$(Html $DetailsId)'>&#26174;&#31034;&#20854;&#20313; $remaining &#20010;</button>" } else { '' }
    return "<div class='attachment-panel'><div class='attachment-toolbar'><span>&#25353;&#22823;&#23567;&#25490;&#24207;&#65292;&#40664;&#35748;&#26174;&#31034;&#21069; 20 &#20010;&#12290;</span>$showMore</div><table class='attachment-table'><thead><tr><th>&#28040;&#24687;&#26102;&#38388;</th><th>&#38468;&#20214;&#21517;</th><th>&#31867;&#22411;</th><th>&#22823;&#23567;</th><th>&#21457;&#36865;&#32773;</th><th>&#25805;&#20316;</th></tr></thead><tbody>$body</tbody></table><div class='delete-status' aria-live='polite'></div></div>"
}

function Render-Table([object]$Table) {
    $withDetails = ([string]$Table.key).Contains('attachment')
    $body = [System.Text.StringBuilder]::new()
    $rank = 0
    foreach ($row in @($Table.rows)) {
        $rank++
        $detailsId = "details-$($Table.key)-$rank"
        $action = if ($withDetails -and $row.attachment_files -gt 0) { "<button class='secondary toggle-details' data-details='$(Html $detailsId)'>&#26597;&#30475;&#38468;&#20214;</button>" } else { '' }
        $actionCell = if ($withDetails) { "<td>$action</td>" } else { '' }
        [void]$body.AppendLine("<tr class='chat-row'><td>$rank</td><td>$(Html $row.title)</td><td><code>$(Html $row.chat_id)</code></td><td class='num'>$($row.message_count)</td><td class='num'>$($row.attachment_files)</td><td class='num'>$([math]::Round($row.attachment_bytes / 1MB, 2)) MiB</td>$actionCell</tr>")
        if ($withDetails -and $row.attachment_files -gt 0) {
            $panel = Render-AttachmentDetails $row $detailsId
            [void]$body.AppendLine("<tr id='$(Html $detailsId)' class='details-row' hidden><td colspan='7'>$panel</td></tr>")
        }
    }
    $actionHeader = if ($withDetails) { '<th>&#35814;&#24773;</th>' } else { '' }
    return "<section><h2>$($Table.html_title)</h2><table class='ranking-table'><thead><tr><th>#</th><th>&#20250;&#35805;</th><th>chat_id</th><th>&#28040;&#24687;</th><th>&#38468;&#20214;</th><th>&#38468;&#20214;&#22823;&#23567;</th>$actionHeader</tr></thead><tbody>$body</tbody></table></section>"
}

function Get-FreeTcpPort {
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port } finally { $probe.Stop() }
}

if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) { throw "Archive root is missing: $ArchiveRoot" }
if (-not $NoOpen) {
    $serverPort = Get-FreeTcpPort
    if (-not $ApiToken) { $ApiToken = [guid]::NewGuid().ToString('N') }
    if (-not $ServerUrl) { $ServerUrl = "http://127.0.0.1:$serverPort/" }
}

$chatIndex = @(Import-Csv -LiteralPath (Join-Path $ArchiveRoot 'chats/chat_index.csv') -Encoding UTF8)
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($chat in $chatIndex) {
    $attachmentRoot = Join-Path $ArchiveRoot ([string]$chat.attachment_root -replace '/', '\')
    $attachments = if (Test-Path -LiteralPath $attachmentRoot -PathType Container) { @(Get-ChildItem -LiteralPath $attachmentRoot -File -Recurse) } else { @() }
    $details = if ($attachments.Count -gt 0) { Get-AttachmentDetails $chat $attachmentRoot $attachments } else { @() }
    $rows.Add([pscustomobject]@{
        chat_id = [string]$chat.resource_id
        chat_mode = [string]$chat.chat_mode
        title = [string]$chat.title
        message_count = if ($chat.message_count -ne '') { [long]$chat.message_count } else { 0L }
        attachment_files = $attachments.Count
        attachment_bytes = [long](($attachments | Measure-Object -Property Length -Sum).Sum)
        complete = [System.Convert]::ToBoolean($chat.complete)
        attachments = @($details)
    })
}

$group = @($rows | Where-Object chat_mode -eq 'group')
$p2p = @($rows | Where-Object chat_mode -eq 'p2p')
$tables = @(
    [ordered]@{ key = 'group_attachment_top10'; title = 'Group attachment size top 10'; html_title = '&#32676;&#32842;&#38468;&#20214;&#22823;&#23567;&#21069;&#21313;'; rows = @($group | Sort-Object attachment_bytes -Descending | Select-Object -First 10) },
    [ordered]@{ key = 'group_message_top10'; title = 'Group message count top 10'; html_title = '&#32676;&#32842;&#28040;&#24687;&#26465;&#25968;&#21069;&#21313;'; rows = @($group | Sort-Object message_count -Descending | Select-Object -First 10) },
    [ordered]@{ key = 'p2p_attachment_top10'; title = 'Direct-chat attachment size top 10'; html_title = '&#31169;&#32842;&#38468;&#20214;&#22823;&#23567;&#21069;&#21313;'; rows = @($p2p | Sort-Object attachment_bytes -Descending | Select-Object -First 10) },
    [ordered]@{ key = 'p2p_message_top10'; title = 'Direct-chat message count top 10'; html_title = '&#31169;&#32842;&#28040;&#24687;&#26465;&#25968;&#21069;&#21313;'; rows = @($p2p | Sort-Object message_count -Descending | Select-Object -First 10) }
)

$sections = foreach ($table in $tables) { Render-Table $table }
$generatedAt = (Get-Date).ToString('o')
$safeApiToken = Html $ApiToken
$html = @"
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>&#39134;&#20070;&#32842;&#22825;&#24402;&#26723;&#27010;&#35272;</title>
<style>
body{font-family:"Segoe UI","Microsoft YaHei",sans-serif;margin:32px;background:#f5f7fb;color:#172033}main{max-width:1380px;margin:auto}h1{margin-bottom:6px}p.meta{color:#64748b;margin-top:0}section{background:white;border:1px solid #e2e8f0;border-radius:12px;padding:18px;margin:20px 0;box-shadow:0 2px 8px rgba(15,23,42,.05)}table{width:100%;border-collapse:collapse}th,td{padding:10px 12px;border-bottom:1px solid #e2e8f0;text-align:left}th{background:#f8fafc}.num{text-align:right;font-variant-numeric:tabular-nums}code{font-size:12px;color:#475569}tr:last-child td{border-bottom:0}button{border:0;border-radius:7px;padding:7px 11px;cursor:pointer;font:inherit}.secondary{background:#e8eef8;color:#1e3a5f}.danger{background:#fee2e2;color:#b91c1c}.danger:disabled{opacity:.55;cursor:wait}.details-row>td{padding:0 12px 18px;background:#f8fafc}.attachment-panel{border:1px solid #dbe4f0;border-radius:10px;background:white;margin-top:8px;overflow:hidden}.attachment-toolbar{display:flex;justify-content:space-between;align-items:center;padding:10px 12px;color:#64748b;background:#f8fafc}.attachment-table th,.attachment-table td{font-size:13px}.stored{font:11px Consolas,monospace;color:#94a3b8;margin-top:3px}.delete-status{padding:0 12px 10px;color:#334155}.error{color:#b91c1c}.success{color:#047857}
</style>
</head>
<body><main>
<h1>&#39134;&#20070;&#32842;&#22825;&#24402;&#26723;&#27010;&#35272;</h1>
<p class="meta">&#29983;&#25104;&#26102;&#38388;&#65306;$(Html $generatedAt) &middot; &#27963;&#36291;&#32676;&#32842;&#65306;$($group.Count) &middot; &#27963;&#36291;&#31169;&#32842;&#65306;$($p2p.Count)</p>
$($sections -join [Environment]::NewLine)
</main>
<script>
const API_TOKEN = '$safeApiToken';
document.addEventListener('click', async function(event) {
  const toggle = event.target.closest('.toggle-details');
  if (toggle) {
    const row = document.getElementById(toggle.dataset.details);
    row.hidden = !row.hidden;
    toggle.textContent = row.hidden ? '\u67e5\u770b\u9644\u4ef6' : '\u6536\u8d77\u9644\u4ef6';
    return;
  }
  const showAll = event.target.closest('.show-all');
  if (showAll) {
    const row = document.getElementById(showAll.dataset.details);
    row.querySelectorAll('.extra-attachment').forEach(function(item) { item.hidden = false; });
    showAll.remove();
    return;
  }
  const button = event.target.closest('.delete-attachment');
  if (!button) return;
  if (!API_TOKEN || location.protocol === 'file:') {
    alert('\u8bf7\u901a\u8fc7\u81ea\u52a8\u6253\u5f00\u7684\u672c\u5730\u62a5\u544a\u670d\u52a1\u4f7f\u7528\u5220\u9664\u529f\u80fd\u3002');
    return;
  }
  if (!confirm('\u786e\u5b9a\u4ece\u672c\u5730\u5f52\u6863\u6c38\u4e45\u5220\u9664\u201c' + button.dataset.name + '\u201d\u5417\uff1f\n\u5220\u9664\u540e\u4f1a\u8bb0\u5f55\u9632\u91cd\u65b0\u4e0b\u8f7d\u7684\u5893\u7891\u3002')) return;
  const status = button.closest('.attachment-panel').querySelector('.delete-status');
  button.disabled = true;
  status.className = 'delete-status';
  status.textContent = '\u6b63\u5728\u5220\u9664\u5e76\u91cd\u5efa\u7d22\u5f15\u4e0e\u6821\u9a8c\u2026';
  try {
    const response = await fetch('/api/attachments/delete', {
      method: 'POST',
      headers: {'Content-Type': 'application/json', 'X-Report-Token': API_TOKEN},
      body: JSON.stringify({chat_id: button.dataset.chat, attachment_path: button.dataset.path})
    });
    const result = await response.json();
    if (!response.ok || !result.ok) throw new Error(result.error || '\u5220\u9664\u5931\u8d25');
    status.className = 'delete-status success';
    status.textContent = '\u5df2\u5220\u9664\uff0c\u6b63\u5728\u5237\u65b0\u62a5\u544a\u2026';
    location.reload();
  } catch (error) {
    button.disabled = false;
    status.className = 'delete-status error';
    status.textContent = error.message;
  }
});
</script>
</body></html>
"@

$outputDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutputPath))
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
[System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($false))
$jsonPath = [System.IO.Path]::ChangeExtension($OutputPath, '.json')
$report = [ordered]@{
    generated_at = $generatedAt
    archive_root = $ArchiveRoot
    active_group_chats = $group.Count
    active_p2p_chats = $p2p.Count
    html_path = [System.IO.Path]::GetFullPath($OutputPath)
    opened = $false
    server_url = $ServerUrl
    attachment_detail_limit = 20
    tables = $tables
}
[System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))

if (-not $NoOpen) {
    $serverScript = Join-Path $PSScriptRoot 'serve_chat_report.ps1'
    $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`" -ArchiveRoot `"$ArchiveRoot`" -ReportPath `"$OutputPath`" -Port $serverPort -Token `"$ApiToken`""
    $serverProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
    $ready = $false
    foreach ($attempt in 1..40) {
        Start-Sleep -Milliseconds 250
        if ($serverProcess.HasExited) { break }
        try {
            $health = Invoke-RestMethod -Uri ($ServerUrl + 'api/health') -Method Get -TimeoutSec 1
            if ($health.ok) { $ready = $true; break }
        }
        catch { }
    }
    if (-not $ready) {
        if (-not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
        throw 'The local chat report server did not start.'
    }
    Start-Process -FilePath $ServerUrl | Out-Null
    $report.opened = $true
    $report | Add-Member -NotePropertyName server_pid -NotePropertyValue $serverProcess.Id -Force
    [System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
}
$report | ConvertTo-Json -Depth 30
