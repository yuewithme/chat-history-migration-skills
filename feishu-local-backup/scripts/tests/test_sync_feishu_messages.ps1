[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $tempBase ("feishu-sync-fixture-{0}" -f [guid]::NewGuid().ToString('N'))
if (-not ([System.IO.Path]::GetFullPath($fixture).StartsWith($tempBase + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'Fixture path escaped the system temp directory.'
}
[System.IO.Directory]::CreateDirectory($fixture) | Out-Null

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }

try {
    $archive = Join-Path $fixture 'archive'
    [System.IO.Directory]::CreateDirectory((Join-Path $archive '_meta')) | Out-Null
    $fakeCli = Join-Path $fixture 'fake-lark-cli.ps1'
    $logPath = Join-Path $fixture 'fake-lark.log'
    $env:FAKE_LARK_LOG = $logPath
    $fakeSource = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$line = $Rest -join ' '
[System.IO.File]::AppendAllText($env:FAKE_LARK_LOG, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
function Emit($Value) { Write-Output ($Value | ConvertTo-Json -Depth 50 -Compress); exit 0 }
if ($Rest[0] -eq '--version') { Write-Output 'lark-cli version fixture'; exit 0 }
if ($Rest[0] -eq 'auth' -and $Rest[1] -eq 'status') {
  Emit ([ordered]@{ok=$true;verified=$true;identity='user';identities=[ordered]@{user=[ordered]@{status='authenticated';userName='Fixture User';openId='ou_fixture'}}})
}
if ($Rest[0] -eq 'im' -and $Rest[1] -eq '+chat-list') {
  Emit ([ordered]@{ok=$true;identity='user';data=[ordered]@{chats=@(
    [ordered]@{chat_id='oc_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';name='Active Chat';chat_mode='group';chat_status='normal';external=$false},
    [ordered]@{chat_id='oc_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';name='Excluded Chat';chat_mode='group';chat_status='normal';external=$false}
  );has_more=$false;page_token=''};meta=[ordered]@{pagination=[ordered]@{complete=$true}}})
}
if ($Rest[0] -eq 'im' -and $Rest[1] -eq '+chat-members-list') {
  Emit ([ordered]@{ok=$true;identity='user';data=[ordered]@{chat_id='oc_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';users=@([ordered]@{member_id='ou_fixture';name='Fixture User'});bots=@();has_more=$false};meta=[ordered]@{pagination=[ordered]@{complete=$true}}})
}
if ($Rest[0] -eq 'im' -and $Rest[1] -eq '+threads-messages-list') {
  $replies = if ($env:FAKE_LARK_SCENARIO -eq 'incremental') {
    @([ordered]@{message_id='om_reply_1';msg_type='text';create_time='2026-08-14T01:10:00+08:00';content='reply one';deleted=$false;updated=$false},
      [ordered]@{message_id='om_reply_2';msg_type='text';create_time='2026-08-14T02:10:00+08:00';content='reply two';deleted=$false;updated=$false})
  } else {
    @([ordered]@{message_id='om_reply_1';msg_type='text';create_time='2026-08-14T01:10:00+08:00';content='reply one';deleted=$false;updated=$false})
  }
  Emit ([ordered]@{ok=$true;identity='user';data=[ordered]@{messages=$replies;has_more=$false;page_token=''};meta=[ordered]@{pagination=[ordered]@{complete=$true}}})
}
if ($Rest[0] -eq 'im' -and $Rest[1] -eq '+chat-messages-list') {
  $chatIndex = [Array]::IndexOf($Rest, '--chat-id')
  $chatId = if ($chatIndex -ge 0) { $Rest[$chatIndex + 1] } else { '' }
  if ($chatId -eq 'oc_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb') {
    [Console]::Error.WriteLine('{"ok":false,"error":{"type":"test","message":"excluded chat must not be fetched"}}'); exit 9
  }
  if ($env:FAKE_LARK_SCENARIO -eq 'failure') {
    [Console]::Error.WriteLine('{"ok":false,"identity":"user","error":{"type":"network","message":"synthetic failure"}}'); exit 2
  }
  $messages = if ($env:FAKE_LARK_SCENARIO -eq 'incremental') {
    @([ordered]@{message_id='om_2';msg_type='text';create_time='2026-08-14T01:00:00+08:00';content='host edited';deleted=$false;updated=$true;update_time='2026-08-14T02:00:00+08:00';thread_id='omt_1'},
      [ordered]@{message_id='om_3';msg_type='text';create_time='2026-08-14T02:00:00+08:00';content='third';deleted=$false;updated=$false})
  } else {
    @([ordered]@{message_id='om_1';msg_type='text';create_time='2026-08-14T00:00:00+08:00';content='first';deleted=$false;updated=$false},
      [ordered]@{message_id='om_2';msg_type='text';create_time='2026-08-14T01:00:00+08:00';content='host';deleted=$false;updated=$false;thread_id='omt_1'})
  }
  Emit ([ordered]@{ok=$true;identity='user';data=[ordered]@{messages=$messages;total=$messages.Count;has_more=$false;page_token=''};meta=[ordered]@{pagination=[ordered]@{complete=$true}}})
}
[Console]::Error.WriteLine('{"ok":false,"error":{"type":"test","message":"unexpected fake command"}}'); exit 7
'@
    Write-Utf8 $fakeCli $fakeSource
    $policies = [ordered]@{schema='fixture-exclusions-v1';chat_exclusions=@([ordered]@{
        chat_id='oc_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';title='Excluded Chat';disposition='purge';scope=@('messages','members','attachments','future_downloads');reason='fixture'
    })}
    $policiesPath = Join-Path $fixture 'policies.json'
    Write-Utf8 $policiesPath ($policies | ConvertTo-Json -Depth 10)
    $sync = Join-Path $scriptRoot 'sync_feishu_messages.ps1'

    $env:FAKE_LARK_SCENARIO = 'full'
    $full = & $sync -ArchiveRoot $archive -Mode Full -ThreadMode All -LarkCliPath $fakeCli -PoliciesPath $policiesPath -NoOpen | ConvertFrom-Json
    Assert-True ($full.status -eq 'complete') 'full synchronization should complete'
    Assert-True ($full.chats_visible -eq 2 -and $full.chats_active -eq 1) "excluded chat must stay out of active indexes (schema=$($full.schema), visible=$($full.chats_visible), active=$($full.chats_active), processed=$($full.chats_processed), excluded=$($full.chats_excluded), succeeded=$($full.chats_succeeded), failed=$($full.chats_failed))"
    $activePath = Get-ChildItem -LiteralPath (Join-Path $archive 'chats\raw') -File -Filter '*--oc_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json' | Select-Object -First 1
    Assert-True ($null -ne $activePath) 'active raw JSON should exist'
    Assert-True (-not (Get-ChildItem -LiteralPath (Join-Path $archive 'chats\raw') -File -Filter '*--oc_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json')) 'excluded raw JSON must not exist'
    $envelope = Get-Content -LiteralPath $activePath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($envelope.data.messages).Count -eq 2) 'full sync should store two messages'
    Assert-True ($envelope.archive_meta.archive_coverage_complete -eq $true) 'full sync should mark complete archive coverage'
    Assert-True (@(($envelope.data.messages | Where-Object message_id -eq 'om_2').thread_replies).Count -eq 1) 'full thread should be attached'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $archive 'chats\readable'))) 'chat Markdown must not be generated'
    $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    Assert-True ($log -notmatch 'oc_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.*chat-messages-list') 'excluded chat must not receive a message request'
    Assert-True ($log -notmatch '--download-resources') 'message sync must not bulk-download attachments'
    $accountPolicyPath = Join-Path $archive '_meta\policies\accounts\ou_fixture\chat_exclusions.json'
    Assert-True (Test-Path -LiteralPath $accountPolicyPath -PathType Leaf) 'effective exclusions must be persisted under the authenticated user'
    $accountPolicy = Get-Content -LiteralPath $accountPolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($accountPolicy.chat_exclusions).Count -eq 1) 'the user-scoped exclusion must contain the confirmed chat'
    $setter = Join-Path $scriptRoot 'set_account_chat_exclusion.ps1'
    $setResult = & $setter -ArchiveRoot $archive -AccountKey 'ou_fixture' -ChatId 'oc_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -Title 'Excluded Chat' -Disposition purge -Scope @('messages','members','attachments','future_downloads') -Reason 'updated fixture decision' | ConvertFrom-Json
    Assert-True ($setResult.ok -and $setResult.policies -eq 1) 'account exclusion setter must update the scoped policy'
    $policyPreview = & (Join-Path $scriptRoot 'apply_chat_exclusions.ps1') -ArchiveRoot $archive | ConvertFrom-Json
    Assert-True ($policyPreview.excluded_groups -eq 1) 'default exclusion apply path must resolve the authenticated user policy rather than the empty Skill template'

    $env:FAKE_LARK_SCENARIO = 'incremental'
    $incremental = & $sync -ArchiveRoot $archive -Mode Incremental -ThreadMode Discovered -LarkCliPath $fakeCli -NoOpen | ConvertFrom-Json
    Assert-True ($incremental.status -eq 'complete') 'incremental synchronization should complete'
    $envelope = Get-Content -LiteralPath $activePath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($envelope.data.messages).Count -eq 3) 'incremental merge should deduplicate and add one message'
    Assert-True ($envelope.archive_meta.archive_coverage_complete -eq $true) 'incremental merge should preserve prior complete archive coverage'
    Assert-True (($envelope.data.messages | Where-Object message_id -eq 'om_2').content -eq 'host edited') 'incoming duplicate must replace the prior version'
    Assert-True (@(($envelope.data.messages | Where-Object message_id -eq 'om_2').thread_replies).Count -eq 2) 'incremental thread refresh should replace replies'
    $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    Assert-True ($log -match '--start') 'incremental synchronization must use an overlap start time'

    $beforeFailure = (Get-FileHash -LiteralPath $activePath.FullName -Algorithm SHA256).Hash
    $env:FAKE_LARK_SCENARIO = 'failure'
    $failure = & $sync -ArchiveRoot $archive -Mode Incremental -ThreadMode Discovered -LarkCliPath $fakeCli -NoOpen | ConvertFrom-Json
    Assert-True ($failure.status -eq 'complete_with_gaps' -and $failure.chats_failed -eq 1) 'failed pull must be recorded as a gap'
    $afterFailure = (Get-FileHash -LiteralPath $activePath.FullName -Algorithm SHA256).Hash
    Assert-True ($beforeFailure -eq $afterFailure) 'failed pull must preserve prior-good raw JSON'
    $gaps = @(Get-Content -LiteralPath (Join-Path $archive '_meta\gaps.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    $activeGap = @($gaps | Where-Object { $_.stage -eq 'chat_messages' -and $_.resource_id -eq 'oc_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -and -not $_.resolved_at })
    Assert-True ($activeGap.Count -eq 1) 'failed pull must add one unresolved durable chat gap'

    $env:FAKE_LARK_SCENARIO = 'incremental'
    $recovery = & $sync -ArchiveRoot $archive -Mode Incremental -ThreadMode Discovered -LarkCliPath $fakeCli -NoOpen | ConvertFrom-Json
    Assert-True ($recovery.status -eq 'complete') 'a later successful pull should recover cleanly'
    $gaps = @(Get-Content -LiteralPath (Join-Path $archive '_meta\gaps.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
    $resolvedGap = @($gaps | Where-Object { $_.stage -eq 'chat_messages' -and $_.resource_id -eq 'oc_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -and $_.resolved_at })
    Assert-True ($resolvedGap.Count -eq 1 -and $resolvedGap[0].status -eq 'resolved') 'a later successful pull must resolve the durable chat gap'

    $merge = Join-Path $scriptRoot 'merge_chat_envelope.ps1'
    $partialPath = Join-Path $fixture 'partial.json'
    $windowPath = Join-Path $fixture 'window.json'
    $partialOutput = Join-Path $fixture 'partial-merged.json'
    $fullOutput = Join-Path $fixture 'full-merged.json'
    Write-Utf8 $partialPath (([ordered]@{ok=$true;data=[ordered]@{messages=@([ordered]@{message_id='om_partial';create_time='1'});has_more=$true;page_token='next'};meta=[ordered]@{pagination=[ordered]@{complete=$false}};archive_meta=[ordered]@{archive_coverage_complete=$false}}) | ConvertTo-Json -Depth 20)
    Write-Utf8 $windowPath (([ordered]@{ok=$true;data=[ordered]@{messages=@([ordered]@{message_id='om_window';create_time='2'});has_more=$false;page_token=''};meta=[ordered]@{pagination=[ordered]@{complete=$true}};archive_meta=[ordered]@{pagination_complete=$true}}) | ConvertTo-Json -Depth 20)
    $null = & $merge -ExistingPath $partialPath -IncomingPath $windowPath -OutputPath $partialOutput | ConvertFrom-Json
    $partialMerged = Get-Content -LiteralPath $partialOutput -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($partialMerged.archive_meta.archive_coverage_complete -eq $false) 'a complete incremental window must not upgrade an incomplete archive'
    $null = & $merge -ExistingPath $partialPath -IncomingPath $windowPath -OutputPath $fullOutput -IncomingIsFullSnapshot | ConvertFrom-Json
    $fullMerged = Get-Content -LiteralPath $fullOutput -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($fullMerged.archive_meta.archive_coverage_complete -eq $true) 'a complete full snapshot may upgrade archive coverage'

    $invalidJsonPath = Join-Path $archive '_meta\synthetic-invalid.json'
    Write-Utf8 $invalidJsonPath '{'
    $validationFailureObserved = $false
    try { $null = & $sync -ArchiveRoot $archive -Mode Incremental -ThreadMode Discovered -LarkCliPath $fakeCli -NoOpen }
    catch { $validationFailureObserved = $true }
    Assert-True $validationFailureObserved 'invalid archive JSON must fail finalization'
    $latestRunPath = Get-ChildItem -LiteralPath (Join-Path $archive '_meta\runs') -Directory | Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'run.json' }
    $latestRun = Get-Content -LiteralPath $latestRunPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $failedManifest = Get-Content -LiteralPath (Join-Path $archive '_meta\manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($latestRun.status -eq 'failed_validation' -and $failedManifest.export_status -eq 'failed_validation') 'validation failure must not leave a false complete status'
    Remove-Item -LiteralPath $invalidJsonPath -Force
    $null = & (Join-Path $scriptRoot 'archive_maintenance.ps1') -Action Rehash -ArchiveRoot $archive | ConvertFrom-Json

    $report = Get-Content -LiteralPath (Join-Path $archive '_meta\reports\chat-overview.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $keys = @(@($report.tables).key | Sort-Object)
    Assert-True (($keys -join ',') -eq 'group_attachment_top10,group_message_top10,p2p_attachment_top10,p2p_message_top10') 'report must contain exactly four required tables'
    $verify = & (Join-Path $scriptRoot 'archive_maintenance.ps1') -Action VerifyHashes -ArchiveRoot $archive -FullHash | ConvertFrom-Json
    Assert-True ($verify.valid -and $verify.cardinality_ok) 'final checksum verification must pass'

    [ordered]@{ok=$true;full_messages=2;incremental_messages=3;excluded_chat_requests=0;failure_preserved_prior_good=$true;gap_recovered=$true;coverage_guarded=$true;false_complete_prevented=$true;checksum_valid=$true;fixture=$fixture} | ConvertTo-Json -Depth 10
}
finally {
    Remove-Item Env:FAKE_LARK_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_LARK_LOG -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture -PathType Container) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

exit 0
