[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,
    [ValidateSet('Full', 'Incremental')]
    [string]$Mode = 'Incremental',
    [ValidateSet('InventoryOnly', 'Knowledge', 'KnowledgeAndBinaries')]
    [string]$ContentMode = 'Knowledge',
    [ValidateSet('Drive', 'Wiki')]
    [string[]]$Domains = @('Drive', 'Wiki'),
    [string]$LarkCliPath,
    [int]$MaxItems = 0,
    [long]$MaxBinaryBytes = 104857600,
    [switch]$DownloadUnknownSize,
    [switch]$SkipAuthCheck,
    [switch]$SkipFinalize
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:LARKSUITE_CLI_NO_UPDATE_NOTIFIER = '1'
$env:LARKSUITE_CLI_NO_SKILLS_NOTIFIER = '1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
$script:Gaps = [System.Collections.Generic.List[object]]::new()
$script:Records = [System.Collections.Generic.List[object]]::new()
$script:Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:ExcludedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:CheckpointReached = $false
$script:RunId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$script:RunRoot = Join-Path $script:Root "_meta\runs\$($script:RunId)"

if ($script:Root -match '^[A-Za-z]:\\?$') { throw "Refusing drive root as archive: $script:Root" }
if ($MaxItems -lt 0) { throw 'MaxItems cannot be negative.' }
if ($MaxBinaryBytes -lt 0) { throw 'MaxBinaryBytes cannot be negative.' }
if ($MaxItems -gt 0) {
    foreach ($relative in @('drive\index.ndjson','wiki\index.ndjson')) {
        $existingIndex = Join-Path $script:Root $relative
        if ((Test-Path -LiteralPath $existingIndex -PathType Leaf) -and (Get-Item -LiteralPath $existingIndex).Length -gt 0) {
            throw 'MaxItems is a smoke-test checkpoint and cannot replace an existing knowledge index.'
        }
    }
}

function New-Directory([string]$Path) { [System.IO.Directory]::CreateDirectory($Path) | Out-Null }
function Write-Utf8([string]$Path, [string]$Text) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ($parent) { New-Directory $parent }
    $temporary = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $utf8NoBom)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}
function Write-Json([string]$Path, [object]$Value, [int]$Depth = 50) { Write-Utf8 $Path ($Value | ConvertTo-Json -Depth $Depth) }
function Write-Ndjson([string]$Path, [object[]]$Rows) {
    $lines = foreach ($row in $Rows) { $row | ConvertTo-Json -Depth 50 -Compress }
    Write-Utf8 $Path $(if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' })
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Encoding UTF8 -Raw | ConvertFrom-Json
}
function Safe-Name([string]$Name, [int]$MaxLength = 80) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'untitled' }
    $value = $Name.Normalize([System.Text.NormalizationForm]::FormKC)
    $value = [regex]::Replace($value, '[\\/:*?""<>|\x00-\x1F]', '_')
    $value = [regex]::Replace($value, '\s+', ' ').Trim().TrimEnd('.')
    if ($value.Length -gt $MaxLength) { $value = $value.Substring(0, $MaxLength).Trim() }
    if (-not $value) { return 'untitled' }
    return $value
}
function Relative-Path([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($script:Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes archive: $full" }
    return ($full.Substring($script:Root.Length + 1) -replace '\\', '/')
}

if (-not $LarkCliPath) { $LarkCliPath = (Get-Command 'lark-cli' -ErrorAction Stop).Source }
$LarkCliPath = [System.IO.Path]::GetFullPath($LarkCliPath)
if (-not (Test-Path -LiteralPath $LarkCliPath -PathType Leaf)) { throw "lark-cli is missing: $LarkCliPath" }

function Invoke-Lark([string[]]$Arguments) {
    New-Directory $script:Root
    $stderrPath = Join-Path $env:TEMP ("lark-knowledge-err-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        Push-Location $script:Root
        try {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                if ([System.IO.Path]::GetExtension($LarkCliPath) -ieq '.ps1') {
                    $effectiveArguments = @($Arguments)
                    for ($i = 0; $i -lt $effectiveArguments.Count; $i++) {
                        if ($i -gt 0 -and $effectiveArguments[$i - 1] -in @('--params','--data') -and $effectiveArguments[$i] -match '^\s*[\[{]') {
                            $effectiveArguments[$i] = $effectiveArguments[$i].Replace('"','\"')
                        }
                    }
                    $output = @(& $LarkCliPath @effectiveArguments 2> $stderrPath)
                }
                else { $output = @(& $LarkCliPath @Arguments 2> $stderrPath) }
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $oldPreference }
        }
        finally { Pop-Location }
        $stdout = ($output -join [Environment]::NewLine)
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Encoding UTF8 -Raw } else { '' }
        $json = $null
        $errorJson = $null
        if ($stdout -and $stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json } catch { } }
        if ($stderr -and $stderr.Trim()) { try { $errorJson = $stderr | ConvertFrom-Json } catch { } }
        return [pscustomobject]@{ ExitCode = $exitCode; Json = $json; ErrorJson = $errorJson; Stdout = $stdout; Stderr = $stderr }
    }
    finally { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
}
function Get-ErrorText([object]$Result, [string]$Fallback) {
    if ($Result.ErrorJson -and $Result.ErrorJson.error -and $Result.ErrorJson.error.message) { return [string]$Result.ErrorJson.error.message }
    if ($Result.Json -and $Result.Json.error -and $Result.Json.error.message) { return [string]$Result.Json.error.message }
    if ($Result.Stderr -and $Result.Stderr.Trim()) { return $Result.Stderr.Trim() }
    return $Fallback
}
function Add-Gap([string]$Domain, [string]$Stage, [string]$ResourceId, [string]$Reason, [bool]$Retryable = $true) {
    $script:Gaps.Add([pscustomobject][ordered]@{
        domain = $Domain; stage = $Stage; resource_id = $ResourceId; reason = $Reason
        status = 'sync_failed'; retryable = $Retryable; first_seen_at = (Get-Date).ToString('o')
        last_attempt_at = (Get-Date).ToString('o'); resolved_at = $null
    })
}
function Save-Envelope([string]$Domain, [string]$Name, [object]$Result) {
    $path = Join-Path $script:RunRoot "$Domain\$Name.json"
    if ($Result.Json) { Write-Json $path $Result.Json 60 }
    else {
        Write-Json $path ([ordered]@{ ok = $false; exit_code = $Result.ExitCode; error = (Get-ErrorText $Result 'No JSON response.') })
    }
    return $path
}
function Add-Record([hashtable]$Values) {
    $id = [string]$Values.resource_id
    $domain = [string]$Values.source_domain
    if (-not $id) { return }
    if ($script:Seen.Add("$domain|$id")) { $script:Records.Add([pscustomobject]$Values) }
}

function Load-Exclusions {
    $paths = @(
        '_meta\policies\personal_data_exclusions.ndjson',
        '_meta\policies\excluded_documents.ndjson',
        '_meta\policies\excluded_resources.ndjson',
        '_meta\policies\excluded_files.ndjson'
    )
    foreach ($relative in $paths) {
        $path = Join-Path $script:Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
            if (-not $line.Trim()) { continue }
            try {
                $row = $line | ConvertFrom-Json
                $active = ($row.prevent_future_download -eq $true) -or ([string]$row.action -eq 'exclude') -or ([string]$row.status -eq 'excluded')
                if (-not $active) { continue }
                foreach ($name in @('stable_id','resource_id','obj_token','file_token','token','resource_token','wiki_token')) {
                    if ($row.PSObject.Properties[$name] -and [string]$row.$name) { [void]$script:ExcludedIds.Add([string]$row.$name) }
                }
            }
            catch { Add-Gap 'policy' 'parse_exclusion' $relative $_.Exception.Message $false }
        }
    }
    $deleted = Read-Json (Join-Path $script:Root '_meta\deleted_attachments.json')
    $deletedRows = if ($deleted -and $deleted.PSObject.Properties['deleted_attachments']) { @($deleted.deleted_attachments) } else { @($deleted) }
    foreach ($row in $deletedRows) {
        if ($null -eq $row -or $row.prevent_future_download -ne $true) { continue }
        foreach ($name in @('stable_id','resource_id','resource_key','file_token','token')) {
            if ($row.PSObject.Properties[$name] -and [string]$row.$name) { [void]$script:ExcludedIds.Add([string]$row.$name) }
        }
    }
}

function Get-DriveInventory {
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ token = ''; path = ''; depth = 0 })
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $pageNumber = 0
    while ($queue.Count -gt 0) {
        $folder = $queue.Dequeue()
        if (-not $visited.Add([string]$folder.token)) { continue }
        $pageToken = ''
        do {
            $params = [ordered]@{ folder_token = [string]$folder.token; page_size = 200 }
            if ($pageToken) { $params.page_token = $pageToken }
            $result = Invoke-Lark @('drive','files','list','--as','user','--params',($params | ConvertTo-Json -Compress),'--format','json')
            $pageNumber++
            $rawPath = Save-Envelope 'drive' ("page-{0:D6}" -f $pageNumber) $result
            if ($result.ExitCode -ne 0 -or -not $result.Json.ok) {
                Add-Gap 'drive' 'files_list' ([string]$folder.token) (Get-ErrorText $result 'Drive listing failed.')
                break
            }
            foreach ($item in @($result.Json.data.files)) {
                $token = [string]$item.token
                $title = [string]$item.name
                $path = if ([string]$folder.path) { ([string]$folder.path).TrimEnd('/') + '/' + $title } else { $title }
                Add-Record ([ordered]@{
                    source_domain = 'drive'; resource_id = $token; obj_token = $token; wiki_token = $null
                    resource_type = [string]$item.type; title = $title; logical_path = $path
                    parent_id = [string]$folder.token; source_url = [string]$item.url
                    owner_id = [string]$item.owner_id; created_time = $item.created_time; modified_time = $item.modified_time
                    size = if ($item.PSObject.Properties['size']) { $item.size } else { $null }
                    discovery_path = Relative-Path $rawPath; policy_status = $(if ($script:ExcludedIds.Contains($token)) { 'excluded' } else { 'active' })
                    content_status = 'pending'; knowledge_path = $null; metadata_path = $null; binary_path = $null
                })
                if ([string]$item.type -eq 'folder' -and $token) { $queue.Enqueue([pscustomobject]@{ token = $token; path = $path; depth = [int]$folder.depth + 1 }) }
                if ($MaxItems -gt 0 -and $script:Records.Count -ge $MaxItems) { $script:CheckpointReached = $true; return }
            }
            $hasMore = [bool]$result.Json.data.has_more
            $next = [string]$result.Json.data.next_page_token
            if ($hasMore -and -not $next) {
                Add-Gap 'drive' 'pagination' ([string]$folder.token) 'has_more was true without next_page_token.'
                break
            }
            $pageToken = $next
        } while ($hasMore)
        if ($MaxItems -gt 0 -and $script:Records.Count -ge $MaxItems) { $script:CheckpointReached = $true; return }
    }
}

function Get-WikiInventory {
    $spaceResult = Invoke-Lark @('wiki','+space-list','--as','user','--page-all','--page-limit','0','--format','json')
    $spacePath = Save-Envelope 'wiki' 'spaces' $spaceResult
    if ($spaceResult.ExitCode -ne 0 -or -not $spaceResult.Json.ok) {
        Add-Gap 'wiki' 'space_list' 'spaces' (Get-ErrorText $spaceResult 'Wiki space listing failed.')
        return
    }
    $spaces = [System.Collections.Generic.List[object]]::new()
    foreach ($space in @($spaceResult.Json.data.spaces)) { $spaces.Add($space) }
    $spaces.Add([pscustomobject]@{ space_id = 'my_library'; name = 'my_library'; description = 'Personal document library'; space_type = 'personal' })
    $pageNumber = 0
    foreach ($space in $spaces) {
        $spaceId = [string]$space.space_id
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{ token = ''; path = [string]$space.name })
        $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        while ($queue.Count -gt 0) {
            $parent = $queue.Dequeue()
            $visitKey = "$spaceId|$([string]$parent.token)"
            if (-not $visited.Add($visitKey)) { continue }
            $pageToken = ''
            do {
                $arguments = [System.Collections.Generic.List[string]]::new()
                foreach ($arg in @('wiki','+node-list','--as','user','--space-id',$spaceId,'--page-size','50','--format','json')) { $arguments.Add([string]$arg) }
                if ([string]$parent.token) { $arguments.Add('--parent-node-token'); $arguments.Add([string]$parent.token) }
                if ($pageToken) { $arguments.Add('--page-token'); $arguments.Add($pageToken) }
                $result = Invoke-Lark $arguments.ToArray()
                $pageNumber++
                $rawPath = Save-Envelope 'wiki' ("nodes-{0:D6}" -f $pageNumber) $result
                if ($result.ExitCode -ne 0 -or -not $result.Json.ok) {
                    Add-Gap 'wiki' 'node_list' $visitKey (Get-ErrorText $result 'Wiki node listing failed.')
                    break
                }
                foreach ($node in @($result.Json.data.nodes)) {
                    $nodeToken = [string]$node.node_token
                    $objToken = [string]$node.obj_token
                    $title = [string]$node.title
                    $path = ([string]$parent.path).TrimEnd('/') + '/' + $title
                    Add-Record ([ordered]@{
                        source_domain = 'wiki'; resource_id = $nodeToken; obj_token = $objToken; wiki_token = $nodeToken
                        resource_type = [string]$node.obj_type; title = $title; logical_path = $path
                        parent_id = [string]$node.parent_node_token; source_url = [string]$node.url
                        owner_id = $null; created_time = $node.created_time; modified_time = $node.modified_time
                        size = $null; space_id = $spaceId; has_child = [bool]$node.has_child
                        discovery_path = Relative-Path $rawPath
                        policy_status = $(if ($script:ExcludedIds.Contains($nodeToken) -or $script:ExcludedIds.Contains($objToken)) { 'excluded' } else { 'active' })
                        content_status = 'pending'; knowledge_path = $null; metadata_path = $null; binary_path = $null
                    })
                    if ([bool]$node.has_child -and $nodeToken) { $queue.Enqueue([pscustomobject]@{ token = $nodeToken; path = $path }) }
                    if ($MaxItems -gt 0 -and $script:Records.Count -ge $MaxItems) { $script:CheckpointReached = $true; return }
                }
                $hasMore = [bool]$result.Json.data.has_more
                $next = [string]$result.Json.data.page_token
                if (-not $next) { $next = [string]$result.Json.data.next_page_token }
                if ($hasMore -and -not $next) {
                    Add-Gap 'wiki' 'pagination' $visitKey 'has_more was true without a continuation token.'
                    break
                }
                $pageToken = $next
            } while ($hasMore)
        }
    }
}

New-Directory $script:RunRoot
Load-Exclusions

$runPath = Join-Path $script:RunRoot 'run.json'
Write-Json $runPath ([ordered]@{
    schema = 'feishu-knowledge-sync-run-v1'; run_id = $script:RunId; started_at = (Get-Date).ToString('o')
    status = 'running'; mode = $Mode; content_mode = $ContentMode; domains = @($Domains)
    source_identity = 'user'; source_mutations = 0
})

if (-not $SkipAuthCheck) {
    $auth = Invoke-Lark @('auth','status','--json','--verify')
    Save-Envelope 'preflight' 'auth-status' $auth | Out-Null
    if ($auth.ExitCode -ne 0 -or -not $auth.Json.verified -or -not $auth.Json.identities.user.verified) { throw 'A verified Feishu user identity is required.' }
}

if ($Domains -contains 'Drive') { Get-DriveInventory }
if ($Domains -contains 'Wiki') { Get-WikiInventory }

$inventorySummary = [ordered]@{
    discovered = $script:Records.Count
    drive = @($script:Records | Where-Object source_domain -eq 'drive').Count
    wiki = @($script:Records | Where-Object source_domain -eq 'wiki').Count
    excluded = @($script:Records | Where-Object policy_status -eq 'excluded').Count
}

Write-Ndjson (Join-Path $script:Root 'drive\index.ndjson') @($script:Records | Where-Object source_domain -eq 'drive')
Write-Ndjson (Join-Path $script:Root 'wiki\index.ndjson') @($script:Records | Where-Object source_domain -eq 'wiki')
Write-Json (Join-Path $script:RunRoot 'inventory_summary.json') $inventorySummary

$summary = [ordered]@{
    schema = 'feishu-knowledge-sync-summary-v1'; run_id = $script:RunId; mode = $Mode; content_mode = $ContentMode
    status = if ($script:CheckpointReached) { 'checkpoint' } elseif ($script:Gaps.Count) { 'inventory_complete_with_gaps' } else { 'inventory_complete' }
    completed_at = (Get-Date).ToString('o'); inventory = $inventorySummary; gaps = $script:Gaps.Count
    note = if ($script:CheckpointReached) { 'MaxItems created a bounded checkpoint; this is not full inventory completion.' } else { 'Content materialization is performed by sync_feishu_knowledge_content.ps1 from these stable indexes.' }
}
Write-Json (Join-Path $script:RunRoot 'summary.json') $summary
Write-Json (Join-Path $script:Root '_meta\state\knowledge_inventory_latest.json') $summary

$run = Read-Json $runPath
$run.status = $summary.status
$run | Add-Member -NotePropertyName completed_at -NotePropertyValue $summary.completed_at -Force
$run | Add-Member -NotePropertyName summary -NotePropertyValue $summary -Force
Write-Json $runPath $run

if ($script:Gaps.Count) {
    $gapPath = Join-Path $script:Root '_meta\gaps.json'
    $existing = Read-Json $gapPath
    $rows = [System.Collections.Generic.List[object]]::new()
    $existingRows = if ($existing -and $existing.PSObject.Properties['gaps']) { @($existing.gaps) } else { @($existing) }
    foreach ($row in $existingRows) { if ($null -ne $row) { $rows.Add($row) } }
    foreach ($gap in $script:Gaps) { $rows.Add($gap) }
    Write-Json $gapPath @($rows) 50
}

if (-not $SkipFinalize) {
    $validation = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action ValidateJson -ArchiveRoot $script:Root | ConvertFrom-Json
    if (-not $validation.valid) { throw 'Knowledge inventory JSON validation failed.' }
    & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $script:Root | Out-Null
    $verify = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action VerifyHashes -ArchiveRoot $script:Root -FullHash | ConvertFrom-Json
    if (-not $verify.valid -or -not $verify.cardinality_ok) { throw 'Knowledge inventory checksum verification failed.' }
    $summary['validation'] = $validation
    $summary['verify'] = $verify
}

$summary | ConvertTo-Json -Depth 40
