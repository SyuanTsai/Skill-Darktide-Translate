# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $OutputPath,
    [string] $TrustedGitPath,
    [string] $TrustedStatPath,
    [switch] $NoFilters
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:TrustedStatPath = if ([string]::IsNullOrWhiteSpace($TrustedStatPath)) { $null } else { [IO.Path]::GetFullPath($TrustedStatPath) }
$script:TrustedGitPath = if ([string]::IsNullOrWhiteSpace($TrustedGitPath)) { $null } else { [IO.Path]::GetFullPath($TrustedGitPath) }

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "$Context contains duplicate JSON property '$($property.Name)'."
            }
            Assert-NoDuplicateJsonProperties -Element $property.Value -Context "$Context.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties -Element $item -Context "$Context[$index]"
            $index++
        }
    }
}

function Read-StrictJson {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file is missing: $Path"
    }
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($text)
    }
    catch {
        throw "JSON is invalid at '$Path': $($_.Exception.Message)"
    }
    try {
        Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context '$'
    }
    finally {
        $document.Dispose()
    }
    try {
        return $text | ConvertFrom-Json -Depth 50
    }
    catch {
        throw "JSON cannot be materialized at '$Path': $($_.Exception.Message)"
    }
}

function Get-UnicodeScalarCount {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $count = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ([char]::IsHighSurrogate($character)) {
            if ($index + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$index + 1])) {
                throw "$Context contains an invalid UTF-16 surrogate sequence."
            }
            $index++
        }
        elseif ([char]::IsLowSurrogate($character)) {
            throw "$Context contains an invalid UTF-16 surrogate sequence."
        }
        $count++
    }
    return $count
}

function ConvertFrom-RestrictedYamlString {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -cmatch '^"(?:[^"\\]|\\.)*"$') {
        try {
            $decoded = $Value | ConvertFrom-Json
            if ($decoded -isnot [string]) { throw 'not a string' }
            return [string]$decoded
        }
        catch { throw "$Context contains an invalid double-quoted YAML string." }
    }
    if ($Value.StartsWith("'", [StringComparison]::Ordinal)) {
        if ($Value -cnotmatch "^'(?:[^']|'')*'$" ) { throw "$Context contains an invalid single-quoted YAML string." }
        return $Value.Substring(1, $Value.Length - 2).Replace("''", "'")
    }
    if ($Value -cmatch '^[\[\]{},&*!|>"%@`]' -or $Value -cmatch '^[?:-](?:\s|$)' -or
        $Value -cmatch ':\s' -or $Value -cmatch '(?:^|\s)#' -or
        $Value -cmatch '^(?i:~|null|true|false|yes|no|on|off|[-+]?(?:0|[1-9][0-9_]*)(?:\.[0-9_]*)?(?:[eE][-+]?[0-9]+)?|\d{4}-\d{2}-\d{2}(?:[Tt ].*)?)$') {
        throw "$Context must be a YAML string scalar, not a collection, tag, comment, or implicitly typed value."
    }
    return $Value
}

function ConvertTo-AsciiLowerInvariant {
    param([Parameter(Mandatory = $true)][string] $Value)

    $builder = [Text.StringBuilder]::new($Value.Length)
    foreach ($character in $Value.ToCharArray()) {
        if ($character -cge 'A' -and $character -cle 'Z') {
            [void]$builder.Append([char]([int]$character + 32))
        }
        else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-GitBlobSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $ObjectId
    )

    if ($ObjectId -cnotmatch '^[0-9a-f]{40}$') { throw "Invalid Git blob identity '$ObjectId'." }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-c', "safe.directory=$RepositoryRoot", '-c', "core.worktree=$RepositoryRoot", '-C', $RepositoryRoot, 'cat-file', 'blob', $ObjectId)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        if (-not $process.Start()) { throw "Could not start Git blob reader for '$ObjectId'." }
        $hash = $hasher.ComputeHash($process.StandardOutput.BaseStream)
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Git blob reader failed for '$ObjectId': $stderr" }
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $process.Dispose()
    }
}

function Get-RawFileSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Assert-RegularFileForHash {
    param(
        [Parameter(Mandatory = $true)][IO.FileSystemInfo] $Item,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context is not a regular non-reparse file: $($Item.FullName)"
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
        if ($null -eq $script:TrustedStatPath) {
            $statCommand = Get-Command stat -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $script:TrustedStatPath = [IO.Path]::GetFullPath([string]$statCommand.Path)
            if (-not (Test-Path -LiteralPath $script:TrustedStatPath -PathType Leaf)) {
                throw "Trusted Linux stat utility is missing: $($script:TrustedStatPath)"
            }
        }
        $previousLcAll = [Environment]::GetEnvironmentVariable('LC_ALL', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('LC_ALL', 'C', [EnvironmentVariableTarget]::Process)
            $fileType = @(& $script:TrustedStatPath -c '%F' -- $Item.FullName 2>$null)
            $statExitCode = $LASTEXITCODE
        }
        finally {
            [Environment]::SetEnvironmentVariable('LC_ALL', $previousLcAll, [EnvironmentVariableTarget]::Process)
        }
        if ($statExitCode -ne 0 -or $fileType.Count -ne 1 -or [string]$fileType[0].Trim() -cne 'regular file') {
            throw "$Context is not a regular file according to the trusted filesystem type check: $($Item.FullName)"
        }
    }
}

function Read-SkillFrontmatter {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId
    )

    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($text -cnotmatch '(?s)\A---\n(?<frontmatter>.*?)\n---\n(?<body>.*)\z') {
        throw "SKILL.md for '$ExpectedSkillId' must contain closed YAML frontmatter."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Matches.body)) {
        throw "SKILL.md for '$ExpectedSkillId' must contain a non-empty Markdown body."
    }

    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in ([string]$Matches.frontmatter).Split("`n")) {
        if ($line -cnotmatch '^(?<key>[a-z][a-z-]*):\s+(?<value>\S.*)$') {
            throw "SKILL.md for '$ExpectedSkillId' has unsupported or malformed frontmatter syntax: '$line'."
        }
        $key = [string]$Matches.key
        $value = ConvertFrom-RestrictedYamlString -Value ([string]$Matches.value).Trim() -Context "SKILL.md $key for '$ExpectedSkillId'"
        if ($key -cnotin @('name', 'description', 'license', 'allowed-tools') -or -not $values.TryAdd($key, $value)) {
            throw "SKILL.md for '$ExpectedSkillId' has an unsupported or duplicate frontmatter key '$key'."
        }
    }
    if ($values.Count -lt 2 -or $values.Count -gt 4 -or -not $values.ContainsKey('name') -or -not $values.ContainsKey('description')) {
        throw "SKILL.md for '$ExpectedSkillId' must define name and description, with only the allowed optional fields."
    }
    if ($values['name'] -cne $ExpectedSkillId) {
        throw "SKILL.md name '$($values['name'])' does not match package '$ExpectedSkillId'."
    }
    $description = $values['description']
    $descriptionLength = Get-UnicodeScalarCount -Value $description -Context "$ExpectedSkillId description"
    if ([string]::IsNullOrWhiteSpace($description) -or $descriptionLength -gt 1024 -or $description.Contains('<') -or $description.Contains('>')) {
        throw "SKILL.md description for '$ExpectedSkillId' violates the Standard v1 text contract."
    }
    if ($values.ContainsKey('allowed-tools') -and [string]::IsNullOrWhiteSpace($values['allowed-tools'])) {
        throw "SKILL.md allowed-tools for '$ExpectedSkillId' must be a non-empty string."
    }
    return [pscustomobject]@{ name = $values['name']; description = $description; allowedTools = if ($values.ContainsKey('allowed-tools')) { $values['allowed-tools'] } else { $null } }
}

function Get-ManagedProjectionSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $Root
    )

    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Managed .agents/skills projection root must be a non-reparse directory.'
    }

    $entries = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    $snapshot = foreach ($entry in $entries) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Managed .agents/skills projection contains a reparse entry '$($entry.FullName)'."
        }
        [pscustomobject][ordered]@{
            path = [IO.Path]::GetRelativePath($repoRoot, $entry.FullName).Replace([char]92, [char]47)
            isContainer = [bool]$entry.PSIsContainer
            attributes = [int]$entry.Attributes
            length = if ($entry.PSIsContainer) { [int64]-1 } else { [int64]$entry.Length }
            creationTimeUtcTicks = [int64]$entry.CreationTimeUtc.Ticks
            lastWriteTimeUtcTicks = [int64]$entry.LastWriteTimeUtc.Ticks
        }
    }
    @($snapshot | Sort-Object -Property path)
}

function Assert-ManagedProjectionSnapshotUnchanged {
    param(
        [Parameter(Mandatory = $true)][object[]] $Before,
        [Parameter(Mandatory = $true)][object[]] $After
    )

    if ($Before.Count -ne $After.Count) {
        throw 'Managed .agents/skills projection changed during validation.'
    }
    for ($index = 0; $index -lt $Before.Count; $index++) {
        $beforeEntry = $Before[$index]
        $afterEntry = $After[$index]
        foreach ($propertyName in @('path', 'isContainer', 'attributes', 'length', 'creationTimeUtcTicks', 'lastWriteTimeUtcTicks')) {
            if ([string]$beforeEntry.$propertyName -cne [string]$afterEntry.$propertyName) {
                throw "Managed .agents/skills projection entry '$($beforeEntry.path)' changed during validation."
            }
        }
    }
}

function Read-OpenAiMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSkillId
    )

    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($text.Contains("`t")) { throw "agents/openai.yaml for '$ExpectedSkillId' must not contain tabs." }

    $topSections = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $interface = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $tools = [Collections.Generic.List[object]]::new()
    $policy = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $section = ''
    $inTools = $false
    $sawTools = $false
    $currentTool = $null

    foreach ($line in $text.Split("`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -cmatch '^# SPDX-FileCopyrightText: 2026 SyuanTsai$' -or
            $line -cmatch '^# SPDX-License-Identifier: Apache-2\.0$') { continue }
        if ($line -cmatch '^\s*["'']') {
            throw "agents/openai.yaml for '$ExpectedSkillId' contains a quoted mapping key."
        }
        if ($line -cmatch '^(?<section>[a-z_]+):$') {
            if ($null -ne $currentTool) {
                $tools.Add([pscustomobject]$currentTool)
                $currentTool = $null
            }
            $section = [string]$Matches.section
            if ($section -cnotin @('interface', 'dependencies', 'policy') -or -not $topSections.Add($section)) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or duplicate section '$section'."
            }
            $inTools = $false
            continue
        }

        if ($section -ceq 'interface' -and $line -cmatch '^  (?<key>[a-z_]+): (?<json>"(?:[^"\\]|\\.)*")$') {
            $key = [string]$Matches.key
            if ($key -cnotin @('display_name', 'short_description', 'default_prompt', 'icon_small', 'icon_large', 'brand_color') -or $interface.ContainsKey($key)) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or duplicate interface key '$key'."
            }
            try { $interface.Add($key, [string](([string]$Matches.json) | ConvertFrom-Json)) }
            catch { throw "agents/openai.yaml for '$ExpectedSkillId' has invalid quoted string '$key'." }
            continue
        }

        if ($section -ceq 'dependencies' -and $line -ceq '  tools:') {
            if ($inTools) { throw "agents/openai.yaml for '$ExpectedSkillId' has duplicate dependencies.tools." }
            $inTools = $true
            $sawTools = $true
            continue
        }
        if ($section -ceq 'dependencies' -and $inTools -and $line -cmatch '^    - type: (?<json>"(?:[^"\\]|\\.)*")$') {
            if ($null -ne $currentTool) { $tools.Add([pscustomobject]$currentTool) }
            $currentTool = [ordered]@{}
            try { $currentTool.type = [string](([string]$Matches.json) | ConvertFrom-Json) }
            catch { throw "agents/openai.yaml for '$ExpectedSkillId' has invalid dependency type." }
            continue
        }
        if ($section -ceq 'dependencies' -and $inTools -and $null -ne $currentTool -and $line -cmatch '^      (?<key>[a-z_]+): (?<json>"(?:[^"\\]|\\.)*")$') {
            $key = [string]$Matches.key
            if ($key -cnotin @('value', 'description', 'transport', 'url') -or $currentTool.Contains($key)) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or duplicate dependency key '$key'."
            }
            try { $currentTool[$key] = [string](([string]$Matches.json) | ConvertFrom-Json) }
            catch { throw "agents/openai.yaml for '$ExpectedSkillId' has invalid dependency string '$key'." }
            continue
        }

        if ($section -ceq 'policy' -and $line -cmatch '^  (?<key>[a-z_]+): (?<value>true|false)$') {
            $key = [string]$Matches.key
            if (-not $policy.TryAdd($key, ([string]$Matches.value -ceq 'true'))) {
                throw "agents/openai.yaml for '$ExpectedSkillId' has duplicate policy key '$key'."
            }
            continue
        }

        throw "agents/openai.yaml for '$ExpectedSkillId' has unsupported or malformed syntax: '$line'."
    }
    if ($null -ne $currentTool) { $tools.Add([pscustomobject]$currentTool) }

    foreach ($required in @('display_name', 'short_description', 'default_prompt')) {
        if (-not $interface.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($interface[$required])) {
            throw "agents/openai.yaml for '$ExpectedSkillId' is missing interface.$required."
        }
    }
    $shortLength = Get-UnicodeScalarCount -Value $interface['short_description'] -Context "$ExpectedSkillId short_description"
    if ($shortLength -lt 25 -or $shortLength -gt 64) {
        throw "agents/openai.yaml interface.short_description for '$ExpectedSkillId' must contain 25 to 64 Unicode scalar values."
    }
    $token = '$' + $ExpectedSkillId
    if ($interface['default_prompt'] -cnotmatch ("(?<![A-Za-z0-9-]){0}(?![A-Za-z0-9-])" -f [regex]::Escape($token))) {
        throw "agents/openai.yaml interface.default_prompt for '$ExpectedSkillId' must reference exact token '$token'."
    }
    if ($topSections.Contains('dependencies') -and (-not $sawTools -or $tools.Count -eq 0)) {
        throw "agents/openai.yaml dependencies for '$ExpectedSkillId' must contain a non-empty tools list."
    }
    if ($topSections.Contains('policy') -and
        ($policy.Count -ne 1 -or -not $policy.ContainsKey('allow_implicit_invocation'))) {
        throw "agents/openai.yaml policy for '$ExpectedSkillId' must contain only allow_implicit_invocation."
    }
    $skillRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent (Split-Path -Parent $Path)) '.'))
    foreach ($iconKey in @('icon_small', 'icon_large')) {
        if ($interface.ContainsKey($iconKey)) {
            $iconValue = [string]$interface[$iconKey]
            if ($iconValue -cnotmatch '^\./assets/[^\r\n]+$') {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' must be a relative ./assets/ path."
            }
            $relativeIconPath = $iconValue.Substring(2).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $iconSegments = $relativeIconPath.Split([IO.Path]::DirectorySeparatorChar)
            if ($iconValue.Contains('\') -or $relativeIconPath.Contains(':') -or
                $iconSegments -contains '' -or $iconSegments -contains '.' -or $iconSegments -contains '..') {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' contains an unsafe asset path."
            }
            $iconPath = [IO.Path]::GetFullPath((Join-Path $skillRoot $relativeIconPath))
            $rootPrefix = $skillRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $iconPath.StartsWith($rootPrefix, [StringComparison]::Ordinal) -or
                -not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' must identify an existing file inside ./assets/."
            }
            $iconItem = Get-Item -LiteralPath $iconPath -Force
            if (($iconItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "agents/openai.yaml interface.$iconKey for '$ExpectedSkillId' must not identify a reparse point."
            }
        }
    }
    if ($interface.ContainsKey('brand_color') -and [string]$interface['brand_color'] -cnotmatch '^#[0-9A-Fa-f]{6}$') {
        throw "agents/openai.yaml interface.brand_color for '$ExpectedSkillId' must be a six-digit hexadecimal color."
    }
    foreach ($tool in $tools) {
        if ($tool.type -cne 'mcp' -or $null -eq $tool.PSObject.Properties['value'] -or [string]::IsNullOrWhiteSpace([string]$tool.value)) {
            throw "agents/openai.yaml dependency for '$ExpectedSkillId' must declare quoted type 'mcp' and a non-empty value."
        }
        foreach ($name in @('description', 'transport')) {
            if ($null -ne $tool.PSObject.Properties[$name] -and [string]::IsNullOrWhiteSpace([string]$tool.$name)) {
                throw "agents/openai.yaml dependency.$name for '$ExpectedSkillId' cannot be empty."
            }
        }
        if ($null -ne $tool.PSObject.Properties['url']) {
            $uri = $null
            if ([string]::IsNullOrWhiteSpace([string]$tool.url) -or
                -not [Uri]::TryCreate([string]$tool.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https') {
                throw "agents/openai.yaml dependency.url for '$ExpectedSkillId' must be absolute HTTPS."
            }
        }
    }
    return [pscustomobject]@{ interface = [pscustomobject]$interface; tools = @($tools); policy = [pscustomobject]$policy }
}

function Get-ContentInventory {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter()][switch] $NoFilters
    )

    $skillRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot "skills/$SkillId"))
    $skillRootItem = Get-Item -LiteralPath $skillRoot -Force
    if (-not $skillRootItem.PSIsContainer -or ($skillRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Skill '$SkillId' root must be a regular non-reparse directory."
    }
    $items = @(Get-ChildItem -LiteralPath $skillRoot -Recurse -Force)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Skill '$SkillId' contains a reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer) {
            Assert-RegularFileForHash -Item $item -Context "Skill '$SkillId' inventory entry"
        }
    }

    $pathToFile = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::Ordinal)
    $nfcPaths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $foldedPaths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) {
        $relative = [IO.Path]::GetRelativePath($skillRoot, $file.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
        $segments = $relative.Split('/')
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('\') -or $relative.Contains(':') -or
            $relative -cmatch '[\x00-\x1f\x7f]' -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
            throw "Skill '$SkillId' contains unsafe inventory path '$relative'."
        }
        if (-not $pathToFile.TryAdd($relative, $file)) {
            throw "Skill '$SkillId' contains duplicate inventory path '$relative'."
        }
        $nfc = $relative.Normalize([Text.NormalizationForm]::FormC)
        if ($nfcPaths.ContainsKey($nfc) -and $nfcPaths[$nfc] -cne $relative) {
            throw "Skill '$SkillId' contains an NFC path collision: '$relative'."
        }
        $nfcPaths[$nfc] = $relative
        $folded = ConvertTo-AsciiLowerInvariant -Value $nfc
        if ($foldedPaths.ContainsKey($folded) -and $foldedPaths[$folded] -cne $relative) {
            throw "Skill '$SkillId' contains an ASCII-case path collision: '$relative'."
        }
        $foldedPaths[$folded] = $relative
    }
    if ($pathToFile.Count -eq 0) { throw "Skill '$SkillId' has an empty package inventory." }

    $gitPath = $script:TrustedGitPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) { throw 'Trusted Git executable was not bound before repository validation.' }
    $gitConfigArguments = @('-c', "safe.directory=$RepositoryRoot", '-c', "core.worktree=$RepositoryRoot")
    $tracked = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $gitOutput = [string]((& $gitPath @gitConfigArguments -C $RepositoryRoot ls-files -s -z -- "skills/$SkillId") -join '')
    if ($LASTEXITCODE -ne 0) { throw "Git inventory lookup failed for '$SkillId'." }
    foreach ($record in @($gitOutput.Split([char]0) | Where-Object { $_ -ne '' })) {
        if ([string]$record -cnotmatch '^(?<mode>[0-9]{6}) (?<objectId>[0-9a-f]{40}) (?<stage>[0-3])\t(?<path>[^\x00\r\n]+)$') {
            throw "Git returned malformed index entry for '$SkillId': $record"
        }
        if ([string]$Matches.mode -cnotin @('100644', '100755') -or [string]$Matches.stage -cne '0') {
            throw "Skill '$SkillId' contains non-regular or unresolved Git entry '$($Matches.path)'."
        }
        $prefix = "skills/$SkillId/"
        $packagePath = ([string]$Matches.path).Substring($prefix.Length)
        $trackedEntry = [pscustomobject][ordered]@{ mode = [string]$Matches.mode; objectId = [string]$Matches.objectId }
        if (-not $tracked.TryAdd($packagePath, $trackedEntry)) {
            throw "Skill '$SkillId' contains duplicate Git index path '$packagePath'."
        }
    }
    if ($tracked.Count -ne $pathToFile.Count) {
        throw "Skill '$SkillId' filesystem inventory does not match the Git index."
    }
    foreach ($path in $pathToFile.Keys) {
        if (-not $tracked.ContainsKey($path)) { throw "Skill '$SkillId' contains untracked package file '$path'." }
    }

    [string[]]$sortedPaths = @($pathToFile.Keys)
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    $files = @()
    $canonical = [Text.StringBuilder]::new()
    foreach ($path in $sortedPaths) {
        $repositoryPath = "skills/$SkillId/$path"
        if (-not $NoFilters) {
            $workingObjectId = ([string](@(
                & $gitPath @gitConfigArguments -C $RepositoryRoot hash-object "--path=$repositoryPath" -- $pathToFile[$path].FullName
            ) | Select-Object -First 1)).Trim()
            if ($LASTEXITCODE -ne 0 -or $workingObjectId -cnotmatch '^[0-9a-f]{40}$' -or $workingObjectId -cne $tracked[$path].objectId) {
                throw "Skill '$SkillId' working-tree content is not bound to its Git index entry '$path'."
            }
        }
        $sha256 = Get-GitBlobSha256 -GitPath $gitPath -RepositoryRoot $RepositoryRoot -ObjectId $tracked[$path].objectId
        # Git's --path hash intentionally honors the repository's normal text
        # normalization. Keep a second raw-byte identity that is independent
        # of .git/config and .gitattributes so post-test evidence can detect a
        # filter that makes substituted bytes look like the indexed blob.
        $rawSha256 = Get-RawFileSha256 -Path $pathToFile[$path].FullName
        $files += [pscustomobject][ordered]@{
            path = $path
            mode = $tracked[$path].mode
            sha256 = $sha256
            rawSha256 = $rawSha256
        }
        [void]$canonical.Append($path).Append("`t").Append($tracked[$path].mode).Append("`t").Append($sha256).Append("`n")
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $contentSha256 = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical.ToString()))) -replace '-', '').ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
    return [pscustomobject][ordered]@{ skillId = $SkillId; contentSha256 = $contentSha256; files = $files }
}

if ($null -eq $script:TrustedGitPath) {
    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $script:TrustedGitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
}
if (-not (Test-Path -LiteralPath $script:TrustedGitPath -PathType Leaf)) {
    throw "Trusted Git executable is missing: $($script:TrustedGitPath)"
}
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
    if ($null -eq $script:TrustedStatPath) {
        $statCommand = Get-Command stat -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $script:TrustedStatPath = [IO.Path]::GetFullPath([string]$statCommand.Path)
    }
    if (-not (Test-Path -LiteralPath $script:TrustedStatPath -PathType Leaf)) {
        throw "Trusted Linux stat utility is missing: $($script:TrustedStatPath)"
    }
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else { [IO.Path]::GetFullPath($RepositoryRoot) }

$sourcePath = Join-Path $repoRoot 'catalog/source.json'
$inventory = Read-StrictJson -Path $sourcePath
Assert-ExactPropertySet -Value $inventory -Expected @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -Context 'catalog/source.json'
if (($inventory.schemaVersion -isnot [int] -and $inventory.schemaVersion -isnot [long]) -or [int64]$inventory.schemaVersion -ne 2) {
    throw 'catalog/source.json schemaVersion must be integer 2.'
}
if ($inventory.sourceId -isnot [string] -or [string]$inventory.sourceId -cne 'darktide-translate') {
    throw "catalog/source.json sourceId must be exact string 'darktide-translate'."
}
if ($inventory.repository -isnot [string] -or [string]$inventory.repository -cne 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git') {
    throw 'catalog/source.json repository identity is invalid.'
}
if ($inventory.skillsRoot -isnot [string] -or [string]$inventory.skillsRoot -cne 'skills') {
    throw "catalog/source.json skillsRoot must be exact string 'skills'."
}
if ($inventory.skills -isnot [array] -or @($inventory.skills).Count -eq 0) {
    throw 'catalog/source.json skills must be a non-empty array.'
}
if (Test-Path -LiteralPath (Join-Path $repoRoot 'catalog/skills-catalog.json')) {
    throw 'Legacy source-owned cross-source catalog must not coexist with catalog/source.json.'
}

$managedProjectionRoot = Join-Path $repoRoot '.agents/skills'
if (Test-Path -LiteralPath $managedProjectionRoot) {
    $manifestPath = Join-Path $repoRoot '.codex/ai-instructions.manifest.json'
    $manifest = Read-StrictJson -Path $manifestPath
    if ($manifest.files -isnot [array] -or @($manifest.files).Count -eq 0) {
        throw 'Managed .agents/skills projection requires a non-empty ai-instructions manifest.'
    }
    $managedEntries = @($manifest.files | Where-Object { $_.artifactType -ceq 'skill' })
    if ($managedEntries.Count -eq 0) {
        throw 'Managed .agents/skills projection has no skill entries in the ai-instructions manifest.'
    }
    $managedTargets = @()
    foreach ($entry in $managedEntries) {
        if ($entry.targetPath -isnot [string] -or
            [string]$entry.targetPath -notmatch '^\.agents/skills/([^/]+)/.+$' -or
            $entry.sha256 -isnot [string] -or [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Managed .agents/skills manifest entry has an unsafe target path or invalid hash.'
        }
        if ($managedTargets -ccontains [string]$entry.targetPath) {
            throw "Managed .agents/skills manifest contains duplicate target '$($entry.targetPath)'."
        }
        $managedTargets += [string]$entry.targetPath
    }
    $projectionSnapshotBeforeHash = @(Get-ManagedProjectionSnapshot -Root $managedProjectionRoot)
    $actualManagedTargets = @(
        $projectionSnapshotBeforeHash | Where-Object { -not $_.isContainer } |
            ForEach-Object { [string]$_.path }
    )
    $missingManagedTargets = @($managedTargets | Where-Object { $actualManagedTargets -notcontains $_ })
    $unexpectedManagedTargets = @($actualManagedTargets | Where-Object { $managedTargets -notcontains $_ })
    if ($missingManagedTargets.Count -gt 0 -or $unexpectedManagedTargets.Count -gt 0) {
        throw "Managed .agents/skills projection does not exactly match its manifest. Missing='$($missingManagedTargets -join ',')' Unexpected='$($unexpectedManagedTargets -join ',')'."
    }
    $projectionHashes = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $managedEntries) {
        $entryPath = Join-Path $repoRoot ([string]$entry.targetPath).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entryPath).Hash.ToLowerInvariant()
        if ($actualHash -cne [string]$entry.sha256) {
            throw "Managed .agents/skills projection hash mismatch for '$($entry.targetPath)'."
        }
        $projectionHashes[[string]$entry.targetPath] = $actualHash
        $managedSkillId = ([regex]::Match([string]$entry.targetPath, '^\.agents/skills/([^/]+)/')).Groups[1].Value
        if (@($inventory.skills) -ccontains $managedSkillId) {
            throw "Managed .agents/skills projection claims source-owned Skill '$managedSkillId'; source and consumer paths must remain separate."
        }
    }

    # The initial recursive snapshot identifies every inspected entry, but the
    # hash reads reopen paths later. Re-scan the root and compare entry metadata
    # before success so a reparse swap or path replacement cannot be hidden by a
    # manifest-matching external target between inspection and hashing.
    $projectionSnapshotAfterHash = @(Get-ManagedProjectionSnapshot -Root $managedProjectionRoot)
    Assert-ManagedProjectionSnapshotUnchanged -Before $projectionSnapshotBeforeHash -After $projectionSnapshotAfterHash
    foreach ($entry in $managedEntries) {
        $entryPath = Join-Path $repoRoot ([string]$entry.targetPath).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $rehash = (Get-FileHash -Algorithm SHA256 -LiteralPath $entryPath).Hash.ToLowerInvariant()
        if ($rehash -cne [string]$projectionHashes[[string]$entry.targetPath]) {
            throw "Managed .agents/skills projection content changed during validation for '$($entry.targetPath)'."
        }
    }
    # The final pathname reads above are still outside the preceding snapshot.
    # Re-scan once more after the last hash so a replacement or reparse swap
    # between the rehash and success cannot be hidden by the final check.
    $projectionSnapshotAfterFinalHash = @(Get-ManagedProjectionSnapshot -Root $managedProjectionRoot)
    Assert-ManagedProjectionSnapshotUnchanged -Before $projectionSnapshotAfterHash -After $projectionSnapshotAfterFinalHash
}

$adapter = Read-StrictJson -Path (Join-Path $repoRoot 'config/standard-v1.json')
Assert-ExactPropertySet -Value $adapter -Expected @('schemaVersion', 'standardVersion', 'authority', 'deviations') -Context 'config/standard-v1.json'
Assert-ExactPropertySet -Value $adapter.authority -Expected @('repository', 'commit', 'archiveUrl', 'archiveSha256', 'files') -Context 'config/standard-v1.json authority'
if (($adapter.schemaVersion -isnot [int] -and $adapter.schemaVersion -isnot [long]) -or [int64]$adapter.schemaVersion -ne 1 -or
    $adapter.standardVersion -isnot [string] -or $adapter.standardVersion -cne 'v1' -or
    $adapter.deviations -isnot [string] -or $adapter.deviations -cne 'None') {
    throw 'config/standard-v1.json identity or deviation contract is invalid.'
}
if ($adapter.authority.repository -isnot [string] -or $adapter.authority.repository -cne 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' -or
    $adapter.authority.commit -isnot [string] -or $adapter.authority.commit -cnotmatch '^[0-9a-f]{40}$' -or
    $adapter.authority.archiveUrl -isnot [string] -or
    $adapter.authority.archiveUrl -cne "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($adapter.authority.commit)" -or
    $adapter.authority.archiveSha256 -isnot [string] -or $adapter.authority.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'config/standard-v1.json authority binding is invalid.'
}
$requiredAuthorityPaths = @(
    'docs/standards/README.md',
    'docs/standards/managed-skill-lifecycle.md',
    'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json',
    'docs/standards/schemas/openai-agent-metadata.schema.json',
    'docs/standards/schemas/source-inventory-v2.schema.json',
    'docs/standards/schemas/validation-security-gate-v1.schema.json',
    'docs/standards/skill-repository-review-matrix.md',
    'docs/standards/skill-repository-standard.md',
    'docs/standards/upstream-interoperability.md',
    'docs/standards/validation-security-gate.json',
    'docs/standards/validation-toolchain.json',
    'scripts/Invoke-StandardAuthorityGate.ps1',
    'scripts/Resolve-PythonWheelClosure.py',
    'scripts/Resolve-StandardValidationTool.ps1'
)
if ($adapter.authority.files -isnot [array] -or @($adapter.authority.files).Count -ne $requiredAuthorityPaths.Count) {
    throw 'config/standard-v1.json authority file inventory is incomplete.'
}
$authorityPaths = @()
foreach ($file in @($adapter.authority.files)) {
    Assert-ExactPropertySet -Value $file -Expected @('path', 'sha256') -Context 'config/standard-v1.json authority file'
    if ($file.path -isnot [string] -or $requiredAuthorityPaths -cnotcontains $file.path -or $authorityPaths -ccontains $file.path -or
        $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'config/standard-v1.json authority file binding is invalid.'
    }
    $authorityPaths += [string]$file.path
}

$skillIds = @($inventory.skills | ForEach-Object {
    if ($_ -isnot [string] -or [string]$_ -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or
        (Get-UnicodeScalarCount -Value ([string]$_) -Context 'Skill ID') -gt 64) {
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

$skillsRoot = Join-Path $repoRoot 'skills'
if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) { throw 'Canonical skills/ source root is missing.' }
$skillsRootItem = Get-Item -LiteralPath $skillsRoot -Force
if (($skillsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Canonical skills/ source root must be a regular non-reparse directory.'
}
$skillsRootEntries = @(Get-ChildItem -LiteralPath $skillsRoot -Force)
foreach ($entry in $skillsRootEntries) {
    if (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Canonical skills/ source root contains a non-package or reparse entry '$($entry.Name)'."
    }
}
[string[]]$actualSkillIds = @($skillsRootEntries | ForEach-Object { $_.Name })
[Array]::Sort($actualSkillIds, [StringComparer]::Ordinal)
if (($actualSkillIds -join "`n") -cne ($skillIds -join "`n")) {
    throw 'catalog/source.json inventory does not exactly match skills/ directories.'
}

function Get-PublisherSkillDiscoveryPaths {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $SkillsRoot
    )

    $discovered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Add-PublisherSkillPath {
        param([Parameter(Mandatory = $true)][string] $Path)

        $item = $null
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch [Management.Automation.ItemNotFoundException] {
            return
        }
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher-discoverable Skill path must be a regular non-reparse file: $Path"
        }
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $item.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
        if (-not $discovered.Add($relativePath)) {
            throw "Publisher-discoverable Skill path was discovered more than once: $relativePath"
        }
    }

    # GitHub CLI discovers root-level */SKILL.md entries, the canonical
    # skills/... layouts, {prefix}/skills/... layouts, and the explicit
    # plugins/{scope}/skills/... layout. Prefixes may be nested, but the
    # package and optional scope depths below remain bounded to the documented
    # publisher layouts; arbitrary SKILL.md recursion is never accepted.
    foreach ($entry in @(Get-ChildItem -LiteralPath $RepositoryRoot -Directory -Force)) {
        if ([string]$entry.Name -ceq '.git' -or ([string]$entry.Name).StartsWith('.')) { continue }
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher discovery root contains a reparse directory: $($entry.FullName)"
        }
        Add-PublisherSkillPath -Path (Join-Path $entry.FullName 'SKILL.md')
    }

    $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    $skillsRootFullPath = [IO.Path]::GetFullPath($SkillsRoot)
    $pendingDirectories = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    foreach ($entry in @(Get-ChildItem -LiteralPath $RepositoryRoot -Directory -Force)) {
        if ([string]$entry.Name -ceq '.git' -or ([string]$entry.Name).StartsWith('.')) { continue }
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher discovery root contains a reparse directory: $($entry.FullName)"
        }
        $pendingDirectories.Push($entry)
    }
    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        if ([string]$directory.Name -ceq 'plugins') { continue }
        if ([string]$directory.Name -ceq 'skills') {
            if ([IO.Path]::GetFullPath($directory.FullName).Equals($skillsRootFullPath, $pathComparison)) { continue }
            foreach ($packageEntry in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force)) {
                if ([string]$packageEntry.Name -ceq '.' -or ([string]$packageEntry.Name).StartsWith('.')) { continue }
                if (($packageEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Publisher discovery nested package contains a reparse directory: $($packageEntry.FullName)"
                }
                Add-PublisherSkillPath -Path (Join-Path $packageEntry.FullName 'SKILL.md')
                foreach ($scopedPackageEntry in @(Get-ChildItem -LiteralPath $packageEntry.FullName -Directory -Force)) {
                    if ([string]$scopedPackageEntry.Name -ceq '.' -or ([string]$scopedPackageEntry.Name).StartsWith('.')) { continue }
                    if (($scopedPackageEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Publisher discovery scoped package contains a reparse directory: $($scopedPackageEntry.FullName)"
                    }
                    Add-PublisherSkillPath -Path (Join-Path $scopedPackageEntry.FullName 'SKILL.md')
                }
            }
            continue
        }
        foreach ($childDirectory in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force)) {
            if ([string]$childDirectory.Name -ceq '.git' -or ([string]$childDirectory.Name).StartsWith('.')) { continue }
            if (($childDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Publisher discovery prefix contains a reparse directory: $($childDirectory.FullName)"
            }
            $pendingDirectories.Push($childDirectory)
        }
    }

    foreach ($scopeEntry in @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -Force)) {
        if (($scopeEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher discovery canonical scope contains a reparse directory: $($scopeEntry.FullName)"
        }
        Add-PublisherSkillPath -Path (Join-Path $scopeEntry.FullName 'SKILL.md')
        foreach ($packageEntry in @(Get-ChildItem -LiteralPath $scopeEntry.FullName -Directory -Force)) {
            if (($packageEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Publisher discovery nested canonical package contains a reparse directory: $($packageEntry.FullName)"
            }
            Add-PublisherSkillPath -Path (Join-Path $packageEntry.FullName 'SKILL.md')
        }
    }

    $pluginsRoot = Join-Path $RepositoryRoot 'plugins'
    if (Test-Path -LiteralPath $pluginsRoot -PathType Container) {
        $pluginsRootItem = Get-Item -LiteralPath $pluginsRoot -Force -ErrorAction Stop
        if (($pluginsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Publisher discovery plugins root is a reparse directory: $pluginsRoot"
        }
        foreach ($scopeEntry in @(Get-ChildItem -LiteralPath $pluginsRoot -Directory -Force)) {
            if (($scopeEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Publisher discovery plugin scope contains a reparse directory: $($scopeEntry.FullName)"
            }
            $pluginSkillsRoot = Join-Path $scopeEntry.FullName 'skills'
            if (-not (Test-Path -LiteralPath $pluginSkillsRoot -PathType Container)) { continue }
            $pluginSkillsRootItem = Get-Item -LiteralPath $pluginSkillsRoot -Force -ErrorAction Stop
            if (($pluginSkillsRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Publisher discovery plugin skills root is a reparse directory: $pluginSkillsRoot"
            }
            foreach ($packageEntry in @(Get-ChildItem -LiteralPath $pluginSkillsRoot -Directory -Force)) {
                if (($packageEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Publisher discovery plugin package contains a reparse directory: $($packageEntry.FullName)"
                }
                Add-PublisherSkillPath -Path (Join-Path $packageEntry.FullName 'SKILL.md')
            }
        }
    }

    [string[]]$sorted = @($discovered)
    [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
    return @($sorted)
}

$expectedPublisherSkillPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($skillId in $skillIds) {
    [void]$expectedPublisherSkillPaths.Add(("skills/{0}/SKILL.md" -f $skillId))
}
$actualPublisherSkillPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($publisherPath in @(Get-PublisherSkillDiscoveryPaths -RepositoryRoot $repoRoot -SkillsRoot $skillsRoot)) {
    [void]$actualPublisherSkillPaths.Add([string]$publisherPath)
}
$missingPublisherPaths = @($expectedPublisherSkillPaths | Where-Object { -not $actualPublisherSkillPaths.Contains([string]$_) })
$unexpectedPublisherPaths = @($actualPublisherSkillPaths | Where-Object { -not $expectedPublisherSkillPaths.Contains([string]$_) })
if ($missingPublisherPaths.Count -gt 0 -or $unexpectedPublisherPaths.Count -gt 0) {
    throw "Publisher-discoverable Skill inventory does not exactly match catalog/source.json. Missing='$($missingPublisherPaths -join ',')' Unexpected='$($unexpectedPublisherPaths -join ',')'."
}

$packages = @()
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $skillsRoot $skillId
    $skillFile = Join-Path $skillRoot 'SKILL.md'
    $metadataFile = Join-Path $skillRoot 'agents/openai.yaml'
    foreach ($requiredPath in @($skillFile, $metadataFile)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Skill '$skillId' is missing '$requiredPath'." }
    }
    [void](Read-SkillFrontmatter -Path $skillFile -ExpectedSkillId $skillId)
    [void](Read-OpenAiMetadata -Path $metadataFile -ExpectedSkillId $skillId)
    $packages += Get-ContentInventory -RepositoryRoot $repoRoot -SkillId $skillId -NoFilters:$NoFilters
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    sourceId = 'darktide-translate'
    skillsRoot = 'skills'
    activeSkillCount = $skillIds.Count
    skills = $packages
    result = 'passed'
}
$json = $result | ConvertTo-Json -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $outputFullPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { [void](New-Item -ItemType Directory -Path $outputDirectory -Force) }
    [IO.File]::WriteAllText($outputFullPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
Write-Host "Darktide Translate repository validation passed: $($skillIds.Count) active Skills."
$json
