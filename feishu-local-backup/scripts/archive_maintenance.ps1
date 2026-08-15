[CmdletBinding()]
param(
    [ValidateSet('Status', 'ValidateJson', 'Rehash', 'VerifyHashes')]
    [string]$Action = 'Status',
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveRoot,
    [switch]$FullHash
)

$ErrorActionPreference = 'Stop'

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Relative-ArchivePath([string]$Path) {
    return ($Path.Substring($ArchiveRoot.Length + 1) -replace '\\', '/')
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
    throw "Archive root does not exist: $ArchiveRoot"
}

$manifestPath = Join-Path $ArchiveRoot '_meta/manifest.json'
$completenessPath = Join-Path $ArchiveRoot '_meta/completeness.json'
$checksumPath = Join-Path $ArchiveRoot '_meta/checksums.sha256'

switch ($Action) {
    'Status' {
        $files = @(Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse)
        $manifest = Read-Json $manifestPath
        $completeness = Read-Json $completenessPath
        $gapPath = Join-Path $ArchiveRoot '_meta/gaps.json'
        $gapJson = Read-Json $gapPath
        $gaps = if ($null -eq $gapJson) { @() } else { @($gapJson) }
        [ordered]@{
            archive_root = $ArchiveRoot
            exists = $true
            format = if ($manifest) { $manifest.archive_format } else { $null }
            status = if ($manifest) { $manifest.export_status } else { 'manifest_missing' }
            completed_at = if ($manifest) { $manifest.export_completed_at } else { $null }
            files = $files.Count
            bytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
            known_gaps = $gaps.Count
            chats = if ($completeness) { $completeness.chats } else { $null }
            drive = if ($completeness) { $completeness.drive } else { $null }
            wiki = if ($completeness) { $completeness.wiki } else { $null }
            calendar = if ($completeness) { $completeness.calendar } else { $null }
            checksum_file = Test-Path -LiteralPath $checksumPath
        } | ConvertTo-Json -Depth 20
    }

    'ValidateJson' {
        $errors = [System.Collections.Generic.List[object]]::new()
        $jsonFiles = @(Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse -Filter '*.json')
        foreach ($file in $jsonFiles) {
            try {
                Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
            }
            catch {
                $errors.Add([pscustomobject]@{
                    path = Relative-ArchivePath $file.FullName
                    error = $_.Exception.Message
                })
            }
        }
        $ndjsonFiles = @(Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse -Filter '*.ndjson')
        foreach ($file in $ndjsonFiles) {
            $lineNumber = 0
            foreach ($line in [System.IO.File]::ReadLines($file.FullName, [System.Text.Encoding]::UTF8)) {
                $lineNumber++
                if (-not $line.Trim()) { continue }
                try { $line | ConvertFrom-Json | Out-Null }
                catch {
                    $errors.Add([pscustomobject]@{
                        path = Relative-ArchivePath $file.FullName
                        line = $lineNumber
                        error = $_.Exception.Message
                    })
                }
            }
        }
        [ordered]@{
            action = 'ValidateJson'
            files_checked = $jsonFiles.Count + $ndjsonFiles.Count
            json_files_checked = $jsonFiles.Count
            ndjson_files_checked = $ndjsonFiles.Count
            errors = $errors.Count
            valid = ($errors.Count -eq 0)
            details = $errors
        } | ConvertTo-Json -Depth 10
        if ($errors.Count -gt 0) { exit 2 }
    }

    'Rehash' {
        $lines = [System.Collections.Generic.List[string]]::new()
        $files = @(Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse | Where-Object { $_.FullName -ne $checksumPath } | Sort-Object FullName)
        foreach ($file in $files) {
            $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
            $lines.Add("$($hash.Hash.ToLowerInvariant())  $(Relative-ArchivePath $file.FullName)")
        }
        Write-Utf8NoBom $checksumPath (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
        [ordered]@{
            action = 'Rehash'
            files_hashed = $lines.Count
            checksum_path = '_meta/checksums.sha256'
            cardinality_ok = ($lines.Count -eq (@(Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse).Count - 1))
        } | ConvertTo-Json
    }

    'VerifyHashes' {
        if (-not (Test-Path -LiteralPath $checksumPath)) { throw "Checksum file is missing: $checksumPath" }
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($line in (Get-Content -LiteralPath $checksumPath -Encoding UTF8)) {
            if (-not $line.Trim()) { continue }
            if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { throw "Invalid checksum line: $line" }
            $entries.Add([pscustomobject]@{ expected = $Matches[1].ToLowerInvariant(); path = $Matches[2] })
        }
        $selected = if ($FullHash -or $entries.Count -le 20) {
            @($entries)
        }
        else {
            @($entries | Select-Object -First 5) + @($entries | Select-Object -Last 5)
        }
        $failures = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $selected) {
            $path = Join-Path $ArchiveRoot ($entry.path -replace '/', '\\')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $failures.Add([pscustomobject]@{ path = $entry.path; reason = 'missing' })
                continue
            }
            $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $entry.expected) {
                $failures.Add([pscustomobject]@{ path = $entry.path; reason = 'hash_mismatch'; expected = $entry.expected; actual = $actual })
            }
        }
        $archiveFileCount = @(Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse).Count
        [ordered]@{
            action = 'VerifyHashes'
            mode = if ($FullHash) { 'full' } else { 'sample' }
            checksum_entries = $entries.Count
            files_checked = $selected.Count
            failures = $failures.Count
            cardinality_ok = ($entries.Count -eq ($archiveFileCount - 1))
            valid = ($failures.Count -eq 0 -and $entries.Count -eq ($archiveFileCount - 1))
            details = $failures
        } | ConvertTo-Json -Depth 10
        if ($failures.Count -gt 0 -or $entries.Count -ne ($archiveFileCount - 1)) { exit 3 }
    }
}
