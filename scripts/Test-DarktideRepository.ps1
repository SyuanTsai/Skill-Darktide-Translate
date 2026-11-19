# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [switch] $ReadOnlySnapshot,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DarktideExactPropertySet {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)][string[]] $Expected,
        [Parameter(Mandatory)][string] $Context
    )

    $actual = @($Value.PSObject.Properties.Name | ForEach-Object { [string]$_ })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($actual.Count -ne $Expected.Count -or $missing.Count -ne 0 -or $unexpected.Count -ne 0) {
        throw "$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-DarktideNoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Context
    )

    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "$Context contains duplicate JSON property '$($property.Name)'."
            }
            Assert-DarktideNoDuplicateJsonProperties -Element $property.Value -Context "$Context.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-DarktideNoDuplicateJsonProperties -Element $item -Context "$Context[$index]"
            $index++
        }
    }
}

function Read-DarktideJson {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Required JSON file must not be a reparse point: $Path"
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        throw "Required JSON file must be UTF-8 without BOM: $Path"
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    try {
        $document = [Text.Json.JsonDocument]::Parse($text)
        try {
            Assert-DarktideNoDuplicateJsonProperties -Element $document.RootElement -Context '$'
        }
        finally {
            $document.Dispose()
        }
        $text | ConvertFrom-Json -Depth 50 -ErrorAction Stop
    }
    catch {
        throw "JSON is invalid at '$Path': $($_.Exception.Message)"
    }
}

function Sort-DarktideInventoryEntries {
    param([Parameter(Mandatory)][object[]] $Entries)

    $byPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Entries) {
        $path = [string]$entry.path
        if ([string]::IsNullOrEmpty($path) -or -not $byPath.TryAdd($path, $entry)) {
            throw "Darktide inventory contains a duplicate path: $path"
        }
    }
    [string[]]$orderedPaths = @($byPath.Keys)
    [Array]::Sort($orderedPaths, [StringComparer]::Ordinal)
    foreach ($path in $orderedPaths) { $byPath[$path] }
}

function Invoke-DarktideGitText {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $output = @(& $GitPath -c "safe.directory=$Root" -c "core.worktree=$Root" -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    @($output | ForEach-Object { [string]$_ })
}

function Get-DarktideGitBlobSha256 {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $ObjectId
    )

    if ($ObjectId -cnotmatch '^[0-9a-f]{40}$') { throw "Invalid Git blob identity '$ObjectId'." }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $GitPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-c', "safe.directory=$Root", '-c', "core.worktree=$Root", '-C', $Root, 'cat-file', 'blob', $ObjectId)) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $process.StartInfo = $start
        [void]$process.Start()
        $stderr = $process.StandardError.ReadToEndAsync()
        $hash = $hasher.ComputeHash($process.StandardOutput.BaseStream)
        $process.WaitForExit()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Git blob read failed for '$ObjectId': $errorText" }
        [Convert]::ToHexString($hash).ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $process.Dispose()
    }
}

function Assert-DarktideRegularTree {
    param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Context)

    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context root must be a regular non-reparse directory."
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context contains a reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer -and $item -isnot [IO.FileInfo]) {
            throw "$Context contains a non-regular file: $($item.FullName)"
        }
    }
}

function Assert-DarktideSkillMetadata {
    param([Parameter(Mandatory)][string] $SkillRoot)

    $skillPath = Join-Path $SkillRoot 'SKILL.md'
    $metadataPath = Join-Path $SkillRoot 'agents/openai.yaml'
    foreach ($path in @($skillPath, $metadataPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required Skill metadata is missing: $path" }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Skill metadata is a reparse point: $path" }
    }
    $skillText = [IO.File]::ReadAllText($skillPath, [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n")
    if ($skillText -cnotmatch '(?s)\A---\n(?<frontmatter>.*?)\n---\n\S') { throw 'SKILL.md frontmatter or body is invalid.' }
    $frontmatter = [string]$Matches.frontmatter
    if ($frontmatter -cnotmatch '(?m)^name:\s+auto-update-darktide-mod\s*$' -or
        $frontmatter -cnotmatch '(?m)^description:\s+\S.+$') {
        throw 'SKILL.md identity or description is invalid.'
    }
    $metadata = [IO.File]::ReadAllText($metadataPath, [Text.UTF8Encoding]::new($false, $true))
    if ($metadata.Contains("`t") -or
        $metadata -cnotmatch '(?m)^\s*display_name:\s+"Auto Update Darktide MOD"\s*$' -or
        $metadata -cnotmatch '(?m)^\s*default_prompt:\s+"[^"]*\$auto-update-darktide-mod[^"]*"\s*$') {
        throw 'agents/openai.yaml identity is invalid.'
    }
}

function Get-DarktideSkillInventory {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $GitPath
    )

    $skillRelative = 'skills/auto-update-darktide-mod'
    $skillRoot = Join-Path $Root $skillRelative
    Assert-DarktideRegularTree -Root $skillRoot -Context 'Darktide Skill'
    Assert-DarktideSkillMetadata -SkillRoot $skillRoot

    $tracked = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $records = ((Invoke-DarktideGitText -GitPath $GitPath -Root $Root -Arguments @('ls-files', '-s', '-z', '--', $skillRelative)) -join '')
    foreach ($record in @($records.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
        if ($record -cnotmatch '^(?<mode>100644|100755) (?<oid>[0-9a-f]{40}) 0\t(?<path>[^\x00\r\n]+)$') {
            throw "Git returned an unsupported Skill index entry: $record"
        }
        $packagePath = ([string]$Matches.path).Substring($skillRelative.Length + 1)
        if (-not $tracked.TryAdd($packagePath, [pscustomobject]@{ mode = [string]$Matches.mode; oid = [string]$Matches.oid })) {
            throw "Git returned a duplicate Skill path: $packagePath"
        }
    }

    $entries = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force)) {
        $relative = [IO.Path]::GetRelativePath($skillRoot, $file.FullName).Replace('\', '/')
        if ($relative -match '(^|/)\.\.?(/|$)' -or $relative.Contains(':') -or -not $tracked.ContainsKey($relative)) {
            throw "Skill filesystem inventory is not safely tracked: $relative"
        }
        $repositoryPath = "$skillRelative/$relative"
        $workingOid = @(
            Invoke-DarktideGitText -GitPath $GitPath -Root $Root `
                -Arguments @('hash-object', "--path=$repositoryPath", '--', $file.FullName)
        )[0].Trim()
        if ($workingOid -cne [string]$tracked[$relative].oid) {
            throw "Skill working-tree bytes differ from the Git index: $relative"
        }
        $entries.Add([pscustomobject][ordered]@{
            path = $relative
            mode = [string]$tracked[$relative].mode
            sha256 = Get-DarktideGitBlobSha256 -GitPath $GitPath -Root $Root -ObjectId ([string]$tracked[$relative].oid)
            rawSha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    if ($entries.Count -ne $tracked.Count -or $entries.Count -eq 0) {
        throw 'Skill filesystem inventory does not exactly match the Git index.'
    }
    @(Sort-DarktideInventoryEntries -Entries $entries.ToArray())
}

function Assert-DarktideProfileCatalog {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $SourceInventory
    )

    $catalog = Read-DarktideJson -Path (Join-Path $Root 'catalog/profiles.json')
    Assert-DarktideExactPropertySet -Value $catalog -Expected @('schemaVersion', 'catalogId', 'sources', 'profiles', 'skills') -Context 'catalog/profiles.json'
    if (($catalog.schemaVersion -isnot [int] -and $catalog.schemaVersion -isnot [long]) -or [int64]$catalog.schemaVersion -ne 1) {
        throw 'catalog/profiles.json schemaVersion must be integer 1.'
    }
    if ($catalog.catalogId -isnot [string] -or [string]$catalog.catalogId -cne 'darktide-translate') {
        throw 'catalog/profiles.json catalogId must be exact string darktide-translate.'
    }

    if ($catalog.sources -isnot [array] -or @($catalog.sources).Count -ne 1) {
        throw 'Profile catalog must contain exactly one source.'
    }
    $source = @($catalog.sources)[0]
    Assert-DarktideExactPropertySet -Value $source -Expected @('id', 'repository') -Context 'catalog/profiles.json source'
    if ($source.id -isnot [string] -or [string]$source.id -cne 'darktide-translate' -or
        $source.repository -isnot [string] -or [string]$source.repository -cne 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git') {
        throw 'Profile catalog source identity is invalid.'
    }

    if ($catalog.profiles -isnot [array] -or @($catalog.profiles).Count -ne 1) {
        throw 'Profile catalog must contain exactly one profile.'
    }
    $profile = @($catalog.profiles)[0]
    Assert-DarktideExactPropertySet -Value $profile -Expected @('id', 'description', 'default', 'includes', 'excludes') -Context 'catalog/profiles.json profile'
    if ($profile.id -isnot [string] -or [string]$profile.id -cne 'darktide-mod-maintenance' -or
        $profile.description -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$profile.description) -or
        $profile.default -isnot [bool] -or $profile.default -ne $false -or
        $profile.includes -isnot [array] -or @($profile.includes).Count -ne 1 -or
        [string]@($profile.includes)[0] -cne 'auto-update-darktide-mod' -or
        $profile.excludes -isnot [array] -or @($profile.excludes).Count -ne 0) {
        throw 'Profile catalog profile identity or membership is invalid.'
    }

    if ($catalog.skills -isnot [array] -or @($catalog.skills).Count -ne 1) {
        throw 'Profile catalog must contain exactly one Skill.'
    }
    $skill = @($catalog.skills)[0]
    Assert-DarktideExactPropertySet -Value $skill -Expected @('id', 'group', 'source', 'profiles', 'compatibility', 'dependencies', 'lifecycle') -Context 'catalog/profiles.json Skill'
    if ($skill.id -isnot [string] -or [string]$skill.id -cne 'auto-update-darktide-mod' -or
        $skill.group -isnot [string] -or [string]$skill.group -cne [string]$profile.id -or
        $skill.profiles -isnot [array] -or @($skill.profiles).Count -ne 1 -or
        [string]@($skill.profiles)[0] -cne [string]$profile.id -or
        @($SourceInventory.skills) -cnotcontains [string]$skill.id) {
        throw 'Profile catalog Skill identity or profile binding is invalid.'
    }
    Assert-DarktideExactPropertySet -Value $skill.source -Expected @('sourceId', 'path') -Context 'catalog/profiles.json Skill source'
    if ($skill.source.sourceId -isnot [string] -or [string]$skill.source.sourceId -cne [string]$source.id -or
        $skill.source.path -isnot [string] -or [string]$skill.source.path -cne "skills/$($skill.id)") {
        throw 'Profile catalog Skill source binding is invalid.'
    }
    if ($skill.dependencies -isnot [array] -or @($skill.dependencies).Count -ne 0) {
        throw 'Profile catalog Skill dependencies must be empty.'
    }

    Assert-DarktideExactPropertySet -Value $skill.lifecycle -Expected @('status', 'aliases') -Context 'catalog/profiles.json Skill lifecycle'
    if ($skill.lifecycle.status -isnot [string] -or [string]$skill.lifecycle.status -cne 'active' -or
        $skill.lifecycle.aliases -isnot [array] -or @($skill.lifecycle.aliases).Count -ne 0) {
        throw 'Profile catalog Skill lifecycle is invalid.'
    }

    Assert-DarktideExactPropertySet -Value $skill.compatibility -Expected @('platforms', 'shells', 'requiredCapabilities', 'anyOfCapabilities') -Context 'catalog/profiles.json Skill compatibility'
    if ($skill.compatibility.platforms -isnot [array] -or @($skill.compatibility.platforms).Count -ne 1 -or
        [string]@($skill.compatibility.platforms)[0] -cne 'windows' -or
        $skill.compatibility.shells -isnot [array] -or @($skill.compatibility.shells).Count -ne 1 -or
        [string]@($skill.compatibility.shells)[0] -cne 'pwsh>=7') {
        throw 'Profile catalog Skill platform compatibility is invalid.'
    }

    if ($skill.compatibility.requiredCapabilities -isnot [array] -or @($skill.compatibility.requiredCapabilities).Count -ne 1) {
        throw 'Profile catalog Skill must declare exactly one required capability.'
    }
    $requiredCapability = @($skill.compatibility.requiredCapabilities)[0]
    Assert-DarktideExactPropertySet -Value $requiredCapability -Expected @('kind', 'id', 'state') -Context 'catalog/profiles.json required capability'
    if ($requiredCapability.kind -isnot [string] -or [string]$requiredCapability.kind -cne 'command' -or
        $requiredCapability.id -isnot [string] -or [string]$requiredCapability.id -cne 'git' -or
        $requiredCapability.state -isnot [string] -or [string]$requiredCapability.state -cne 'available') {
        throw 'Profile catalog required capability is invalid.'
    }

    if ($skill.compatibility.anyOfCapabilities -isnot [array] -or @($skill.compatibility.anyOfCapabilities).Count -ne 2) {
        throw 'Profile catalog Skill must declare exactly two alternative capabilities.'
    }
    $alternativeCapabilityKeys = @()
    foreach ($capability in @($skill.compatibility.anyOfCapabilities)) {
        Assert-DarktideExactPropertySet -Value $capability -Expected @('kind', 'id', 'state') -Context 'catalog/profiles.json alternative capability'
        if ($capability.kind -isnot [string] -or $capability.id -isnot [string] -or $capability.state -isnot [string]) {
            throw 'Profile catalog alternative capability contract is invalid.'
        }
        $alternativeCapabilityKeys += "{0}|{1}|{2}" -f $capability.kind, $capability.id, $capability.state
    }
    foreach ($expectedCapability in @('connector|github|configured', 'command|gh|authenticated')) {
        if ($alternativeCapabilityKeys -cnotcontains $expectedCapability) {
            throw 'Profile catalog alternative capability contract is invalid.'
        }
    }
}

function Assert-DarktideConsumerConfiguration {
    param([Parameter(Mandatory)][string] $Root)

    $pinPath = Join-Path $Root 'config/authority-pin.json'
    $gatePath = Join-Path $Root 'config/consumer-gate.json'
    $hasPin = Test-Path -LiteralPath $pinPath -PathType Leaf
    $hasGate = Test-Path -LiteralPath $gatePath -PathType Leaf
    if ($hasPin -ne $hasGate) { throw 'Consumer authority pin and gate configuration must either both exist or both be absent.' }
    if (-not $hasPin) { return 'pre-conversion' }

    $pin = Read-DarktideJson -Path $pinPath
    Assert-DarktideExactPropertySet -Value $pin -Expected @('schemaVersion', 'repository', 'commit') -Context 'authority pin'
    if (($pin.schemaVersion -isnot [int] -and $pin.schemaVersion -isnot [long]) -or [int64]$pin.schemaVersion -ne 1 -or
        $pin.repository -isnot [string] -or [string]$pin.repository -cne 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' -or
        $pin.commit -isnot [string] -or [string]$pin.commit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Consumer authority pin is invalid.'
    }
    $gate = Read-DarktideJson -Path $gatePath
    Assert-DarktideExactPropertySet -Value $gate -Expected @('schemaVersion', 'repositoryId', 'sourceRepository', 'activeSkills', 'repositoryChecks') -Context 'consumer gate'
    if (($gate.schemaVersion -isnot [int] -and $gate.schemaVersion -isnot [long]) -or [int64]$gate.schemaVersion -ne 1 -or
        $gate.repositoryId -isnot [string] -or [string]$gate.repositoryId -cne 'skill-darktide-translate' -or
        $gate.sourceRepository -isnot [string] -or [string]$gate.sourceRepository -cne 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git' -or
        $gate.activeSkills -isnot [array] -or @($gate.activeSkills).Count -ne 1 -or
        [string]@($gate.activeSkills)[0] -cne 'auto-update-darktide-mod' -or
        $gate.repositoryChecks -isnot [array]) {
        throw 'Consumer gate identity is invalid.'
    }
    $checks = @($gate.repositoryChecks)
    if ($checks.Count -ne 2) { throw 'Consumer gate must declare exactly two repository checks.' }
    $expected = @(
        'repository-darktide|general|scripts/Test-DarktideRepository.ps1',
        'repository-pester|pester|tests'
    )
    $actual = foreach ($check in $checks) {
        Assert-DarktideExactPropertySet -Value $check -Expected @('id', 'kind', 'path') -Context 'consumer repository check'
        if ($check.id -isnot [string] -or $check.kind -isnot [string] -or $check.path -isnot [string]) {
            throw 'Consumer repository checks are invalid or out of order.'
        }
        '{0}|{1}|{2}' -f [string]$check.id, [string]$check.kind, [string]$check.path
    }
    if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'Consumer repository checks are invalid or out of order.' }
    'consumer'
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else {
    [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path)
}
if ($ReadOnlySnapshot -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
    throw 'ReadOnlySnapshot does not permit an output file.'
}
$repoItem = Get-Item -LiteralPath $repoRoot -Force
if (-not $repoItem.PSIsContainer -or ($repoItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'RepositoryRoot must be a regular non-reparse directory.'
}

$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
$gitRoot = @(
    Invoke-DarktideGitText -GitPath $gitPath -Root $repoRoot -Arguments @('rev-parse', '--show-toplevel')
)[0].Trim()
$comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not [IO.Path]::GetFullPath($gitRoot).Equals($repoRoot, $comparison)) {
    throw 'RepositoryRoot must be the Git repository root.'
}

$source = Read-DarktideJson -Path (Join-Path $repoRoot 'catalog/source.json')
Assert-DarktideExactPropertySet -Value $source -Expected @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -Context 'catalog/source.json'
if (($source.schemaVersion -isnot [int] -and $source.schemaVersion -isnot [long]) -or [int64]$source.schemaVersion -ne 2) {
    throw 'catalog/source.json schemaVersion must be integer 2.'
}
if ($source.sourceId -isnot [string] -or [string]$source.sourceId -cne 'darktide-translate') {
    throw "catalog/source.json sourceId must be exact string 'darktide-translate'."
}
if ($source.repository -isnot [string] -or [string]$source.repository -cne 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git') {
    throw 'catalog/source.json repository identity is invalid.'
}
if ($source.skillsRoot -isnot [string] -or [string]$source.skillsRoot -cne 'skills') {
    throw "catalog/source.json skillsRoot must be exact string 'skills'."
}
if ($source.skills -isnot [array] -or @($source.skills).Count -eq 0) {
    throw 'catalog/source.json skills must be a non-empty array.'
}
$skillIds = @($source.skills | ForEach-Object {
    if ($_ -isnot [string] -or [string]$_ -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or ([string]$_).Length -gt 64) {
        throw "Invalid Skill ID in source inventory: '$_'."
    }
    [string]$_
})
[string[]]$sortedSkillIds = @($skillIds)
[Array]::Sort($sortedSkillIds, [StringComparer]::Ordinal)
$uniqueSkillIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($skillId in $skillIds) {
    if (-not $uniqueSkillIds.Add($skillId)) { throw "Duplicate Skill ID '$skillId'." }
}
if (($skillIds -join "`n") -cne ($sortedSkillIds -join "`n")) {
    throw 'catalog/source.json skills must use ordinal ascending order.'
}
if ($skillIds.Count -ne 1 -or $skillIds[0] -cne 'auto-update-darktide-mod') {
    throw 'Source inventory identity is invalid.'
}
Assert-DarktideProfileCatalog -Root $repoRoot -SourceInventory $source
$layout = Assert-DarktideConsumerConfiguration -Root $repoRoot

$skillsRoot = Join-Path $repoRoot 'skills'
Assert-DarktideRegularTree -Root $skillsRoot -Context 'Source Skill root'
$skillDirectories = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | ForEach-Object { [string]$_.Name })
if (($skillDirectories -join "`n") -cne 'auto-update-darktide-mod') { throw 'Source Skill directories do not match catalog/source.json.' }
$files = @(Get-DarktideSkillInventory -Root $repoRoot -GitPath $gitPath)

$discoverable = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter 'SKILL.md' -Force |
        Where-Object { $_.FullName -notmatch '[\\/]\.git(?:[\\/]|$)' } |
        ForEach-Object { [IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/') })
if (($discoverable -join "`n") -cne 'skills/auto-update-darktide-mod/SKILL.md') {
    throw "Publisher-discoverable Skill inventory is invalid: $($discoverable -join ',')"
}

$canonical = ($files | ForEach-Object { "$($_.path)`t$($_.mode)`t$($_.sha256)`n" }) -join ''
$contentSha256 = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($canonical))
).ToLowerInvariant()
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    report = 'darktide-repository-check-v1'
    sourceId = 'darktide-translate'
    layout = $layout
    activeSkillCount = 1
    skills = @([pscustomobject][ordered]@{
        skillId = 'auto-update-darktide-mod'
        contentSha256 = $contentSha256
        files = $files
    })
    result = 'passed'
}
$json = $result | ConvertTo-Json -Depth 20 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $fullOutputPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][IO.Directory]::CreateDirectory($parent) }
    $stream = [IO.FileStream]::new($fullOutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
        $stream.Write($bytes)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}
[Console]::Out.WriteLine($json)
