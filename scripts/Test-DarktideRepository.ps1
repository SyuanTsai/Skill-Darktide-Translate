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

function Get-DarktideSnapshotFileMode {
    param([Parameter(Mandatory)][string] $Path)

    if ([OperatingSystem]::IsWindows()) { return '100644' }
    $mode = [IO.File]::GetUnixFileMode($Path)
    $executeBits = [IO.UnixFileMode]::UserExecute -bor
        [IO.UnixFileMode]::GroupExecute -bor
        [IO.UnixFileMode]::OtherExecute
    if (($mode -band $executeBits) -ne 0) { return '100755' }
    '100644'
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

function Read-DarktideStrictUtf8File {
    param([Parameter(Mandatory)][string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        3
    }
    else {
        0
    }
    [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
}

function Get-DarktideUnicodeScalarCount {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Context
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
    $count
}

function ConvertFrom-DarktideRestrictedYamlString {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Context
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
    $Value
}

function Read-DarktideSkillFrontmatter {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSkillId
    )

    $text = (Read-DarktideStrictUtf8File -Path $Path).Replace("`r`n", "`n").Replace("`r", "`n")
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
        $value = ConvertFrom-DarktideRestrictedYamlString -Value ([string]$Matches.value).Trim() -Context "SKILL.md $key for '$ExpectedSkillId'"
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
    $descriptionLength = Get-DarktideUnicodeScalarCount -Value $description -Context "$ExpectedSkillId description"
    if ([string]::IsNullOrWhiteSpace($description) -or $descriptionLength -gt 1024 -or $description.Contains('<') -or $description.Contains('>')) {
        throw "SKILL.md description for '$ExpectedSkillId' violates the Standard v1 text contract."
    }
    if ($values.ContainsKey('allowed-tools') -and [string]::IsNullOrWhiteSpace($values['allowed-tools'])) {
        throw "SKILL.md allowed-tools for '$ExpectedSkillId' must be a non-empty string."
    }
    [pscustomobject]@{
        name = $values['name']
        description = $description
        allowedTools = if ($values.ContainsKey('allowed-tools')) { $values['allowed-tools'] } else { $null }
    }
}

function Read-DarktideOpenAiMetadata {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSkillId
    )

    $text = (Read-DarktideStrictUtf8File -Path $Path).Replace("`r`n", "`n").Replace("`r", "`n")
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
    $shortLength = Get-DarktideUnicodeScalarCount -Value $interface['short_description'] -Context "$ExpectedSkillId short_description"
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
    [pscustomobject]@{ interface = [pscustomobject]$interface; tools = @($tools); policy = [pscustomobject]$policy }
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
    [void](Read-DarktideSkillFrontmatter -Path $skillPath -ExpectedSkillId 'auto-update-darktide-mod')
    $metadata = Read-DarktideOpenAiMetadata -Path $metadataPath -ExpectedSkillId 'auto-update-darktide-mod'
    if ([string]$metadata.interface.display_name -cne 'Auto Update Darktide MOD') {
        throw 'agents/openai.yaml identity is invalid.'
    }
}

function Get-DarktideSkillInventory {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][ValidateSet('git', 'snapshot')][string] $InventoryMode,
        [string] $GitPath
    )

    $skillRelative = 'skills/auto-update-darktide-mod'
    $skillRoot = Join-Path $Root $skillRelative
    Assert-DarktideRegularTree -Root $skillRoot -Context 'Darktide Skill'
    Assert-DarktideSkillMetadata -SkillRoot $skillRoot

    $tracked = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($InventoryMode -ceq 'git') {
        if ([string]::IsNullOrWhiteSpace($GitPath)) { throw 'Git inventory mode requires a bound Git executable.' }
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
    }

    $entries = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force)) {
        $relative = [IO.Path]::GetRelativePath($skillRoot, $file.FullName).Replace('\', '/')
        if ($relative -match '(^|/)\.\.?(/|$)' -or $relative.Contains(':')) {
            throw "Skill filesystem inventory contains an unsafe path: $relative"
        }
        [void](Read-DarktideStrictUtf8File -Path $file.FullName)

        if ($InventoryMode -ceq 'git') {
            if (-not $tracked.ContainsKey($relative)) {
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
            $mode = [string]$tracked[$relative].mode
            $sha256 = Get-DarktideGitBlobSha256 -GitPath $GitPath -Root $Root -ObjectId ([string]$tracked[$relative].oid)
        }
        else {
            $mode = Get-DarktideSnapshotFileMode -Path $file.FullName
            $sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $entries.Add([pscustomobject][ordered]@{
            path = $relative
            mode = $mode
            sha256 = $sha256
            rawSha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    if ($InventoryMode -ceq 'git' -and $entries.Count -ne $tracked.Count) {
        throw 'Skill filesystem inventory does not exactly match the Git index.'
    }
    if ($entries.Count -eq 0) { throw 'Skill filesystem inventory must not be empty.' }
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

$comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$gitMetadataEntries = @(Get-ChildItem -LiteralPath $repoRoot -Force | Where-Object {
        ([string]$_.Name).Equals('.git', $comparison)
    })
if ($gitMetadataEntries.Count -gt 1) { throw 'RepositoryRoot contains ambiguous .git entries.' }
$inventoryMode = if ($gitMetadataEntries.Count -eq 0) { 'snapshot' } else { 'git' }
$gitPath = $null
if ($inventoryMode -ceq 'git') {
    try {
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
    }
    catch {
        throw "RepositoryRoot contains .git but the Git executable is unavailable: $($_.Exception.Message)"
    }
    try {
        $gitRoot = @(
            Invoke-DarktideGitText -GitPath $gitPath -Root $repoRoot -Arguments @('rev-parse', '--show-toplevel')
        )[0].Trim()
    }
    catch {
        throw "RepositoryRoot contains .git but is not a valid Git repository root: $($_.Exception.Message)"
    }
    if (-not [IO.Path]::GetFullPath($gitRoot).Equals($repoRoot, $comparison)) {
        throw 'RepositoryRoot contains .git but does not identify RepositoryRoot as the Git repository root.'
    }
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
if (Test-Path -LiteralPath (Join-Path $repoRoot 'catalog/skills-catalog.json')) {
    throw 'Legacy source-owned cross-source catalog must not coexist with catalog/source.json.'
}
$layout = Assert-DarktideConsumerConfiguration -Root $repoRoot

$skillsRoot = Join-Path $repoRoot 'skills'
Assert-DarktideRegularTree -Root $skillsRoot -Context 'Source Skill root'
$skillsRootEntries = @(Get-ChildItem -LiteralPath $skillsRoot -Force)
foreach ($entry in $skillsRootEntries) {
    if (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Source Skill root contains a non-package or reparse entry '$($entry.Name)'."
    }
}
$skillDirectories = @($skillsRootEntries | ForEach-Object { [string]$_.Name })
if (($skillDirectories -join "`n") -cne 'auto-update-darktide-mod') { throw 'Source Skill directories do not match catalog/source.json.' }
$files = @(Get-DarktideSkillInventory -Root $repoRoot -InventoryMode $inventoryMode -GitPath $gitPath)

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
    inventoryMode = $inventoryMode
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
