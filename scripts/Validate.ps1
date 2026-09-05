# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $ArtifactsRoot = $(
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP }
        else { [IO.Path]::GetTempPath() }
    ),
    [string] $AuthorityArchivePath,
    [string] $BaseCommit,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NoDuplicateJsonProperties {
    param([Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element, [string] $Context = '$')
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "$Context contains duplicate JSON property '$($property.Name)'." }
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
function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try { Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context $Context }
        finally { $document.Dispose() }
        return $text | ConvertFrom-Json -Depth 100
    }
    catch { throw "$Context is not valid unambiguous UTF-8 JSON: $($_.Exception.Message)" }
}

function Assert-Sha256 {
    param($Value, [string] $Context)
    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context must be a lowercase SHA-256 value."
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Object -isnot [pscustomobject] -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "$Context is missing required property '$Name'."
    }
    return ,$Object.PSObject.Properties[$Name].Value
}

function Get-ValidationSecurityAction {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $Severity,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $matches = @($Policy.security.severity | Where-Object { $_.level -ceq $Severity })
    if ($matches.Count -ne 1 -or $matches[0].action -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$matches[0].action)) {
        throw "$Context has no unique central action for severity '$Severity'."
    }
    return [string]$matches[0].action
}

function ConvertTo-ValidationSecurityFinding {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $ReportedSeverity,
        [Parameter(Mandatory = $true)][string] $Stage,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)] $Issue
    )
    $severityAliases = [ordered]@{
        critical = 'critical'
        high = 'high'
        medium = 'medium'
        low = 'low'
        informational = 'informational'
        info = 'informational'
    }
    $severityKey = $ReportedSeverity.ToLowerInvariant()
    if (-not $severityAliases.Contains($severityKey)) {
        throw "$Stage returned unsupported severity '$ReportedSeverity' for '$SkillId'."
    }
    $severity = [string]$severityAliases[$severityKey]
    $action = Get-ValidationSecurityAction -Policy $Policy -Severity $severity -Context $Stage
    [pscustomobject][ordered]@{
        stage = $Stage
        skillId = $SkillId
        severity = $severity
        action = $action
        issue = $Issue
    }
}

function Test-PathEqual {
    param([string] $Left, [string] $Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right), $comparison)
}

function Test-PathWithinOrEqual {
    param([string] $Path, [string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-NoReparseAncestors {
    param([string] $Path, [string] $Context)
    $currentPath = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context is backed by a reparse point: $currentPath"
        }
        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parentPath) -or (Test-PathEqual -Left $parentPath -Right $currentPath)) { break }
        $currentPath = $parentPath
    }
}

function Resolve-ReportedFilePath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $SkillRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "$Context must be a non-empty path string." }
    $candidate = [string]$Value
    if ($candidate -cmatch '^file:') {
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) {
            throw "$Context must be a local Skill path."
        }
        $candidate = $uri.LocalPath
    }
    elseif (-not [IO.Path]::IsPathRooted($candidate) -and $candidate -cmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
        throw "$Context must be a local Skill path."
    }
    if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $SkillRoot $candidate }
    $fullPath = Assert-PathWithinRoot -Path $candidate -Root $SkillRoot -Context $Context
    foreach ($relativePath in $ExpectedInventoryPaths) {
        if (Test-PathEqual -Left $fullPath -Right (Join-Path $SkillRoot $relativePath)) { return $fullPath }
    }
    throw "$Context does not identify a file in the candidate-bound Skill inventory: $fullPath"
}

function Assert-SkillSpectorReport {
    param($Report, [string] $SkillRoot, [string] $SkillId, [string[]] $ExpectedInventoryPaths)
    $executionSuccessful = Get-RequiredProperty -Object $Report -Name 'execution_successful' -Context 'SkillSpector report'
    $completeness = Get-RequiredProperty -Object $Report -Name 'analysis_completeness' -Context 'SkillSpector report'
    $coverage = Get-RequiredProperty -Object $completeness -Name 'coverage_percent' -Context 'SkillSpector completeness'
    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [single], [double], [decimal])
    $coverageIsNumeric = $false
    foreach ($type in $numericTypes) { if ($coverage -is $type) { $coverageIsNumeric = $true; break } }
    if ($executionSuccessful -isnot [bool] -or -not $executionSuccessful -or
        (Get-RequiredProperty -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-RequiredProperty -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -or
        (Get-RequiredProperty -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-RequiredProperty -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -or
        (Get-RequiredProperty -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -isnot [string] -or
        (Get-RequiredProperty -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -cne 'complete' -or
        -not $coverageIsNumeric -or $coverage -ne 100) {
        throw "SkillSpector did not prove complete static analysis for '$SkillId'."
    }
    foreach ($name in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
        $items = Get-RequiredProperty -Object $completeness -Name $name -Context 'SkillSpector completeness'
        if ($items -isnot [array] -or @($items).Count -ne 0) {
            $detail = ConvertTo-Json -InputObject $items -Depth 12 -Compress
            throw "SkillSpector reported incomplete '$name' evidence for '$SkillId': $detail"
        }
    }
    $skill = Get-RequiredProperty -Object $Report -Name 'skill' -Context 'SkillSpector report'
    $reportedName = Get-RequiredProperty -Object $skill -Name 'name' -Context 'SkillSpector skill identity'
    $reportedSource = Get-RequiredProperty -Object $skill -Name 'source' -Context 'SkillSpector skill identity'
    if ($reportedName -isnot [string] -or $reportedName -cne $SkillId -or
        $reportedSource -isnot [string] -or -not (Test-PathEqual -Left $reportedSource -Right $SkillRoot)) {
        throw "SkillSpector report identity does not match '$SkillId'."
    }
    $components = Get-RequiredProperty -Object $Report -Name 'components' -Context 'SkillSpector report'
    if ($components -isnot [array] -or @($components).Count -ne $ExpectedInventoryPaths.Count) {
        throw "SkillSpector did not cover the exact candidate-bound inventory for '$SkillId'."
    }
    $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($component in @($components)) {
        $path = Get-RequiredProperty -Object $component -Name 'path' -Context 'SkillSpector component'
        if ($path -isnot [string] -or -not ($ExpectedInventoryPaths -ccontains $path) -or -not $observed.Add($path)) {
            throw "SkillSpector did not cover the exact candidate-bound inventory for '$SkillId'."
        }
    }
    $issues = Get-RequiredProperty -Object $Report -Name 'issues' -Context 'SkillSpector report'
    if ($issues -isnot [array]) { throw "SkillSpector issues must be an array for '$SkillId'." }
    return @($issues)
}

function Assert-SkillValidatorReport {
    param($Report, [string] $SkillRoot, [string[]] $ExpectedInventoryPaths, [string] $SkillId)
    $skillDirectory = Get-RequiredProperty -Object $Report -Name 'skill_dir' -Context 'skill-validator report'
    $passed = Get-RequiredProperty -Object $Report -Name 'passed' -Context 'skill-validator report'
    $errors = Get-RequiredProperty -Object $Report -Name 'errors' -Context 'skill-validator report'
    $warnings = Get-RequiredProperty -Object $Report -Name 'warnings' -Context 'skill-validator report'
    $results = Get-RequiredProperty -Object $Report -Name 'results' -Context 'skill-validator report'
    if ($skillDirectory -isnot [string] -or -not (Test-PathEqual -Left $skillDirectory -Right $SkillRoot) -or
        $passed -isnot [bool] -or -not $passed -or
        ($errors -isnot [int] -and $errors -isnot [long]) -or [int64]$errors -ne 0 -or
        ($warnings -isnot [int] -and $warnings -isnot [long]) -or [int64]$warnings -ne 0 -or
        $results -isnot [array] -or @($results).Count -le 0) {
        throw "skill-validator did not produce a clean candidate-bound report for '$SkillId'."
    }
    foreach ($result in @($results)) {
        $level = Get-RequiredProperty -Object $result -Name 'level' -Context 'skill-validator result'
        $category = Get-RequiredProperty -Object $result -Name 'category' -Context 'skill-validator result'
        $message = Get-RequiredProperty -Object $result -Name 'message' -Context 'skill-validator result'
        if ($level -isnot [string] -or $level -cnotin @('pass', 'info', 'warning', 'error') -or $level -in @('warning', 'error') -or
            $category -isnot [string] -or [string]::IsNullOrWhiteSpace($category) -or
            $message -isnot [string] -or [string]::IsNullOrWhiteSpace($message)) {
            throw "skill-validator returned a malformed or blocking result for '$SkillId'."
        }
        if ($null -ne $result.PSObject.Properties['file']) {
            [void](Resolve-ReportedFilePath -Value $result.file -SkillRoot $SkillRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-validator result file')
        }
        if ($null -ne $result.PSObject.Properties['line'] -and
            (($result.line -isnot [int] -and $result.line -isnot [long]) -or [int64]$result.line -le 0)) {
            throw "skill-validator returned an invalid line for '$SkillId'."
        }
    }
}

function Assert-SkillToolsReport {
    param($Report, [string] $SkillRoot, [string[]] $ExpectedInventoryPaths, [string] $SkillId)
    $version = Get-RequiredProperty -Object $Report -Name 'version' -Context 'skill-tools SARIF'
    $runs = Get-RequiredProperty -Object $Report -Name 'runs' -Context 'skill-tools SARIF'
    if ($version -isnot [string] -or $version -cne '2.1.0' -or $runs -isnot [array] -or @($runs).Count -ne 1) {
        throw "skill-tools did not produce SARIF 2.1.0 for '$SkillId'."
    }
    $run = $runs[0]
    $driver = Get-RequiredProperty -Object (Get-RequiredProperty -Object $run -Name 'tool' -Context 'skill-tools SARIF run') -Name 'driver' -Context 'skill-tools SARIF tool'
    $driverName = Get-RequiredProperty -Object $driver -Name 'name' -Context 'skill-tools SARIF driver'
    $rules = Get-RequiredProperty -Object $driver -Name 'rules' -Context 'skill-tools SARIF driver'
    $results = Get-RequiredProperty -Object $run -Name 'results' -Context 'skill-tools SARIF run'
    if ($driverName -isnot [string] -or $driverName -cne 'skill-tools' -or $rules -isnot [array] -or
        $results -isnot [array]) {
        throw "skill-tools SARIF is incomplete for '$SkillId'."
    }
    $ruleById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($rule in @($rules)) {
        $ruleId = Get-RequiredProperty -Object $rule -Name 'id' -Context 'skill-tools SARIF rule'
        if ($ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or $ruleById.ContainsKey($ruleId)) {
            throw "skill-tools SARIF rule metadata is malformed for '$SkillId'."
        }
        $ruleById.Add($ruleId, $rule)
    }
    foreach ($result in @($results)) {
        $ruleId = Get-RequiredProperty -Object $result -Name 'ruleId' -Context 'skill-tools SARIF result'
        if ($ruleId -isnot [string] -or -not $ruleById.ContainsKey($ruleId)) { throw "skill-tools SARIF references an unknown rule for '$SkillId'." }
        $effectiveLevel = if ($null -ne $result.PSObject.Properties['level']) { $result.level } else {
            $configuration = Get-RequiredProperty -Object $ruleById[$ruleId] -Name 'defaultConfiguration' -Context 'skill-tools SARIF rule'
            Get-RequiredProperty -Object $configuration -Name 'level' -Context 'skill-tools SARIF rule default'
        }
        if ($effectiveLevel -isnot [string] -or $effectiveLevel -cnotin @('none', 'note', 'warning', 'error') -or $effectiveLevel -ceq 'error') {
            throw "skill-tools SARIF contains a malformed or error-level result for '$SkillId'."
        }
        $message = Get-RequiredProperty -Object $result -Name 'message' -Context 'skill-tools SARIF result'
        $messageText = Get-RequiredProperty -Object $message -Name 'text' -Context 'skill-tools SARIF message'
        $locations = Get-RequiredProperty -Object $result -Name 'locations' -Context 'skill-tools SARIF result'
        if ($messageText -isnot [string] -or [string]::IsNullOrWhiteSpace($messageText) -or $locations -isnot [array] -or @($locations).Count -le 0) {
            throw "skill-tools SARIF lacks candidate-bound evidence for '$SkillId'."
        }
        foreach ($location in @($locations)) {
            $physical = Get-RequiredProperty -Object $location -Name 'physicalLocation' -Context 'skill-tools SARIF location'
            $artifact = Get-RequiredProperty -Object $physical -Name 'artifactLocation' -Context 'skill-tools SARIF physical location'
            $uri = Get-RequiredProperty -Object $artifact -Name 'uri' -Context 'skill-tools SARIF artifact location'
            [void](Resolve-ReportedFilePath -Value $uri -SkillRoot $SkillRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-tools SARIF artifact location')
        }
    }
}

function Assert-PathWithinRoot {
    param([string] $Path, [string] $Root, [string] $Context)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $fullPath.StartsWith($fullRoot, $comparison)) { throw "$Context escapes its controlled root: $fullPath" }
    return $fullPath
}

function Assert-ReceiptFile {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $PathProperty,
        [Parameter(Mandatory = $true)][string] $HashProperty,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $pathValue = $Receipt.PSObject.Properties[$PathProperty]
    $hashValue = $Receipt.PSObject.Properties[$HashProperty]
    if ($null -eq $pathValue -or $pathValue.Value -isnot [string] -or
        $null -eq $hashValue -or $hashValue.Value -isnot [string]) {
        throw "$Context receipt does not provide $PathProperty/$HashProperty."
    }
    Assert-Sha256 -Value ([string]$hashValue.Value) -Context "$Context receipt file hash"
    $path = Assert-PathWithinRoot -Path ([string]$pathValue.Value) -Root $InstallRoot -Context $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Context installed file is missing: $path" }
    Assert-NoReparseAncestors -Path $path -Context "$Context installed file"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$hashValue.Value) { throw "$Context installed file changed after resolution." }
    return $path
}

function Assert-ExternalReceiptFile {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $PathProperty,
        [Parameter(Mandatory = $true)][string] $HashProperty,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $pathValue = $Receipt.PSObject.Properties[$PathProperty]
    $hashValue = $Receipt.PSObject.Properties[$HashProperty]
    if ($null -eq $pathValue -or $pathValue.Value -isnot [string] -or
        $null -eq $hashValue -or $hashValue.Value -isnot [string]) {
        throw "$Context receipt does not provide $PathProperty/$HashProperty."
    }
    if (-not [IO.Path]::IsPathRooted([string]$pathValue.Value)) {
        throw "$Context receipt path must be absolute."
    }
    Assert-Sha256 -Value ([string]$hashValue.Value) -Context "$Context receipt file hash"
    $path = [IO.Path]::GetFullPath([string]$pathValue.Value)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Context runtime file is missing: $path" }
    Assert-NoReparseAncestors -Path $path -Context "$Context runtime file"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$hashValue.Value) { throw "$Context runtime file changed after resolution." }
    return $path
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $DiagnosticRoot
    )
    if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) { throw "$Context executable is missing: $Command" }
    $stderrPath = Join-Path $DiagnosticRoot ("stderr-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    try {
        $stdout = @(& $Command @Arguments 2> $stderrPath)
        $exitCode = $LASTEXITCODE
        $stdoutText = ($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
        if ($exitCode -ne 0) {
            throw "$Context exited with code $exitCode.`nSTDOUT:`n$stdoutText`nSTDERR:`n$stderrText"
        }
        return $stdoutText
    }
    finally {
        if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
    }
}

function Test-SecurityRelevantSkillChange {
    param([string] $GitPath, [string] $RepositoryRoot, [string] $BaseCommit)
    if ([string]::IsNullOrWhiteSpace($BaseCommit)) { return $false }
    $lines = @(& $GitPath -c "safe.directory=$RepositoryRoot" -C $RepositoryRoot diff --find-renames=100% --name-status "$BaseCommit...HEAD")
    if ($LASTEXITCODE -ne 0) { throw "Could not compare candidate with base commit '$BaseCommit'." }
    foreach ($line in $lines) {
        $columns = ([string]$line).Split("`t")
        $status = $columns[0]
        if ($status -ceq 'R100' -and $columns.Count -eq 3 -and
            $columns[1] -clike '.agents/skills/*' -and $columns[2] -clike 'skills/*') {
            continue
        }
        foreach ($path in @($columns | Select-Object -Skip 1)) {
            if ($path -clike 'skills/*') { return $true }
        }
    }
    return $false
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else { [IO.Path]::GetFullPath($RepositoryRoot) }
$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
$gitConfigArguments = @('-c', "safe.directory=$repoRoot")

$candidateCommit = ([string](@(& $gitPath @gitConfigArguments -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $candidateCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Candidate must be an immutable Git commit.' }
$dirty = @(& $gitPath @gitConfigArguments -C $repoRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Canonical validation requires a clean candidate commit; commit or remove every tracked/untracked change first.'
}
$resolvedBaseCommit = ''
if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    $baseRevision = "$BaseCommit^{commit}"
    $baseOutput = @(& $gitPath @gitConfigArguments -C $repoRoot rev-parse --verify --end-of-options $baseRevision 2>$null)
    if ($LASTEXITCODE -ne 0 -or $baseOutput.Count -ne 1 -or [string]$baseOutput[0] -cnotmatch '^[0-9a-f]{40}$') {
        throw "Base commit '$BaseCommit' does not resolve to one immutable commit."
    }
    $resolvedBaseCommit = ([string]$baseOutput[0]).Trim()
    & $gitPath @gitConfigArguments -C $repoRoot merge-base --is-ancestor $resolvedBaseCommit $candidateCommit
    if ($LASTEXITCODE -ne 0 -or $resolvedBaseCommit -ceq $candidateCommit) {
        throw 'Base commit must be a distinct ancestor of the immutable candidate.'
    }
    $BaseCommit = $resolvedBaseCommit
}

$adapterPath = Join-Path $repoRoot 'config/standard-v1.json'
$adapter = Read-JsonFile -Path $adapterPath -Context 'Standard v1 repository adapter'
if ($adapter.schemaVersion -ne 1 -or $adapter.standardVersion -cne 'v1' -or $adapter.deviations -cne 'None') {
    throw 'Standard v1 repository adapter identity or deviation contract is invalid.'
}
if ($adapter.authority.repository -cne 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git' -or
    $adapter.authority.commit -notmatch '^[0-9a-f]{40}$') {
    throw 'Standard authority repository or immutable commit is invalid.'
}
$expectedArchiveUrl = "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($adapter.authority.commit)"
if ($adapter.authority.archiveUrl -cne $expectedArchiveUrl) { throw 'Standard authority archive URL is not the exact approved immutable codeload path.' }
Assert-Sha256 -Value $adapter.authority.archiveSha256 -Context 'Authority archive identity'

$artifactsRootPath = [IO.Path]::GetFullPath($ArtifactsRoot)
if (Test-PathWithinOrEqual -Path $artifactsRootPath -Root $repoRoot) {
    throw 'Artifacts root must be outside the candidate repository.'
}
[void](New-Item -ItemType Directory -Path $artifactsRootPath -Force)
$artifactsItem = Get-Item -LiteralPath $artifactsRootPath -Force
if (-not $artifactsItem.PSIsContainer -or ($artifactsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Artifacts root must be a regular non-reparse directory.'
}
Assert-NoReparseAncestors -Path $artifactsRootPath -Context 'Artifacts root'
$runId = [guid]::NewGuid().ToString('N')
# Keep the on-disk prefix short enough for Windows venv and wheel paths; evidence retains the full run ID.
$runRoot = Join-Path $artifactsRootPath "sgv1-$($runId.Substring(0, 12))"
$authorityExtractRoot = Join-Path $runRoot 'authority'
$installRoot = Join-Path $runRoot 'tools'
if (Test-Path -LiteralPath $runRoot) { throw 'Run-owned artifacts path unexpectedly already exists.' }
[void](New-Item -ItemType Directory -Path $runRoot)
Assert-NoReparseAncestors -Path $runRoot -Context 'Run-owned artifacts path'
[void](New-Item -ItemType Directory -Path $authorityExtractRoot -Force)
[void](New-Item -ItemType Directory -Path $installRoot -Force)

# Bind the exact package/file inventory before any scanner is acquired or executed.
$integrityReportPath = Join-Path $runRoot 'candidate-integrity.json'
$integrityJson = & (Join-Path $repoRoot 'scripts/Test-Repository.ps1') -RepositoryRoot $repoRoot -OutputPath $integrityReportPath | Select-Object -Last 1
$integrityReport = $integrityJson | ConvertFrom-Json -Depth 100
if ($integrityReport.result -cne 'passed' -or [int]$integrityReport.activeSkillCount -le 0) {
    throw 'Candidate integrity verification did not bind a non-empty active Skill inventory.'
}
$skillIds = @($integrityReport.skills | ForEach-Object { [string]$_.skillId })

$archivePath = Join-Path $runRoot 'authority.zip'
if ([string]::IsNullOrWhiteSpace($AuthorityArchivePath)) {
    Invoke-WebRequest -Uri $adapter.authority.archiveUrl -OutFile $archivePath
}
else {
    $suppliedArchive = [IO.Path]::GetFullPath($AuthorityArchivePath)
    if (-not (Test-Path -LiteralPath $suppliedArchive -PathType Leaf)) { throw 'Supplied authority archive does not exist.' }
    Copy-Item -LiteralPath $suppliedArchive -Destination $archivePath
}
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
if ($archiveHash -cne [string]$adapter.authority.archiveSha256) { throw 'Authority archive SHA-256 does not match the approved immutable snapshot.' }
Expand-Archive -LiteralPath $archivePath -DestinationPath $authorityExtractRoot
$authorityRoots = @(Get-ChildItem -LiteralPath $authorityExtractRoot -Directory)
if ($authorityRoots.Count -ne 1 -or ($authorityRoots[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Authority archive must contain exactly one non-reparse repository root.'
}
$authorityRoot = $authorityRoots[0].FullName

$authorityFiles = @()
$seenAuthorityPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entry in @($adapter.authority.files)) {
    if ($entry.path -isnot [string] -or [string]$entry.path -cnotmatch '^[a-zA-Z0-9._/-]+$' -or
        [string]$entry.path -match '(^|/)\.\.?(/|$)' -or -not $seenAuthorityPaths.Add([string]$entry.path)) {
        throw 'Authority file inventory contains an unsafe or duplicate path.'
    }
    Assert-Sha256 -Value $entry.sha256 -Context "Authority file '$($entry.path)' identity"
    $authorityFile = Assert-PathWithinRoot -Path (Join-Path $authorityRoot ([string]$entry.path)) -Root $authorityRoot -Context 'Authority file'
    if (-not (Test-Path -LiteralPath $authorityFile -PathType Leaf)) { throw "Authority file is missing: $($entry.path)" }
    $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $authorityFile).Hash.ToLowerInvariant()
    if ($fileHash -cne [string]$entry.sha256) { throw "Authority file identity mismatch: $($entry.path)" }
    $authorityFiles += [pscustomobject][ordered]@{ path = [string]$entry.path; sha256 = $fileHash }
}
$requiredAuthorityFiles = @(
    'docs/standards/README.md',
    'docs/standards/managed-skill-lifecycle.md',
    'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json',
    'docs/standards/skill-repository-standard.md',
    'docs/standards/skill-repository-review-matrix.md',
    'docs/standards/upstream-interoperability.md',
    'docs/standards/validation-security-gate.json',
    'docs/standards/validation-toolchain.json',
    'docs/standards/schemas/validation-security-gate-v1.schema.json',
    'docs/standards/schemas/source-inventory-v2.schema.json',
    'docs/standards/schemas/openai-agent-metadata.schema.json',
    'scripts/Invoke-StandardAuthorityGate.ps1',
    'scripts/Resolve-StandardValidationTool.ps1',
    'scripts/Resolve-PythonWheelClosure.py'
)
foreach ($required in $requiredAuthorityFiles) {
    if (-not $seenAuthorityPaths.Contains($required)) { throw "Authority inventory does not bind required file '$required'." }
}

$standardPath = Join-Path $authorityRoot 'docs/standards/skill-repository-standard.md'
$standardText = Get-Content -LiteralPath $standardPath -Raw -Encoding UTF8
if ($standardText -cnotmatch '(?m)^# Agent Skill Repository Standard v1$' -or $standardText -cnotmatch '(?m)^Status: \*\*Normative\*\*$') {
    throw 'Verified authority snapshot does not identify normative Standard v1.'
}
$resolverPath = Join-Path $authorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
$policyPath = Join-Path $authorityRoot 'docs/standards/validation-toolchain.json'
$authorityGatePath = Join-Path $authorityRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
$validationSecurityGatePath = Join-Path $authorityRoot 'docs/standards/validation-security-gate.json'
. $authorityGatePath -DefineFunctionsOnly
$validationSecurityGate = Assert-AuthorityValidationSecurityGate `
    -Policy (Read-JsonFile -Path $validationSecurityGatePath -Context 'Validation/security gate policy')
$validationSecurityGatePolicySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $validationSecurityGatePath).Hash.ToLowerInvariant()

$policyReceiptPath = Join-Path $runRoot 'policy.json'
& $resolverPath -PolicyPath $policyPath -ValidatePolicyOnly -OutputPath $policyReceiptPath | Out-Host
$policyReceipt = Read-JsonFile -Path $policyReceiptPath -Context 'Validation tool policy receipt'
if ($policyReceipt.policy -cne 'latest-stable-per-validation-run' -or
    $policyReceipt.sourceTrust.enforcement -cne 'exact-approved-source' -or
    $policyReceipt.recordResolvedIdentityWhenAvailable -ne $true) {
    throw 'Validation tool policy receipt does not preserve the central trust contract.'
}

$expectedSources = [ordered]@{
    'skillspector' = 'NVIDIA/SkillSpector'
    'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    'skill-tools' = 'npm:skill-tools'
    'pester' = 'PowerShellGallery:Pester'
}
$receipts = [ordered]@{}
foreach ($toolName in $expectedSources.Keys) {
    $receiptPath = Join-Path $runRoot "receipt-$toolName.json"
    & $resolverPath -PolicyPath $policyPath -ToolName $toolName -Install -InstallRoot $installRoot -OutputPath $receiptPath | Out-Host
    $receipt = Read-JsonFile -Path $receiptPath -Context "$toolName resolver receipt"
    if ($receipt.toolName -cne $toolName -or $receipt.source -cne $expectedSources[$toolName] -or
        $receipt.channel -cne 'latest-stable' -or $receipt.frozenForRun -ne $true -or
        [string]::IsNullOrWhiteSpace([string]$receipt.resolvedVersion) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.resolvedIdentity)) {
        throw "$toolName receipt does not bind the approved frozen latest-stable identity."
    }
    $receipts[$toolName] = $receipt
    if ($toolName -ceq 'skillspector') {
        Remove-Item -LiteralPath 'Env:GITHUB_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue
    }
}

$skillSpectorPath = Assert-ReceiptFile -Receipt $receipts.skillspector -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'SkillSpector'
$skillValidatorPath = Assert-ReceiptFile -Receipt $receipts.'skill-validator' -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'skill-validator'
$skillToolsNodePath = Assert-ExternalReceiptFile -Receipt $receipts.'skill-tools' -PathProperty 'nodePath' -HashProperty 'nodeSha256' -Context 'skill-tools Node'
$skillToolsEntryPoint = Assert-ReceiptFile -Receipt $receipts.'skill-tools' -PathProperty 'entryPointPath' -HashProperty 'entryPointSha256' -InstallRoot $installRoot -Context 'skill-tools entry point'
$pesterModulePath = Assert-ReceiptFile -Receipt $receipts.pester -PathProperty 'modulePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'Pester module'

$securityFindings = @()
$securityBlockers = @()
$securityHumanReview = @()
$securityTracked = @()
$staticReports = @()
$staticFindingCount = 0
$skillValidatorReports = @()
$skillToolsReports = @()

# Stage 3: Package Validation. This must complete before any SkillSpector scan.
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $skillIntegrity = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($skillIntegrity.Count -ne 1) { throw "Candidate integrity evidence is ambiguous for '$skillId'." }
    $expectedInventoryPaths = @($skillIntegrity[0].files | ForEach-Object { [string]$_.path })
    $validatorOutput = Invoke-NativeChecked -Command $skillValidatorPath -Arguments @('-o', 'json', 'validate', 'structure', '--allow-dirs=agents', $skillRoot) -Context "skill-validator package validation for $skillId" -DiagnosticRoot $runRoot
    $validatorReportPath = Join-Path $runRoot "skill-validator-$skillId.json"
    [IO.File]::WriteAllText($validatorReportPath, $validatorOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $validatorReport = Read-JsonFile -Path $validatorReportPath -Context "skill-validator package validation report for $skillId"
    Assert-SkillValidatorReport -Report $validatorReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillValidatorReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($validatorReportPath) }
}

# Stage 4: SkillSpector Static.
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $skillIntegrity = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($skillIntegrity.Count -ne 1) { throw "Candidate integrity evidence is ambiguous for '$skillId'." }
    $expectedInventoryPaths = @($skillIntegrity[0].files | ForEach-Object { [string]$_.path })
    $reportPath = Join-Path $runRoot "skillspector-static-$skillId.json"
    [void](Invoke-NativeChecked -Command $skillSpectorPath -Arguments @('scan', $skillRoot, '--no-llm', '--format', 'json', '--output', $reportPath) -Context "SkillSpector static scan for $skillId" -DiagnosticRoot $runRoot)
    $report = Read-JsonFile -Path $reportPath -Context "SkillSpector static report for $skillId"
    $issues = @(Assert-SkillSpectorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId -ExpectedInventoryPaths $expectedInventoryPaths)
    foreach ($issue in $issues) {
        $reportedSeverity = Get-RequiredProperty -Object $issue -Name 'severity' -Context 'SkillSpector issue'
        if ($reportedSeverity -isnot [string] -or [string]::IsNullOrWhiteSpace($reportedSeverity)) {
            throw "SkillSpector returned an issue without severity for '$skillId'."
        }
        $finding = ConvertTo-ValidationSecurityFinding `
            -Policy $validationSecurityGate `
            -ReportedSeverity ([string]$reportedSeverity) `
            -Stage 'skillspector-static' `
            -SkillId $skillId `
            -Issue $issue
        $securityFindings += $finding
        $staticFindingCount++
        switch ([string]$finding.action) {
            'BLOCK' { $securityBlockers += $finding }
            'HUMAN_REVIEW_REQUIRED' { $securityHumanReview += $finding; $securityBlockers += $finding }
            'RECORD_AND_TRACK' { $securityTracked += $finding }
            default { throw "Central validation/security gate returned unsupported action '$($finding.action)'." }
        }
    }
    $staticReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($reportPath); findings = $issues.Count; files = $expectedInventoryPaths.Count }
}

# Stage 5: Repository Tests.
$repositoryReportPath = Join-Path $runRoot 'repository-validation.json'
$repositoryJson = & (Join-Path $repoRoot 'scripts/Test-Repository.ps1') -RepositoryRoot $repoRoot -OutputPath $repositoryReportPath | Select-Object -Last 1
$repositoryReport = $repositoryJson | ConvertFrom-Json -Depth 100
if ($repositoryReport.result -cne 'passed' -or [int]$repositoryReport.activeSkillCount -ne $skillIds.Count) {
    throw 'Repository validation did not cover the exact active Skill inventory.'
}
foreach ($skillId in $skillIds) {
    $before = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    $after = @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($before.Count -ne 1 -or $after.Count -ne 1 -or $before[0].contentSha256 -cne $after[0].contentSha256) {
        throw "Candidate Skill '$skillId' changed between integrity verification and repository validation."
    }
}
$diffArguments = if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    @($gitConfigArguments + @('-C', $repoRoot, 'diff', '--check', "$BaseCommit...HEAD"))
}
else {
    @($gitConfigArguments + @('-C', $repoRoot, 'diff-tree', '--check', '--root', '-r', 'HEAD'))
}
$diffOutput = @(& $gitPath @diffArguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Whitespace validation failed for the candidate event range.`n$($diffOutput -join [Environment]::NewLine)"
}

foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $expectedInventoryPaths = @(
        @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })[0].files |
            ForEach-Object { [string]$_.path }
    )
    $toolsOutput = Invoke-NativeChecked -Command $skillToolsNodePath -Arguments @($skillToolsEntryPoint, 'check', $skillRoot, '--format', 'sarif', '--fail-on', 'warning', '--min-score', '91') -Context "skill-tools repository test for $skillId" -DiagnosticRoot $runRoot
    $toolsReportPath = Join-Path $runRoot "skill-tools-$skillId.sarif.json"
    [IO.File]::WriteAllText($toolsReportPath, $toolsOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $toolsReport = Read-JsonFile -Path $toolsReportPath -Context "skill-tools report for $skillId"
    Assert-SkillToolsReport -Report $toolsReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillToolsReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($toolsReportPath) }
}

Remove-Module Pester -Force -ErrorAction SilentlyContinue
Import-Module $pesterModulePath -Force -ErrorAction Stop
$loadedPester = Get-Module Pester | Select-Object -First 1
if ($null -eq $loadedPester -or [string]$loadedPester.Version -cne [string]$receipts.pester.resolvedVersion) {
    throw 'The exact frozen Pester module was not imported.'
}
$pesterResult = Invoke-Pester -Path (Join-Path $repoRoot 'tests') -PassThru
if ($null -eq $pesterResult -or [int64]$pesterResult.TotalCount -le 0 -or [int64]$pesterResult.FailedCount -ne 0 -or
    [int64]$pesterResult.PassedCount + [int64]$pesterResult.SkippedCount -ne [int64]$pesterResult.TotalCount) {
    throw 'Pester repository regression did not complete successfully.'
}

$semanticTriggered = $staticFindingCount -gt 0 -or (Test-SecurityRelevantSkillChange -GitPath $gitPath -RepositoryRoot $repoRoot -BaseCommit $BaseCommit)
$semanticReports = @()
if ($semanticTriggered) {
    foreach ($skillId in $skillIds) {
        $skillRoot = Join-Path $repoRoot "skills/$skillId"
        $expectedInventoryPaths = @(
            @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })[0].files |
                ForEach-Object { [string]$_.path }
        )
        $semanticPath = Join-Path $runRoot "skillspector-semantic-$skillId.json"
        [void](Invoke-NativeChecked -Command $skillSpectorPath -Arguments @('scan', $skillRoot, '--format', 'json', '--output', $semanticPath) -Context "SkillSpector semantic scan for $skillId" -DiagnosticRoot $runRoot)
        $semanticReport = Read-JsonFile -Path $semanticPath -Context "SkillSpector semantic report for $skillId"
        try {
            $semanticIssues = @(Assert-SkillSpectorReport -Report $semanticReport -SkillRoot $skillRoot -SkillId $skillId -ExpectedInventoryPaths $expectedInventoryPaths)
        }
        catch {
            throw "Triggered SkillSpector semantic scan did not complete for '$skillId': $($_.Exception.Message)"
        }
        foreach ($issue in $semanticIssues) {
            $reportedSeverity = Get-RequiredProperty -Object $issue -Name 'severity' -Context 'SkillSpector semantic issue'
            if ($reportedSeverity -isnot [string] -or [string]::IsNullOrWhiteSpace($reportedSeverity)) {
                throw "SkillSpector semantic scan returned an issue without severity for '$skillId'."
            }
            $finding = ConvertTo-ValidationSecurityFinding `
                -Policy $validationSecurityGate `
                -ReportedSeverity ([string]$reportedSeverity) `
                -Stage 'conditional-semantic-scan' `
                -SkillId $skillId `
                -Issue $issue
            $securityFindings += $finding
            switch ([string]$finding.action) {
                'BLOCK' { $securityBlockers += $finding }
                'HUMAN_REVIEW_REQUIRED' { $securityHumanReview += $finding; $securityBlockers += $finding }
                'RECORD_AND_TRACK' { $securityTracked += $finding }
                default { throw "Central validation/security gate returned unsupported action '$($finding.action)'." }
            }
        }
        $semanticReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($semanticPath); findings = $semanticIssues.Count }
    }
}

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    standardVersion = 'v1'
    runId = $runId
    authority = [ordered]@{
        repository = [string]$adapter.authority.repository
        commit = [string]$adapter.authority.commit
        archiveSha256 = $archiveHash
        files = $authorityFiles
    }
    canonicalGate = [ordered]@{
        policy = [string]$validationSecurityGate.policy
        policyPath = 'docs/standards/validation-security-gate.json'
        policySha256 = $validationSecurityGatePolicySha256
        stageIds = @($validationSecurityGate.stages | ForEach-Object { [string]$_.id })
    }
    candidate = [ordered]@{
        repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
        commit = $candidateCommit
        baseCommit = $resolvedBaseCommit
    }
    tools = @($expectedSources.Keys | ForEach-Object {
        [pscustomobject][ordered]@{
            toolName = $_
            source = [string]$receipts[$_].source
            version = [string]$receipts[$_].resolvedVersion
            resolvedIdentity = [string]$receipts[$_].resolvedIdentity
        }
    })
    skills = @($repositoryReport.skills | ForEach-Object { [pscustomobject][ordered]@{ skillId = $_.skillId; contentSha256 = $_.contentSha256 } })
    security = [ordered]@{
        result = if (@($securityBlockers).Count -eq 0) { 'passed' } else { 'blocked' }
        findings = $securityFindings
        humanReviewRequired = $securityHumanReview
        blockingFindings = $securityBlockers
        trackedFindings = $securityTracked
    }
    stages = [ordered]@{
        controlledAcquisition = 'passed'
        integrityVerification = 'passed'
        packageValidation = $skillValidatorReports
        skillspectorStatic = $staticReports
        repositoryTests = [ordered]@{
            repositoryValidation = 'passed'
            skillTools = $skillToolsReports
            pester = [ordered]@{ result = 'passed'; total = [int]$pesterResult.TotalCount; passed = [int]$pesterResult.PassedCount; skipped = [int]$pesterResult.SkippedCount }
        }
        conditionalSemanticScan = [ordered]@{ triggered = $semanticTriggered; reports = $semanticReports }
        aiReview = 'required-before-release'
        humanApproval = 'required-before-release'
        publishOrInstall = 'blocked-until-approved-release'
        postInstallVerification = 'required-after-install'
    }
    deviations = 'None'
    result = if (@($securityBlockers).Count -eq 0) { 'passed' } else { 'blocked' }
}
$summaryJson = $summary | ConvertTo-Json -Depth 100
$summaryPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $runRoot 'conformance-report.json'
}
else {
    Assert-PathWithinRoot -Path ([IO.Path]::GetFullPath($OutputPath)) -Root $artifactsRootPath -Context 'Conformance output'
}
$summaryDirectory = Split-Path -Parent $summaryPath
if (-not [string]::IsNullOrWhiteSpace($summaryDirectory)) {
    [void](New-Item -ItemType Directory -Path $summaryDirectory -Force)
    Assert-NoReparseAncestors -Path $summaryDirectory -Context 'Conformance output directory'
}
if (Test-Path -LiteralPath $summaryPath) { throw 'Conformance output path already exists; evidence must not overwrite prior content.' }
[IO.File]::WriteAllText($summaryPath, $summaryJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
if (@($securityBlockers).Count -gt 0) {
    Write-Host "Darktide Translate Standard v1 canonical validation blocked by the central security gate. Evidence: $summaryPath"
}
else {
    Write-Host "Darktide Translate Standard v1 canonical validation passed. Evidence: $summaryPath"
}
$summaryJson
if (@($securityBlockers).Count -gt 0) {
    throw 'Canonical validation/security gate blocked the candidate; resolve central findings and obtain required Human Review before release or install.'
}
