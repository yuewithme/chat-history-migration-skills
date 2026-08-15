[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,
    [string]$AccountKey,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^oc_[0-9a-f]+$')]
    [string]$ChatId,
    [string]$Title,
    [ValidateSet('purge', 'quarantine')]
    [string]$Disposition = 'purge',
    [Parameter(Mandatory = $true)]
    [string[]]$Scope,
    [Parameter(Mandatory = $true)]
    [string]$Reason
)

$ErrorActionPreference = 'Stop'

function Write-JsonAtomic([string]$Path, [object]$Value) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ('.policy-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
        Get-Content -LiteralPath $temporary -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Archive root is missing: $root" }
$allowedScopes = @('messages', 'members', 'attachments', 'active_indexes', 'future_downloads', 'future_attachment_downloads')
foreach ($value in $Scope) { if ($value -notin $allowedScopes) { throw "Unsupported exclusion scope: $value" } }
if (-not $Scope.Count) { throw 'At least one exclusion scope is required.' }
if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'A concrete reason is required.' }

$legacyPath = Join-Path $root '_meta\exclusions.json'
$legacy = if (Test-Path -LiteralPath $legacyPath -PathType Leaf) { Get-Content -LiteralPath $legacyPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
if (-not $AccountKey -and $legacy -and $legacy.account_scope) { $AccountKey = [string]$legacy.account_scope.open_id }
if ($AccountKey -notmatch '^[A-Za-z0-9_-]+$') { throw 'A safe Feishu user open_id is required.' }
if ($legacy -and $legacy.account_scope.open_id -and [string]$legacy.account_scope.open_id -ne $AccountKey) { throw 'AccountKey does not match the archive account scope.' }

$target = Join-Path $root "_meta\policies\accounts\$AccountKey\chat_exclusions.json"
$byId = @{}
if (Test-Path -LiteralPath $target -PathType Leaf) {
    $current = Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($current.account_scope -and [string]$current.account_scope.open_id -ne $AccountKey) { throw 'Existing account policy has a mismatched scope.' }
    foreach ($policy in @($current.chat_exclusions)) { if ($policy.chat_id) { $byId[[string]$policy.chat_id] = $policy } }
}
$byId[$ChatId] = [ordered]@{
    chat_id = $ChatId; title = $Title; disposition = $Disposition; scope = @($Scope | Select-Object -Unique)
    reason = $Reason; decided_at = (Get-Date).ToString('o'); decision_source = 'explicit_user_instruction'
}
$value = [ordered]@{
    schema = 'feishu-account-chat-exclusions-v1'; updated_at = (Get-Date).ToString('o')
    account_scope = [ordered]@{ identity = 'user'; open_id = $AccountKey; account_label = if ($legacy -and $legacy.account_scope) { [string]$legacy.account_scope.account_label } else { $null } }
    chat_exclusions = @($byId.Values | Sort-Object chat_id)
    note = 'Loaded before every downstream chat request; stable IDs, not titles, control exclusion.'
}
Write-JsonAtomic $target $value
Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
[ordered]@{ ok = $true; account_key = $AccountKey; chat_id = $ChatId; disposition = $Disposition; scope = @($Scope); policies = $byId.Count; path = ($target.Substring($root.Length + 1) -replace '\\', '/') } | ConvertTo-Json -Depth 10
