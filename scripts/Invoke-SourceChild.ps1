# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

# Darktide Translate Core v2 source child. The protected source driver copies
# these exact bytes into its run-owned setup root, freezes them, and dispatches
# one mode per Core v2 source slot. The child never reads candidate scripts.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('package-adapter', 'skill-validator', 'skill-tools', 'static')][string] $Mode,
    [Parameter(Mandatory = $true)][string] $ToolchainPath,
    [Parameter(Mandatory = $true)][string] $ToolchainSha256,
    [Parameter(Mandatory = $true)][string] $DriverModulePath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string] $DriverModuleSha256,
    [Parameter(Mandatory = $true)][string] $AuthorityRuntimeManifestPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $AuthorityRevision,
    [ValidateRange(1, 86400)][int] $TimeoutSeconds = 900
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The driver writes a protected-base copy into the run-owned setup root and
# binds its exact bytes in the adapter frozen-file inventory. Load those bytes
# as a dynamic module so no candidate pathname is ever imported and pathname
# replacement after the read cannot change the executed module.
$driverStream = [IO.FileStream]::new([IO.Path]::GetFullPath($DriverModulePath), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { $driverBytes = [byte[]]::new($driverStream.Length); $driverStream.ReadExactly($driverBytes) }
finally { $driverStream.Dispose() }
if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($driverBytes)).ToLowerInvariant() -cne $DriverModuleSha256) {
    throw 'Frozen protected source driver bytes changed.'
}
$driverText = [Text.UTF8Encoding]::new($false, $true).GetString($driverBytes)
$driverModule = New-Module -Name 'DarktideFrozenSourceDriver' -ScriptBlock ([scriptblock]::Create($driverText))
Import-Module -ModuleInfo $driverModule -Force -ErrorAction Stop
$authorityManifest = [IO.Path]::GetFullPath($AuthorityRuntimeManifestPath)
if ([IO.Path]::GetFileName($authorityManifest) -cne 'platform-runtime.psd1' -or
    [IO.Path]::GetFileName((Split-Path -Parent $authorityManifest)) -cne 'scripts') {
    throw 'Frozen authority runtime manifest has an unexpected layout.'
}
$authorityRoot = Split-Path -Parent (Split-Path -Parent $authorityManifest)
$platformRuntimeModule = Import-DarktideAuthorityPlatformRuntime -AuthorityRoot $authorityRoot -AuthorityRevision $AuthorityRevision
Import-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction Stop

function Open-ChildFile {
    param([Parameter(Mandatory)][string] $Path, [string] $Access = 'Read', [string] $CreateMode = 'OpenExisting')
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($full)) -RootOnly
    try {
        $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access $Access -CreateMode $CreateMode
        $identity = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink -VerifyPath
        return [pscustomobject]@{ Parent=$parent; File=$file; Identity=$identity; Path=$full }
    }
    catch { $parent.Dispose(); throw }
}
function Close-ChildFile { param([Parameter(Mandatory)]$Binding) try { $Binding.File.Dispose() } finally { $Binding.Parent.Dispose() } }
function Test-ChildFile {
    param([Parameter(Mandatory)][string]$Path)
    $binding=$null
    try { $binding=Open-ChildFile -Path $Path; return $true } catch { return $false }
    finally { if($null-ne$binding){Close-ChildFile $binding} }
}
function Test-ChildDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $lease=$null
    try { $lease=Open-PlatformDirectory -Root ([IO.Path]::GetFullPath($Path)) -RootOnly; return $true } catch { return $false }
    finally { if($null-ne$lease){$lease.Dispose()} }
}
function Write-ChildUtf8CreateNew {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $binding=Open-ChildFile -Path $Path -Access ReadWrite -CreateMode CreateNew
    try {
        $binding.File.WriteNewBytes([Text.UTF8Encoding]::new($false).GetBytes($Text))
        [void](Assert-PlatformFileIdentity -Lease $binding.File -Expected $binding.Identity -SingleLink -VerifyPath)
    } finally { Close-ChildFile $binding }
}
function Read-ChildText {
    param([Parameter(Mandatory)][string]$Path,[int]$Limit=268435456)
    $binding=Open-ChildFile -Path $Path
    try {
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($binding.File.ReadAllBytes($Limit))
        [void](Assert-PlatformFileIdentity -Lease $binding.File -Expected $binding.Identity -SingleLink -VerifyPath)
        return $text
    } finally { Close-ChildFile $binding }
}
function Remove-ChildOwnedFile {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-ChildFile -Path $Path)){return}
    $binding=Open-ChildFile -Path $Path -Access ReadWrite
    $state=$binding.File.Observation
    $binding.File.Dispose()
    try { Remove-PlatformOwnedFile -ParentLease $binding.Parent -Leaf ([IO.Path]::GetFileName($binding.Path)) -ExpectedState $state | Out-Null }
    finally { $binding.Parent.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    $binding=Open-ChildFile -Path $Path
    try {
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($binding.File.ReadAllBytes(268435456))).ToLowerInvariant()
        [void](Assert-PlatformFileIdentity -Lease $binding.File -Expected $binding.Identity -SingleLink -VerifyPath)
        return $hash
    } finally { Close-ChildFile $binding }
}
function Assert-FileIdentity {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Sha256, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-ChildFile -Path $Path) -or (Get-FileSha256 -Path $Path) -cne $Sha256) { throw "$Context changed or is missing." }
}
function Get-Property {
    param([Parameter(Mandatory = $true)] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { throw "$Context is missing '$Name'." }
    return $Object.PSObject.Properties[$Name].Value
}
function Read-Json {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    try { return (Read-ChildText -Path $Path | ConvertFrom-Json -Depth 100) }
    catch { throw "$Context is not valid JSON: $($_.Exception.Message)" }
}
function Test-PathEqual {
    param([Parameter(Mandatory = $true)][string] $Left, [Parameter(Mandatory = $true)][string] $Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right), $comparison)
}
function Test-PathWithin {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}
function Get-ActiveSkills {
    $values = @([string]$env:STANDARD_VALIDATION_ACTIVE_SKILLS -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { throw 'Central runner did not provide active Skill identities.' }
    return [string[]]$values
}
function Get-SkillRoot {
    param([Parameter(Mandatory = $true)][string] $SkillId)
    $skillsRoot = [IO.Path]::GetFullPath([string]$env:STANDARD_VALIDATION_SKILLS_ROOT)
    $skillRoot = [IO.Path]::GetFullPath((Join-Path $skillsRoot $SkillId))
    if (-not (Test-PathWithin -Path $skillRoot -Root $skillsRoot) -or -not (Test-ChildDirectory -Path $skillRoot)) {
        throw "Central runner supplied an unsafe or missing Skill root: $SkillId"
    }
    return $skillRoot
}
function Get-InventoryPaths {
    param([Parameter(Mandatory = $true)][string] $SkillRoot)
    $root = [IO.Path]::GetFullPath($SkillRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootLease=Open-PlatformDirectory -Root $root -RootOnly
    try { $paths = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            ForEach-Object { $_.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace([IO.Path]::DirectorySeparatorChar, '/') }
    ) } finally { $rootLease.Dispose() }
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    if ($paths.Count -eq 0) { throw "Skill inventory is empty: $SkillRoot" }
    return [string[]]$paths
}
function Resolve-ReportedFilePath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $SkillRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw "$Context must identify a file." }
    $candidate = [string]$Value
    if ($candidate -cmatch '^file:') {
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) { throw "$Context must be a local file." }
        $candidate = $uri.LocalPath
    }
    elseif (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $SkillRoot $candidate }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-PathWithin -Path $full -Root $SkillRoot)) { throw "$Context escapes the Skill root." }
    foreach ($relative in $ExpectedPaths) {
        if (Test-PathEqual -Left $full -Right (Join-Path $SkillRoot $relative)) { return $full }
    }
    throw "$Context is outside the candidate-bound inventory."
}
function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string] $Text)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
function New-Finding {
    param([Parameter(Mandatory = $true)] $Issue, [Parameter(Mandatory = $true)][string] $SkillId, [Parameter(Mandatory = $true)][string] $Stage)
    $severity = [string](Get-Property -Object $Issue -Name 'severity' -Context "$Stage issue").ToLowerInvariant()
    $severity = switch ($severity) {
        'critical' { 'critical'; break }
        'high' { 'high'; break }
        'medium' { 'medium'; break }
        'low' { 'low'; break }
        'informational' { 'informational'; break }
        'info' { 'informational'; break }
        default { throw "$Stage returned unsupported severity '$severity' for '$SkillId'." }
    }
    $issueJson = $Issue | ConvertTo-Json -Depth 30 -Compress
    $path = if ($null -ne $Issue.PSObject.Properties['file']) { [string]$Issue.file } elseif ($null -ne $Issue.PSObject.Properties['path']) { [string]$Issue.path } else { '' }
    return [ordered]@{
        severity = $severity
        fingerprint = Get-TextSha256 -Text $issueJson
        ruleId = if ($null -ne $Issue.PSObject.Properties['rule_id']) { [string]$Issue.rule_id } elseif ($null -ne $Issue.PSObject.Properties['ruleId']) { [string]$Issue.ruleId } else { $Stage }
        message = if ($null -ne $Issue.PSObject.Properties['message']) { [string]$Issue.message } else { $issueJson }
        path = $path
        skillId = $SkillId
    }
}
function New-Envelope {
    param(
        [Parameter(Mandatory = $true)][string[]] $ActiveSkills,
        [array] $Findings = @(),
        [hashtable] $Additional
    )
    $value = [ordered]@{
        schemaVersion = 1
        status = 'passed'
        decision = 'PASS'
        candidateIdentity = [string]$env:STANDARD_VALIDATION_CANDIDATE_ID
        activeSkills = @($ActiveSkills)
        findings = @($Findings)
    }
    if ($Mode -cin @('skill-validator', 'skill-tools', 'static')) { $value.nativeReports = @($script:NativeReports) }
    if ($null -ne $Additional) {
        foreach ($key in $Additional.Keys) { $value[$key] = $Additional[$key] }
    }
    [Console]::Out.WriteLine(($value | ConvertTo-Json -Depth 100 -Compress))
    exit 0
}
$script:NativeReports = @()
function Add-NativeReport {
    param([Parameter(Mandatory = $true)][string] $Command, [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][int] $ExitCode, [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SkillId)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-ChildFile -Path $fullPath)) { throw 'Native tool did not create its raw report file.' }
    $script:NativeReports += [pscustomobject][ordered]@{
        skillId = $SkillId
        command = [IO.Path]::GetFullPath($Command)
        commandSha256 = Get-FileSha256 -Path $Command
        arguments = @($Arguments)
        exitCode = $ExitCode
        path = $fullPath
        sha256 = Get-FileSha256 -Path $fullPath
    }
}
function Invoke-ChildOwnedCommand {
    param([Parameter(Mandatory)][string] $Command, [Parameter(Mandatory)][string[]] $Arguments)
    $commandBinding=$null; $executableBinding=$null; $workingLease=$null; $process=$null; $cleanup=$null; $exitCode=$null; $timedOut=$false
    $captureId=[guid]::NewGuid().ToString('N')
    $stdoutPath=Join-Path (Get-Location) "$captureId.stdout"
    $stderrPath=Join-Path (Get-Location) "$captureId.stderr"
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        $commandBinding=Open-ChildFile -Path $Command
        $extension=[IO.Path]::GetExtension($commandBinding.Path).ToLowerInvariant()
        if($extension -eq '.ps1'){
            $hostPath=[IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
            $executableBinding=Open-ChildFile -Path $hostPath
            $launchArguments=@('-NoProfile','-NonInteractive','-File',$commandBinding.Path)+$Arguments
            $argumentZero=$hostPath
        } else {
            $executableBinding=$commandBinding
            $launchArguments=$Arguments
            $argumentZero=$commandBinding.Path
        }
        $environment=@{}; foreach($entry in Get-ChildItem Env:){if($null-ne$entry.Value){$environment[[string]$entry.Name]=[string]$entry.Value}}
        $workingLease=Open-PlatformDirectory -Root ([IO.Path]::GetFullPath((Get-Location).Path)) -RootOnly
        $process=Start-PlatformOwnedProcess -ExecutableLease $executableBinding.File -ArgumentZero $argumentZero -ArgumentList $launchArguments `
            -Environment $environment -WorkingDirectoryLease $workingLease -Deadline $deadline -StdoutPath $stdoutPath -StderrPath $stderrPath -OutputLimitCharacters 1048576
        while(-not $process.HasExited -and [DateTimeOffset]::UtcNow -lt $deadline){[void]$process.WaitForExit([TimeSpan]::FromMilliseconds(50))}
        $timedOut=-not $process.HasExited
        if(-not $timedOut){$exitCode=[int]$process.ExitCode}
    }
    finally {
        if($null-ne$process){
            try{$cleanup=Stop-PlatformOwnedProcess -Lease $process -ExpectedStartIdentity $process.StartIdentity -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)); if($null -eq $exitCode -and $process.HasExited){$exitCode=[int]$process.ExitCode}}
            finally{$process.Dispose()}
        }
        if($null-ne$workingLease){$workingLease.Dispose()}
        if($null-ne$commandBinding){[void](Assert-PlatformFileIdentity -Lease $commandBinding.File -Expected $commandBinding.Identity -SingleLink -VerifyPath)}
        if($null-ne$executableBinding-and$executableBinding-ne$commandBinding){Close-ChildFile $executableBinding}
        if($null-ne$commandBinding){Close-ChildFile $commandBinding}
    }
    if(-not (Test-DarktideOwnedProcessCleanupReceipt -Receipt $cleanup)){throw 'Native tool cleanup could not be verified.'}
    if($timedOut){throw "Native tool exceeded its $TimeoutSeconds second deadline."}
    $stdout=if(Test-ChildFile $stdoutPath){Read-ChildText $stdoutPath}else{''}
    $stderr=if(Test-ChildFile $stderrPath){Read-ChildText $stderrPath}else{''}
    # Captures are run-owned evidence. Keep them create-only; the enclosing CI
    # run root owns eventual cleanup, so no P11 directory mutation is needed.
    return [pscustomobject]@{exitCode=[int]$exitCode;stdout=$stdout;stderr=$stderr}
}
function Invoke-NativeJson {
    param([Parameter(Mandatory = $true)][string] $Command, [Parameter(Mandatory = $true)][string[]] $Arguments, [Parameter(Mandatory = $true)][string] $Context)
    try {
        $process = Invoke-ChildOwnedCommand -Command $Command -Arguments $Arguments
        $exitCode = [int]$process.exitCode
        $stderr = [string]$process.stderr
        $json = ([string]$process.stdout).Trim()
        $nativePath = Join-Path (Get-Location) ("native-$Mode-$($env:STANDARD_VALIDATION_SKILL_ID).json")
        Write-ChildUtf8CreateNew -Path $nativePath -Text $json
        Add-NativeReport -Command $Command -Arguments $Arguments -ExitCode $exitCode -Path $nativePath -SkillId ([string]$env:STANDARD_VALIDATION_SKILL_ID)
        if ($exitCode -ne 0) { throw "$Context returned exit code $exitCode. $stderr" }
        if ([string]::IsNullOrWhiteSpace($json)) { throw "$Context produced no JSON output." }
        return ($json | ConvertFrom-Json -Depth 100)
    }
    finally { }
}
function Invoke-DomainJson {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $ReportName
    )
    try {
        $process = Invoke-ChildOwnedCommand -Command $Command -Arguments $Arguments
        $exitCode = [int]$process.exitCode
        $stderr = [string]$process.stderr
        $json = ([string]$process.stdout).Trim()
        $reportPath = Join-Path (Get-Location) $ReportName
        if (Test-ChildFile -Path $reportPath) { throw "$Context report path already exists." }
        Write-ChildUtf8CreateNew -Path $reportPath -Text $json
        if ($exitCode -ne 0) { throw "$Context returned exit code $exitCode. $stderr" }
        if ([string]::IsNullOrWhiteSpace($json)) { throw "$Context produced no JSON output." }
        return ($json | ConvertFrom-Json -Depth 100)
    }
    finally { }
}
function Assert-SkillValidatorReport {
    param([Parameter(Mandatory = $true)] $Report, [Parameter(Mandatory = $true)][string] $SkillRoot, [Parameter(Mandatory = $true)][string[]] $Inventory, [Parameter(Mandatory = $true)][string] $SkillId)
    $results = @(Assert-StandardValidationSkillValidatorReport -Report $Report -SkillRoot $SkillRoot -SkillId $SkillId)
    $findings = @()
    foreach ($result in $results) {
        $level = [string](Get-Property -Object $result -Name 'level' -Context 'skill-validator result')
        if ($null -ne $result.PSObject.Properties['file']) {
            [void](Resolve-ReportedFilePath -Value $result.file -SkillRoot $SkillRoot -ExpectedPaths $Inventory -Context 'skill-validator result file')
        }
        if ($level -eq 'info') {
            $findings += [ordered]@{ severity = 'informational'; fingerprint = Get-TextSha256 -Text ($result | ConvertTo-Json -Depth 20 -Compress); ruleId = [string]$result.category; message = [string]$result.message; path = if ($null -ne $result.PSObject.Properties['file']) { [string]$result.file } else { '' }; skillId = $SkillId }
        }
    }
    return ,$findings
}
function Assert-SkillToolsReport {
    param([Parameter(Mandatory = $true)] $Report, [Parameter(Mandatory = $true)][string] $SkillRoot, [Parameter(Mandatory = $true)][string[]] $Inventory, [Parameter(Mandatory = $true)][string] $SkillId)
    $version = [string](Get-Property -Object $Report -Name 'version' -Context 'skill-tools SARIF')
    $runs = @(Get-Property -Object $Report -Name 'runs' -Context 'skill-tools SARIF')
    if ($version -cne '2.1.0' -or $runs.Count -ne 1) { throw "skill-tools did not produce SARIF 2.1.0 for '$SkillId'." }
    $run = $runs[0]
    $driver = Get-Property -Object (Get-Property -Object $run -Name 'tool' -Context 'skill-tools SARIF run') -Name 'driver' -Context 'skill-tools SARIF tool'
    $driverName = [string](Get-Property -Object $driver -Name 'name' -Context 'skill-tools SARIF driver')
    $rules = @(Get-Property -Object $driver -Name 'rules' -Context 'skill-tools SARIF driver')
    $results = @(Get-Property -Object $run -Name 'results' -Context 'skill-tools SARIF run')
    if ($driverName -cne 'skill-tools') { throw "skill-tools SARIF driver identity is invalid for '$SkillId'." }
    $ruleById = @{}
    foreach ($rule in $rules) { $ruleById[[string](Get-Property -Object $rule -Name 'id' -Context 'skill-tools SARIF rule')] = $rule }
    $findings = @()
    foreach ($result in $results) {
        $ruleId = [string](Get-Property -Object $result -Name 'ruleId' -Context 'skill-tools SARIF result')
        if (-not $ruleById.ContainsKey($ruleId)) { throw "skill-tools SARIF references an unknown rule for '$SkillId'." }
        $level = if ($null -ne $result.PSObject.Properties['level']) { [string]$result.level } else {
            [string](Get-Property -Object (Get-Property -Object $ruleById[$ruleId] -Name 'defaultConfiguration' -Context 'skill-tools SARIF rule') -Name 'level' -Context 'skill-tools SARIF rule default')
        }
        if ($level -notin @('none', 'note', 'warning', 'error')) { throw "skill-tools SARIF level is malformed for '$SkillId'." }
        if ($level -in @('warning', 'error')) { throw "skill-tools SARIF contains a blocking result for '$SkillId'." }
        $message = Get-Property -Object $result -Name 'message' -Context 'skill-tools SARIF result'
        $locations = @(Get-Property -Object $result -Name 'locations' -Context 'skill-tools SARIF result')
        if ([string]::IsNullOrWhiteSpace([string](Get-Property -Object $message -Name 'text' -Context 'skill-tools SARIF message')) -or $locations.Count -eq 0) { throw "skill-tools SARIF lacks candidate-bound evidence for '$SkillId'." }
        foreach ($location in $locations) {
            $physical = Get-Property -Object $location -Name 'physicalLocation' -Context 'skill-tools SARIF location'
            $artifact = Get-Property -Object $physical -Name 'artifactLocation' -Context 'skill-tools SARIF physical location'
            [void](Resolve-ReportedFilePath -Value (Get-Property -Object $artifact -Name 'uri' -Context 'skill-tools SARIF artifact location') -SkillRoot $SkillRoot -ExpectedPaths $Inventory -Context 'skill-tools SARIF artifact location')
        }
        if ($level -eq 'note') {
            $findings += [ordered]@{ severity = 'informational'; fingerprint = Get-TextSha256 -Text ($result | ConvertTo-Json -Depth 20 -Compress); ruleId = $ruleId; message = [string]$message.text; path = ''; skillId = $SkillId }
        }
    }
    return ,$findings
}
function Assert-SkillSpectorReport {
    param([Parameter(Mandatory = $true)] $Report, [Parameter(Mandatory = $true)][string] $SkillRoot, [Parameter(Mandatory = $true)][string] $SkillId, [Parameter(Mandatory = $true)][string[]] $Inventory)
    $execution = Get-Property -Object $Report -Name 'execution_successful' -Context 'SkillSpector report'
    $completeness = Get-Property -Object $Report -Name 'analysis_completeness' -Context 'SkillSpector report'
    if ($execution -isnot [bool] -or -not $execution -or
        (Get-Property -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-Property -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -or
        (Get-Property -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-Property -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -or
        [string](Get-Property -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -cne 'complete' -or
        [double](Get-Property -Object $completeness -Name 'coverage_percent' -Context 'SkillSpector completeness') -ne 100) {
        throw "SkillSpector did not prove complete static analysis for '$SkillId'."
    }
    foreach ($name in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
        if (@(Get-Property -Object $completeness -Name $name -Context 'SkillSpector completeness').Count -ne 0) { throw "SkillSpector reported incomplete '$name' evidence for '$SkillId'." }
    }
    $skill = Get-Property -Object $Report -Name 'skill' -Context 'SkillSpector report'
    if ([string](Get-Property -Object $skill -Name 'name' -Context 'SkillSpector skill identity') -cne $SkillId -or
        -not (Test-PathEqual -Left ([string](Get-Property -Object $skill -Name 'source' -Context 'SkillSpector skill identity')) -Right $SkillRoot)) {
        throw "SkillSpector report identity does not match '$SkillId'."
    }
    $components = @(Get-Property -Object $Report -Name 'components' -Context 'SkillSpector report')
    if ($components.Count -ne $Inventory.Count) { throw "SkillSpector did not cover the exact inventory for '$SkillId'." }
    $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($component in $components) {
        $path = [string](Get-Property -Object $component -Name 'path' -Context 'SkillSpector component')
        if (-not ($Inventory -ccontains $path) -or -not $observed.Add($path)) { throw "SkillSpector did not cover the exact inventory for '$SkillId'." }
    }
    $issuesProperty = $Report.PSObject.Properties['issues']
    if ($null -eq $issuesProperty -or $issuesProperty.Value -isnot [array]) { throw "SkillSpector issues must be an array for '$SkillId'." }
    $issuesValue = $issuesProperty.Value
    $issues = @($issuesValue)
    $findings = @()
    foreach ($issue in $issues) { $findings += New-Finding -Issue $issue -SkillId $SkillId -Stage 'skillspector-static' }
    return ,$findings
}

try {
    $toolchain = Read-Json -Path $ToolchainPath -Context 'run-owned validation toolchain'
    Assert-FileIdentity -Path $ToolchainPath -Sha256 $ToolchainSha256 -Context 'run-owned validation toolchain'
    $candidateRoot = [IO.Path]::GetFullPath([string]$env:STANDARD_VALIDATION_CANDIDATE_ROOT)
    if ($Mode -cin @('skill-validator', 'package-adapter')) {
        Assert-FileIdentity -Path ([string]$toolchain.centralRunnerPath) -Sha256 ([string]$toolchain.centralRunnerSha256) -Context 'central validation runner'
        $sharedReportFunctions = & {
            param($RunnerPath, $CandidateRoot, $ToolchainPath)
            . $RunnerPath -DefineFunctionsOnly -CandidateRoot $CandidateRoot -AdapterPath $ToolchainPath `
                -ArtifactsRoot ([IO.Path]::GetFullPath((Get-Location).Path)) -SourceRepository 'https://example.test' `
                -SourceRevision ('0' * 40) -BaseRevision ('0' * 40)
            $exports = @{}
            foreach ($name in @(
                'Get-StandardValidationFullPath',
                'Get-StandardValidationCaseVariant',
                'Get-StandardValidationPathCaseBehavior',
                'Get-StandardValidationPathComparison',
                'Test-StandardValidationSameResolvedPath',
                'Assert-StandardValidationSkillValidatorReport'
            )) {
                $exports[$name] = (Get-Command $name -CommandType Function -ErrorAction Stop).ScriptBlock
            }
            return $exports
        } ([string]$toolchain.centralRunnerPath) $candidateRoot $ToolchainPath
        foreach ($name in $sharedReportFunctions.Keys) {
            Set-Item -Path "function:$name" -Value $sharedReportFunctions[$name]
        }
    }
    $activeSkills = @(Get-ActiveSkills)
    $candidateId = [string]$env:STANDARD_VALIDATION_CANDIDATE_ID
    if ([string]::IsNullOrWhiteSpace($candidateId)) { throw 'Central runner did not provide a candidate identity.' }

    switch ($Mode) {
        'package-adapter' {
            # Darktide domain package contract (v1 Stage 3 strict check and the
            # Stage 5 route contract). Every invocation must pass; any failure
            # fails the whole package-adapter slot.
            Assert-FileIdentity -Path ([string]$toolchain.skillValidatorPath) -Sha256 ([string]$toolchain.skillValidatorSha256) -Context 'skill-validator executable'
            Assert-FileIdentity -Path ([string]$toolchain.skillToolsNodePath) -Sha256 ([string]$toolchain.skillToolsNodeSha256) -Context 'skill-tools Node runtime'
            Assert-FileIdentity -Path ([string]$toolchain.skillToolsEntryPointPath) -Sha256 ([string]$toolchain.skillToolsEntryPointSha256) -Context 'skill-tools entry point'
            $findings = @()
            $strictChecks = @()
            foreach ($skillId in $activeSkills) {
                $skillRoot = Get-SkillRoot -SkillId $skillId
                $inventory = Get-InventoryPaths -SkillRoot $skillRoot
                $report = Invoke-DomainJson -Command ([string]$toolchain.skillValidatorPath) -Arguments @('check', '--strict', '--allow-dirs=agents', '-o', 'json', $skillRoot) -Context "skill-validator strict check '$skillId'" -ReportName "domain-skill-validator-check-$skillId.json"
                $findings += Assert-SkillValidatorReport -Report $report -SkillRoot $skillRoot -Inventory $inventory -SkillId $skillId
                $strictChecks += $skillId
            }
            $skillsRoot = [IO.Path]::GetFullPath([string]$env:STANDARD_VALIDATION_SKILLS_ROOT)
            $routeCases = @(
                [pscustomobject]@{ query = 'Update a Warhammer 40,000 DARKTIDE MOD from a verified Nexus Main file and preserve active zh-tw'; expected = 'auto-update-darktide-mod' },
                [pscustomobject]@{ query = 'Resume a DARKTIDE MOD update run using its exact evidence and finalize the merge'; expected = 'auto-update-darktide-mod' }
            )
            $routeResults = @()
            $routeIndex = 0
            foreach ($routeCase in $routeCases) {
                if ($activeSkills -cnotcontains [string]$routeCase.expected) { throw "Route contract expects inactive Skill '$($routeCase.expected)'." }
                $routeReport = Invoke-DomainJson -Command ([string]$toolchain.skillToolsNodePath) -Arguments @([string]$toolchain.skillToolsEntryPointPath, 'route', [string]$routeCase.query, '--skills', $skillsRoot, '--top-k', '1', '--format', 'json') -Context "skill-tools route '$($routeCase.query)'" -ReportName "domain-skill-tools-route-$routeIndex.json"
                $selected = @($routeReport)
                if ($selected.Count -ne 1) { throw "skill-tools route did not return exactly one result for '$($routeCase.query)'." }
                $routeSkill = Get-Property -Object $selected[0] -Name 'skill' -Context 'skill-tools route result'
                if ($routeSkill -isnot [string] -or [string]$routeSkill -cne [string]$routeCase.expected) {
                    throw "skill-tools route selected '$routeSkill' for '$($routeCase.query)'; expected '$($routeCase.expected)'."
                }
                $routeResults += [ordered]@{ query = [string]$routeCase.query; expected = [string]$routeCase.expected; selected = [string]$routeSkill }
                $routeIndex++
            }
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ adapterStatus = 'passed'; domainContract = 'darktide-translate-package-v1'; strictChecks = @($strictChecks); routeResults = @($routeResults); semanticRequired = $false }
        }
        'skill-validator' {
            $skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
            $skillRoot = Get-SkillRoot -SkillId $skillId
            $inventory = Get-InventoryPaths -SkillRoot $skillRoot
            Assert-FileIdentity -Path ([string]$toolchain.skillValidatorPath) -Sha256 ([string]$toolchain.skillValidatorSha256) -Context 'skill-validator executable'
            $report = Invoke-NativeJson -Command ([string]$toolchain.skillValidatorPath) -Arguments @('-o', 'json', 'validate', 'structure', '--allow-dirs=agents', $skillRoot) -Context "skill-validator '$skillId'"
            $findings = Assert-SkillValidatorReport -Report $report -SkillRoot $skillRoot -Inventory $inventory -SkillId $skillId
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ skillId = $skillId; skillInventorySha256 = [string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256; semanticRequired = $false }
        }
        'skill-tools' {
            $skillId = [string]$env:STANDARD_VALIDATION_SKILL_ID
            $skillRoot = Get-SkillRoot -SkillId $skillId
            $inventory = Get-InventoryPaths -SkillRoot $skillRoot
            Assert-FileIdentity -Path ([string]$toolchain.skillToolsNodePath) -Sha256 ([string]$toolchain.skillToolsNodeSha256) -Context 'skill-tools Node runtime'
            Assert-FileIdentity -Path ([string]$toolchain.skillToolsEntryPointPath) -Sha256 ([string]$toolchain.skillToolsEntryPointSha256) -Context 'skill-tools entry point'
            $report = Invoke-NativeJson -Command ([string]$toolchain.skillToolsNodePath) -Arguments @([string]$toolchain.skillToolsEntryPointPath, 'check', $skillRoot, '--format', 'sarif', '--fail-on', 'warning', '--min-score', '91') -Context "skill-tools '$skillId'"
            $findings = Assert-SkillToolsReport -Report $report -SkillRoot $skillRoot -Inventory $inventory -SkillId $skillId
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ skillId = $skillId; skillInventorySha256 = [string]$env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256; semanticRequired = $false }
        }
        'static' {
            Assert-FileIdentity -Path ([string]$toolchain.skillSpectorPath) -Sha256 ([string]$toolchain.skillSpectorSha256) -Context 'SkillSpector executable'
            # Keep Python import caches outside the frozen installed tool closure.
            $env:PYTHONDONTWRITEBYTECODE = '1'
            # Preserve the v1 SkillSpector workflow budget; the central runner owns the process deadline.
            $env:SKILLSPECTOR_MAX_WORKFLOW_SECONDS = '1200'
            $findings = @()
            foreach ($skillId in $activeSkills) {
                $skillRoot = Get-SkillRoot -SkillId $skillId
                $inventory = Get-InventoryPaths -SkillRoot $skillRoot
                $reportPath = Join-Path (Get-Location) ("skillspector-$skillId.json")
                if (Test-ChildFile -Path $reportPath) { throw "SkillSpector stdout report path already exists for '$skillId'." }
                $nativeArguments = @('scan', $skillRoot, '--no-llm', '--format', 'json')
                $nativeProcess = Invoke-ChildOwnedCommand -Command ([string]$toolchain.skillSpectorPath) -Arguments $nativeArguments
                $nativeExit = [int]$nativeProcess.exitCode
                $staticStderr = [string]$nativeProcess.stderr
                Write-ChildUtf8CreateNew -Path $reportPath -Text ([string]$nativeProcess.stdout).Trim()
                if (-not [string]::IsNullOrEmpty($staticStderr) -and $staticStderr.Length -gt 4096) { $staticStderr = $staticStderr.Substring(0, 4096) + '[truncated]' }
                $staticStderrDiagnostic = if ([string]::IsNullOrWhiteSpace($staticStderr)) { '' } else { " SkillSpector stderr: $staticStderr" }
                Add-NativeReport -Command ([string]$toolchain.skillSpectorPath) -Arguments $nativeArguments -ExitCode $nativeExit -Path $reportPath -SkillId $skillId
                if ($nativeExit -ne 0) { throw "SkillSpector returned exit code $nativeExit for '$skillId'.$staticStderrDiagnostic" }
                try {
                    $report = Read-Json -Path $reportPath -Context "SkillSpector report for '$skillId'"
                }
                catch {
                    throw "Could not read SkillSpector report for '$skillId'.$staticStderrDiagnostic $($_.Exception.Message)"
                }
                $findings += Assert-SkillSpectorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId -Inventory $inventory
            }
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ scannerIdentity = 'SkillSpector'; analyzerCompleteness = 'complete'; semanticRequired = $false }
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
