[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('feishu-knowledge-test-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $fixture 'archive'
$fakeCli = Join-Path $fixture 'fake-lark-cli.ps1'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Read-Ndjson([string]$Path) {
    $rows = @()
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) { if ($line.Trim()) { $rows += ($line | ConvertFrom-Json) } }
    return @($rows)
}

$fake = @'
$ErrorActionPreference = 'Stop'
$arguments = @($args)
function Value([string]$Name) { $i=[Array]::IndexOf($arguments,$Name); if($i -ge 0 -and $i+1 -lt $arguments.Count){ return $arguments[$i+1] }; return '' }
function Emit([object]$Value) { $Value | ConvertTo-Json -Depth 50 -Compress; exit 0 }
if($arguments[0] -eq 'auth'){
  Emit ([ordered]@{ok=$true;verified=$true;identities=[ordered]@{user=[ordered]@{verified=$true;openId='ou_test'}}})
}
if($arguments[0] -eq 'drive' -and $arguments[1] -eq 'files'){
  $p=Value '--params'
  if($p -notmatch 'fld1'){
    Emit ([ordered]@{ok=$true;data=[ordered]@{files=@(
      [ordered]@{token='fld1';name='Folder';type='folder';url='https://example/fld1'},
      [ordered]@{token='doc1';name='Drive Doc';type='docx';url='https://example/doc1'},
      [ordered]@{token='bin2';name='small-file.pdf';type='file';size=1024;url='https://example/bin2'},
      [ordered]@{token='bin1';name='large-video.mp4';type='file';size=209715200;url='https://example/bin1'}
    );has_more=$false;next_page_token=''}})
  }
  Emit ([ordered]@{ok=$true;data=[ordered]@{files=@([ordered]@{token='sheet1';name='Sheet';type='sheet';url='https://example/sheet1'});has_more=$false;next_page_token=''}})
}
if($arguments[0] -eq 'wiki' -and $arguments[1] -eq '+space-list'){
  Emit ([ordered]@{ok=$true;data=[ordered]@{spaces=@([ordered]@{space_id='1001';name='Team Wiki';space_type='team'});has_more=$false}})
}
if($arguments[0] -eq 'wiki' -and $arguments[1] -eq '+node-list'){
  $space=Value '--space-id'; $parent=Value '--parent-node-token'
  if($space -eq 'my_library'){
    Emit ([ordered]@{ok=$true;data=[ordered]@{nodes=@([ordered]@{node_token='wikemy';obj_token='docmy';obj_type='docx';title='Personal Doc';has_child=$false});has_more=$false;page_token=''}})
  }
  if($parent -eq 'wikfolder'){
    Emit ([ordered]@{ok=$true;data=[ordered]@{nodes=@([ordered]@{node_token='wikslides';obj_token='slides1';obj_type='slides';title='Slides';has_child=$false});has_more=$false;page_token=''}})
  }
  Emit ([ordered]@{ok=$true;data=[ordered]@{nodes=@(
    [ordered]@{node_token='wikdoc';obj_token='doc2';obj_type='docx';title='Wiki Doc';has_child=$false},
    [ordered]@{node_token='wikbase';obj_token='base1';obj_type='bitable';title='Base';has_child=$false},
    [ordered]@{node_token='wikmind';obj_token='mind1';obj_type='mindnote';title='Mindnote';has_child=$false},
    [ordered]@{node_token='wikfolder';obj_token='fldwiki';obj_type='folder';title='Child';has_child=$true}
  );has_more=$false;page_token=''}})
}
if($arguments[0] -eq 'docs' -and $arguments[1] -eq '+fetch'){
  $doc=Value '--doc'
  Emit ([ordered]@{ok=$true;data=[ordered]@{document=[ordered]@{document_id=$doc;revision_id=2;content=("# " + $doc + "`n`nBody`n");reference_map=[ordered]@{};tips=''}}})
}
if($arguments[0] -eq 'mindnotes'){
  Emit ([ordered]@{ok=$true;data=[ordered]@{nodes=@(
    [ordered]@{node_id='n1';parent_id='';texts=@([ordered]@{text=[ordered]@{content='Root'}})},
    [ordered]@{node_id='n2';parent_id='n1';texts=@([ordered]@{text=[ordered]@{content='Child'}})}
  )}})
}
if($arguments[0] -eq 'drive' -and $arguments[1] -eq '+export'){
  $dir=Value '--output-dir'; if($dir.StartsWith('./')){$dir=$dir.Substring(2)}
  $name=Value '--file-name'; $target=Join-Path (Get-Location) (Join-Path $dir $name)
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null
  [System.IO.File]::WriteAllText($target,'synthetic export')
  Emit ([ordered]@{ok=$true;data=[ordered]@{path=$target;ready=$true}})
}
if($arguments[0] -eq 'drive' -and $arguments[1] -eq '+download'){
  $path=Value '--output'; if($path.StartsWith('./')){$path=$path.Substring(2)}
  $target=Join-Path (Get-Location) $path
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null
  [System.IO.File]::WriteAllText($target,'synthetic binary')
  Emit ([ordered]@{ok=$true;data=[ordered]@{path=$target}})
}
Write-Error ('Unexpected fake CLI call: ' + ($arguments -join ' ')); exit 2
'@

try {
    [System.IO.Directory]::CreateDirectory($archive) | Out-Null
    [System.IO.File]::WriteAllText($fakeCli, $fake, $utf8NoBom)

    $inventoryJson = & (Join-Path $scriptRoot 'sync_feishu_knowledge.ps1') -ArchiveRoot $archive -Mode Full -ContentMode Knowledge -LarkCliPath $fakeCli -SkipFinalize | ConvertFrom-Json
    $gapDetails = if (Test-Path -LiteralPath (Join-Path $archive '_meta\gaps.json')) { Get-Content -LiteralPath (Join-Path $archive '_meta\gaps.json') -Encoding utf8 -Raw } else { '' }
    Assert-True ($inventoryJson.status -eq 'inventory_complete') ("Inventory did not complete: " + ($inventoryJson | ConvertTo-Json -Depth 12 -Compress) + " gaps=" + $gapDetails)
    Assert-True ($inventoryJson.inventory.discovered -eq 11) 'Expected 11 unique Drive/Wiki records.'

    $contentJson = & (Join-Path $scriptRoot 'sync_feishu_knowledge_content.ps1') -ArchiveRoot $archive -ContentMode Knowledge -LarkCliPath $fakeCli -SkipFinalize | ConvertFrom-Json
    Assert-True ($contentJson.status -eq 'complete') 'Content stage did not complete.'
    Assert-True ($contentJson.markdown -eq 4) 'Expected four Markdown knowledge artifacts.'
    Assert-True ($contentJson.structured_exports -eq 3) 'Expected Sheet, Base and Slides exports.'

    $drive = Read-Ndjson (Join-Path $archive 'drive\index.ndjson')
    $wiki = Read-Ndjson (Join-Path $archive 'wiki\index.ndjson')
    Assert-True (@($drive).Count -eq 5) 'Drive recursion did not retain five records.'
    Assert-True (@($wiki).Count -eq 6) 'Wiki recursion or my_library coverage is incomplete.'
    Assert-True (@($wiki | Where-Object resource_id -eq 'wikslides').Count -eq 1) 'Child Wiki node was not traversed.'
    Assert-True (@($wiki | Where-Object resource_id -eq 'wikemy').Count -eq 1) 'my_library was not traversed.'
    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $archive 'drive\documents') -File -Filter '*.md').Count -eq 1) 'Drive document Markdown missing.'
    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $archive 'wiki\documents') -File -Filter '*.md').Count -eq 3) 'Wiki document/Mindnote Markdown missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $archive 'drive\structured\sheet1.xlsx')) 'Sheet export missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $archive 'wiki\structured\base1.base')) 'Base export missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $archive 'wiki\structured\slides1.pptx')) 'Slides export missing.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $archive 'drive\files\bin1--large-video.mp4'))) 'Knowledge mode downloaded a large binary.'

    $policyPath = Join-Path $archive '_meta\policies\excluded_files.ndjson'
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($policyPath)) | Out-Null
    [System.IO.File]::WriteAllText($policyPath, (([ordered]@{resource_id='bin2';action='exclude';prevent_future_download=$true} | ConvertTo-Json -Compress) + [Environment]::NewLine), $utf8NoBom)
    $binaryJson = & (Join-Path $scriptRoot 'sync_feishu_knowledge_content.ps1') -ArchiveRoot $archive -ContentMode KnowledgeAndBinaries -LarkCliPath $fakeCli -MaxBinaryBytes 104857600 -SkipFinalize | ConvertFrom-Json
    Assert-True ($binaryJson.binaries_downloaded -eq 0) 'A tombstoned or oversized binary was downloaded.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $archive 'drive\files\bin2--small-file.pdf'))) 'Tombstone did not prevent the small-file request.'

    $plan = & (Join-Path $scriptRoot 'sync_feishu_all.ps1') -ArchiveRoot $archive -PlanOnly | ConvertFrom-Json
    Assert-True (@($plan.stages).Count -eq 6) 'Unified plan is incomplete.'

    [ordered]@{
        ok = $true; records = @($drive).Count + @($wiki).Count; markdown = $contentJson.markdown
        structured_exports = $contentJson.structured_exports; gaps = $contentJson.gaps
        large_binary_downloaded = $false; tombstoned_binary_downloaded = $false
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $fixture -PathType Container) {
        Get-ChildItem -LiteralPath $fixture -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) { $_.Attributes = $_.Attributes -bxor [IO.FileAttributes]::ReadOnly }
        }
        [System.IO.Directory]::Delete($fixture, $true)
    }
}

exit 0
