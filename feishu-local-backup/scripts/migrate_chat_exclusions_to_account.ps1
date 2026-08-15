[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,
    [string]$AccountKey
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
$legacyPath = Join-Path $root '_meta\exclusions.json'
if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { throw "Legacy exclusions are missing: $legacyPath" }
$legacy = Get-Content -LiteralPath $legacyPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $AccountKey -and $legacy.account_scope) { $AccountKey = [string]$legacy.account_scope.open_id }
if ($AccountKey -notmatch '^[A-Za-z0-9_-]+$') { throw 'A safe Feishu user open_id is required.' }
if ($legacy.account_scope -and $legacy.account_scope.open_id -and [string]$legacy.account_scope.open_id -ne $AccountKey) {
    throw 'The requested account does not match the legacy exclusion scope.'
}

$target = Join-Path $root "_meta\policies\accounts\$AccountKey\chat_exclusions.json"
$byId = @{}
if (Test-Path -LiteralPath $target -PathType Leaf) {
    $existing = Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($existing.account_scope -and [string]$existing.account_scope.open_id -ne $AccountKey) { throw 'Existing account policy has a mismatched scope.' }
    foreach ($policy in @($existing.chat_exclusions)) { if ($policy.chat_id) { $byId[[string]$policy.chat_id] = $policy } }
}
foreach ($policy in @($legacy.chat_exclusions)) { if ($policy.chat_id) { $byId[[string]$policy.chat_id] = $policy } }

$value = [ordered]@{
    schema = 'feishu-account-chat-exclusions-v1'
    updated_at = (Get-Date).ToString('o')
    account_scope = [ordered]@{ identity = 'user'; open_id = $AccountKey; account_label = if ($legacy.account_scope) { [string]$legacy.account_scope.account_label } else { $null } }
    chat_exclusions = @($byId.Values | Sort-Object chat_id)
    migrated_from = '_meta/exclusions.json'
    note = 'Loaded before every downstream chat request; stable IDs, not titles, control exclusion.'
}
Write-JsonAtomic $target $value
Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
[ordered]@{ ok = $true; account_key = $AccountKey; policies = $byId.Count; path = ($target.Substring($root.Length + 1) -replace '\\', '/') } | ConvertTo-Json -Depth 5
