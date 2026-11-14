# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

# Protected Core v2 source driver for Darktide Translate.
#
# The PR-B workflow executes this module from the exact event-base `driver/`
# checkout. It binds only the prepared target authority tuple below (commit,
# codeload archive SHA-256 and the complete runner-read inventory). The active
# v1 pin in config/standard-v1.json is intentionally independent: explicit
# source purposes require the candidate config to name this exact tuple.
#
# This module never loads Windows-only APIs. Process ownership, isolation and
# environment filtering for the tools it starts are delegated to the pinned
# central runner (`Invoke-StandardValidationProcess`) and to the central
# Core v2 runner itself.

Set-StrictMode -Version Latest

$script:DarktideSourceRepository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
$script:DarktidePreparedAuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:DarktidePreparedAuthorityCommit = 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
$script:DarktidePreparedAuthorityArchiveSha256 = 'c6bf36892d419c6751aeb2fde678e71975e2cec5448350e3700c337cd7a10c3d'
$script:DarktidePreparedAuthorityFiles = [ordered]@{
    'docs/standards/README.md' = 'c7aa1fc7f42d3c5017ff8a79752b83149056b6c8f3e0b7d2fc04c6a54bdfb265'
    'docs/standards/managed-skill-lifecycle.md' = '4e3f8595072d663f51d18aa28f42293fda5456362b49c0ea3f0157ae3dcf56dd'
    'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json' = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863'
    'docs/standards/schemas/openai-agent-metadata.schema.json' = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a'
    'docs/standards/schemas/source-inventory-v2.schema.json' = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e'
    'docs/standards/schemas/validation-security-gate-v1.schema.json' = 'b924b28a791f4d6eedcc0aa1c01fb62687ec863c0c17048093bfdd99aaa55b74'
    'docs/standards/skill-repository-review-matrix.md' = 'fa209ee5b49f99b503104664107606519195a30da18025093f9a4d4b8cfed774'
    'docs/standards/skill-repository-standard.md' = 'ee813e9b59b2ced182b25e0a05430f33624c2b89155b30d3f84017c7f3234c81'
    'docs/standards/upstream-interoperability.md' = '8e48cc4831d151ffa4665433d79ad88e8871cb1d694861908dd0206406dcefe5'
    'docs/standards/validation-security-gate.json' = '1ab4c1208885a3aeb74654d8133426367134446e2b7519f06e63de3a53b16067'
    'docs/standards/validation-toolchain.json' = '001054854960563201d969a826db990f01ab93a2e87120ccc5ee42be8f8417d7'
    'scripts/Invoke-StandardAuthorityGate.ps1' = 'b4972681e79f788485e3925b737a7b0faac38a63c617450472758f2cc33798ef'
    'scripts/Resolve-PythonWheelClosure.py' = '45bd49b13acaee461ac38cbdd303016d74f516ae494d77cbd127366603c90681'
    'scripts/Resolve-StandardValidationTool.ps1' = 'c0d68b227fc04e19d710a89c4559fe45e0cc979eead846006261dc2dc5bfa14f'
    'docs/standards/schemas/standard-validation-adapter-v1.schema.json' = '11aa88fc25716d748bd4f514f1a44f02390ad1745dd5a5c5beee07f642fd5639'
    'docs/standards/schemas/standard-validation-evidence-v1.schema.json' = 'e177a6832d055b51a440615fec65d01941b1b0c32bf468b962c8eb79750db924'
    'docs/standards/standard-validation-contract-v1.json' = '2fa394ee48f940cdc2272c64199b90d95dea3665e1496df49cd0bd695cbdbe15'
    'docs/standards/pr12-source-merge-adoption.json' = '4c5262f2a11d228195230c15fa4faaf9614af6b59f110e5d9c08f242ce809175'
    'docs/standards/trust-anchors/human-approval-public-key.xml' = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b'
    'docs/standards/trust-anchors/trusted-supervisor-public-key.xml' = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27'
    'scripts/Invoke-StandardValidation.ps1' = '776c35c2f4c3a3fb61b6920e38e127b7a05b4a13e865b0aa9d2b4d1347e97624'
    'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json' = '109091979d0a47e2035d3d8b20963fcdb85680e5da737bf1f27121608115d430'
    'scripts/StandardSemanticBridge.psm1' = 'dc3a990b6cce8ce4f282f4d4ed74fb37f83a993f3bbfb8765a0dbde0ef7eb365'
    'docs/standards/schemas/upstream-adapter-v1.schema.json' = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7'
    'docs/standards/upstream-adapter.json' = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31'
    'scripts/Validate-UpstreamAdapter.ps1' = '3b6e6474690b1ae9f9486544b68f50ca29b96f5dbe6aa8d6c6cd8570afad500b'
    'docs/standards/standard-core-validation-v2.json' = 'dd3c3d1bb83a439895ed35a949ff376b9d59d25e69063c86714eb42edaad84df'
    'docs/standards/schemas/standard-core-adapter-v2.schema.json' = '7399980e8765528b759a3734a133447eb9581ac24a9c4780dc8faadd6af0c1c5'
    'docs/standards/schemas/standard-core-evidence-v2.schema.json' = '7c083b9603b75518220e7e70e5704728a7e3dee0d5b5cf09dc9c755f49d64153'
    'docs/standards/third-party-raw-skill-sources.md' = '18649fd56eada4a94a5d47de778669b0ebcecfb85b84f5c581d283b21979f7ac'
    'docs/standards/schemas/third-party-raw-skill-source-v1.schema.json' = '9d8585d95c606486f947a3f89e39341af840335376e86910eb7f4ed25bdc16ed'
    'docs/standards/examples/third-party-raw-skill-source-v1.json' = 'decbf276cbeea33c60d8b36b7b16838babe951cd84d13ae4a8a7a8261dc6d9c8'
    'docs/standards/skillspector-approved-sources.json' = 'baaaf2a66e98f2c28a48fddd04051f09cf5498ef6c7978cbf45f5d415b69a330'
    'docs/standards/schemas/skillspector-approved-sources-v1.schema.json' = '20fa8516c9dcb7c9ae15f4682092dc583411db3149fac2641fef7b5182c3d12b'
    'docs/standards/static-parser-host-ownership.json' = '994acd989327d094d22ce2c68ca20eceec609f4e494f4e5d252cfcdef742de2c'
    'scripts/platform-runtime.psd1' = 'd3d8eef434484b3b2449cd4762e60b94afc314d9beb91481538c7f57207a11c9'
    'scripts/platform-runtime.psm1' = 'ad051b2794ce4dc10108404201735d02f7b032ed0e633c5f22f73c884fb10370'
    'scripts/installer-safe-mutation.psm1' = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293'
    'scripts/WindowsDacl.psm1' = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6'
    'scripts/platform/PlatformNative.cs' = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514'
    'scripts/platform/UnixNative.cs' = '171da4acded889da89ab4e7af2729e9bbf4f3639cf1e63fe08a4c046f7545c74'
    'scripts/platform/WindowsNative.cs' = '6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433'
    'scripts/platform/WindowsInstallerMutation.cs' = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218'
    'scripts/platform/OwnedProcess.cs' = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58'
    'scripts/platform/UnixProcess.cs' = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1'
    'scripts/platform/WindowsProcess.cs' = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6'
    'scripts/platform/Unix.psm1' = 'ec3b3bb0b39e1ce84d4c8f60a78c44fb40cb9d58c13ed88a6b9d9db978fcc147'
    'scripts/platform/RuntimePreparation.psm1' = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077'
    'scripts/platform/Windows.psm1' = '9b7442178083a9b165ed3bf53367d5c3ce1b1f09d56f0f6efe964b524e17be0b'
    'scripts/platform/Linux.psm1' = '52c261d577ee7b3946771d1112030996896fdd119e06ac3849e430a3d56fb38c'
    'scripts/platform/MacOS.psm1' = '8f25edfbee5ab36b5e1c42eb55c6dbab44db0bc29896c180612b1248920c7c47'
}
$script:DarktideProtectedReaderPaths = @(
    'scripts/Test-Repository.ps1',
    'scripts/Invoke-CorePester.ps1',
    'scripts/CorePesterIntegrity.psm1',
    'config/pester-6.2.0-closure.lock.json'
)
$script:DarktideChildRunnerName = 'Invoke-SourceChild.ps1'
$script:DarktideSourceToolNames = @('skill-validator', 'skill-tools', 'skillspector')
$script:DarktideSetupTokenVariable = 'DT_SOURCE_SETUP_GITHUB_TOKEN'

function Assert-DarktideExactPropertySet {
    param(
        [Parameter(Mandatory = $true)][AllowNull()] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Value -or $Value -is [array] -or $Value -is [string] -or $Value -is [ValueType] -or $null -eq $Value.PSObject) {
        throw "$Context must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "$Context has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-DarktideNoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "$Context contains duplicate JSON property '$($property.Name)'." }
            Assert-DarktideNoDuplicateJsonProperties -Element $property.Value -Context "$Context.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-DarktideNoDuplicateJsonProperties -Element $item -Context "$Context[$index]"
            $index++
        }
    }
}

function Read-DarktideJsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try { Assert-DarktideNoDuplicateJsonProperties -Element $document.RootElement -Context $Context }
        finally { $document.Dispose() }
        return $text | ConvertFrom-Json -Depth 100
    }
    catch { throw "$Context is not valid unambiguous UTF-8 JSON: $($_.Exception.Message)" }
}

function Get-DarktideFileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-DarktidePathComparison {
    if ($IsWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Test-DarktidePathEqual {
    param([Parameter(Mandatory = $true)][string] $Left, [Parameter(Mandatory = $true)][string] $Right)
    return [IO.Path]::GetFullPath($Left).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Equals(
        [IO.Path]::GetFullPath($Right).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        (Get-DarktidePathComparison))
}

function Test-DarktidePathWithinOrEqual {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = Get-DarktidePathComparison
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Test-DarktidePathOverlap {
    # "Must be outside" checks never relax on a case-insensitive volume:
    # overlap is evaluated with OrdinalIgnoreCase on every platform.
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = [StringComparison]::OrdinalIgnoreCase
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-DarktidePathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-DarktidePathWithinOrEqual -Path $fullPath -Root $Root)) { throw "$Context must stay within '$Root': $Path" }
    return $fullPath
}

function Assert-DarktideOutsideRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if (Test-DarktidePathOverlap -Path $Path -Root $Root) {
        throw "$Context must be outside '$Root': $Path"
    }
}

function Resolve-DarktidePhysicalPath {
    # Resolve every existing link component (for example macOS /var and /tmp,
    # which are system symlinks to /private/...) so trusted roots are compared
    # by their physical location. Windows paths are returned unchanged.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

    $full = [IO.Path]::GetFullPath($Path)
    if ($IsWindows) { return $full }
    $resolved = [IO.Path]::GetPathRoot($full)
    foreach ($segment in @($full.Substring($resolved.Length).Split([IO.Path]::DirectorySeparatorChar) | Where-Object { $_ -ne '' })) {
        $candidate = Join-Path $resolved $segment
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and -not [string]::IsNullOrEmpty([string]$item.LinkType)) {
            $target = [IO.Directory]::ResolveLinkTarget($candidate, $true)
            if ($null -eq $target) { $target = [IO.File]::ResolveLinkTarget($candidate, $true) }
            if ($null -eq $target) { throw "Could not resolve the physical target of '$candidate'." }
            $candidate = [IO.Path]::GetFullPath([string]$target.FullName)
        }
        $resolved = $candidate
    }
    return $resolved
}

function Assert-DarktideNoReparseAncestors {
    # Windows: every ancestor up to the volume root must be a non-reparse
    # entry (unchanged v1 semantics). Linux/macOS: the walk stops at the
    # trusted boundary (TrustedRoot, or the immediate parent when none is
    # supplied); ancestors above the boundary are system path components that
    # are resolved physically instead of rejected. Nothing at or below the
    # boundary may be a link.
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context,
        [string] $TrustedRoot
    )
    $current = [IO.Path]::GetFullPath($Path)
    if ($IsWindows) {
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context is backed by a reparse point: $current" }
            $parent = Split-Path -Parent $current
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
            $current = $parent
        }
        return
    }
    $checkBoundary = -not [string]::IsNullOrWhiteSpace($TrustedRoot)
    $boundary = if ($checkBoundary) { [IO.Path]::GetFullPath($TrustedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) } else { Split-Path -Parent $current }
    if ([string]::IsNullOrWhiteSpace($boundary)) { $boundary = [IO.Path]::GetPathRoot($current) }
    if (-not (Test-DarktidePathWithinOrEqual -Path $current -Root $boundary)) { throw "$Context escapes its trusted root '$boundary': $current" }
    while ($true) {
        $atBoundary = $current.TrimEnd([IO.Path]::DirectorySeparatorChar).Equals($boundary.TrimEnd([IO.Path]::DirectorySeparatorChar), [StringComparison]::Ordinal)
        if ($atBoundary -and -not $checkBoundary) { break }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrEmpty([string]$item.LinkType)) {
            throw "$Context is backed by a reparse point: $current"
        }
        if ($atBoundary) { break }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    [void](Resolve-DarktidePhysicalPath -Path $boundary)
}

function Write-DarktideUtf8CreateNew {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Create-only source setup parent directory is missing: $parent"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $stream = [IO.FileStream]::new($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Get-DarktideResolvedGitPath {
    $command = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $commandPath = [IO.Path]::GetFullPath([string]$command.Path)
    $commandItem = Get-Item -LiteralPath $commandPath -Force -ErrorAction Stop
    if ($commandItem.PSIsContainer) { throw 'Resolved Git command path must be a file.' }
    if ($IsWindows) {
        if (($commandItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Resolved Git command path must be a plain, non-reparse file on Windows.'
        }
        return $commandPath
    }
    $resolvedTarget = if (($commandItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [IO.File]::ResolveLinkTarget($commandPath, $true)
    }
    else { $commandItem }
    if ($null -eq $resolvedTarget) { throw 'Resolved Git command path symbolic link could not be resolved.' }
    $physicalPath = [IO.Path]::GetFullPath([string]$resolvedTarget.FullName)
    $physicalItem = Get-Item -LiteralPath $physicalPath -Force -ErrorAction Stop
    if ($physicalItem.PSIsContainer -or ($physicalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Resolved Git physical target must be a regular, non-link file.'
    }
    return $physicalPath
}

function Get-DarktideCurrentPowerShellPath {
    # The verified runtime is the process executing this driver; a PATH lookup
    # could select a different pwsh than the workflow verified.
    $path = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $expectedName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    if ([IO.Path]::GetFileName($path) -cne $expectedName) {
        throw "Source purposes must run under PowerShell 7 ($expectedName); current host is '$path'."
    }
    return $path
}

function Resolve-DarktideGitRevision {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Revision,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $output = @(& $GitPath -C $Root rev-parse --verify --end-of-options "$Revision^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or ([string]$output[0]).Trim() -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Context '$Revision' does not resolve to one immutable commit."
    }
    return ([string]$output[0]).Trim()
}

function Resolve-DarktideGoRuntimeVersion {
    param([string] $Expected)
    if (-not [string]::IsNullOrWhiteSpace($Expected)) {
        if ($Expected -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'ExpectedGoRuntimeVersion must be a stable semantic Go version.' }
        return $Expected
    }
    $go = Get-Command go -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $output = @(& $go.Path version)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1 -or [string]$output[0] -notmatch '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+)\s') {
        throw 'Could not resolve the current stable Go runtime version.'
    }
    return [string]$Matches.version
}

function Get-DarktideEventName {
    switch ([string]$env:GITHUB_EVENT_NAME) {
        'pull_request' { return 'pull_request' }
        'push' { return 'push' }
        'workflow_dispatch' { return 'workflow_dispatch' }
        'pre-push' { return 'pre-push' }
        default { return 'local' }
    }
}

function Get-DarktideActiveSkillIds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Root)

    $inventory = Read-DarktideJsonFile -Path (Join-Path $Root 'catalog/source.json') -Context 'catalog/source.json'
    Assert-DarktideExactPropertySet -Value $inventory -Expected @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -Context 'catalog/source.json'
    if ($inventory.schemaVersion -ne 2 -or [string]$inventory.sourceId -cne 'darktide-translate' -or
        [string]$inventory.repository -cne $script:DarktideSourceRepository -or [string]$inventory.skillsRoot -cne 'skills' -or
        $inventory.skills -isnot [array] -or @($inventory.skills).Count -eq 0) {
        throw 'catalog/source.json is not the strict Darktide Translate source inventory.'
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'catalog/skills-catalog.json')) {
        throw 'Legacy source-owned cross-source catalog must not coexist with catalog/source.json.'
    }
    [string[]]$declared = @($inventory.skills | ForEach-Object {
        if ($_ -isnot [string] -or [string]$_ -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Invalid Skill ID in catalog/source.json: '$_'." }
        [string]$_
    })
    [string[]]$sorted = @($declared)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skillId in $declared) { if (-not $seen.Add($skillId)) { throw "Duplicate Skill ID '$skillId'." } }
    if (($declared -join "`n") -cne ($sorted -join "`n")) { throw 'catalog/source.json skills must use ordinal ascending order.' }
    $skillsRoot = Join-Path $Root 'skills'
    if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) { throw 'Canonical skills/ source root is missing.' }
    [string[]]$actual = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | ForEach-Object { [string]$_.Name })
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($sorted -join "`n")) { throw 'catalog/source.json inventory does not exactly match skills/ directories.' }
    return $sorted
}

function Get-DarktideSourceAuthorityPin {
    [CmdletBinding()]
    param()

    $files = [ordered]@{}
    foreach ($entry in $script:DarktidePreparedAuthorityFiles.GetEnumerator()) {
        $files[[string]$entry.Key] = [string]$entry.Value
    }
    return [pscustomobject][ordered]@{
        repository = $script:DarktidePreparedAuthorityRepository
        commit = $script:DarktidePreparedAuthorityCommit
        archiveUrl = "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($script:DarktidePreparedAuthorityCommit)"
        archiveSha256 = $script:DarktidePreparedAuthorityArchiveSha256
        files = $files
    }
}

function Assert-DarktideSourceAuthorityTuple {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()] $Authority)

    Assert-DarktideExactPropertySet -Value $Authority -Expected @('repository', 'commit', 'archiveUrl', 'archiveSha256', 'files') -Context 'Prepared source authority'
    $expected = Get-DarktideSourceAuthorityPin
    foreach ($field in @('repository', 'commit', 'archiveUrl', 'archiveSha256')) {
        if ($Authority.$field -isnot [string] -or [string]$Authority.$field -cne [string]$expected.$field) {
            throw "Prepared source authority $field does not match the exact approved tuple."
        }
    }
    if ($Authority.files -isnot [array] -or @($Authority.files).Count -ne $expected.files.Count) {
        throw 'Prepared source authority file tuple is incomplete.'
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedPaths = @($expected.files.Keys)
    for ($index = 0; $index -lt $expectedPaths.Count; $index++) {
        $file = @($Authority.files)[$index]
        Assert-DarktideExactPropertySet -Value $file -Expected @('path', 'sha256') -Context "Prepared source authority file at index $index"
        if ($file.path -isnot [string] -or $file.sha256 -isnot [string]) {
            throw "Prepared source authority file fields must be strings at index $index."
        }
        $path = [string]$file.path
        $segments = @($path.Split('/'))
        if ([string]::IsNullOrWhiteSpace($path) -or $path.StartsWith('/', [StringComparison]::Ordinal) -or
            $path.Contains('\') -or $path.Contains(':') -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
            throw "Prepared source authority contains an unsafe file path at index $index."
        }
        if (-not $seen.Add($path)) { throw "Prepared source authority contains duplicate file path '$path'." }
        if ([string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Prepared source authority file SHA-256 is invalid at index $index." }
        if ($path -cne [string]$expectedPaths[$index]) { throw "Prepared source authority file path or order mismatch at index $index." }
        if ([string]$file.sha256 -cne [string]$expected.files[$path]) { throw "Prepared source authority file identity mismatch at index $index." }
    }
    return $expected
}

function Assert-DarktideSourceAuthorityConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()] $Config)

    Assert-DarktideExactPropertySet -Value $Config -Expected @('schemaVersion', 'standardVersion', 'authority', 'deviations') -Context 'config/standard-v1.json'
    if ($Config.schemaVersion -ne 1 -or [string]$Config.standardVersion -cne 'v1' -or $Config.deviations -isnot [string] -or [string]$Config.deviations -cne 'None') {
        throw 'config/standard-v1.json identity or deviation contract is invalid.'
    }
    return Assert-DarktideSourceAuthorityTuple -Authority $Config.authority
}

function Resolve-DarktideSourceRoute {
    [CmdletBinding()]
    param(
        [int] $AdapterVersion = 1,
        [switch] $PrepareSourceTools,
        [switch] $SourceValidation,
        [string] $SourceToolsPath,
        [string] $AuthorityRepositoryRoot,
        [string] $TrustedToolRoot,
        [System.Collections.IDictionary] $BoundParameters = @{}
    )

    $sourceParameterNames = @('SourceToolsPath', 'AuthorityRepositoryRoot', 'TrustedToolRoot')
    $hasSourcePurpose = $PrepareSourceTools -or $SourceValidation
    if (-not $hasSourcePurpose) {
        if ($AdapterVersion -ne 1 -or @($BoundParameters.Keys | Where-Object { $_ -cin @($sourceParameterNames + 'AdapterVersion') }).Count -gt 0) {
            throw 'AdapterVersion, SourceToolsPath, AuthorityRepositoryRoot and TrustedToolRoot are only valid with -AdapterVersion 2 and an explicit source purpose.'
        }
        return [pscustomobject]@{ mode = 'v1' }
    }
    if ($AdapterVersion -ne 2) { throw 'Explicit source purposes require -AdapterVersion 2.' }
    if ($PrepareSourceTools -and $SourceValidation) { throw 'PrepareSourceTools and SourceValidation are separate setup and execution requests.' }
    $v1OnlyNames = @(
        'AuthorityArchivePath', 'TrustedTestCommit', 'BootstrapTransition', 'EnableSemanticScan', 'SemanticCredentialNames',
        'ProtectedPesterServerProxy', 'ProtectedPesterSupervisor'
    )
    $conflicts = @($BoundParameters.Keys | Where-Object { $_ -cin $v1OnlyNames -or ([string]$_).StartsWith('Pester', [StringComparison]::Ordinal) })
    if ($conflicts.Count -gt 0) { throw "Core v2 source purposes do not accept v1 parameters: $($conflicts -join ', ')." }
    if ([string]::IsNullOrWhiteSpace($SourceToolsPath)) { throw 'Explicit source setup or validation requires SourceToolsPath.' }
    if ([string]::IsNullOrWhiteSpace($AuthorityRepositoryRoot)) { throw 'Explicit source setup or validation requires AuthorityRepositoryRoot.' }
    if ([string]::IsNullOrWhiteSpace($TrustedToolRoot)) { throw 'Explicit source setup or validation requires TrustedToolRoot.' }
    $mode = if ($PrepareSourceTools) { 'prepare-source-tools' } else { 'source-validation' }
    return [pscustomobject]@{ mode = $mode; authority = Get-DarktideSourceAuthorityPin }
}

function Get-DarktideProtectedDriverRoot {
    return [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}

function Get-DarktideSourceChildRunnerPath {
    [CmdletBinding()]
    param()
    $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $script:DarktideChildRunnerName))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Protected source child runner is missing from the driver.' }
    return $path
}

function Assert-DarktideSourceProtectedReaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ProtectedBaseRoot,
        [Parameter(Mandatory = $true)][string] $CandidateRoot
    )

    $protectedRoot = [IO.Path]::GetFullPath($ProtectedBaseRoot)
    $candidateRootFull = [IO.Path]::GetFullPath($CandidateRoot)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($relative in $script:DarktideProtectedReaderPaths) {
        $basePath = Join-Path $protectedRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $candidatePath = Join-Path $candidateRootFull ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        foreach ($path in @($basePath, $candidatePath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Protected reader is missing: $path" }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Protected reader is a reparse point: $path" }
        }
        $baseHash = Get-DarktideFileSha256 -Path $basePath
        $candidateHash = Get-DarktideFileSha256 -Path $candidatePath
        if ($baseHash -cne $candidateHash) { throw "Candidate protected reader differs from the trusted driver bytes: $relative" }
        $result.Add([pscustomobject][ordered]@{ path = $relative; sha256 = $baseHash })
    }
    return $result.ToArray()
}

function Assert-DarktidePreparedAuthorityCheckout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $AuthorityRoot,
        [Parameter(Mandatory = $true)] $AuthorityPin
    )

    $fullRoot = [IO.Path]::GetFullPath($AuthorityRoot)
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw "Prepared authority Git checkout is missing: $fullRoot" }
    Assert-DarktideNoReparseAncestors -Path $fullRoot -Context 'Prepared authority checkout'
    $top = @(& $GitPath -C $fullRoot rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $top.Count -ne 1 -or -not (Test-DarktidePathEqual -Left ([string]$top[0]) -Right $fullRoot)) {
        throw 'Prepared authority path is not the root of a Git checkout.'
    }
    $head = @(& $GitPath -C $fullRoot rev-parse --verify --end-of-options 'HEAD^{commit}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1 -or ([string]$head[0]).Trim() -cne [string]$AuthorityPin.commit) {
        throw 'Prepared authority checkout HEAD does not match the exact approved revision.'
    }
    $origins = @(& $GitPath -C $fullRoot config --local --get-all remote.origin.url 2>$null)
    if ($LASTEXITCODE -ne 0 -or $origins.Count -ne 1) { throw 'Prepared authority checkout must have exactly one origin URL.' }
    $origin = ([string]$origins[0]).Trim().TrimEnd('/') -replace '\.git$', ''
    $expectedOrigin = ([string]$AuthorityPin.repository).Trim().TrimEnd('/') -replace '\.git$', ''
    if (-not $origin.Equals($expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Prepared authority checkout origin does not match the pinned authority repository.'
    }
    $dirty = @(& $GitPath -C $fullRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Prepared authority checkout must be clean and immutable.' }
    $headRevision = ([string]$head[0]).Trim()

    foreach ($entry in $AuthorityPin.files.GetEnumerator()) {
        $filePath = [IO.Path]::GetFullPath((Join-Path $fullRoot ($entry.Key -replace '/', [IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-DarktidePathWithinOrEqual -Path $filePath -Root $fullRoot)) { throw "Prepared authority file escaped its checkout: $($entry.Key)" }
        Assert-DarktideNoReparseAncestors -Path $filePath -Context 'Prepared authority file'
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf) -or (Get-DarktideFileSha256 -Path $filePath) -cne [string]$entry.Value) {
            throw "Prepared authority file identity mismatch: $($entry.Key)"
        }
        $treeEntry = @(& $GitPath -C $fullRoot ls-tree $headRevision -- ([string]$entry.Key) 2>$null)
        if ($LASTEXITCODE -ne 0 -or $treeEntry.Count -ne 1 -or
            [string]$treeEntry[0] -cnotmatch ('^(?<mode>100644|100755) blob (?<objectId>[0-9a-f]{40})\t' + [regex]::Escape([string]$entry.Key) + '$')) {
            throw "Prepared authority path is not a regular Git blob: $($entry.Key)"
        }
        $expectedBlob = [string]$Matches.objectId
        $actualBlob = @(& $GitPath -C $fullRoot hash-object --no-filters -- ([string]$entry.Key) 2>$null)
        if ($LASTEXITCODE -ne 0 -or $actualBlob.Count -ne 1 -or ([string]$actualBlob[0]).Trim() -cne $expectedBlob) {
            throw "Prepared authority file bytes differ from its immutable Git blob: $($entry.Key)"
        }
    }
    return [pscustomobject]@{ root = $fullRoot; revision = [string]$AuthorityPin.commit; runnerPath = (Join-Path $fullRoot 'scripts/Invoke-StandardValidation.ps1') }
}

function Remove-DarktideOwnedCoreAdapterRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $OwnedRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $RunId,
        [Parameter(Mandatory = $true)][string] $OwnerToken,
        [Parameter(Mandatory = $true)][string[]] $ProtectedRoots
    )

    if ($RunId -cnotmatch '^[0-9a-f]{32}$' -or $OwnerToken -cnotmatch '^[0-9a-f]{32}$') { throw 'Core adapter cleanup identity is invalid.' }
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $ArtifactsRoot ".core-v2-adapter-$RunId"))
    $ownedFull = [IO.Path]::GetFullPath($OwnedRoot)
    if (-not (Test-DarktidePathEqual -Left $ownedFull -Right $expectedRoot) -or
        -not (Test-DarktidePathEqual -Left (Split-Path -Parent $ownedFull) -Right $ArtifactsRoot)) {
        throw 'Core adapter cleanup path is not the exact run-owned sibling.'
    }
    if (-not (Test-Path -LiteralPath $ownedFull -PathType Container)) { return }
    foreach ($root in $ProtectedRoots) { Assert-DarktideOutsideRoot -Path $ownedFull -Root $root -Context 'Core adapter cleanup root' }
    Assert-DarktideNoReparseAncestors -Path $ownedFull -Context 'Core adapter cleanup root'

    $markerPath = Join-Path $ownedFull '.source-owned.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'Core adapter cleanup ownership marker is missing.' }
    $marker = Read-DarktideJsonFile -Path $markerPath -Context 'Core adapter cleanup marker'
    Assert-DarktideExactPropertySet -Value $marker -Expected @('owner', 'runId', 'token') -Context 'Core adapter cleanup marker'
    if ([string]$marker.owner -cne 'darktide-translate-source-core-adapter' -or
        [string]$marker.runId -cne $RunId -or [string]$marker.token -cne $OwnerToken) {
        throw 'Core adapter cleanup marker does not match this source run.'
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $ownedFull -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Core adapter cleanup found a reparse point: $($item.FullName)" }
    }
    Remove-Item -LiteralPath $ownedFull -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $ownedFull) { throw 'Core adapter cleanup did not remove its exact run-owned root.' }
}

function Get-DarktideCoreAdapterLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $RunId
    )

    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Core adapter layout requires the canonical source setup RunId.' }
    $root = [IO.Path]::GetFullPath($ArtifactsRoot)
    $adapterRoot = [IO.Path]::GetFullPath((Join-Path $root ".core-v2-adapter-$RunId"))
    if (-not (Test-DarktidePathEqual -Left (Split-Path -Parent $adapterRoot) -Right $root)) {
        throw 'Core adapter layout must be a direct ArtifactsRoot child.'
    }
    return [pscustomobject][ordered]@{
        adapterRoot = $adapterRoot
        adapterPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'standard-core-adapter-v2.json'))
        ownerMarkerPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot '.source-owned.json'))
    }
}

function New-DarktideSourceCoreAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $PowerShell,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ActiveSkillIds,
        [Parameter(Mandatory = $true)] $SourceValidation
    )

    $fullPowerShell = [IO.Path]::GetFullPath($PowerShell)
    if (-not (Test-Path -LiteralPath $fullPowerShell -PathType Leaf)) { throw 'Core source adapter PowerShell executable is missing.' }
    if ($ActiveSkillIds.Count -eq 0) { throw 'Core source adapter requires at least one active Skill.' }
    foreach ($skillId in $ActiveSkillIds) {
        if ([string]$skillId -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Core source adapter contains an invalid Skill ID: '$skillId'." }
    }
    $powerShellSha256 = Get-DarktideFileSha256 -Path $fullPowerShell
    return [ordered]@{
        schemaVersion = 2
        adapter = 'standard-core-adapter-v2'
        skillsRoot = 'skills'
        activeSkills = @($ActiveSkillIds)
        checks = @(
            [ordered]@{ id = 'repository-general'; kind = 'general'; executable = $fullPowerShell; executableSha256 = $powerShellSha256; arguments = @('-NoProfile', '-NonInteractive', '-File', 'scripts/Test-Repository.ps1', '-ReadOnlySnapshot') }
            [ordered]@{ id = 'repository-pester'; kind = 'pester'; executable = $fullPowerShell; executableSha256 = $powerShellSha256; arguments = @('-NoProfile', '-NonInteractive', '-File', 'scripts/Invoke-CorePester.ps1') }
        )
        sourceValidation = $SourceValidation
    }
}

function Get-DarktideSourceDispatchArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ChildPath,
        [Parameter(Mandatory = $true)][string] $ToolchainPath,
        [Parameter(Mandatory = $true)][string] $ToolchainSha256
    )

    $base = @('-NoProfile', '-NonInteractive', '-File', $ChildPath, '-ToolchainPath', $ToolchainPath, '-ToolchainSha256', $ToolchainSha256)
    return [ordered]@{
        packageAdapter = @($base + @('-Mode', 'package-adapter'))
        skillValidator = @($base + @('-Mode', 'skill-validator'))
        skillTools = @($base + @('-Mode', 'skill-tools'))
        staticAnalyzer = @($base + @('-Mode', 'static'))
    }
}

function Assert-DarktideSourceReceiptClosureFrozen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Bindings,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $FrozenFiles
    )

    if ($Bindings.Count -ne 3) { throw 'Source setup requires exactly three resolver receipts.' }
    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $seenFrozen = [Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($file in $FrozenFiles) {
        Assert-DarktideExactPropertySet -Value $file -Expected @('path', 'sha256') -Context 'Source frozen file'
        if ([string]$file.path -cne [IO.Path]::GetFullPath([string]$file.path) -or
            [string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not $seenFrozen.Add([string]$file.path)) {
            throw 'Source frozen files must have unique absolute paths and lowercase SHA-256 identities.'
        }
    }

    $seenTools = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($binding in $Bindings) {
        Assert-DarktideExactPropertySet -Value $binding -Expected @('path', 'sha256') -Context 'Source tool receipt binding'
        $receiptPath = [IO.Path]::GetFullPath([string]$binding.path)
        if ([string]$binding.sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-DarktideFileSha256 -Path $receiptPath) -cne [string]$binding.sha256) {
            throw 'Source tool receipt does not match its frozen SHA-256 binding.'
        }
        $receiptFrozen = @($FrozenFiles | Where-Object { (Test-DarktidePathEqual -Left ([string]$_.path) -Right $receiptPath) -and [string]$_.sha256 -ceq [string]$binding.sha256 })
        if ($receiptFrozen.Count -ne 1) { throw 'Source tool receipt file is not frozen exactly once.' }

        $receipt = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($receiptPath, [Text.UTF8Encoding]::new($false, $true))) -Depth 50 -ErrorAction Stop
        $toolName = [string]$receipt.toolName
        if ($toolName -cnotin $script:DarktideSourceToolNames -or -not $seenTools.Add($toolName)) {
            throw 'Source tool receipts must identify each approved tool exactly once.'
        }
        $pairs = if ($toolName -ceq 'skill-tools') { @(@('entryPointPath', 'entryPointSha256'), @('nodePath', 'nodeSha256')) } else { @(, @('executablePath', 'executableSha256')) }
        foreach ($pair in $pairs) {
            $pathProperty = $receipt.PSObject.Properties[[string]$pair[0]]
            $hashProperty = $receipt.PSObject.Properties[[string]$pair[1]]
            if ($null -eq $pathProperty -or $null -eq $hashProperty -or
                $pathProperty.Value -isnot [string] -or $hashProperty.Value -isnot [string] -or
                [string]$hashProperty.Value -cnotmatch '^[0-9a-f]{64}$' -or -not [IO.Path]::IsPathRooted([string]$pathProperty.Value)) {
                throw "Source $toolName receipt has an invalid $($pair[0]) frozen identity."
            }
            $frozenMatches = @($FrozenFiles | Where-Object {
                (Test-DarktidePathEqual -Left ([string]$_.path) -Right ([string]$pathProperty.Value)) -and [string]$_.sha256 -ceq [string]$hashProperty.Value
            })
            if ($frozenMatches.Count -ne 1) { throw "Source $toolName receipt $($pair[0]) is not frozen exactly once." }
        }
    }
}

function Write-DarktideSourceSetupArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [AllowEmptyString()][string] $ProtectedToken
    )

    if (-not [string]::IsNullOrEmpty($ProtectedToken) -and $Text.Contains($ProtectedToken, [StringComparison]::Ordinal)) {
        throw 'Source setup artifact content contains the protected resolver credential.'
    }
    Write-DarktideUtf8CreateNew -Path $Path -Text $Text
}

function New-DarktideSourceToolSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $AuthorityRoot,
        [Parameter(Mandatory = $true)] $AuthorityPin,
        [Parameter(Mandatory = $true)][string] $PowerShell,
        [Parameter(Mandatory = $true)][string] $CandidateRevision,
        [Parameter(Mandatory = $true)][string] $PreparedPath,
        [Parameter(Mandatory = $true)][string] $GoVersion,
        [Parameter(Mandatory = $true)][int] $LimitSeconds,
        [hashtable] $ResolverEnvironment = @{}
    )

    $protectedToken = if ($ResolverEnvironment.ContainsKey('STANDARD_VALIDATION_GITHUB_API_TOKEN')) { [string]$ResolverEnvironment['STANDARD_VALIDATION_GITHUB_API_TOKEN'] } else { '' }
    $setupId = [guid]::NewGuid().ToString('N')
    $owned = [IO.Path]::GetFullPath((Join-Path $Root "source-tools-$setupId"))
    if (Test-Path -LiteralPath $owned) { throw 'Source setup root already exists.' }
    [void](New-Item -ItemType Directory -Path $owned -ErrorAction Stop)
    Assert-DarktideNoReparseAncestors -Path $owned -Context 'Source setup owned root'

    $runner = Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'Pinned source authority runner is missing.' }
    . $runner -DefineFunctionsOnly -CandidateRoot $AuthorityRoot -AdapterPath $PreparedPath -ArtifactsRoot $Root -SourceRepository $script:DarktideSourceRepository -SourceRevision $CandidateRevision -BaseRevision $CandidateRevision -AuthorityRevision ([string]$AuthorityPin.commit)

    $resolver = Join-Path $AuthorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
    $policy = Join-Path $AuthorityRoot 'docs/standards/validation-toolchain.json'
    $receipts = [ordered]@{}
    $receiptBindings = @()
    foreach ($tool in $script:DarktideSourceToolNames) {
        $receiptPath = Join-Path $owned "receipt-$tool.json"
        $resolverArguments = @('-NoProfile', '-NonInteractive', '-File', $resolver, '-PolicyPath', $policy, '-ToolName', $tool, '-Install', '-InstallRoot', (Join-Path $owned 'installed'), '-ExpectedGoRuntimeVersion', $GoVersion, '-RunId', $setupId, '-OutputPath', $receiptPath)
        $result = Invoke-StandardValidationProcess -Command $PowerShell -Arguments $resolverArguments -WorkingDirectory $owned -Environment $ResolverEnvironment -TimeoutSeconds $LimitSeconds -CoreLifecycleOnly
        Write-DarktideSourceSetupArtifact -Path (Join-Path $owned "setup-$tool-process.json") -Text (($result | ConvertTo-Json -Depth 30) + [Environment]::NewLine) -ProtectedToken $protectedToken
        if ($result.status -cne 'passed' -or $result.exitCode -ne 0 -or -not $result.cleanedUp) {
            throw "Source setup $tool failed: $($result.status), exit=$($result.exitCode), cleanup=$($result.cleanedUp). $($result.stderr)"
        }
        $receipts[$tool] = Read-DarktideJsonFile -Path $receiptPath -Context "$tool source receipt"
        $receiptBindings += [pscustomobject]@{ path = $receiptPath; sha256 = Get-DarktideFileSha256 -Path $receiptPath }
    }

    $toolchain = [ordered]@{
        centralRunnerPath = [IO.Path]::GetFullPath($runner)
        centralRunnerSha256 = Get-DarktideFileSha256 -Path $runner
        skillValidatorPath = [string]$receipts.'skill-validator'.executablePath
        skillValidatorSha256 = [string]$receipts.'skill-validator'.executableSha256
        skillToolsNodePath = [string]$receipts.'skill-tools'.nodePath
        skillToolsNodeSha256 = [string]$receipts.'skill-tools'.nodeSha256
        skillToolsEntryPointPath = [string]$receipts.'skill-tools'.entryPointPath
        skillToolsEntryPointSha256 = [string]$receipts.'skill-tools'.entryPointSha256
        skillSpectorPath = [string]$receipts.skillspector.executablePath
        skillSpectorSha256 = [string]$receipts.skillspector.executableSha256
        skillSpectorReceiptPath = [string]$receiptBindings[2].path
        skillSpectorReceiptSha256 = [string]$receiptBindings[2].sha256
    }
    $toolchainPath = Join-Path $owned 'toolchain.json'
    Write-DarktideSourceSetupArtifact -Path $toolchainPath -Text (($toolchain | ConvertTo-Json -Depth 20) + [Environment]::NewLine) -ProtectedToken $protectedToken

    $child = Join-Path $owned $script:DarktideChildRunnerName
    [IO.File]::WriteAllBytes($child, [IO.File]::ReadAllBytes((Get-DarktideSourceChildRunnerPath)))
    if ((Get-DarktideFileSha256 -Path $child) -cne (Get-DarktideFileSha256 -Path (Get-DarktideSourceChildRunnerPath))) {
        throw 'Source setup child runner copy differs from the protected driver.'
    }
    $dispatchArguments = Get-DarktideSourceDispatchArguments -ChildPath $child -ToolchainPath $toolchainPath -ToolchainSha256 (Get-DarktideFileSha256 -Path $toolchainPath)
    $frozenPaths = @($PowerShell, $child, $toolchainPath, $runner, $toolchain.skillValidatorPath, $toolchain.skillToolsNodePath, $toolchain.skillToolsEntryPointPath, $toolchain.skillSpectorPath) + @($receiptBindings | ForEach-Object { [string]$_.path })
    $frozen = @(foreach ($file in @($frozenPaths | Select-Object -Unique)) {
        [pscustomobject]@{ path = [IO.Path]::GetFullPath($file); sha256 = Get-DarktideFileSha256 -Path $file }
    })
    Assert-DarktideSourceReceiptClosureFrozen -Bindings $receiptBindings -FrozenFiles $frozen
    Assert-StandardCoreFrozenFiles -Files $frozen
    Assert-StandardCoreSourceToolReceipts -Bindings $receiptBindings -FrozenFiles $frozen -RunId $setupId

    $dispatch = [ordered]@{
        packageAdapter = [ordered]@{ command = $PowerShell; arguments = $dispatchArguments.packageAdapter }
        skillValidator = [ordered]@{ command = $PowerShell; arguments = $dispatchArguments.skillValidator }
        skillTools = [ordered]@{ command = $PowerShell; arguments = $dispatchArguments.skillTools }
        staticAnalyzer = [ordered]@{ command = $PowerShell; arguments = $dispatchArguments.staticAnalyzer }
        frozenFiles = $frozen
        toolReceipts = $receiptBindings
    }
    $prepared = [ordered]@{
        schemaVersion = 1
        preparation = 'darktide-translate-source-tools'
        runId = $setupId
        sourceRevision = $CandidateRevision
        authorityRevision = [string]$AuthorityPin.commit
        ownedRoot = $owned
        sourceValidation = $dispatch
    }
    Write-DarktideSourceSetupArtifact -Path $PreparedPath -Text (($prepared | ConvertTo-Json -Depth 40) + [Environment]::NewLine) -ProtectedToken $protectedToken
}

function Write-DarktideSourceTimingSidecar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $OutputLines,
        [Parameter(Mandatory = $true)][string] $RunId,
        [Parameter(Mandatory = $true)][string] $SourceRevision,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [Parameter(Mandatory = $true)][string] $AuthorityRevision,
        [switch] $RequireCoreEvidence
    )

    $records = [Collections.Generic.List[object]]::new()
    $prefix = '[StandardValidation timing] '
    foreach ($line in $OutputLines) {
        $text = [string]$line
        if (-not $text.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        try { $record = ConvertFrom-Json -InputObject $text.Substring($prefix.Length) -Depth 5 -ErrorAction Stop }
        catch { throw 'Source validation emitted a malformed structured timing record.' }
        Assert-DarktideExactPropertySet -Value $record -Expected @('stage', 'phase', 'state', 'calls', 'files', 'bytes', 'elapsedSeconds') -Context 'Source validation timing record'
        if ([string]$record.stage -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or
            [string]$record.phase -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or
            [string]$record.state -cnotin @('started', 'heartbeat', 'completed', 'failed', 'cancelled')) {
            throw 'Source validation timing record has an invalid stage, phase, or state.'
        }
        $calls = [long]$record.calls
        $files = [long]$record.files
        $bytes = [long]$record.bytes
        $elapsed = [double]$record.elapsedSeconds
        if ($calls -lt 0 -or $files -lt 0 -or $bytes -lt 0 -or [double]::IsNaN($elapsed) -or [double]::IsInfinity($elapsed) -or $elapsed -lt 0) {
            throw 'Source validation timing record has an invalid counter or duration.'
        }
        $records.Add([pscustomobject][ordered]@{
            stage = [string]$record.stage; phase = [string]$record.phase; state = [string]$record.state
            calls = $calls; files = $files; bytes = $bytes; elapsedSeconds = $elapsed
        })
    }
    if ($RequireCoreEvidence) {
        foreach ($phase in @('candidate-inventory', 'file-inventory', 'inventory-sort', 'closure-content-hash')) {
            if (@($records | Where-Object { [string]$_.phase -ceq $phase -and [string]$_.state -ceq 'completed' }).Count -eq 0) {
                throw "Successful source validation omitted completed '$phase' timing evidence."
            }
        }
    }
    $sidecar = [ordered]@{
        schemaVersion = 1
        report = 'standard-core-source-timing-v1'
        runId = $RunId
        sourceRevision = $SourceRevision
        baseRevision = $BaseRevision
        authorityRevision = $AuthorityRevision
        records = @($records.ToArray())
    }
    Write-DarktideUtf8CreateNew -Path $Path -Text (($sidecar | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    return [IO.Path]::GetFullPath($Path)
}

function Read-DarktideSourceToolSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $SourceRevision,
        [Parameter(Mandatory = $true)][string] $AuthorityRevision,
        [Parameter(Mandatory = $true)][string] $PowerShell,
        [Parameter(Mandatory = $true)][string] $AuthorityRoot
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $authorityRunner = Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'
    . $authorityRunner -DefineFunctionsOnly -CandidateRoot $AuthorityRoot -AdapterPath $fullPath -ArtifactsRoot (Split-Path -Parent $fullPath) -SourceRepository $script:DarktideSourceRepository -SourceRevision $SourceRevision -BaseRevision $SourceRevision -AuthorityRevision $AuthorityRevision
    Assert-DarktideNoReparseAncestors -Path $fullPath -Context 'Prepared source setup'
    $prepared = Read-DarktideJsonFile -Path $fullPath -Context 'Prepared source setup'
    Assert-DarktideExactPropertySet -Value $prepared -Expected @('schemaVersion', 'preparation', 'runId', 'sourceRevision', 'authorityRevision', 'ownedRoot', 'sourceValidation') -Context 'Prepared source setup'
    if ([int]$prepared.schemaVersion -ne 1 -or [string]$prepared.preparation -cne 'darktide-translate-source-tools' -or
        [string]$prepared.runId -cnotmatch '^[0-9a-f]{32}$' -or [string]$prepared.sourceRevision -cne $SourceRevision -or
        [string]$prepared.authorityRevision -cne $AuthorityRevision) {
        throw 'Prepared source tools do not bind this candidate and authority.'
    }
    Assert-DarktideExactPropertySet -Value $prepared.sourceValidation -Expected @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer', 'frozenFiles', 'toolReceipts') -Context 'Prepared source dispatch'
    foreach ($slot in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
        Assert-DarktideExactPropertySet -Value $prepared.sourceValidation.$slot -Expected @('command', 'arguments') -Context "Prepared source dispatch $slot"
        if ([string]$prepared.sourceValidation.$slot.command -cne $PowerShell) {
            throw "Prepared source dispatch $slot does not use the verified PowerShell runtime."
        }
    }
    $expectedOwned = Join-Path (Split-Path -Parent $fullPath) "source-tools-$($prepared.runId)"
    if (-not (Test-DarktidePathEqual -Left ([string]$prepared.ownedRoot) -Right $expectedOwned)) { throw 'Prepared source setup owned root differs.' }
    Assert-DarktideNoReparseAncestors -Path $expectedOwned -Context 'Prepared source setup owned root'
    $child = Join-Path $expectedOwned $script:DarktideChildRunnerName
    if ((Get-DarktideFileSha256 -Path $child) -cne (Get-DarktideFileSha256 -Path (Get-DarktideSourceChildRunnerPath))) {
        throw 'Prepared source child runner differs from the protected driver.'
    }
    $toolchain = Join-Path $expectedOwned 'toolchain.json'
    Assert-StandardCoreFrozenFiles -Files @($prepared.sourceValidation.frozenFiles)
    Assert-StandardCoreSourceToolReceipts -Bindings @($prepared.sourceValidation.toolReceipts) -FrozenFiles @($prepared.sourceValidation.frozenFiles) -RunId ([string]$prepared.runId)
    Assert-DarktideSourceReceiptClosureFrozen -Bindings @($prepared.sourceValidation.toolReceipts) -FrozenFiles @($prepared.sourceValidation.frozenFiles)

    $receipts = @{}
    foreach ($receiptBinding in @($prepared.sourceValidation.toolReceipts)) {
        $receipt = Read-DarktideJsonFile -Path ([string]$receiptBinding.path) -Context 'Prepared source resolver receipt'
        $receipts[[string]$receipt.toolName] = $receipt
    }
    $preparedToolchain = Read-DarktideJsonFile -Path $toolchain -Context 'Prepared source toolchain'
    Assert-DarktideExactPropertySet -Value $preparedToolchain -Expected @('centralRunnerPath', 'centralRunnerSha256', 'skillValidatorPath', 'skillValidatorSha256', 'skillToolsNodePath', 'skillToolsNodeSha256', 'skillToolsEntryPointPath', 'skillToolsEntryPointSha256', 'skillSpectorPath', 'skillSpectorSha256', 'skillSpectorReceiptPath', 'skillSpectorReceiptSha256') -Context 'Prepared source toolchain'
    $expectedRunner = [IO.Path]::GetFullPath($authorityRunner)
    if (-not (Test-DarktidePathEqual -Left ([string]$preparedToolchain.centralRunnerPath) -Right $expectedRunner) -or
        [string]$preparedToolchain.centralRunnerSha256 -cne (Get-DarktideFileSha256 -Path $expectedRunner)) {
        throw 'Prepared source toolchain differs from the verified authority files.'
    }
    foreach ($binding in @(
        @{ actualPath = $preparedToolchain.skillValidatorPath; actualSha = $preparedToolchain.skillValidatorSha256; expectedPath = $receipts.'skill-validator'.executablePath; expectedSha = $receipts.'skill-validator'.executableSha256; name = 'skill-validator' },
        @{ actualPath = $preparedToolchain.skillToolsNodePath; actualSha = $preparedToolchain.skillToolsNodeSha256; expectedPath = $receipts.'skill-tools'.nodePath; expectedSha = $receipts.'skill-tools'.nodeSha256; name = 'skill-tools Node' },
        @{ actualPath = $preparedToolchain.skillToolsEntryPointPath; actualSha = $preparedToolchain.skillToolsEntryPointSha256; expectedPath = $receipts.'skill-tools'.entryPointPath; expectedSha = $receipts.'skill-tools'.entryPointSha256; name = 'skill-tools entry point' },
        @{ actualPath = $preparedToolchain.skillSpectorPath; actualSha = $preparedToolchain.skillSpectorSha256; expectedPath = $receipts.skillspector.executablePath; expectedSha = $receipts.skillspector.executableSha256; name = 'skillspector' }
    )) {
        if ([string]$binding.actualPath -cne [string]$binding.expectedPath -or [string]$binding.actualSha -cne [string]$binding.expectedSha) {
            throw "Prepared source toolchain does not match the $($binding.name) resolver receipt."
        }
    }
    $staticReceipt = @($prepared.sourceValidation.toolReceipts | Where-Object { [string]$_.path -ceq [string]$preparedToolchain.skillSpectorReceiptPath })
    if ($staticReceipt.Count -ne 1 -or [string]$staticReceipt[0].sha256 -cne [string]$preparedToolchain.skillSpectorReceiptSha256 -or
        (Read-DarktideJsonFile -Path ([string]$staticReceipt[0].path) -Context 'Prepared Static receipt').toolName -cne 'skillspector') {
        throw 'Prepared source Static receipt differs.'
    }

    $expectedArguments = Get-DarktideSourceDispatchArguments -ChildPath $child -ToolchainPath $toolchain -ToolchainSha256 (Get-DarktideFileSha256 -Path $toolchain)
    foreach ($slot in @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')) {
        if ((ConvertTo-Json -InputObject @($prepared.sourceValidation.$slot.arguments) -Compress) -cne (ConvertTo-Json -InputObject @($expectedArguments[$slot]) -Compress)) {
            throw 'Prepared source dispatch differs from the protected driver.'
        }
    }
    return $prepared
}

function Get-DarktideSourceResolverEnvironment {
    [CmdletBinding()]
    param([switch] $IncludeSetupToken)

    $environment = @{}
    if ($IncludeSetupToken) {
        $token = [Environment]::GetEnvironmentVariable($script:DarktideSetupTokenVariable, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($token)) { $environment['STANDARD_VALIDATION_GITHUB_API_TOKEN'] = $token }
    }
    Remove-Item -LiteralPath "Env:$($script:DarktideSetupTokenVariable)", 'Env:GITHUB_TOKEN', 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue
    return $environment
}

function Assert-DarktideCandidateWhitespace {
    # v1 Stage 5 `git diff --check` over the event range. The Core v2 children
    # only see a .git-less snapshot, so the protected driver enforces it before
    # the central runner starts.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $BaseRevision,
        [Parameter(Mandatory = $true)][string] $CandidateRevision
    )
    $output = @(& $GitPath -c core.whitespace=blank-at-eol,blank-at-eof,space-before-tab -C $RepositoryRoot diff --check "$BaseRevision...$CandidateRevision" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Whitespace validation failed for the candidate event range.`n$($output -join [Environment]::NewLine)"
    }
}

function Invoke-DarktideSourcePurpose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('prepare-source-tools', 'source-validation')][string] $Mode,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][string] $SourceToolsPath,
        [Parameter(Mandatory = $true)][string] $AuthorityRepositoryRoot,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [string] $BaseCommit,
        [string] $ExpectedGoRuntimeVersion,
        [string] $OutputPath,
        [int] $TimeoutSeconds = 900
    )

    $resolverEnvironment = Get-DarktideSourceResolverEnvironment -IncludeSetupToken:($Mode -ceq 'prepare-source-tools')
    $repoRoot = [IO.Path]::GetFullPath($RepositoryRoot)
    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { throw "RepositoryRoot does not exist: $repoRoot" }
    $authorityPin = Assert-DarktideSourceAuthorityConfig -Config (Read-DarktideJsonFile -Path (Join-Path $repoRoot 'config/standard-v1.json') -Context 'candidate config/standard-v1.json')
    $gitPath = Get-DarktideResolvedGitPath
    $pwshPath = Get-DarktideCurrentPowerShellPath
    $candidateCommit = Resolve-DarktideGitRevision -GitPath $gitPath -Root $repoRoot -Revision 'HEAD' -Context 'Candidate revision'
    $dirty = @(& $gitPath -C $repoRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Explicit source purposes require a clean immutable candidate commit.' }
    $protectedReaders = @(Assert-DarktideSourceProtectedReaders -ProtectedBaseRoot (Get-DarktideProtectedDriverRoot) -CandidateRoot $repoRoot)

    $baseRevision = $null
    if ($Mode -ceq 'source-validation') {
        # The workflow computes the merge-base of the event base and candidate;
        # the driver never falls back to HEAD^.
        if ([string]::IsNullOrWhiteSpace($BaseCommit)) { throw 'SourceValidation requires an explicit BaseCommit.' }
        $baseRevision = Resolve-DarktideGitRevision -GitPath $gitPath -Root $repoRoot -Revision $BaseCommit -Context 'Base commit'
        & $gitPath -C $repoRoot merge-base --is-ancestor $baseRevision $candidateCommit
        if ($LASTEXITCODE -ne 0 -or $baseRevision -ceq $candidateCommit) { throw 'Base commit must be a distinct ancestor of the immutable source candidate.' }
        Assert-DarktideCandidateWhitespace -GitPath $gitPath -RepositoryRoot $repoRoot -BaseRevision $baseRevision -CandidateRevision $candidateCommit
    }

    $authorityCheckout = Assert-DarktidePreparedAuthorityCheckout -GitPath $gitPath -AuthorityRoot $AuthorityRepositoryRoot -AuthorityPin $authorityPin
    if (-not (Test-Path -LiteralPath $TrustedToolRoot -PathType Container)) { throw "Trusted PowerShell root is missing: $TrustedToolRoot" }
    $trustedRoot = Resolve-DarktidePhysicalPath -Path $TrustedToolRoot
    $pwshPath = Resolve-DarktidePhysicalPath -Path $pwshPath
    Assert-DarktideNoReparseAncestors -Path $trustedRoot -Context 'Trusted PowerShell root'
    if (-not (Test-DarktidePathWithinOrEqual -Path $pwshPath -Root $trustedRoot) -or (Test-DarktidePathEqual -Left $pwshPath -Right $trustedRoot)) {
        throw 'Trusted PowerShell executable must be within TrustedToolRoot.'
    }

    foreach ($root in @($repoRoot, $authorityCheckout.root, $TrustedToolRoot, (Get-DarktideProtectedDriverRoot))) {
        if ((Test-DarktidePathOverlap -Path $ArtifactsRoot -Root $root) -or (Test-DarktidePathOverlap -Path $root -Root $ArtifactsRoot)) {
            throw "Source artifacts root must not overlap '$root'."
        }
    }
    [void](New-Item -ItemType Directory -Path $ArtifactsRoot -Force)
    $artifactsRootFull = Resolve-DarktidePhysicalPath -Path $ArtifactsRoot
    foreach ($root in @($repoRoot, $authorityCheckout.root, $trustedRoot, (Get-DarktideProtectedDriverRoot))) {
        Assert-DarktideOutsideRoot -Path $artifactsRootFull -Root $root -Context 'Source artifacts root'
        if (Test-DarktidePathOverlap -Path $root -Root $artifactsRootFull) { throw "Source artifacts root must not contain '$root'." }
    }
    [void](New-Item -ItemType Directory -Path $artifactsRootFull -Force)
    Assert-DarktideNoReparseAncestors -Path $artifactsRootFull -Context 'Source artifacts root'

    if ($Mode -ceq 'prepare-source-tools') {
        $sourceToolsParent = Split-Path -Parent ([IO.Path]::GetFullPath($SourceToolsPath))
        if (-not (Test-Path -LiteralPath $sourceToolsParent -PathType Container)) { throw 'Source tools output must be directly within ArtifactsRoot.' }
        $preparedPath = Join-Path (Resolve-DarktidePhysicalPath -Path $sourceToolsParent) (Split-Path -Leaf $SourceToolsPath)
        $preparedPath = Assert-DarktidePathWithinRoot -Path $preparedPath -Root $artifactsRootFull -Context 'Source tools output'
        if (-not (Test-DarktidePathEqual -Left (Split-Path -Parent $preparedPath) -Right $artifactsRootFull)) {
            throw 'Source tools output must be directly within ArtifactsRoot.'
        }
        if (Test-Path -LiteralPath $preparedPath) { throw 'Source tools output already exists.' }
        $goVersion = Resolve-DarktideGoRuntimeVersion -Expected $ExpectedGoRuntimeVersion
        New-DarktideSourceToolSetup -Root $artifactsRootFull -AuthorityRoot $authorityCheckout.root -AuthorityPin $authorityPin `
            -PowerShell $pwshPath -CandidateRevision $candidateCommit -PreparedPath $preparedPath -GoVersion $goVersion `
            -LimitSeconds $TimeoutSeconds -ResolverEnvironment $resolverEnvironment
        return 0
    }

    if (-not (Test-Path -LiteralPath $SourceToolsPath -PathType Leaf)) { throw "Prepared source tools are missing: $SourceToolsPath" }
    $preparedPath = Resolve-DarktidePhysicalPath -Path $SourceToolsPath
    foreach ($root in @($repoRoot, $authorityCheckout.root, $trustedRoot)) {
        Assert-DarktideOutsideRoot -Path $preparedPath -Root $root -Context 'Source tools input'
    }
    $prepared = Read-DarktideSourceToolSetup -Path $preparedPath -SourceRevision $candidateCommit -AuthorityRevision ([string]$authorityPin.commit) -PowerShell $pwshPath -AuthorityRoot $authorityCheckout.root
    $eventName = Get-DarktideEventName
    $activeSkills = @(Get-DarktideActiveSkillIds -Root $repoRoot)
    $runId = [string]$prepared.runId
    $coreArtifactsRoot = Join-Path $artifactsRootFull "source-validation-$runId"
    $adapterLayout = Get-DarktideCoreAdapterLayout -ArtifactsRoot $artifactsRootFull -RunId $runId
    $adapterRoot = [string]$adapterLayout.adapterRoot
    if ((Test-Path -LiteralPath $coreArtifactsRoot) -or (Test-Path -LiteralPath $adapterRoot)) { throw 'Source validation run-owned path unexpectedly exists.' }
    [void](New-Item -ItemType Directory -Path $coreArtifactsRoot -ErrorAction Stop)
    Assert-DarktideNoReparseAncestors -Path $coreArtifactsRoot -Context 'Source validation artifacts root'
    $outputFull = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $coreArtifactsRoot 'darktide-translate-source-validation.json' }
        else { Assert-DarktidePathWithinRoot -Path $OutputPath -Root $coreArtifactsRoot -Context 'Source validation OutputPath' }
    if (Test-Path -LiteralPath $outputFull) { throw 'Source validation output path is not create-only.' }
    $adapterOwned = $false
    $adapterOwnerToken = [guid]::NewGuid().ToString('N')
    try {
        [void](New-Item -ItemType Directory -Path $adapterRoot -ErrorAction Stop)
        $adapterOwned = $true
        Assert-DarktideNoReparseAncestors -Path $adapterRoot -Context 'Core adapter root'
        $ownerMarker = [ordered]@{ owner = 'darktide-translate-source-core-adapter'; runId = $runId; token = $adapterOwnerToken }
        Write-DarktideUtf8CreateNew -Path ([string]$adapterLayout.ownerMarkerPath) -Text (($ownerMarker | ConvertTo-Json -Compress) + [Environment]::NewLine)
        $adapterPath = [string]$adapterLayout.adapterPath
        $adapter = New-DarktideSourceCoreAdapter -PowerShell $pwshPath -ActiveSkillIds $activeSkills -SourceValidation $prepared.sourceValidation
        Write-DarktideUtf8CreateNew -Path $adapterPath -Text (($adapter | ConvertTo-Json -Depth 30) + [Environment]::NewLine)

        $centralRunnerPath = [string]$authorityCheckout.runnerPath
        . $centralRunnerPath -DefineFunctionsOnly -CandidateRoot $repoRoot -AdapterPath $adapterPath -ArtifactsRoot $coreArtifactsRoot `
            -SourceRepository $script:DarktideSourceRepository -SourceRevision $candidateCommit -BaseRevision $baseRevision `
            -AuthorityRevision ([string]$authorityPin.commit) -RunId $runId -EventName $eventName -TimeoutSeconds $TimeoutSeconds
        $validationSecurityPolicy = Read-DarktideJsonFile -Path (Join-Path $authorityCheckout.root 'docs/standards/validation-security-gate.json') -Context 'Prepared authority validation security policy'
        $skillSpectorStages = @($validationSecurityPolicy.stages | Where-Object { [string]$_.id -ceq 'skillspector-static' })
        if ($skillSpectorStages.Count -ne 1 -or $null -eq $skillSpectorStages[0].platformUnavailableException) {
            throw 'Prepared authority validation security policy has no unique SkillSpector platform exception contract.'
        }
        $skillSpectorPlatformPolicy = $skillSpectorStages[0].platformUnavailableException
        $arguments = @(
            '-CandidateRoot', $repoRoot,
            '-AdapterPath', $adapterPath,
            '-ArtifactsRoot', $coreArtifactsRoot,
            '-OutputPath', $outputFull,
            '-SourceRepository', $script:DarktideSourceRepository,
            '-SourceRevision', $candidateCommit,
            '-BaseRevision', $baseRevision,
            '-EventName', $eventName,
            '-AuthorityRevision', [string]$authorityPin.commit,
            '-TimeoutSeconds', [string]$TimeoutSeconds,
            '-TrustedToolRoot', $trustedRoot,
            '-SourceValidation',
            '-RunId', $runId
        )
        $centralOutput = @(& $pwshPath -NoProfile -NonInteractive -File $centralRunnerPath @arguments 2>&1)
        $centralExitCode = $LASTEXITCODE
        $centralOutput | Out-Host
        $timingSidecarPath = Join-Path $artifactsRootFull "source-validation-timing-$runId.json"
        [void](Write-DarktideSourceTimingSidecar -Path $timingSidecarPath -OutputLines @($centralOutput | ForEach-Object { [string]$_ }) `
            -RunId $runId -SourceRevision $candidateCommit -BaseRevision $baseRevision -AuthorityRevision ([string]$authorityPin.commit) `
            -RequireCoreEvidence:($centralExitCode -eq 0))
        Write-Host "Source validation timing sidecar: $timingSidecarPath"
        if ($centralExitCode -ne 0) { return [int]$centralExitCode }
        if (-not (Test-Path -LiteralPath $outputFull -PathType Leaf)) { throw 'Source validation did not write its canonical report.' }
        $reportHashBeforeProjection = Get-DarktideFileSha256 -Path $outputFull
        $report = Read-DarktideJsonFile -Path $outputFull -Context 'Source validation report projection'
        [void](Assert-StandardCoreSourceCheckReport -Report $report -ExpectedSourceRevision $candidateCommit -ExpectedBaseRevision $baseRevision `
            -ExpectedAuthorityRevision ([string]$authorityPin.commit) -ExpectedEventName $eventName -ArtifactsRoot $coreArtifactsRoot `
            -OutputPath $outputFull -ProcessExitCode $centralExitCode -ValidationSecurityPolicy $skillSpectorPlatformPolicy)
        if ((Get-DarktideFileSha256 -Path $outputFull) -cne $reportHashBeforeProjection) { throw 'Source validation report bytes changed during final projection.' }
        Write-Host ("Protected readers verified: {0}" -f (($protectedReaders | ForEach-Object { "$($_.path)=$($_.sha256)" }) -join '; '))
        return 0
    }
    finally {
        if ($adapterOwned) {
            Remove-DarktideOwnedCoreAdapterRoot -OwnedRoot $adapterRoot -ArtifactsRoot $artifactsRootFull -RunId $runId `
                -OwnerToken $adapterOwnerToken -ProtectedRoots @($repoRoot, $authorityCheckout.root, $trustedRoot, $coreArtifactsRoot)
        }
    }
}

function Invoke-DarktideSourceEntryPoint {
    # Validate.ps1 dispatches here before any v1 Windows-only gate or type.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $BoundParameters, [string] $DefaultArtifactsRoot)

    $boundNames = @($BoundParameters.Keys | ForEach-Object { [string]$_ })
    $get = { param([string] $Name, $Default) if ($boundNames -ccontains $Name) { $BoundParameters[$Name] } else { $Default } }
    $route = Resolve-DarktideSourceRoute -AdapterVersion ([int](& $get 'AdapterVersion' 1)) `
        -PrepareSourceTools:([bool](& $get 'PrepareSourceTools' $false)) -SourceValidation:([bool](& $get 'SourceValidation' $false)) `
        -SourceToolsPath ([string](& $get 'SourceToolsPath' '')) -AuthorityRepositoryRoot ([string](& $get 'AuthorityRepositoryRoot' '')) `
        -TrustedToolRoot ([string](& $get 'TrustedToolRoot' '')) -BoundParameters $BoundParameters
    if ([string]$route.mode -ceq 'v1') { throw 'Invoke-DarktideSourceEntryPoint only handles explicit Core v2 source purposes.' }
    $repositoryRoot = [string](& $get 'RepositoryRoot' '')
    if ([string]::IsNullOrWhiteSpace($repositoryRoot)) { $repositoryRoot = Get-DarktideProtectedDriverRoot }
    $artifactsRoot = [string](& $get 'ArtifactsRoot' $DefaultArtifactsRoot)
    if ([string]::IsNullOrWhiteSpace($artifactsRoot)) { throw 'Explicit source purposes require ArtifactsRoot.' }
    return Invoke-DarktideSourcePurpose -Mode ([string]$route.mode) -RepositoryRoot $repositoryRoot -ArtifactsRoot $artifactsRoot `
        -SourceToolsPath ([string](& $get 'SourceToolsPath' '')) -AuthorityRepositoryRoot ([string](& $get 'AuthorityRepositoryRoot' '')) `
        -TrustedToolRoot ([string](& $get 'TrustedToolRoot' '')) -BaseCommit ([string](& $get 'BaseCommit' '')) `
        -ExpectedGoRuntimeVersion ([string](& $get 'ExpectedGoRuntimeVersion' $env:STANDARD_GO_RUNTIME_VERSION)) `
        -OutputPath ([string](& $get 'OutputPath' '')) -TimeoutSeconds ([int](& $get 'TimeoutSeconds' 900))
}

Export-ModuleMember -Function Get-DarktideSourceAuthorityPin, Assert-DarktideSourceAuthorityTuple, Assert-DarktideSourceAuthorityConfig, Resolve-DarktideSourceRoute, Get-DarktideSourceChildRunnerPath, Assert-DarktideSourceProtectedReaders, Assert-DarktidePreparedAuthorityCheckout, Get-DarktideCoreAdapterLayout, New-DarktideSourceCoreAdapter, Get-DarktideSourceDispatchArguments, Assert-DarktideSourceReceiptClosureFrozen, Write-DarktideSourceTimingSidecar, Get-DarktideSourceResolverEnvironment, Assert-DarktideCandidateWhitespace, Get-DarktideActiveSkillIds, Invoke-DarktideSourcePurpose, Invoke-DarktideSourceEntryPoint, Test-DarktidePathOverlap
