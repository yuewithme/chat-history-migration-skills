[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExistingPath,
    [Parameter(Mandatory = $true)]
    [string]$IncomingPath,
    [string]$OutputPath,
    [switch]$IncomingIsFullSnapshot
)

$ErrorActionPreference = 'Stop'
if (-not $OutputPath) { $OutputPath = $ExistingPath }

function Read-Envelope([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label file is missing: $Path" }
    $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $value.ok) { throw "$Label envelope is not successful; refusing to merge over prior data" }
    return $value
}

$existing = Read-Envelope $ExistingPath 'Existing'
$incoming = Read-Envelope $IncomingPath 'Incoming'
$messages = @{}

foreach ($message in $existing.data.messages) {
    $id = [string]$message.message_id
    if (-not $id) { throw 'Existing envelope contains a message without message_id' }
    $messages[$id] = $message
}
foreach ($message in $incoming.data.messages) {
    $id = [string]$message.message_id
    if (-not $id) { throw 'Incoming envelope contains a message without message_id' }
    $messages[$id] = $message
}

$merged = @($messages.Values | Sort-Object `
    @{ Expression = { $position = 0L; if ([long]::TryParse([string]$_.message_position, [ref]$position)) { $position } else { [long]::MaxValue } } }, `
    @{ Expression = { [string]$_.create_time } }, `
    @{ Expression = { [string]$_.message_id } })

$base = $incoming
$base.data.messages = $merged
$base.data | Add-Member -NotePropertyName total -NotePropertyValue $merged.Count -Force
$incomingComplete = if ($incoming.meta -and $incoming.meta.pagination -and $null -ne $incoming.meta.pagination.complete) {
    [bool]$incoming.meta.pagination.complete
} else {
    -not [bool]$incoming.data.has_more
}
$existingCoverageComplete = if ($existing.archive_meta -and $null -ne $existing.archive_meta.archive_coverage_complete) {
    [bool]$existing.archive_meta.archive_coverage_complete
} elseif ($existing.archive_meta -and $null -ne $existing.archive_meta.pagination_complete) {
    [bool]$existing.archive_meta.pagination_complete
} else {
    -not [bool]$existing.data.has_more
}
$archiveCoverageComplete = $incomingComplete -and ($IncomingIsFullSnapshot -or $existingCoverageComplete)
if ($incomingComplete) {
    $base.data | Add-Member -NotePropertyName has_more -NotePropertyValue $false -Force
    $base.data | Add-Member -NotePropertyName page_token -NotePropertyValue '' -Force
}
$archiveMeta = if ($incoming.archive_meta) { $incoming.archive_meta } else { [pscustomobject]@{} }
$archiveMeta | Add-Member -NotePropertyName merged_at -NotePropertyValue (Get-Date).ToString('o') -Force
$archiveMeta | Add-Member -NotePropertyName existing_messages -NotePropertyValue @($existing.data.messages).Count -Force
$archiveMeta | Add-Member -NotePropertyName incoming_messages -NotePropertyValue @($incoming.data.messages).Count -Force
$archiveMeta | Add-Member -NotePropertyName merged_messages -NotePropertyValue $merged.Count -Force
$archiveMeta | Add-Member -NotePropertyName duplicate_ids_replaced_by_incoming -NotePropertyValue (@($existing.data.messages).Count + @($incoming.data.messages).Count - $merged.Count) -Force
$archiveMeta | Add-Member -NotePropertyName incoming_pagination_complete -NotePropertyValue $incomingComplete -Force
$archiveMeta | Add-Member -NotePropertyName incoming_is_full_snapshot -NotePropertyValue ([bool]$IncomingIsFullSnapshot) -Force
$archiveMeta | Add-Member -NotePropertyName prior_archive_coverage_complete -NotePropertyValue $existingCoverageComplete -Force
$archiveMeta | Add-Member -NotePropertyName archive_coverage_complete -NotePropertyValue $archiveCoverageComplete -Force
$base | Add-Member -NotePropertyName archive_meta -NotePropertyValue $archiveMeta -Force

$outputDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutputPath))
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$temporary = Join-Path $outputDirectory ('.merge-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    [System.IO.File]::WriteAllText($temporary, ($base | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
    Get-Content -LiteralPath $temporary -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    Move-Item -LiteralPath $temporary -Destination $OutputPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

[ordered]@{
    output = [System.IO.Path]::GetFullPath($OutputPath)
    messages = $merged.Count
    ok = $true
} | ConvertTo-Json
