[CmdletBinding()]
param(
    [string]$ArchiveRoot,
    [string]$ArchiveHome = $env:CHAT_HISTORY_ARCHIVE_HOME,
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')]
    [string]$ProfileId,
    [ValidateSet('Full', 'Incremental')]
    [string]$Mode = 'Incremental',
    [ValidateSet('InventoryOnly', 'Knowledge', 'KnowledgeAndBinaries')]
    [string]$ContentMode = 'Knowledge',
    [ValidateSet('None', 'Discovered', 'All')]
    [string]$ThreadMode = 'Discovered',
    [string]$LarkCliPath,
    [int]$MaxChats = 0,
    [long]$MaxBinaryBytes = 104857600,
    [switch]$DownloadUnknownSize,
    [switch]$SkipChats,
    [switch]$SkipKnowledge,
    [switch]$SkipAuthCheck,
    [switch]$NoOpen,
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
if ($ArchiveRoot -and $PSBoundParameters.ContainsKey('ArchiveHome')) { throw 'Use either -ArchiveRoot or -ArchiveHome with -ProfileId, not both.' }
if (-not $ArchiveRoot) {
    if (-not $ArchiveHome -or -not $ProfileId) { throw 'Pass -ArchiveRoot or use -ArchiveHome / CHAT_HISTORY_ARCHIVE_HOME with -ProfileId.' }
    $ArchiveRoot = Join-Path $ArchiveHome "feishu\$ProfileId"
}
$root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
if ($root -match '^[A-Za-z]:\\?$') { throw "Refusing drive root as archive: $root" }
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Archive root does not exist; run initialize_archive.ps1 first: $root" }
$markerPath = Join-Path $root 'archive-profile.json'
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($marker.schema -ne 'chat-history-archive-profile-v1' -or $marker.source -ne 'feishu') { throw "Archive profile mismatch: $markerPath" }
    if ($ProfileId -and $marker.profile_id -ne $ProfileId) { throw "Profile ID mismatch: expected $ProfileId, found $($marker.profile_id)" }
} else {
    $recognizedLegacy = (Test-Path -LiteralPath (Join-Path $root '_meta')) -or (Test-Path -LiteralPath (Join-Path $root 'chats')) -or (Test-Path -LiteralPath (Join-Path $root 'drive')) -or (Test-Path -LiteralPath (Join-Path $root 'wiki'))
    if (-not $recognizedLegacy) { throw "Archive has no profile marker and is not a recognized Feishu legacy layout: $root" }
    Write-Warning "Using a recognized legacy archive without archive-profile.json: $root"
}

$plan = [ordered]@{
    schema = 'feishu-full-backup-plan-v1'; archive_root = $root; mode = $Mode; content_mode = $ContentMode
    identity = 'user'; source_mutations = 0
    stages = @(
        [ordered]@{ name = 'preflight'; action = 'verify identity, policies, tombstones and archive state' },
        [ordered]@{ name = 'chat_preflight'; action = 'generate and automatically open four-table HTML when chat data exists'; enabled = -not $SkipChats },
        [ordered]@{ name = 'chats'; action = 'authoritative JSON full/incremental synchronization'; enabled = -not $SkipChats },
        [ordered]@{ name = 'knowledge_inventory'; action = 'recursive Drive and Wiki inventory including my_library'; enabled = -not $SkipKnowledge },
        [ordered]@{ name = 'knowledge_content'; action = 'Markdown documents, structured/native snapshots and policy-controlled binaries'; enabled = (-not $SkipKnowledge -and $ContentMode -ne 'InventoryOnly') },
        [ordered]@{ name = 'finalize'; action = 'validate JSON, write checksums last, verify full hash cardinality' }
    )
}
if ($PlanOnly) { $plan | ConvertTo-Json -Depth 20; exit 0 }

$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$runRoot = Join-Path $root "_meta\runs\$runId"
[System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
$runPath = Join-Path $runRoot 'full_backup.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Write-Json([string]$Path, [object]$Value) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 60), $utf8NoBom)
}

$result = [ordered]@{
    schema = 'feishu-full-backup-run-v1'; run_id = $runId; started_at = (Get-Date).ToString('o')
    status = 'running'; plan = $plan; stages = [ordered]@{}; source_mutations = 0
}
Write-Json $runPath $result

try {
    if (-not $SkipChats) {
        $args = @{
            ArchiveRoot = $root; Mode = $Mode; ThreadMode = $ThreadMode; MaxChats = $MaxChats
            SkipFinalize = $true; NoOpen = $NoOpen; SkipAuthCheck = $SkipAuthCheck
        }
        if ($LarkCliPath) { $args.LarkCliPath = $LarkCliPath }
        $chatOutput = & (Join-Path $PSScriptRoot 'sync_feishu_messages.ps1') @args | ConvertFrom-Json
        $result.stages.chats = $chatOutput
        Write-Json $runPath $result
    }

    if (-not $SkipKnowledge) {
        $inventoryArgs = @{
            ArchiveRoot = $root; Mode = $Mode; ContentMode = $ContentMode
            MaxBinaryBytes = $MaxBinaryBytes; SkipFinalize = $true; SkipAuthCheck = $SkipAuthCheck
        }
        if ($LarkCliPath) { $inventoryArgs.LarkCliPath = $LarkCliPath }
        $inventoryOutput = & (Join-Path $PSScriptRoot 'sync_feishu_knowledge.ps1') @inventoryArgs | ConvertFrom-Json
        $result.stages.knowledge_inventory = $inventoryOutput
        Write-Json $runPath $result

        if ($ContentMode -ne 'InventoryOnly') {
            $contentArgs = @{
                ArchiveRoot = $root; ContentMode = $ContentMode
                MaxBinaryBytes = $MaxBinaryBytes; DownloadUnknownSize = $DownloadUnknownSize; SkipFinalize = $true
            }
            if ($LarkCliPath) { $contentArgs.LarkCliPath = $LarkCliPath }
            $contentOutput = & (Join-Path $PSScriptRoot 'sync_feishu_knowledge_content.ps1') @contentArgs | ConvertFrom-Json
            $result.stages.knowledge_content = $contentOutput
            Write-Json $runPath $result
        }
    }

    $validation = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action ValidateJson -ArchiveRoot $root | ConvertFrom-Json
    if (-not $validation.valid) { throw 'Full backup JSON/NDJSON validation failed.' }
    $result.stages.validation = $validation
    $result.status = 'finalizing'
    Write-Json $runPath $result

    & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $root | Out-Null
    $verify = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action VerifyHashes -ArchiveRoot $root -FullHash | ConvertFrom-Json
    if (-not $verify.valid -or -not $verify.cardinality_ok) { throw 'Full backup checksum verification failed.' }

    $result.status = if (($result.stages.chats -and $result.stages.chats.status -match 'gap|fail') -or ($result.stages.knowledge_inventory -and $result.stages.knowledge_inventory.status -match 'gap|fail') -or ($result.stages.knowledge_content -and $result.stages.knowledge_content.status -match 'gap|fail')) { 'complete_with_gaps' } else { 'complete' }
    $result.completed_at = (Get-Date).ToString('o')
    $result.stages.verify = $verify
    Write-Json $runPath $result

    # The run file changed after verification; rehash and verify again so checksums remain the final mutation.
    & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $root | Out-Null
    $finalVerify = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action VerifyHashes -ArchiveRoot $root -FullHash | ConvertFrom-Json
    if (-not $finalVerify.valid -or -not $finalVerify.cardinality_ok) { throw 'Final run-state checksum verification failed.' }
    $result.final_verify = [ordered]@{ valid = $finalVerify.valid; cardinality_ok = $finalVerify.cardinality_ok }
    $result | ConvertTo-Json -Depth 60
}
catch {
    $result.status = 'failed'
    $result.completed_at = (Get-Date).ToString('o')
    $result.error = $_.Exception.Message
    Write-Json $runPath $result
    throw
}
