# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

# Workflow-leg helpers executed from the protected event-base `driver/`
# checkout: protected helper blob verification, platform leg receipts and
# the three-platform receipt-set verification used by the aggregate job.

Set-StrictMode -Version Latest

$script:DarktideProtectedDriverHelperPaths = @(
    'scripts/Validate.ps1',
    'scripts/StandardSourceDriver.psm1',
    'scripts/Invoke-SourceChild.ps1',
    'scripts/StandardWorkflowLeg.psm1',
    'scripts/Prepare-WorkflowPowerShell.ps1',
    'scripts/PowerShellRelease.psm1',
    'scripts/Prepare-PesterRuntime.ps1',
    'scripts/CorePesterIntegrity.psm1',
    'config/pester-6.2.0-closure.lock.json'
)
$script:DarktideLegReceiptName = 'darktide-translate-platform-leg-v1'
$script:DarktideLegPlatforms = [ordered]@{
    windows = [ordered]@{ os = 'windows-latest'; arch = 'x64'; runnerOs = 'Windows' }
    linux = [ordered]@{ os = 'ubuntu-latest'; arch = 'x64'; runnerOs = 'Linux' }
    macos = [ordered]@{ os = 'macos-latest'; arch = 'arm64'; runnerOs = 'macOS' }
}
$script:DarktideLegOutcomeNames = @(
    'preserveCheckoutBytes', 'candidateCheckout', 'authorityCheckout', 'driverCheckout', 'identityBinding',
    'goSetup', 'goCapture', 'pythonSetup', 'pythonCapture', 'nodeSetup', 'nodeCapture', 'powerShellRelease', 'powerShellCache',
    'powerShellInstall', 'powerShellRuntime', 'pesterCache', 'pesterPreparation',
    'sourceToolPreparation', 'sourceValidation', 'finalEvidence'
)

function Get-DarktideProtectedDriverHelperPaths {
    [CmdletBinding()]
    param()
    return @($script:DarktideProtectedDriverHelperPaths)
}

function Get-DarktideLegOutcomeNames {
    [CmdletBinding()]
    param()
    return @($script:DarktideLegOutcomeNames)
}

function Assert-DarktideProtectedDriverCheckout {
    # Every protected helper executed from driver/ must be one regular Git blob
    # at the exact event base, and its raw bytes must hash to that blob without
    # line-ending filters.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $DriverRoot,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [string] $GitPath = ((Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    )

    if ($BaseRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Protected driver base revision must be one full commit SHA.' }
    $root = [IO.Path]::GetFullPath($DriverRoot)
    $head = @(& $GitPath -C $root rev-parse --verify 'HEAD^{commit}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or ([string]$head[0]).Trim() -cne $BaseRevision) {
        throw 'Protected driver HEAD differs from the exact event base SHA.'
    }
    $dirty = @(& $GitPath -C $root status --porcelain=v1 --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Protected driver checkout is not clean.' }
    $bindings = [Collections.Generic.List[object]]::new()
    foreach ($relative in $script:DarktideProtectedDriverHelperPaths) {
        $path = Join-Path $root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrEmpty([string]$item.LinkType)) {
            throw "Protected driver helper must be a plain file: $relative"
        }
        $entries = @(& $GitPath -C $root ls-tree --full-tree $BaseRevision -- $relative 2>$null)
        if ($LASTEXITCODE -ne 0 -or $entries.Count -ne 1 -or
            [string]$entries[0] -cnotmatch ('^(?:100644|100755) blob (?<objectId>[0-9a-f]{40})\t' + [regex]::Escape($relative) + '$')) {
            throw "Protected base must contain the exact helper as one regular Git blob: $relative"
        }
        $objectId = [string]$Matches.objectId
        $raw = @(& $GitPath -C $root hash-object --no-filters -- $path 2>$null)
        if ($LASTEXITCODE -ne 0 -or $raw.Count -ne 1 -or ([string]$raw[0]).Trim() -cne $objectId) {
            throw "Protected driver helper raw bytes differ from the exact event-base Git blob: $relative"
        }
        $bindings.Add([pscustomobject][ordered]@{
            path = $relative
            blob = $objectId
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        })
    }
    return $bindings.ToArray()
}

function New-DarktidePlatformLegReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux', 'macos')][string] $Platform,
        [Parameter(Mandatory = $true)][string] $Os,
        [Parameter(Mandatory = $true)][string] $Architecture,
        [Parameter(Mandatory = $true)][string] $RunnerOs,
        [Parameter(Mandatory = $true)][string] $RunId,
        [Parameter(Mandatory = $true)][string] $RunAttempt,
        [Parameter(Mandatory = $true)][string] $EventName,
        [Parameter(Mandatory = $true)][string] $CandidateSha,
        [Parameter(Mandatory = $true)][string] $BaseSha,
        [Parameter(Mandatory = $true)][string] $AuthoritySha,
        [AllowEmptyString()][string] $PythonVersion = '',
        [AllowEmptyString()][string] $PowerShellVersion = '',
        [AllowEmptyString()][string] $PowerShellArchiveSha256 = '',
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Outcomes,
        [AllowEmptyString()][string] $SourceReportSha256 = '',
        [AllowNull()] $SetupSeconds = $null,
        [AllowNull()] $SourceValidationSeconds = $null,
        [AllowNull()] $TotalSeconds = $null
    )

    # A receipt is always written (even for a failing leg) so the aggregate can
    # name the failure; only its shape is validated here.
    $outcomeNames = @($Outcomes.Keys | ForEach-Object { [string]$_ })
    if (($outcomeNames -join "`n") -cne ($script:DarktideLegOutcomeNames -join "`n")) {
        throw 'Leg receipt protected-step inventory is incomplete or reordered.'
    }
    $orderedOutcomes = [ordered]@{}
    foreach ($name in $script:DarktideLegOutcomeNames) { $orderedOutcomes[$name] = [string]$Outcomes[$name] }
    $receipt = [ordered]@{
        schemaVersion = 1
        receipt = $script:DarktideLegReceiptName
        platform = $Platform
        os = $Os
        arch = $Architecture
        runnerOs = $RunnerOs
        runId = $RunId
        runAttempt = $RunAttempt
        eventName = $EventName
        candidateSha = $CandidateSha
        baseSha = $BaseSha
        authoritySha = $AuthoritySha
        pythonVersion = $PythonVersion
        powerShell = [ordered]@{ version = $PowerShellVersion; archiveSha256 = $PowerShellArchiveSha256 }
        outcomes = $orderedOutcomes
        sourceReportSha256 = if ([string]::IsNullOrWhiteSpace($SourceReportSha256)) { $null } else { $SourceReportSha256 }
        timing = [ordered]@{ setupSeconds = $SetupSeconds; sourceValidationSeconds = $SourceValidationSeconds; totalSeconds = $TotalSeconds }
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((($receipt | ConvertTo-Json -Depth 10) + "`n"))
    $stream = [IO.FileStream]::new($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    return $fullPath
}

function Test-DarktidePlatformLegReceiptSet {
    # Returns every problem found; an empty result means the receipt set is the
    # exact, successful {windows, linux, macos} leg set for this run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ReceiptPaths,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $MatrixResult,
        [Parameter(Mandatory = $true)][string] $RunId,
        [Parameter(Mandatory = $true)][string] $RunAttempt,
        [Parameter(Mandatory = $true)][string] $EventName,
        [Parameter(Mandatory = $true)][string] $CandidateSha,
        [Parameter(Mandatory = $true)][string] $BaseSha,
        [Parameter(Mandatory = $true)][string] $AuthoritySha
    )

    $problems = [Collections.Generic.List[string]]::new()
    if ($MatrixResult -cne 'success') { $problems.Add("canonical-validation matrix result is '$MatrixResult', expected 'success'.") }
    if ($ReceiptPaths.Count -ne 3) { $problems.Add("Expected exactly three leg receipt files; found $($ReceiptPaths.Count).") }
    $receipts = [Collections.Generic.List[object]]::new()
    foreach ($path in $ReceiptPaths) {
        try { $receipts.Add((Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop)) }
        catch { $problems.Add("Receipt '$([IO.Path]::GetFileName($path))' is invalid JSON: $($_.Exception.Message)") }
    }
    foreach ($receipt in $receipts) {
        if ([string]$receipt.platform -cnotin @($script:DarktideLegPlatforms.Keys)) { $problems.Add("Unexpected receipt platform '$($receipt.platform)'.") }
    }
    foreach ($platform in $script:DarktideLegPlatforms.Keys) {
        $platformReceipts = @($receipts | Where-Object { [string]$_.platform -ceq $platform })
        if ($platformReceipts.Count -ne 1) {
            $problems.Add("Platform '$platform' must have exactly one receipt; found $($platformReceipts.Count).")
            continue
        }
        $receipt = $platformReceipts[0]
        $expected = $script:DarktideLegPlatforms[$platform]
        foreach ($binding in @(
            @('schemaVersion', [string]$receipt.schemaVersion, '1'),
            @('receipt', [string]$receipt.receipt, $script:DarktideLegReceiptName),
            @('os', [string]$receipt.os, [string]$expected.os),
            @('arch', [string]$receipt.arch, [string]$expected.arch),
            @('runnerOs', [string]$receipt.runnerOs, [string]$expected.runnerOs),
            @('runId', [string]$receipt.runId, $RunId),
            @('runAttempt', [string]$receipt.runAttempt, $RunAttempt),
            @('eventName', [string]$receipt.eventName, $EventName),
            @('candidateSha', [string]$receipt.candidateSha, $CandidateSha),
            @('baseSha', [string]$receipt.baseSha, $BaseSha),
            @('authoritySha', [string]$receipt.authoritySha, $AuthoritySha)
        )) {
            if ($binding[1] -cne $binding[2]) { $problems.Add("$platform receipt $($binding[0])='$($binding[1])', expected '$($binding[2])'.") }
        }
        if ([string]$receipt.pythonVersion -cnotmatch '^3\.12\.[0-9]+$') { $problems.Add("$platform receipt has no approved Python 3.12 version.") }
        if ([string]$receipt.powerShell.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { $problems.Add("$platform receipt has no verified PowerShell version.") }
        if ([string]$receipt.powerShell.archiveSha256 -cnotmatch '^[0-9a-f]{64}$') { $problems.Add("$platform receipt has no verified PowerShell archive SHA-256.") }
        $names = @($receipt.outcomes.PSObject.Properties.Name)
        if (($names -join "`n") -cne ($script:DarktideLegOutcomeNames -join "`n")) { $problems.Add("$platform receipt protected-step inventory is incomplete or reordered.") }
        foreach ($outcome in $receipt.outcomes.PSObject.Properties) {
            if ([string]$outcome.Value -cne 'success') { $problems.Add("$platform protected step '$($outcome.Name)' outcome is '$($outcome.Value)'.") }
        }
        if ([string]$receipt.sourceReportSha256 -cnotmatch '^[0-9a-f]{64}$') { $problems.Add("$platform receipt has no source report SHA-256.") }
    }
    $pythonMinors = @($receipts | ForEach-Object {
        $match = [regex]::Match([string]$_.pythonVersion, '^(?<mm>[0-9]+\.[0-9]+)\.[0-9]+$')
        if ($match.Success) { $match.Groups['mm'].Value }
    } | Sort-Object -Unique)
    if ($pythonMinors.Count -ne 1) { $problems.Add('Python major.minor differs across platform receipts or is missing.') }
    return $problems.ToArray()
}

Export-ModuleMember -Function Get-DarktideProtectedDriverHelperPaths, Get-DarktideLegOutcomeNames, Assert-DarktideProtectedDriverCheckout, New-DarktidePlatformLegReceipt, Test-DarktidePlatformLegReceiptSet
