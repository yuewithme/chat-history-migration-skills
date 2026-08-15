[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveRoot,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^oc_[0-9a-f]+$')]
    [string]$ChatId,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceKey
)

$ErrorActionPreference = 'Stop'
$path = Join-Path ([System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')) '_meta/deleted_attachments.json'
$entries = @()
if (Test-Path -LiteralPath $path -PathType Leaf) {
    $policy = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($policy.entries)
}
$match = @($entries | Where-Object {
    [string]$_.chat_id -eq $ChatId -and
    [string]$_.resource_key -eq $ResourceKey -and
    [string]$_.status -eq 'deleted' -and
    [System.Convert]::ToBoolean($_.prevent_future_download)
} | Select-Object -First 1)
$result = [ordered]@{
    chat_id = $ChatId
    resource_key = $ResourceKey
    allow_download = ($match.Count -eq 0)
    reason = if ($match.Count) { 'active_user_deletion_tombstone' } else { 'no_active_tombstone' }
    tombstone_path = '_meta/deleted_attachments.json'
}
$result | ConvertTo-Json -Depth 5
if ($match.Count) { exit 4 }
