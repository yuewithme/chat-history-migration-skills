[CmdletBinding()]
param(
    [ValidateSet('Check', 'Install')]
    [string]$Action = 'Check',

    [string]$InstalledPath = (Join-Path $env:USERPROFILE '.codex\skills\feishu-local-backup'),

    [switch]$Prune
)

$ErrorActionPreference = 'Stop'

function Get-NormalizedRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-IsUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = Get-NormalizedRoot -Path $Root
    return $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SkillInventory {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPath = Get-NormalizedRoot -Path $Root
    $gitRoot = Join-Path $rootPath '.git'
    $inventory = @{}

    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        return $inventory
    }

    Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force |
        Where-Object {
            $fullPath = [IO.Path]::GetFullPath($_.FullName)
            -not $fullPath.Equals($gitRoot, [StringComparison]::OrdinalIgnoreCase) -and
            -not (Test-IsUnderRoot -Path $fullPath -Root $gitRoot)
        } |
        ForEach-Object {
            $relativePath = $_.FullName.Substring($rootPath.Length).TrimStart([char[]]'\/')
            $inventory[$relativePath] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }

    return $inventory
}

function Compare-SkillInventory {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Source,
        [Parameter(Mandatory = $true)][hashtable]$Installed
    )

    $missing = @($Source.Keys | Where-Object { -not $Installed.ContainsKey($_) } | Sort-Object)
    $different = @($Source.Keys | Where-Object { $Installed.ContainsKey($_) -and $Source[$_] -ne $Installed[$_] } | Sort-Object)
    $extra = @($Installed.Keys | Where-Object { -not $Source.ContainsKey($_) } | Sort-Object)

    return [pscustomobject]@{
        equal = ($missing.Count -eq 0 -and $different.Count -eq 0 -and $extra.Count -eq 0)
        source_file_count = $Source.Count
        installed_file_count = $Installed.Count
        missing = $missing
        different = $different
        extra = $extra
    }
}

$sourcePath = Get-NormalizedRoot -Path (Join-Path $PSScriptRoot '..')
$targetPath = Get-NormalizedRoot -Path $InstalledPath

if (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'SKILL.md') -PathType Leaf)) {
    throw "Invalid project Skill source: $sourcePath"
}

if ([IO.Path]::GetFileName($targetPath) -ne 'feishu-local-backup') {
    throw "InstalledPath must end with feishu-local-backup: $targetPath"
}

if ($sourcePath.Equals($targetPath, [StringComparison]::OrdinalIgnoreCase)) {
    [pscustomobject]@{
        action = $Action.ToLowerInvariant()
        source = $sourcePath
        installed = $targetPath
        equal = $true
        note = 'Source and installed path are the same directory.'
    } | ConvertTo-Json -Depth 5
    exit 0
}

if ($Action -eq 'Install') {
    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    $sourceInventory = Get-SkillInventory -Root $sourcePath

    foreach ($relativePath in $sourceInventory.Keys) {
        $sourceFile = Join-Path $sourcePath $relativePath
        $targetFile = Join-Path $targetPath $relativePath
        $targetDirectory = Split-Path -Parent $targetFile
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
    }

    if ($Prune) {
        if (-not (Test-Path -LiteralPath (Join-Path $targetPath 'SKILL.md') -PathType Leaf)) {
            throw "Refusing to prune an invalid installed Skill: $targetPath"
        }

        $installedInventory = Get-SkillInventory -Root $targetPath
        $extraPaths = @($installedInventory.Keys | Where-Object { -not $sourceInventory.ContainsKey($_) })
        foreach ($relativePath in $extraPaths) {
            $targetFile = [IO.Path]::GetFullPath((Join-Path $targetPath $relativePath))
            if (-not (Test-IsUnderRoot -Path $targetFile -Root $targetPath)) {
                throw "Refusing to prune a path outside the installed Skill: $targetFile"
            }
            Remove-Item -LiteralPath $targetFile -Force
        }
    }
}

$sourceInventory = Get-SkillInventory -Root $sourcePath
$installedInventory = Get-SkillInventory -Root $targetPath
$comparison = Compare-SkillInventory -Source $sourceInventory -Installed $installedInventory

[pscustomobject]@{
    action = $Action.ToLowerInvariant()
    source = $sourcePath
    installed = $targetPath
    equal = $comparison.equal
    source_file_count = $comparison.source_file_count
    installed_file_count = $comparison.installed_file_count
    missing = $comparison.missing
    different = $comparison.different
    extra = $comparison.extra
} | ConvertTo-Json -Depth 6

if (-not $comparison.equal) {
    exit 1
}
