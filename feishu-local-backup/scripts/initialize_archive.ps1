[CmdletBinding()]
param(
    [string]$ArchiveRoot,
    [string]$ArchiveHome = $env:CHAT_HISTORY_ARCHIVE_HOME,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')]
    [string]$ProfileId,
    [switch]$AdoptExisting
)

$ErrorActionPreference = 'Stop'
if ($ArchiveRoot -and $PSBoundParameters.ContainsKey('ArchiveHome')) {
    throw 'Use either -ArchiveRoot or -ArchiveHome with -ProfileId, not both.'
}
if (-not $ArchiveRoot -and -not $ArchiveHome) {
    throw 'Archive location is required: pass -ArchiveRoot or set -ArchiveHome / CHAT_HISTORY_ARCHIVE_HOME.'
}
$root = if ($ArchiveRoot) {
    [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
} else {
    [System.IO.Path]::GetFullPath((Join-Path $ArchiveHome "feishu\$ProfileId")).TrimEnd('\')
}
if ($root -match '^[A-Za-z]:\\?$') { throw "Refusing drive root as archive: $root" }

[System.IO.Directory]::CreateDirectory($root) | Out-Null
$markerPath = Join-Path $root 'archive-profile.json'
$recognized = (Test-Path -LiteralPath (Join-Path $root '_meta')) -or
    (Test-Path -LiteralPath (Join-Path $root 'chats')) -or
    (Test-Path -LiteralPath (Join-Path $root 'drive')) -or
    (Test-Path -LiteralPath (Join-Path $root 'wiki'))

if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($marker.schema -ne 'chat-history-archive-profile-v1' -or $marker.source -ne 'feishu') {
        throw "Archive profile mismatch: $markerPath"
    }
    if ($marker.profile_id -ne $ProfileId) { throw "Profile ID mismatch: expected $ProfileId, found $($marker.profile_id)" }
} else {
    $entries = @(Get-ChildItem -LiteralPath $root -Force)
    if ($entries.Count -gt 0 -and (-not $AdoptExisting -or -not $recognized)) {
        throw 'Non-empty archive root has no profile marker; inspect it, then rerun with -AdoptExisting only if it is the intended Feishu archive.'
    }
    $marker = [ordered]@{
        schema = 'chat-history-archive-profile-v1'
        source = 'feishu'
        profile_id = $ProfileId
        layout_version = 1
        created_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = $marker | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($markerPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

$directories = @(
    '_meta\policies', '_meta\reports', '_meta\runs', '_meta\state',
    'chats\raw', 'chats\members', 'chats\attachments', 'chats\quarantine',
    'drive\raw', 'drive\documents', 'drive\metadata', 'drive\structured', 'drive\files',
    'wiki\raw', 'wiki\documents', 'wiki\metadata', 'wiki\structured', 'wiki\attachments', 'wiki\files'
)
foreach ($relative in $directories) { [System.IO.Directory]::CreateDirectory((Join-Path $root $relative)) | Out-Null }

[ordered]@{ initialized = $true; archive_root = $root; profile = $marker } | ConvertTo-Json -Depth 10
