[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveRoot,
    [string]$ReportPath,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1024, 65535)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Token,
    [ValidateRange(5, 1440)]
    [int]$IdleTimeoutMinutes = 720
)

$ErrorActionPreference = 'Stop'
if (-not $ReportPath) { $ReportPath = Join-Path $ArchiveRoot '_meta\reports\chat-overview.html' }
$serverUrl = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($serverUrl)

function Send-Bytes([System.Net.HttpListenerContext]$Context, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes) {
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    if ($Bytes.Length -gt 0) { $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length) }
    $Context.Response.OutputStream.Close()
}

function Send-Text([System.Net.HttpListenerContext]$Context, [int]$StatusCode, [string]$ContentType, [string]$Text) {
    Send-Bytes $Context $StatusCode $ContentType ([System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Send-Json([System.Net.HttpListenerContext]$Context, [int]$StatusCode, [object]$Value) {
    Send-Text $Context $StatusCode 'application/json; charset=utf-8' ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Require-Token([System.Net.HttpListenerRequest]$Request) {
    $provided = [string]$Request.Headers['X-Report-Token']
    if (-not [string]::Equals($provided, $Token, [System.StringComparison]::Ordinal)) { throw 'Invalid report token.' }
}

$listener.Start()
$lastActivity = Get-Date
$stopRequested = $false
try {
    while (-not $stopRequested) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(1000)) {
            if (((Get-Date) - $lastActivity).TotalMinutes -ge $IdleTimeoutMinutes) {
                $stopRequested = $true
                break
            }
        }
        if ($stopRequested) { break }
        $context = $task.Result
        $lastActivity = Get-Date
        try {
            $request = $context.Request
            $path = $request.Url.AbsolutePath
            if ($request.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/chat-overview.html')) {
                if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { throw "Report is missing: $ReportPath" }
                Send-Bytes $context 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes($ReportPath))
            }
            elseif ($request.HttpMethod -eq 'GET' -and ($path -eq '/api/report' -or $path -eq '/chat-overview.json')) {
                $jsonPath = [System.IO.Path]::ChangeExtension($ReportPath, '.json')
                if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { throw "Report JSON is missing: $jsonPath" }
                Send-Bytes $context 200 'application/json; charset=utf-8' ([System.IO.File]::ReadAllBytes($jsonPath))
            }
            elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/api/health') {
                Send-Json $context 200 ([ordered]@{ ok = $true; archive_root = $ArchiveRoot; report_path = $ReportPath; pid = $PID })
            }
            elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/favicon.ico') {
                Send-Bytes $context 204 'image/x-icon' ([byte[]]@())
            }
            elseif ($request.HttpMethod -eq 'POST' -and $path -eq '/api/attachments/delete') {
                Require-Token $request
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $payload = $body | ConvertFrom-Json
                $chatId = [string]$payload.chat_id
                $paths = if ($payload.attachment_paths) { @($payload.attachment_paths | ForEach-Object { [string]$_ }) } else { @([string]$payload.attachment_path) }
                if ($paths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($paths[0])) { throw 'No attachment path was supplied.' }
                $deleteJson = & (Join-Path $PSScriptRoot 'remove_chat_attachments.ps1') -ArchiveRoot $ArchiveRoot -ChatId $chatId -AttachmentPath $paths -ConfirmDelete -SkipRehash
                $deleteResult = $deleteJson | ConvertFrom-Json
                try {
                    $null = & (Join-Path $PSScriptRoot 'generate_chat_report.ps1') -ArchiveRoot $ArchiveRoot -OutputPath $ReportPath -NoOpen -ApiToken $Token -ServerUrl $serverUrl
                }
                finally {
                    $rehash = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $ArchiveRoot | ConvertFrom-Json
                    $deleteResult | Add-Member -NotePropertyName rehash -NotePropertyValue $rehash -Force
                }
                Send-Json $context 200 ([ordered]@{ ok = $true; deletion = $deleteResult; report_refreshed = $true })
            }
            elseif ($request.HttpMethod -eq 'POST' -and $path -eq '/api/shutdown') {
                Require-Token $request
                Send-Json $context 200 ([ordered]@{ ok = $true; stopping = $true })
                $stopRequested = $true
            }
            else {
                Send-Json $context 404 ([ordered]@{ ok = $false; error = 'Not found.' })
            }
        }
        catch {
            try { Send-Json $context 400 ([ordered]@{ ok = $false; error = $_.Exception.Message }) } catch { }
        }
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
