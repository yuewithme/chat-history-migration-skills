[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchiveRoot,
    [ValidateSet('Full', 'Incremental')]
    [string]$Mode = 'Incremental',
    [ValidateSet('None', 'Discovered', 'All')]
    [string]$ThreadMode = 'Discovered',
    [string]$LarkCliPath,
    [string]$PoliciesPath,
    [string]$AccountKey,
    [int]$OverlapMinutes = 10,
    [int]$PageLimit = 1000,
    [int]$MaxChats = 0,
    [string[]]$ChatId,
    [switch]$SkipMembers,
    [switch]$NoOpen,
    [switch]$SkipFinalize,
    [switch]$SkipAuthCheck
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:LARKSUITE_CLI_NO_UPDATE_NOTIFIER = '1'
$env:LARKSUITE_CLI_NO_SKILLS_NOTIFIER = '1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\')
$script:CurrentGaps = [System.Collections.Generic.List[object]]::new()
$script:SucceededStages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

if ($OverlapMinutes -lt 0 -or $OverlapMinutes -gt 1440) { throw 'OverlapMinutes must be between 0 and 1440.' }
if ($PageLimit -lt 1 -or $PageLimit -gt 1000) { throw 'PageLimit must be between 1 and 1000.' }
if ($script:Root -match '^[A-Za-z]:\\?$') { throw "Refusing drive root as archive: $script:Root" }
if (-not $PoliciesPath) { $PoliciesPath = Join-Path $PSScriptRoot '..\references\exclusions.json' }

function New-Directory([string]$Path) { [System.IO.Directory]::CreateDirectory($Path) | Out-Null }
function Write-Utf8([string]$Path, [string]$Text) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ($parent) { New-Directory $parent }
    $temporary = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $utf8NoBom)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}
function Write-Json([string]$Path, [object]$Value, [int]$Depth = 40) { Write-Utf8 $Path ($Value | ConvertTo-Json -Depth $Depth) }
function Write-Ndjson([string]$Path, [object[]]$Rows) {
    $lines = foreach ($row in $Rows) { $row | ConvertTo-Json -Depth 40 -Compress }
    Write-Utf8 $Path $(if (@($lines).Count) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' })
}
function Append-Ndjson([string]$Path, [object]$Value) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ($parent) { New-Directory $parent }
    [System.IO.File]::AppendAllText($Path, (($Value | ConvertTo-Json -Depth 40 -Compress) + [Environment]::NewLine), $utf8NoBom)
}
function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Relative-Path([string]$Path) { return ($Path.Substring($script:Root.Length + 1) -replace '\\', '/') }
function Safe-Name([string]$Name, [int]$MaxLength = 80) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'untitled' }
    $safe = $Name.Normalize([System.Text.NormalizationForm]::FormKC)
    $safe = [regex]::Replace($safe, '[\\/:*?""<>|\x00-\x1F]', '_')
    $safe = [regex]::Replace($safe, '\s+', ' ').Trim().TrimEnd('.')
    if ($safe.Length -gt $MaxLength) { $safe = $safe.Substring(0, $MaxLength).Trim() }
    if (-not $safe) { return 'untitled' }
    return $safe
}
function Has-Scope([object]$Policy, [string]$Scope) { return (@($Policy.scope) -contains $Scope) }

if (-not $LarkCliPath) {
    $command = Get-Command 'lark-cli' -ErrorAction Stop
    $LarkCliPath = $command.Source
}
$LarkCliPath = [System.IO.Path]::GetFullPath($LarkCliPath)
if (-not (Test-Path -LiteralPath $LarkCliPath -PathType Leaf)) { throw "lark-cli is missing: $LarkCliPath" }

function Invoke-Lark([string[]]$Arguments, [string]$WorkingDirectory = $script:Root) {
    New-Directory $WorkingDirectory
    $stderrPath = Join-Path $env:TEMP ("lark-sync-err-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        Push-Location $WorkingDirectory
        try {
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                if ([System.IO.Path]::GetExtension($LarkCliPath) -ieq '.ps1') {
                    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LarkCliPath @Arguments 2> $stderrPath)
                }
                else {
                    $output = @(& $LarkCliPath @Arguments 2> $stderrPath)
                }
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previousPreference }
        }
        finally { Pop-Location }
        $stdout = ($output -join [Environment]::NewLine)
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }
        $json = $null
        $errorJson = $null
        if ($stdout.Trim()) { try { $json = $stdout | ConvertFrom-Json } catch { } }
        if ($stderr.Trim()) { try { $errorJson = $stderr | ConvertFrom-Json } catch { } }
        return [pscustomobject]@{ ExitCode = $exitCode; Json = $json; ErrorJson = $errorJson; Stdout = $stdout; Stderr = $stderr }
    }
    finally { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
}

function Assert-LarkSuccess([object]$Result, [string]$Operation) {
    if ($Result.ExitCode -ne 0 -or $null -eq $Result.Json -or $Result.Json.ok -ne $true) {
        $error = if ($Result.ErrorJson -and $Result.ErrorJson.error) { $Result.ErrorJson.error } elseif ($Result.Json -and $Result.Json.error) { $Result.Json.error } else { $null }
        $message = if ($error -and $error.message) { [string]$error.message } else { "$Operation failed with exit code $($Result.ExitCode)." }
        throw $message
    }
}

function Convert-MessageTime([object]$Value) {
    $text = [string]$Value
    if (-not $text) { return $null }
    $number = 0L
    if ([long]::TryParse($text, [ref]$number)) {
        try {
            if ($number -gt 9999999999) { return [DateTimeOffset]::FromUnixTimeMilliseconds($number) }
            return [DateTimeOffset]::FromUnixTimeSeconds($number)
        }
        catch { return $null }
    }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-LastMessageTime([object]$Envelope) {
    $latest = $null
    foreach ($message in @($Envelope.data.messages)) {
        $parsed = Convert-MessageTime $message.create_time
        if ($parsed -and ($null -eq $latest -or $parsed -gt $latest)) { $latest = $parsed }
    }
    return $latest
}

function Get-PaginationComplete([object]$Envelope) {
    if ($Envelope.meta -and $Envelope.meta.pagination -and $null -ne $Envelope.meta.pagination.complete) { return [bool]$Envelope.meta.pagination.complete }
    return -not [bool]$Envelope.data.has_more
}

function Record-Error([string]$Stage, [string]$ResourceId, [string]$Title, [object]$Result, [string]$Message) {
    $timestamp = (Get-Date).ToString('o')
    $error = if ($Result -and $Result.ErrorJson -and $Result.ErrorJson.error) { $Result.ErrorJson.error } elseif ($Result -and $Result.Json -and $Result.Json.error) { $Result.Json.error } else { $null }
    Append-Ndjson $script:ErrorsPath ([ordered]@{
        timestamp = $timestamp; stage = $Stage; resource_type = 'chat'; resource_id = $ResourceId; resource_name = $Title
        message = $Message; exit_code = if ($Result) { $Result.ExitCode } else { $null }
        error_type = if ($error) { [string]$error.type } else { $null }; error_subtype = if ($error) { [string]$error.subtype } else { $null }
        error_code = if ($error) { $error.code } else { $null }; missing_scopes = if ($error) { @($error.missing_scopes) } else { @() }
    })
    $script:CurrentGaps.Add([pscustomobject][ordered]@{
        domain = 'chat'; stage = $Stage; resource_id = $ResourceId; resource_name = $Title
        reason = $Message; status = 'sync_failed'; retryable = $true
        first_seen_at = $timestamp; last_attempt_at = $timestamp; resolved_at = $null
    })
}

function Add-SucceededStage([string]$Stage, [string]$ResourceId) {
    [void]$script:SucceededStages.Add("$Stage|$ResourceId")
}

function Update-GapLedger {
    $path = Join-Path $script:Root '_meta\gaps.json'
    $rows = [System.Collections.Generic.List[object]]::new()
    $existing = Read-Json $path
    $existingRows = if ($existing -and $existing.PSObject.Properties['gaps']) { @($existing.gaps) } else { @($existing) }
    $now = (Get-Date).ToString('o')
    foreach ($row in $existingRows) {
        if ($null -eq $row) { continue }
        $stage = if ($row.PSObject.Properties['stage']) { [string]$row.stage } else { '' }
        $key = "$stage|$([string]$row.resource_id)"
        if ([string]$row.domain -eq 'chat' -and $stage -and -not $row.resolved_at -and $script:SucceededStages.Contains($key)) {
            $row | Add-Member -NotePropertyName status -NotePropertyValue 'resolved' -Force
            $row | Add-Member -NotePropertyName resolved_at -NotePropertyValue $now -Force
            $row | Add-Member -NotePropertyName last_attempt_at -NotePropertyValue $now -Force
        }
        $rows.Add($row)
    }
    foreach ($gap in $script:CurrentGaps) {
        $match = @($rows | Where-Object {
            [string]$_.domain -eq 'chat' -and [string]$_.stage -eq [string]$gap.stage -and
            [string]$_.resource_id -eq [string]$gap.resource_id -and -not $_.resolved_at
        } | Select-Object -First 1)
        if ($match.Count) {
            $match[0] | Add-Member -NotePropertyName reason -NotePropertyValue ([string]$gap.reason) -Force
            $match[0] | Add-Member -NotePropertyName status -NotePropertyValue ([string]$gap.status) -Force
            $match[0] | Add-Member -NotePropertyName retryable -NotePropertyValue ([bool]$gap.retryable) -Force
            $match[0] | Add-Member -NotePropertyName last_attempt_at -NotePropertyValue ([string]$gap.last_attempt_at) -Force
        }
        else { $rows.Add($gap) }
    }
    Write-Json $path @($rows) 40
}

function Load-Policies {
    $byId = @{}
    $accountPolicyPath = if ($script:AccountKey) { Join-Path $script:Root "_meta\policies\accounts\$($script:AccountKey)\chat_exclusions.json" } else { $null }
    $archivePolicyInput = if ($accountPolicyPath -and (Test-Path -LiteralPath $accountPolicyPath -PathType Leaf)) { $accountPolicyPath } else { Join-Path $script:Root '_meta\exclusions.json' }
    foreach ($path in @($PoliciesPath, $archivePolicyInput)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $config = Read-Json $path
        if ($config.account_scope -and $config.account_scope.open_id -and [string]$config.account_scope.open_id -ne $script:AccountKey) {
            throw "Account policy does not match the authenticated user: $path"
        }
        foreach ($policy in @($config.chat_exclusions)) {
            if ($policy.chat_id) { $byId[[string]$policy.chat_id] = $policy }
        }
    }
    return $byId
}

function Expand-Threads([object]$Envelope, [string]$ChatTitle) {
    if ($ThreadMode -eq 'None') { return }
    foreach ($message in @($Envelope.data.messages)) {
        $threadId = [string]$message.thread_id
        if (-not $threadId) { continue }
        $thread = Invoke-Lark @('im', '+threads-messages-list', '--as', 'user', '--thread', $threadId, '--order', 'asc', '--page-all', '--page-limit', [string]$PageLimit, '--page-size', '50', '--format', 'json')
        if ($thread.ExitCode -eq 0 -and $thread.Json -and $thread.Json.ok) {
            $message | Add-Member -NotePropertyName thread_replies -NotePropertyValue @($thread.Json.data.messages) -Force
            $message | Add-Member -NotePropertyName thread_pagination_complete -NotePropertyValue (Get-PaginationComplete $thread.Json) -Force
            $message.PSObject.Properties.Remove('thread_has_more')
            $message.PSObject.Properties.Remove('thread_replies_error')
            Add-SucceededStage 'thread_messages' $threadId
        }
        else {
            $message | Add-Member -NotePropertyName thread_replies_error -NotePropertyValue $true -Force
            Record-Error 'thread_messages' $threadId $ChatTitle $thread 'Failed to refresh full thread replies.'
        }
    }
}

New-Directory $script:Root
foreach ($relative in @('_meta', '_meta\state', '_meta\runs', '_meta\reports', '_meta\policies', 'chats\raw', 'chats\members', 'chats\attachments', 'chats\by_type\p2p', 'chats\by_type\group')) {
    New-Directory (Join-Path $script:Root $relative)
}
$archiveExclusionsPath = Join-Path $script:Root '_meta\exclusions.json'
if (-not (Test-Path -LiteralPath $archiveExclusionsPath -PathType Leaf)) {
    Write-Json $archiveExclusionsPath ([ordered]@{
        schema = 'feishu-local-backup-exclusions-v3'; updated_at = (Get-Date).ToString('o'); chat_exclusions = @()
        note = 'Archive-local stable-ID policies. Add decisions here; do not place private decisions in the reusable Skill.'
    })
}
$profilePath = Join-Path $script:Root '_meta\policies\personal_knowledge_profile.json'
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    $templatePath = Join-Path $PSScriptRoot '..\references\personal-knowledge-profile.template.json'
    $profile = Read-Json $templatePath
    $profile.owner_label = 'unknown'
    $profile.updated_at = (Get-Date).ToString('o')
    Write-Json $profilePath $profile
}
$readmePath = Join-Path $script:Root 'README_FOR_AI.md'
if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
    Write-Utf8 $readmePath @'
# Feishu personal data foundation

- Read `_meta/manifest.json`, `_meta/completeness.json`, and `_meta/gaps.json` before claiming coverage.
- Chat content is authoritative JSON under `chats/raw/`; do not treat generated Markdown as authoritative.
- Use `chats/chat_index.csv` and `chats/by_type/` to discover active conversations.
- Message resource keys remain in JSON. Binary attachments are a separate policy-aware layer under `chats/attachments/<chat_id>/`.
- Honor `_meta/exclusions.json`, `_meta/deleted_attachments.json`, and `_meta/policies/` before refresh or download.
- Verify current files with `_meta/checksums.sha256`.
'@
}

$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$runRoot = Join-Path $script:Root "_meta\runs\$runId"
New-Directory $runRoot
New-Directory (Join-Path $runRoot 'incoming')
$script:ErrorsPath = Join-Path $runRoot 'errors.ndjson'
$runPath = Join-Path $runRoot 'run.json'
$reportPath = Join-Path $script:Root '_meta\reports\chat-overview.html'
$startedAt = (Get-Date).ToString('o')
$reportToken = [guid]::NewGuid().ToString('N')

$preflightReport = $null
if ((Test-Path -LiteralPath (Join-Path $script:Root 'chats\by_type\group\index.json')) -and (Test-Path -LiteralPath (Join-Path $script:Root 'chats\by_type\p2p\index.json'))) {
    $reportArgs = @{ ArchiveRoot = $script:Root; OutputPath = $reportPath; ApiToken = $reportToken }
    if ($NoOpen) { $reportArgs.NoOpen = $true }
    $preflightReport = & (Join-Path $PSScriptRoot 'generate_chat_report.ps1') @reportArgs | ConvertFrom-Json
}
$versionResult = Invoke-Lark @('--version')
$toolVersion = if ($versionResult.ExitCode -eq 0) { ([string]$versionResult.Stdout).Trim() } else { 'unknown' }

Write-Json $runPath ([ordered]@{
    schema = 'feishu-message-sync-run-v1'; run_id = $runId; operation = 'sync_feishu_messages'; mode = $Mode
    identity = 'user'; started_at = $startedAt; status = 'running'; thread_mode = $ThreadMode
    attachments = 'not_downloaded_by_message_sync'; source_mutations = 0; tool = [ordered]@{ name = 'lark-cli'; version = $toolVersion }
})

if (-not $SkipAuthCheck) {
    $auth = Invoke-Lark @('auth', 'status', '--json', '--verify')
    Assert-LarkSuccess $auth 'lark-cli auth status'
    $verified = [bool]$auth.Json.verified
    if (-not $verified -and $auth.Json.identities -and $auth.Json.identities.user) { $verified = ([string]$auth.Json.identities.user.status -eq 'authenticated') }
    if (-not $verified) { throw 'Verified Feishu user authorization is required.' }
    $authenticatedOpenId = if ($auth.Json.identities -and $auth.Json.identities.user) {
        if ($auth.Json.identities.user.openId) { [string]$auth.Json.identities.user.openId } else { [string]$auth.Json.identities.user.open_id }
    } else { '' }
    if ($AccountKey -and $authenticatedOpenId -and $AccountKey -ne $authenticatedOpenId) { throw 'AccountKey does not match the authenticated Feishu user.' }
    if (-not $AccountKey) { $AccountKey = $authenticatedOpenId }
}
if (-not $AccountKey) { throw 'Unable to resolve the Feishu user open_id; provide -AccountKey only for an already verified/test identity.' }
if ($AccountKey -notmatch '^[A-Za-z0-9_-]+$') { throw "Unsafe account key: $AccountKey" }
$script:AccountKey = $AccountKey

$policies = Load-Policies
$accountPolicyPath = Join-Path $script:Root "_meta\policies\accounts\$AccountKey\chat_exclusions.json"
Write-Json $accountPolicyPath ([ordered]@{
    schema = 'feishu-account-chat-exclusions-v1'; updated_at = (Get-Date).ToString('o')
    account_scope = [ordered]@{ identity = 'user'; open_id = $AccountKey }
    chat_exclusions = @($policies.Values | Sort-Object chat_id)
    note = 'Effective stable-ID exclusions for this authenticated Feishu user. Loaded before every downstream chat request.'
})
$chatList = Invoke-Lark @('im', '+chat-list', '--as', 'user', '--types=p2p,group', '--sort', 'active_time', '--page-all', '--page-limit', [string]$PageLimit, '--page-size', '100', '--format', 'json')
Assert-LarkSuccess $chatList 'chat enumeration'
Write-Utf8 (Join-Path $script:Root 'chats\raw\_chat_list.json') $chatList.Stdout
$allChats = @($chatList.Json.data.chats)
if ($ChatId -and $ChatId.Count -gt 0) {
    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $ChatId) { [void]$selected.Add($id) }
    $allChats = @($allChats | Where-Object { $selected.Contains([string]$_.chat_id) })
}
if ($MaxChats -gt 0) { $allChats = @($allChats | Select-Object -First $MaxChats) }

$existingIndex = @{}
$chatIndexPath = Join-Path $script:Root 'chats\chat_index.csv'
if (Test-Path -LiteralPath $chatIndexPath -PathType Leaf) {
    foreach ($row in @(Import-Csv -LiteralPath $chatIndexPath -Encoding UTF8)) { $existingIndex[[string]$row.resource_id] = $row }
}

$processed = 0; $succeeded = 0; $failed = 0; $excluded = 0; $mergedMessages = 0
foreach ($chat in $allChats) {
    $processed++
    $id = [string]$chat.chat_id
    $title = if ([string]::IsNullOrWhiteSpace([string]$chat.name)) { "unnamed-$id" } else { [string]$chat.name }
    $policy = if ($policies.ContainsKey($id)) { $policies[$id] } else { $null }
    $fullExcluded = $policy -and (([string]$policy.disposition -eq 'quarantine') -or (Has-Scope $policy 'messages'))
    if ($fullExcluded) { $excluded++; continue }

    $rawRelative = $null
    if ($existingIndex.ContainsKey($id) -and $existingIndex[$id].raw_path) { $rawRelative = [string]$existingIndex[$id].raw_path }
    if (-not $rawRelative) { $rawRelative = "chats/raw/$(Safe-Name $title)--$id.json" }
    $rawPath = Join-Path $script:Root ($rawRelative -replace '/', '\')
    $existingEnvelope = $null
    if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
        try { $existingEnvelope = Read-Json $rawPath } catch { Record-Error 'existing_json_validation' $id $title $null $_.Exception.Message }
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @('im', '+chat-messages-list', '--as', 'user', '--chat-id', $id, '--order', 'asc', '--page-all', '--page-limit', [string]$PageLimit, '--page-size', '50', '--format', 'json')) { $arguments.Add($item) }
    if ($Mode -eq 'Incremental' -and $existingEnvelope) {
        $last = Get-LastMessageTime $existingEnvelope
        if ($last) {
            $start = $last.AddMinutes(-$OverlapMinutes).ToString('o')
            $arguments.Add('--start'); $arguments.Add($start)
            $arguments.Add('--end'); $arguments.Add((Get-Date).ToString('o'))
        }
    }
    $result = Invoke-Lark $arguments.ToArray()
    if ($result.ExitCode -ne 0 -or -not $result.Json -or $result.Json.ok -ne $true) {
        $failed++
        Record-Error 'chat_messages' $id $title $result 'Failed to fetch messages; prior-good JSON was preserved.'
        continue
    }
    if ($ThreadMode -eq 'Discovered') { Expand-Threads $result.Json $title }
    $result.Json | Add-Member -NotePropertyName archive_meta -NotePropertyValue ([ordered]@{
        fetched_at = (Get-Date).ToString('o'); run_id = $runId; mode = $Mode; identity = 'user'
        pagination_complete = (Get-PaginationComplete $result.Json)
        archive_coverage_complete = (Get-PaginationComplete $result.Json)
        resources_downloaded = $false
    }) -Force
    $incomingPath = Join-Path $runRoot "incoming\$id.json"
    Write-Json $incomingPath $result.Json 80
    Get-Content -LiteralPath $incomingPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null

    if ($existingEnvelope) {
        $null = & (Join-Path $PSScriptRoot 'merge_chat_envelope.ps1') -ExistingPath $rawPath -IncomingPath $incomingPath -OutputPath $rawPath -IncomingIsFullSnapshot:($Mode -eq 'Full') | ConvertFrom-Json
    }
    else {
        Copy-Item -LiteralPath $incomingPath -Destination $rawPath -Force
    }
    $finalEnvelope = Read-Json $rawPath
    if ($ThreadMode -eq 'All') {
        Expand-Threads $finalEnvelope $title
        Write-Json $rawPath $finalEnvelope 100
        $finalEnvelope = Read-Json $rawPath
    }
    $mergedMessages += @($finalEnvelope.data.messages).Count
    $succeeded++
    Add-SucceededStage 'chat_messages' $id

    if (-not $SkipMembers -and [string]$chat.chat_mode -ne 'p2p') {
        $memberResult = Invoke-Lark @('im', '+chat-members-list', '--as', 'user', '--chat-id', $id, '--page-all', '--page-limit', [string]$PageLimit, '--page-size', '100', '--format', 'json')
        if ($memberResult.ExitCode -eq 0 -and $memberResult.Json -and $memberResult.Json.ok) {
            Write-Utf8 (Join-Path $script:Root "chats\members\$(Safe-Name $title)--$id.json") $memberResult.Stdout
            Add-SucceededStage 'chat_members' $id
        }
        else { Record-Error 'chat_members' $id $title $memberResult 'Failed to refresh members; message JSON remains valid.' }
    }
    Write-Json (Join-Path $script:Root '_meta\state\progress.json') ([ordered]@{
        stage = 'messages'; updated_at = (Get-Date).ToString('o'); total = $allChats.Count; processed = $processed
        succeeded = $succeeded; failed = $failed; excluded = $excluded; current_chat_id = $id; current_chat_name = $title
    })
}

$records = [System.Collections.Generic.List[object]]::new()
foreach ($chat in @($chatList.Json.data.chats)) {
    $id = [string]$chat.chat_id
    $policy = if ($policies.ContainsKey($id)) { $policies[$id] } else { $null }
    if ($policy -and (([string]$policy.disposition -eq 'quarantine') -or (Has-Scope $policy 'messages'))) { continue }
    $title = if ([string]::IsNullOrWhiteSpace([string]$chat.name)) { "unnamed-$id" } else { [string]$chat.name }
    $rawRelative = if ($existingIndex.ContainsKey($id) -and $existingIndex[$id].raw_path) { [string]$existingIndex[$id].raw_path } else { "chats/raw/$(Safe-Name $title)--$id.json" }
    $rawPath = Join-Path $script:Root ($rawRelative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $rawPath -PathType Leaf)) { continue }
    try { $envelope = Read-Json $rawPath } catch { Record-Error 'chat_json_validation' $id $title $null $_.Exception.Message; continue }
    $messages = @($envelope.data.messages)
    $times = @($messages | ForEach-Object { Convert-MessageTime $_.create_time } | Where-Object { $_ } | Sort-Object)
    $attachmentRoot = Join-Path $script:Root "chats\attachments\$id"
    $attachments = if (Test-Path -LiteralPath $attachmentRoot -PathType Container) { @(Get-ChildItem -LiteralPath $attachmentRoot -File -Recurse) } else { @() }
    $memberFile = Get-ChildItem -LiteralPath (Join-Path $script:Root 'chats\members') -File -Filter "*--$id.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    $records.Add([pscustomobject]@{
        resource_type = 'chat'; resource_id = $id; title = $title
        chat_mode = if ([string]$chat.chat_mode -eq 'p2p') { 'p2p' } else { 'group' }
        status = [string]$chat.chat_status; external = [bool]$chat.external; message_count = $messages.Count
        first_message_time = if ($times.Count) { $times[0].ToString('o') } else { $null }
        last_message_time = if ($times.Count) { $times[$times.Count - 1].ToString('o') } else { $null }
        pagination_complete = if ($envelope.archive_meta -and $null -ne $envelope.archive_meta.archive_coverage_complete) { [bool]$envelope.archive_meta.archive_coverage_complete } elseif ($envelope.archive_meta -and $null -ne $envelope.archive_meta.pagination_complete) { [bool]$envelope.archive_meta.pagination_complete } else { Get-PaginationComplete $envelope }
        complete = if ($envelope.archive_meta -and $null -ne $envelope.archive_meta.archive_coverage_complete) { [bool]$envelope.archive_meta.archive_coverage_complete } elseif ($envelope.archive_meta -and $null -ne $envelope.archive_meta.pagination_complete) { [bool]$envelope.archive_meta.pagination_complete } else { Get-PaginationComplete $envelope }
        raw_path = $rawRelative; members_path = if ($memberFile) { Relative-Path $memberFile.FullName } else { $null }
        attachment_root = "chats/attachments/$id"; attachment_files = $attachments.Count
        attachment_bytes = [long](($attachments | Measure-Object Length -Sum).Sum); raw_json_bytes = (Get-Item -LiteralPath $rawPath).Length
    })
}

Update-GapLedger
Write-Ndjson (Join-Path $script:Root '_meta\state\chat_inventory.ndjson') $records
$records | Select-Object resource_type,resource_id,title,chat_mode,status,message_count,complete,raw_path,attachment_root | Export-Csv -LiteralPath $chatIndexPath -NoTypeInformation -Encoding UTF8

$summaries = @()
foreach ($type in @('p2p', 'group')) {
    $rows = @($records | Where-Object chat_mode -eq $type | Sort-Object title, resource_id)
    $excludedForType = @($chatList.Json.data.chats | Where-Object {
        $isType = if ($type -eq 'p2p') { [string]$_.chat_mode -eq 'p2p' } else { [string]$_.chat_mode -ne 'p2p' }
        $candidatePolicy = if ($policies.ContainsKey([string]$_.chat_id)) { $policies[[string]$_.chat_id] } else { $null }
        $isType -and $candidatePolicy -and ((Has-Scope $candidatePolicy 'messages') -or [string]$candidatePolicy.disposition -eq 'quarantine')
    })
    Write-Json (Join-Path $script:Root "chats\by_type\$type\index.json") @($rows)
    $rows | Export-Csv -LiteralPath (Join-Path $script:Root "chats\by_type\$type\index.csv") -NoTypeInformation -Encoding UTF8
    $summary = [ordered]@{
        chat_mode = $type; meaning = if ($type -eq 'p2p') { 'one-to-one direct conversation' } else { 'multi-member group conversation' }
        visible_chats = @($chatList.Json.data.chats | Where-Object { if ($type -eq 'p2p') { $_.chat_mode -eq 'p2p' } else { $_.chat_mode -ne 'p2p' } }).Count
        excluded_chats = $excludedForType.Count
        chats = $rows.Count; complete_chats = @($rows | Where-Object complete).Count; incomplete_chats = @($rows | Where-Object { -not $_.complete }).Count
        messages = [long](($rows | Measure-Object message_count -Sum).Sum); attachment_files = [long](($rows | Measure-Object attachment_files -Sum).Sum)
        attachment_bytes = [long](($rows | Measure-Object attachment_bytes -Sum).Sum); raw_json_bytes = [long](($rows | Measure-Object raw_json_bytes -Sum).Sum)
        index_json = "chats/by_type/$type/index.json"; index_csv = "chats/by_type/$type/index.csv"
    }
    Write-Json (Join-Path $script:Root "chats\by_type\$type\summary.json") $summary
    $summaries += [pscustomobject]$summary
}
Write-Json (Join-Path $script:Root 'chats\by_type\manifest.json') ([ordered]@{
    generated_at = (Get-Date).ToString('o'); source_identity = 'user'; source = 'chats/raw/_chat_list.json'
    classification_field = 'chat_mode'; storage_note = 'Indexes do not duplicate raw JSON or attachments.'; summary = $summaries
    exclusions = '_meta/exclusions.json'; quarantine_root = 'chats/quarantine'
})

$existingUnified = @()
$inventoryPath = Join-Path $script:Root '_meta\inventory.ndjson'
if (Test-Path -LiteralPath $inventoryPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $inventoryPath -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $row = $line | ConvertFrom-Json; if ([string]$row.resource_type -ne 'chat') { $existingUnified += $row } } catch { }
    }
}
Write-Ndjson $inventoryPath @($existingUnified + $records)

$attachmentFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'chats\attachments') -File -Recurse -ErrorAction SilentlyContinue)
$chatComplete = @($records | Where-Object complete).Count
$completenessPath = Join-Path $script:Root '_meta\completeness.json'
$completeness = Read-Json $completenessPath
if (-not $completeness) { $completeness = [pscustomobject]@{} }
$completeness | Add-Member -NotePropertyName chats -NotePropertyValue ([ordered]@{
    enumerated = $records.Count; complete = $chatComplete; incomplete = $records.Count - $chatComplete
    messages_exported = [long](($records | Measure-Object message_count -Sum).Sum); excluded = $excluded
    format = 'authoritative_json'; markdown_generated = $false
}) -Force
$completeness | Add-Member -NotePropertyName attachments -NotePropertyValue ([ordered]@{
    files = $attachmentFiles.Count; bytes = [long](($attachmentFiles | Measure-Object Length -Sum).Sum)
    sync_default = 'metadata_only'; note = 'Message resource keys remain in JSON; binaries require a separate policy-aware download.'
}) -Force
$completeness | Add-Member -NotePropertyName chat_types -NotePropertyValue ([ordered]@{ p2p = $summaries[0]; group = $summaries[1] }) -Force
$completeness | Add-Member -NotePropertyName chat_sync_updated_at -NotePropertyValue (Get-Date).ToString('o') -Force
Write-Json $completenessPath $completeness

$manifestPath = Join-Path $script:Root '_meta\manifest.json'
$manifest = Read-Json $manifestPath
if (-not $manifest) { $manifest = [pscustomobject]@{} }
$manifest | Add-Member -NotePropertyName archive_format -NotePropertyValue 'feishu-personal-data-foundation-v1' -Force
$manifest | Add-Member -NotePropertyName identity -NotePropertyValue ([ordered]@{ type = 'user'; open_id = $AccountKey }) -Force
$manifest | Add-Member -NotePropertyName chat_content_authority -NotePropertyValue 'chats/raw/*.json' -Force
$manifest | Add-Member -NotePropertyName last_message_sync_at -NotePropertyValue (Get-Date).ToString('o') -Force
$pendingStatus = if ($SkipFinalize) { 'complete_unverified' } else { 'finalizing' }
$manifest | Add-Member -NotePropertyName export_status -NotePropertyValue $pendingStatus -Force
Write-Json $manifestPath $manifest

$finalReportArgs = @{ ArchiveRoot = $script:Root; OutputPath = $reportPath; ApiToken = $reportToken }
if ($preflightReport -and $preflightReport.server_url) {
    $finalReportArgs.ServerUrl = [string]$preflightReport.server_url
    $finalReportArgs.NoOpen = $true
}
elseif ($NoOpen) { $finalReportArgs.NoOpen = $true }
$finalReport = & (Join-Path $PSScriptRoot 'generate_chat_report.ps1') @finalReportArgs | ConvertFrom-Json

$totalExcluded = [long](($summaries | Measure-Object excluded_chats -Sum).Sum)
$summary = [ordered]@{
    schema = 'feishu-message-sync-summary-v1'; run_id = $runId; mode = $Mode; status = $pendingStatus
    completed_at = if ($SkipFinalize) { (Get-Date).ToString('o') } else { $null }
    chats_visible = @($chatList.Json.data.chats).Count; chats_active = $records.Count
    chats_processed = $processed; chats_succeeded = $succeeded; chats_failed = $failed
    chats_excluded = $excluded; chats_excluded_total = $totalExcluded
    messages_active = [long](($records | Measure-Object message_count -Sum).Sum); thread_mode = $ThreadMode
    message_format = 'json'; chat_markdown_generated = $false; resources_downloaded = 0
    report_path = Relative-Path $reportPath; errors_path = if (Test-Path $script:ErrorsPath) { Relative-Path $script:ErrorsPath } else { $null }
}
Write-Json (Join-Path $script:Root '_meta\state\chats_complete.json') $summary
$run = Read-Json $runPath
$run.status = $summary.status
$run | Add-Member -NotePropertyName completed_at -NotePropertyValue $summary.completed_at -Force
$run | Add-Member -NotePropertyName summary -NotePropertyValue $summary -Force
Write-Json $runPath $run

if ($SkipFinalize) {
    $summary | ConvertTo-Json -Depth 30
    exit 0
}

$validation = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action ValidateJson -ArchiveRoot $script:Root | ConvertFrom-Json
if (-not $validation.valid) {
    $summary['status'] = 'failed_validation'
    $summary['completed_at'] = (Get-Date).ToString('o')
    $summary['validation'] = $validation
    $manifest | Add-Member -NotePropertyName export_status -NotePropertyValue 'failed_validation' -Force
    $run.status = 'failed_validation'
    $run.completed_at = $summary['completed_at']
    $run.summary = $summary
    Write-Json (Join-Path $script:Root '_meta\state\chats_complete.json') $summary
    Write-Json $manifestPath $manifest
    Write-Json $runPath $run
    throw 'JSON/NDJSON validation failed; checksums were not regenerated.'
}

$finalStatus = if ($failed) { 'complete_with_gaps' } else { 'complete' }
$completedAt = (Get-Date).ToString('o')
$summary['status'] = $finalStatus
$summary['completed_at'] = $completedAt
$summary['validation'] = $validation
$completeness | Add-Member -NotePropertyName finalized_at -NotePropertyValue $completedAt -Force
$manifest | Add-Member -NotePropertyName export_status -NotePropertyValue $(if ($failed) { 'complete_with_chat_gaps' } else { 'complete' }) -Force
$run.status = $finalStatus
$run.completed_at = $completedAt
$run.summary = $summary
Write-Json $completenessPath $completeness
Write-Json (Join-Path $script:Root '_meta\state\chats_complete.json') $summary
Write-Json $manifestPath $manifest
Write-Json $runPath $run

$rehash = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $script:Root | ConvertFrom-Json
$verify = & (Join-Path $PSScriptRoot 'archive_maintenance.ps1') -Action VerifyHashes -ArchiveRoot $script:Root -FullHash | ConvertFrom-Json
if (-not $verify.valid -or -not $verify.cardinality_ok) {
    $summary['status'] = 'failed_integrity'
    $manifest | Add-Member -NotePropertyName export_status -NotePropertyValue 'failed_integrity' -Force
    $run.status = 'failed_integrity'
    $run.summary = $summary
    Write-Json (Join-Path $script:Root '_meta\state\chats_complete.json') $summary
    Write-Json $manifestPath $manifest
    Write-Json $runPath $run
    throw 'Final checksum verification failed.'
}
$summary['rehash'] = $rehash
$summary['verify'] = $verify
$summary | ConvertTo-Json -Depth 30
