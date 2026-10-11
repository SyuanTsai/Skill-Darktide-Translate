# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $ArtifactsRoot = $([IO.Path]::GetTempPath()),
    [string] $AuthorityArchivePath,
    [string] $AuthorityRepositoryRoot,
    [string] $TrustedToolRoot,
    [string] $BaseCommit,
    [string] $ExpectedGoRuntimeVersion = $env:STANDARD_GO_RUNTIME_VERSION,
    [string] $OutputPath,
    [switch] $PrepareSourceTools,
    [switch] $SourceValidation,
    [string] $SourceToolsPath,
    [ValidateRange(1,10800)][int] $TimeoutSeconds = 1800
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SourceRepository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
$script:AuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$script:SourceAuthorityCommit = 'ff85d5f80fe795b96354e753074b5ce59ad04ecd'
$script:SourceAuthorityArchiveSha256 = '3dc38613f2e2316ad8fcc79d4bf48d0b03fd8398f8dacc72d156abcbce95ea9d'
$script:SourceAuthorityFiles = [ordered]@{
    'docs/standards/README.md' = '43c1526ac55302f62b706688905be160d9805cc3a6a800189d689e66fa727b71'
    'docs/standards/managed-skill-lifecycle.md' = '70950cf8bdd02819efae6f6e06ac5be1da3e70f809c23e3c6f8d3b217797416c'
    'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json' = '9a7f4c02588d2b88194e953a41766a72a9426fa89d4c3781c5750dcc22d35863'
    'docs/standards/schemas/openai-agent-metadata.schema.json' = '23c1aaee28a54fea1946a61d6122a2097906ffa5bdd66c8014fc6b1625c9062a'
    'docs/standards/schemas/source-inventory-v2.schema.json' = '084550944b4141ab5535f58fb6e99730a5c34b56103f6b59fd5a352679caa98e'
    'docs/standards/schemas/validation-security-gate-v1.schema.json' = 'ac58302e0e350c1ab4ba4dad8a33cd3abce12d592537fbdb23dfb1936d064e91'
    'docs/standards/skill-repository-review-matrix.md' = '299925aabe3cab360827baad9bdeb1f0f56fc320dad967e49fe0b6bf9cdf8f8a'
    'docs/standards/skill-repository-standard.md' = '86a24a75eaf96f9eaa02307937a46d1b2ce788cf63b4657c60bec9815b2ca4b3'
    'docs/standards/upstream-interoperability.md' = '4329e8586e88713027bcd95c7537331e050a89b004f2361223efdc01bf44370e'
    'docs/standards/validation-security-gate.json' = '657122dde340f1f7f4442780cc27ffcb00b60c0d2afdcea22d63fbf7dbfdca7d'
    'docs/standards/validation-toolchain.json' = '1dddbf4c5736e22e56f6ecb298542f41d39e116ab00ca24ad18beb7a3eab40ed'
    'scripts/Invoke-StandardAuthorityGate.ps1' = '8e00ee1e48ef8359ab7be3539f8f7585ccde18b41e26d810843715ebc3656a4c'
    'scripts/Resolve-PythonWheelClosure.py' = 'f9fcd99c408849f98564fbc4c30f3d7e6ad8148b60cb4d8f58fc29b040c4519c'
    'scripts/Resolve-StandardValidationTool.ps1' = '71e6d5b191b74202e96f34a856d3317efb18662e17c8368d112d89b7d6795b15'
    'docs/standards/schemas/standard-validation-adapter-v1.schema.json' = '11aa88fc25716d748bd4f514f1a44f02390ad1745dd5a5c5beee07f642fd5639'
    'docs/standards/schemas/standard-validation-evidence-v1.schema.json' = '8ed4a9d7158273d7a1e9d898acf07f57e9170822cb7cbb70f1e2eec7195867ee'
    'docs/standards/standard-validation-contract-v1.json' = '707edf8945ad9a7097df1dfb22a8f05ce47d0e0a66e2e44381036d630e854da0'
    'docs/standards/pr12-source-merge-adoption.json' = '4c5262f2a11d228195230c15fa4faaf9614af6b59f110e5d9c08f242ce809175'
    'docs/standards/trust-anchors/human-approval-public-key.xml' = '1e46153b72d02f3ce2fb26becd449df4f1590d8e5cb441b1954006a5602bbd9b'
    'docs/standards/trust-anchors/trusted-supervisor-public-key.xml' = '4d550851f43405920156f40c9fc648d99a69dd73efc200f6968d8a837e7fbf27'
    'scripts/Invoke-StandardValidation.ps1' = 'a4ee880810171428a6abd2e8fd5db2da1eaeda4abc0fc6c72dc259b4a709174b'
    'docs/standards/schemas/standard-semantic-consent-evidence-v2.schema.json' = '109091979d0a47e2035d3d8b20963fcdb85680e5da737bf1f27121608115d430'
    'scripts/StandardSemanticBridge.psm1' = 'daf90f703898cc56fc3310e1eec462bafa6552edcac0de4f08a3cd4b9f63a429'
    'docs/standards/schemas/upstream-adapter-v1.schema.json' = '3cff6246463188a91cc54c6a46315a949314767a759c6214e5b28e4db95ac8d7'
    'docs/standards/upstream-adapter.json' = 'c4f5133b24841bb9c66182dc3d5a027596f864ec28e410d47249a67b3b97ad31'
    'scripts/Validate-UpstreamAdapter.ps1' = '3b6e6474690b1ae9f9486544b68f50ca29b96f5dbe6aa8d6c6cd8570afad500b'
    'docs/standards/standard-core-validation-v2.json' = '2ba91aec827a642517fd90d294524e0dfc3fed9ae19c27d867d442d73b4915d6'
    'docs/standards/schemas/standard-core-adapter-v2.schema.json' = '7399980e8765528b759a3734a133447eb9581ac24a9c4780dc8faadd6af0c1c5'
    'docs/standards/schemas/standard-core-evidence-v2.schema.json' = '4a8c61f32484bfe928e4f15f6422de7dc7b63d9d1fc95bca4f8f5c4c37334d24'
    'docs/standards/third-party-raw-skill-sources.md' = '18649fd56eada4a94a5d47de778669b0ebcecfb85b84f5c581d283b21979f7ac'
    'docs/standards/schemas/third-party-raw-skill-source-v1.schema.json' = '9d8585d95c606486f947a3f89e39341af840335376e86910eb7f4ed25bdc16ed'
    'docs/standards/examples/third-party-raw-skill-source-v1.json' = 'decbf276cbeea33c60d8b36b7b16838babe951cd84d13ae4a8a7a8261dc6d9c8'
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Value -or $Value -is [array] -or $Value -is [string] -or $null -eq $Value.PSObject) {
        throw "$Context must be a JSON object."
    }
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

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-GitBlobSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $Revision,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [ValidateRange(1, 300)][int] $ProcessTimeoutSeconds = 30
    )

    $normalizedPath = $RelativePath.Replace([char]92, [char]47)
    $treeInfo = [Diagnostics.ProcessStartInfo]::new()
    $treeInfo.FileName = $GitPath
    $treeInfo.UseShellExecute = $false
    $treeInfo.CreateNoWindow = $true
    $treeInfo.RedirectStandardOutput = $true
    $treeInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $RepositoryRoot, 'ls-tree', $Revision, '--', $normalizedPath)) {
        [void]$treeInfo.ArgumentList.Add($argument)
    }
    $treeProcess = [Diagnostics.Process]::new()
    $treeProcess.StartInfo = $treeInfo
    $treeStarted = $false
    $treeFailure = $null
    $treeCleanupError = $null
    $treeOutput = $null
    try {
        if (-not $treeProcess.Start()) { throw "Could not start Git tree lookup for '$normalizedPath'." }
        $treeStarted = $true
        $treeClock = [Diagnostics.Stopwatch]::StartNew()
        $treeOutputTask = $treeProcess.StandardOutput.ReadToEndAsync()
        $treeErrorTask = $treeProcess.StandardError.ReadToEndAsync()
        while (-not ($treeProcess.HasExited -and $treeOutputTask.IsCompleted -and $treeErrorTask.IsCompleted)) {
            if ($treeClock.Elapsed.TotalSeconds -ge $ProcessTimeoutSeconds) {
                throw "Git tree lookup timed out after $ProcessTimeoutSeconds seconds for '$normalizedPath'."
            }
            [void]$treeProcess.WaitForExit(100)
        }
        $treeOutput = $treeOutputTask.GetAwaiter().GetResult()
        [void]$treeErrorTask.GetAwaiter().GetResult()
        if ($treeProcess.ExitCode -ne 0) { throw "Pinned authority path is not one tracked file: $normalizedPath" }
    }
    catch { $treeFailure = $_ }
    finally {
        if ($treeStarted -and -not $treeProcess.HasExited) {
            try { $treeProcess.Kill($true) }
            catch { if (-not $treeProcess.HasExited) { $treeCleanupError = $_.Exception.Message } }
            if (-not $treeProcess.WaitForExit(5000)) { $treeCleanupError = 'Git tree lookup did not exit after owned process-tree termination.' }
        }
        $treeProcess.Dispose()
    }
    if ($null -ne $treeCleanupError) { throw "Git tree lookup cleanup failed for '$normalizedPath': $treeCleanupError" }
    if ($null -ne $treeFailure) { throw $treeFailure }
    $treeEntry = @($treeOutput -split '\r?\n' | Where-Object { $_.Length -gt 0 })
    if ($treeEntry.Count -ne 1) { throw "Pinned authority path is not one tracked file: $normalizedPath" }
    $treePattern = '^(?<mode>100644|100755) blob (?<objectId>[0-9a-f]{40})\t' + [regex]::Escape($normalizedPath) + '$'
    if ([string]$treeEntry[0] -cnotmatch $treePattern) { throw "Pinned authority path is not a regular Git blob: $normalizedPath" }
    $objectId = [string]$Matches.objectId

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-C', $RepositoryRoot, 'cat-file', 'blob', $objectId)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $hasher = [Security.Cryptography.SHA256]::Create()
    $started = $false
    $failure = $null
    $cleanupError = $null
    $result = $null
    try {
        if (-not $process.Start()) { throw "Could not start Git blob reader for '$normalizedPath'." }
        $started = $true
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $hashTask = $hasher.ComputeHashAsync($process.StandardOutput.BaseStream)
        $stderrTail = [Text.StringBuilder]::new()
        $stderrLimit = 4096
        $stderrTruncated = $false
        $stderrBuffer = [char[]]::new(4096)
        $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
        $stderrDone = $false
        while ($true) {
            if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
                $readCount = $stderrTask.GetAwaiter().GetResult()
                if ($readCount -eq 0) {
                    $stderrDone = $true
                    $stderrTask = $null
                }
                else {
                    $take = [Math]::Min($readCount, $stderrLimit - $stderrTail.Length)
                    if ($take -gt 0) { [void]$stderrTail.Append($stderrBuffer, 0, $take) }
                    if ($take -lt $readCount) { $stderrTruncated = $true }
                    $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
                }
            }
            if ($process.HasExited -and $hashTask.IsCompleted -and $stderrDone) { break }
            if ($clock.Elapsed.TotalSeconds -ge $ProcessTimeoutSeconds) {
                throw "Git blob reader timed out after $ProcessTimeoutSeconds seconds for '$normalizedPath'."
            }
            if ($null -ne $stderrTask) { [void]$stderrTask.Wait(100) }
            elseif (-not $process.HasExited) { [void]$process.WaitForExit(100) }
            else { Start-Sleep -Milliseconds 50 }
        }
        $hash = $hashTask.GetAwaiter().GetResult()
        $stderr = $stderrTail.ToString()
        if ($stderrTruncated) { $stderr += '[truncated]' }
        if ($process.ExitCode -ne 0) {
            throw "Git blob reader failed for '$normalizedPath' with exit $($process.ExitCode): $stderr"
        }
        $result = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    catch { $failure = $_ }
    finally {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true) }
            catch { if (-not $process.HasExited) { $cleanupError = $_.Exception.Message } }
            if (-not $process.WaitForExit(5000)) { $cleanupError = 'Git blob reader did not exit after owned process-tree termination.' }
        }
        $hasher.Dispose()
        $process.Dispose()
    }
    if ($null -ne $cleanupError) { throw "Git blob reader cleanup failed for '$normalizedPath': $cleanupError" }
    if ($null -ne $failure) { throw $failure }
    return $result
}

function Test-AuthorityWorktreeSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )

    # Git may check out text with CRLF on Windows. Compare actual bytes first,
    # then permit only that line-ending conversion from the pinned Git blob.
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $actual = ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
        if ($actual -ceq $ExpectedSha256) { return $true }
        $normalized = [IO.MemoryStream]::new($bytes.Length)
        try {
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                if ($bytes[$index] -eq 13 -and $index + 1 -lt $bytes.Length -and $bytes[$index + 1] -eq 10) {
                    continue
                }
                $normalized.WriteByte($bytes[$index])
            }
            $actual = ([BitConverter]::ToString($hasher.ComputeHash($normalized.ToArray())) -replace '-', '').ToLowerInvariant()
            return $actual -ceq $ExpectedSha256
        }
        finally { $normalized.Dispose() }
    }
    finally { $hasher.Dispose() }
}

function Assert-Sha256 {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Context)
    if ($Value -cnotmatch '^[0-9a-f]{64}$') { throw "$Context must be a lowercase SHA-256 value." }
}

function Test-PathWithinOrEqual {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Test-PathEqual {
    param([Parameter(Mandatory = $true)][string] $Left, [Parameter(Mandatory = $true)][string] $Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right), $comparison)
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-PathWithinOrEqual -Path $fullPath -Root $Root)) { throw "$Context must stay within '$Root': $Path" }
    return $fullPath
}

function Assert-OutsideRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if (Test-PathWithinOrEqual -Path $Path -Root $Root) { throw "$Context must be outside '$Root': $Path" }
}

function Assert-NoReparseAncestors {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Context is backed by a reparse point: $current" }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), $Text, [Text.UTF8Encoding]::new($false))
}

function Write-Utf8NoBomCreateNew {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Text)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $stream = $null
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-ResolvedGitPath {
    $command = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    return [IO.Path]::GetFullPath([string]$command.Path)
}

function Get-ResolvedPowerShellPath {
    $path = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    if ([IO.Path]::GetFileName($path) -cnotin @('pwsh.exe','pwsh') -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Canonical validation must run in the verified PowerShell executable.'
    }
    return $path
}

function Resolve-GitRevision {
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

function Resolve-GoRuntimeVersion {
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

function Get-EventName {
    $event = [string]$env:GITHUB_EVENT_NAME
    switch ($event) {
        'pull_request' { return 'pull_request' }
        'push' { return 'push' }
        'workflow_dispatch' { return 'workflow_dispatch' }
        'pre-push' { return 'pre-push' }
        default { return 'local' }
    }
}

function Assert-StandardCoreAuthorityCheckout {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $AuthorityRoot,
        [Parameter(Mandatory = $true)] $AuthorityPin
    )

    $fullRoot = [IO.Path]::GetFullPath($AuthorityRoot)
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) { throw "Pinned authority Git checkout is missing: $fullRoot" }
    Assert-NoReparseAncestors -Path $fullRoot -Context 'Pinned authority checkout'
    $top = @(& $GitPath -C $fullRoot rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $top.Count -ne 1 -or -not (Test-PathEqual -Left ([string]$top[0]) -Right $fullRoot)) {
        throw 'Pinned authority path is not the root of a Git checkout.'
    }
    $head = Resolve-GitRevision -GitPath $GitPath -Root $fullRoot -Revision 'HEAD' -Context 'Pinned authority HEAD'
    if ($head -cne [string]$AuthorityPin.commit) { throw 'Pinned authority checkout HEAD does not match the selected authority revision.' }
    $origins = @(& $GitPath -C $fullRoot config --local --get-all remote.origin.url 2>$null)
    if ($LASTEXITCODE -ne 0 -or $origins.Count -ne 1) { throw 'Pinned authority checkout must have exactly one origin URL.' }
    $origin = ([string]$origins[0]).Trim().TrimEnd('/') -replace '\.git$', ''
    $expectedOrigin = ([string]$AuthorityPin.repository).Trim().TrimEnd('/') -replace '\.git$', ''
    if (-not $origin.Equals($expectedOrigin, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Pinned authority checkout origin does not match the selected authority repository.'
    }
    $dirty = @(& $GitPath -C $fullRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Pinned authority checkout must be clean and immutable.' }

    foreach ($entry in $AuthorityPin.files.GetEnumerator()) {
        $filePath = Assert-PathWithinRoot -Path (Join-Path $fullRoot ($entry.Key -replace '/', [IO.Path]::DirectorySeparatorChar)) -Root $fullRoot -Context 'Pinned authority file'
        Assert-NoReparseAncestors -Path $filePath -Context 'Pinned authority file'
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf) -or
            (Get-GitBlobSha256 -GitPath $GitPath -RepositoryRoot $fullRoot -Revision $head -RelativePath $entry.Key) -cne [string]$entry.Value -or
            -not (Test-AuthorityWorktreeSha256 -Path $filePath -ExpectedSha256 ([string]$entry.Value))) {
            throw "Pinned authority file identity mismatch: $($entry.Key)"
        }
    }
    $coreContract = Join-Path $fullRoot 'docs/standards/standard-core-validation-v2.json'
    Assert-NoReparseAncestors -Path $coreContract -Context 'Pinned Core v2 contract'
    if (-not (Test-Path -LiteralPath $coreContract -PathType Leaf)) {
        throw 'Pinned authority checkout is missing the tracked Core v2 contract.'
    }
    $coreContractSha256 = Get-GitBlobSha256 -GitPath $GitPath -RepositoryRoot $fullRoot -Revision $head -RelativePath 'docs/standards/standard-core-validation-v2.json'
    if (-not (Test-AuthorityWorktreeSha256 -Path $coreContract -ExpectedSha256 $coreContractSha256)) {
        throw 'Pinned Core v2 contract worktree content differs from the immutable authority commit.'
    }
    return [pscustomobject]@{
        root = $fullRoot
        runnerPath = (Join-Path $fullRoot 'scripts/Invoke-StandardValidation.ps1')
        revision = $head
    }
}

function New-StandardCoreAuthoritySnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $SourceRoot,
        [Parameter(Mandatory = $true)][string] $OwnedRoot,
        [Parameter(Mandatory = $true)] $AuthorityPin
    )

    $snapshotRoot = Assert-PathWithinRoot -Path (Join-Path $OwnedRoot 'authority') -Root $OwnedRoot -Context 'Core authority snapshot'
    if (Test-Path -LiteralPath $snapshotRoot) { throw 'Core authority snapshot path already exists.' }
    $hooksRoot = Join-Path $OwnedRoot '.empty-git-hooks'
    [void](New-Item -ItemType Directory -Path $hooksRoot -ErrorAction Stop)
    Assert-NoReparseAncestors -Path $hooksRoot -Context 'Core authority snapshot hooks'
    # A local no-hardlink clone copies available Git objects, including partial
    # clone packs, without sharing the caller's mutable worktree or object files.
    & $GitPath -c "core.hooksPath=$hooksRoot" -c core.autocrlf=false -c core.longpaths=true clone --quiet --local --no-hardlinks --no-checkout -- $SourceRoot $snapshotRoot
    if ($LASTEXITCODE -ne 0) { throw 'Could not materialize the pinned authority Git objects in the run-owned snapshot.' }
    & $GitPath -C $snapshotRoot config --local core.autocrlf false
    if ($LASTEXITCODE -ne 0) { throw 'Could not disable checkout line-ending conversion in the authority snapshot.' }
    & $GitPath -C $snapshotRoot config --local core.longpaths true
    if ($LASTEXITCODE -ne 0) { throw 'Could not enable long paths in the authority snapshot.' }
    $snapshotPaths = @($AuthorityPin.files.Keys) + @('docs/standards/standard-core-validation-v2.json')
    & $GitPath -c "core.hooksPath=$hooksRoot" -C $snapshotRoot sparse-checkout set --no-cone -- $snapshotPaths
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the pinned authority files for the run-owned snapshot.' }
    & $GitPath -C $snapshotRoot config --local --replace-all remote.origin.url ([string]$AuthorityPin.repository)
    if ($LASTEXITCODE -ne 0) { throw 'Could not bind the authority snapshot origin.' }
    & $GitPath -c "core.hooksPath=$hooksRoot" -c core.autocrlf=false -C $snapshotRoot checkout --quiet --detach ([string]$AuthorityPin.commit)
    if ($LASTEXITCODE -ne 0) { throw 'Could not check out the exact pinned authority commit.' }
    return Assert-StandardCoreAuthorityCheckout -GitPath $GitPath -AuthorityRoot $snapshotRoot -AuthorityPin $AuthorityPin
}

function New-StandardCoreAdapterV2 {
    param(
        [Parameter(Mandatory = $true)][string] $PowerShellPath,
        [Parameter(Mandatory = $true)][string] $TrustedToolRoot,
        [Parameter(Mandatory = $true)][string] $CandidateAuthorityAdapterRunId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ActiveSkillIds
    )

    $fullPowerShellPath = [IO.Path]::GetFullPath($PowerShellPath)
    $fullTrustedToolRoot = [IO.Path]::GetFullPath($TrustedToolRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not (Test-Path -LiteralPath $fullPowerShellPath -PathType Leaf) -or
        (-not $fullPowerShellPath.Equals($fullTrustedToolRoot, $comparison) -and
         -not $fullPowerShellPath.StartsWith($fullTrustedToolRoot + [IO.Path]::DirectorySeparatorChar, $comparison))) {
        throw 'Trusted PowerShell executable must be a regular file within TrustedToolRoot.'
    }
    if ($CandidateAuthorityAdapterRunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Core Pester requires the canonical outer adapter run identity.'
    }
    if ($ActiveSkillIds.Count -eq 0) { throw 'Core adapter requires at least one active Skill.' }
    foreach ($skillId in $ActiveSkillIds) {
        if ($skillId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Core adapter contains an invalid active Skill ID: '$skillId'." }
    }
    $powerShellSha256 = (Get-FileHash -LiteralPath $fullPowerShellPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $generalArguments = @('-NoProfile', '-NonInteractive', '-File', 'scripts/Test-Repository.ps1', '-ReadOnlySnapshot')
    $pesterArguments = @('-NoProfile', '-NonInteractive', '-File', 'scripts/Invoke-CorePester.ps1',
        '-CandidateAuthorityAdapterRunId', $CandidateAuthorityAdapterRunId)
    return [ordered]@{
        schemaVersion = 2
        adapter = 'standard-core-adapter-v2'
        skillsRoot = 'skills'
        activeSkills = @($ActiveSkillIds)
        checks = @(
            [ordered]@{ id = 'repository-general'; kind = 'general'; executable = $fullPowerShellPath; executableSha256 = $powerShellSha256; arguments = $generalArguments },
            [ordered]@{ id = 'repository-pester'; kind = 'pester'; executable = $fullPowerShellPath; executableSha256 = $powerShellSha256; arguments = $pesterArguments }
        )
    }
}

function New-SourceToolSetup {
    param([string] $Root, [string] $AuthorityRoot, $AuthorityPin, [string] $PowerShell,
        [string] $CandidateRevision, [string] $Git, [string] $CandidateRoot,
        [string] $PreparedPath, [string] $GoVersion, [int] $LimitSeconds)
    $setupId = [guid]::NewGuid().ToString('N')
    $owned = Assert-PathWithinRoot -Path (Join-Path $Root "source-tools-$setupId") -Root $Root -Context 'Source setup owned root'
    if (Test-Path -LiteralPath $owned) { throw 'Source setup root already exists.' }
    [void](New-Item -ItemType Directory -Path $owned -ErrorAction Stop)
    Assert-NoReparseAncestors -Path $owned -Context 'Source setup owned root'
    $runner = Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'
    . $runner -DefineFunctionsOnly -CandidateRoot $CandidateRoot -AdapterPath $PreparedPath -ArtifactsRoot $Root `
        -SourceRepository $script:SourceRepository -SourceRevision $CandidateRevision -BaseRevision $CandidateRevision
    $resolver = Join-Path $AuthorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
    $policy = Join-Path $AuthorityRoot 'docs/standards/validation-toolchain.json'
    $receipts = [ordered]@{}
    $receiptBindings = @()
    foreach ($tool in @('skill-validator', 'skill-tools', 'skillspector')) {
        $receiptPath = Join-Path $owned "receipt-$tool.json"
        $result = Invoke-StandardValidationProcess -Command $PowerShell -Arguments @('-NoProfile','-NonInteractive','-File',$resolver,
            '-PolicyPath',$policy,'-ToolName',$tool,'-Install','-InstallRoot',(Join-Path $owned 'installed'),
            '-ExpectedGoRuntimeVersion',$GoVersion,'-RunId',$setupId,'-OutputPath',$receiptPath) `
            -WorkingDirectory $owned -Environment @{} -TimeoutSeconds $LimitSeconds -CoreLifecycleOnly
        Write-Utf8NoBomCreateNew -Path (Join-Path $owned "setup-$tool-process.json") -Text ($result | ConvertTo-Json -Depth 30)
        if ($result.status -cne 'passed' -or $result.exitCode -ne 0 -or -not $result.cleanedUp) { throw "Source setup $tool failed: $($result.status), exit=$($result.exitCode), cleanup=$($result.cleanedUp). $($result.stderr)" }
        $receipts[$tool] = Read-JsonFile -Path $receiptPath -Context "$tool source receipt"
        $receiptBindings += [pscustomobject]@{path=$receiptPath;sha256=(Get-FileSha256 -Path $receiptPath)}
    }
    $toolchain = [ordered]@{
        centralRunnerPath=$runner; centralRunnerSha256=(Get-FileSha256 -Path $runner)
        upstreamAdapterValidatorPath=(Join-Path $AuthorityRoot 'scripts/Validate-UpstreamAdapter.ps1')
        upstreamAdapterValidatorSha256=(Get-FileSha256 -Path (Join-Path $AuthorityRoot 'scripts/Validate-UpstreamAdapter.ps1'))
        upstreamPolicyPath=(Join-Path $AuthorityRoot 'docs/standards/upstream-adapter.json')
        upstreamPolicySha256=(Get-FileSha256 -Path (Join-Path $AuthorityRoot 'docs/standards/upstream-adapter.json'))
        skillValidatorPath=[string]$receipts.'skill-validator'.executablePath; skillValidatorSha256=[string]$receipts.'skill-validator'.executableSha256
        skillToolsNodePath=[string]$receipts.'skill-tools'.nodePath; skillToolsNodeSha256=[string]$receipts.'skill-tools'.nodeSha256
        skillToolsEntryPointPath=[string]$receipts.'skill-tools'.entryPointPath; skillToolsEntryPointSha256=[string]$receipts.'skill-tools'.entryPointSha256
        skillSpectorPath=[string]$receipts.skillspector.executablePath; skillSpectorSha256=[string]$receipts.skillspector.executableSha256
        skillSpectorReceiptPath=[string]$receiptBindings[2].path; skillSpectorReceiptSha256=[string]$receiptBindings[2].sha256
    }
    $toolchainPath = Join-Path $owned 'toolchain.json'
    Write-Utf8NoBomCreateNew -Path $toolchainPath -Text ($toolchain | ConvertTo-Json -Depth 20)
    $wrapper = Join-Path $owned 'Invoke-DarktideValidationChild.ps1'
    Write-Utf8NoBomCreateNew -Path $wrapper -Text $childRunnerText
    $archive = Join-Path $owned 'candidate.zip'
    & $Git -C $CandidateRoot archive --format=zip "--output=$archive" $CandidateRevision
    if ($LASTEXITCODE -ne 0) { throw 'Source setup could not archive the exact candidate.' }
    $arguments = @('-NoProfile','-NonInteractive','-File',$wrapper,'-ToolchainPath',$toolchainPath,
        '-ToolchainSha256',(Get-FileSha256 -Path $toolchainPath),'-SourceRepository',$script:SourceRepository,
        '-SourceRevision',$CandidateRevision,'-ArchiveSha256',(Get-FileSha256 -Path $archive))
    $files = @($PowerShell,$wrapper,$toolchainPath,$runner,$toolchain.upstreamAdapterValidatorPath,$toolchain.upstreamPolicyPath,
        $toolchain.skillValidatorPath,[string]$receipts.'skill-tools'.executablePath,$toolchain.skillToolsNodePath,$toolchain.skillToolsEntryPointPath,$toolchain.skillSpectorPath) + @($receiptBindings.path)
    $frozen = @(foreach ($file in @($files | Select-Object -Unique)) { [pscustomobject]@{path=[IO.Path]::GetFullPath($file);sha256=(Get-FileSha256 -Path $file)} })
    Assert-StandardCoreFrozenFiles -Files $frozen
    Assert-StandardCoreSourceToolReceipts -Bindings $receiptBindings -FrozenFiles $frozen -RunId $setupId
    $dispatch = [ordered]@{
        packageAdapter=[ordered]@{command=$PowerShell;arguments=@($arguments + @('-Mode','package-adapter'))}
        skillValidator=[ordered]@{command=$PowerShell;arguments=@($arguments + @('-Mode','skill-validator'))}
        skillTools=[ordered]@{command=$PowerShell;arguments=@($arguments + @('-Mode','skill-tools'))}
        staticAnalyzer=[ordered]@{command=$PowerShell;arguments=@($arguments + @('-Mode','static'))}
        frozenFiles=$frozen;toolReceipts=$receiptBindings
    }
    Write-Utf8NoBomCreateNew -Path $PreparedPath -Text ([ordered]@{
        schemaVersion=1; preparation='darktide-source-tools';runId=$setupId;sourceRevision=$CandidateRevision
        authorityRevision=[string]$AuthorityPin.commit;ownedRoot=$owned;sourceValidation=$dispatch
    } | ConvertTo-Json -Depth 40)
}

function Read-SourceToolSetup {
    param([string] $Path, [string] $SourceRevision, [string] $AuthorityRevision, [string] $PowerShell, [string] $AuthorityRoot)
    if (-not [string]::IsNullOrWhiteSpace($AuthorityRoot)) {
        . (Join-Path $AuthorityRoot 'scripts/Invoke-StandardValidation.ps1') -DefineFunctionsOnly `
            -CandidateRoot $AuthorityRoot -AdapterPath $Path -ArtifactsRoot (Split-Path -Parent $Path) `
            -SourceRepository $script:SourceRepository -SourceRevision $SourceRevision -BaseRevision $SourceRevision -AuthorityRevision $AuthorityRevision
    }
    Assert-NoReparseAncestors -Path $Path -Context 'Prepared source setup'
    $prepared = Read-JsonFile -Path $Path -Context 'Prepared source setup'
    Assert-ExactPropertySet -Value $prepared -Expected @('schemaVersion','preparation','runId','sourceRevision','authorityRevision','ownedRoot','sourceValidation') -Context 'Prepared source setup'
    if ($prepared.schemaVersion -ne 1 -or $prepared.preparation -cne 'darktide-source-tools' -or
        $prepared.runId -cnotmatch '^[0-9a-f]{32}$' -or $prepared.sourceRevision -cne $SourceRevision -or
        $prepared.authorityRevision -cne $AuthorityRevision -or $prepared.sourceValidation.packageAdapter.command -cne $PowerShell) {
        throw 'Prepared source tools do not bind this candidate, authority and runtime.'
    }
    $expectedOwned = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) "source-tools-$($prepared.runId)"
    if (-not (Test-PathEqual -Left $prepared.ownedRoot -Right $expectedOwned)) { throw 'Prepared source setup owned root differs.' }
    Assert-NoReparseAncestors -Path $expectedOwned -Context 'Prepared source setup owned root'
    $wrapper = Join-Path $expectedOwned 'Invoke-DarktideValidationChild.ps1'
    $wrapperHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($childRunnerText))).ToLowerInvariant()
    if ((Get-FileSha256 -Path $wrapper) -cne $wrapperHash) { throw 'Prepared source wrapper differs from the protected driver.' }
    $toolchain = Join-Path $expectedOwned 'toolchain.json'
    Assert-StandardCoreFrozenFiles -Files @($prepared.sourceValidation.frozenFiles)
    Assert-StandardCoreSourceToolReceipts -Bindings @($prepared.sourceValidation.toolReceipts) -FrozenFiles @($prepared.sourceValidation.frozenFiles) -RunId $prepared.runId
    $receipts = @{}
    foreach ($receiptBinding in @($prepared.sourceValidation.toolReceipts)) {
        $receipt = Read-JsonFile -Path $receiptBinding.path -Context 'Prepared source resolver receipt'
        $receipts[[string]$receipt.toolName] = $receipt
    }
    $preparedToolchain = Read-JsonFile -Path $toolchain -Context 'Prepared source toolchain'
    if (-not [string]::IsNullOrWhiteSpace($AuthorityRoot)) {
        foreach ($authorityBinding in @(
            @('centralRunnerPath','centralRunnerSha256','scripts/Invoke-StandardValidation.ps1'),
            @('upstreamAdapterValidatorPath','upstreamAdapterValidatorSha256','scripts/Validate-UpstreamAdapter.ps1'),
            @('upstreamPolicyPath','upstreamPolicySha256','docs/standards/upstream-adapter.json')
        )) {
            $expectedAuthorityFile = Join-Path $AuthorityRoot $authorityBinding[2]
            if ([string]$preparedToolchain.($authorityBinding[0]) -cne [string]$expectedAuthorityFile -or
                [string]$preparedToolchain.($authorityBinding[1]) -cne (Get-FileSha256 -Path $expectedAuthorityFile)) {
                throw 'Prepared source toolchain differs from the verified authority files.'
            }
        }
    }
    foreach ($binding in @(
        @{ actualPath=$preparedToolchain.skillValidatorPath; actualSha=$preparedToolchain.skillValidatorSha256; expectedPath=$receipts.'skill-validator'.executablePath; expectedSha=$receipts.'skill-validator'.executableSha256; name='skill-validator' },
        @{ actualPath=$preparedToolchain.skillToolsNodePath; actualSha=$preparedToolchain.skillToolsNodeSha256; expectedPath=$receipts.'skill-tools'.nodePath; expectedSha=$receipts.'skill-tools'.nodeSha256; name='skill-tools Node' },
        @{ actualPath=$preparedToolchain.skillToolsEntryPointPath; actualSha=$preparedToolchain.skillToolsEntryPointSha256; expectedPath=$receipts.'skill-tools'.entryPointPath; expectedSha=$receipts.'skill-tools'.entryPointSha256; name='skill-tools entry point' },
        @{ actualPath=$preparedToolchain.skillSpectorPath; actualSha=$preparedToolchain.skillSpectorSha256; expectedPath=$receipts.skillspector.executablePath; expectedSha=$receipts.skillspector.executableSha256; name='skillspector' }
    )) {
        if ([string]$binding.actualPath -cne [string]$binding.expectedPath -or [string]$binding.actualSha -cne [string]$binding.expectedSha) {
            throw "Prepared source toolchain does not match the $($binding.name) resolver receipt."
        }
    }
    $staticReceipt = @($prepared.sourceValidation.toolReceipts | Where-Object { [string]$_.path -ceq [string]$preparedToolchain.skillSpectorReceiptPath })
    if ($staticReceipt.Count -ne 1 -or [string]$staticReceipt[0].sha256 -cne [string]$preparedToolchain.skillSpectorReceiptSha256 -or
        (Read-JsonFile -Path $staticReceipt[0].path -Context 'Prepared Static receipt').toolName -cne 'skillspector') {
        throw 'Prepared source Static receipt differs.'
    }
    $arguments = @('-NoProfile','-NonInteractive','-File',$wrapper,'-ToolchainPath',$toolchain,
        '-ToolchainSha256',(Get-FileSha256 -Path $toolchain),'-SourceRepository',$script:SourceRepository,
        '-SourceRevision',$SourceRevision,'-ArchiveSha256',(Get-FileSha256 -Path (Join-Path $expectedOwned 'candidate.zip')))
    foreach ($entry in @(@('packageAdapter','package-adapter'),@('skillValidator','skill-validator'),@('skillTools','skill-tools'),@('staticAnalyzer','static'))) {
        $command = $prepared.sourceValidation.($entry[0])
        if ([string]$command.command -cne $PowerShell -or
            (ConvertTo-Json -InputObject @($command.arguments) -Compress) -cne (ConvertTo-Json -InputObject @($arguments + @('-Mode',$entry[1])) -Compress)) {
            throw 'Prepared source dispatch differs from the protected driver.'
        }
    }
    return $prepared
}

function Get-StandardCoreRunPaths {
    param(
        [Parameter(Mandatory = $true)][string] $ArtifactsRoot,
        [Parameter(Mandatory = $true)][bool] $ArtifactsRootWasExplicit,
        [string] $OutputPath,
        [string] $PreparedRunId
    )

    $requestedRoot = [IO.Path]::GetFullPath($ArtifactsRoot)
    $runId = if ([string]::IsNullOrWhiteSpace($PreparedRunId)) { [guid]::NewGuid().ToString('N') } else { $PreparedRunId }
    if ($runId -cnotmatch '^[0-9a-f]{32}$') { throw 'Source setup run identity is invalid.' }
    if ($ArtifactsRootWasExplicit) {
        $coreArtifactsRoot = $requestedRoot
        $adapterParent = Split-Path -Parent $coreArtifactsRoot
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            throw 'Core Run requires an explicit -ArtifactsRoot when -OutputPath is supplied.'
        }
        $coreArtifactsRoot = Join-Path $requestedRoot "core-v2-$runId"
        $adapterParent = $requestedRoot
    }
    if ([string]::IsNullOrWhiteSpace($adapterParent)) { throw 'Core Run could not resolve a sibling adapter directory.' }

    $adapterRoot = Join-Path $adapterParent ".core-v2-adapter-$runId"
    if ((Test-PathWithinOrEqual -Path $adapterRoot -Root $coreArtifactsRoot) -or
        (Test-PathWithinOrEqual -Path $coreArtifactsRoot -Root $adapterRoot)) {
        throw 'Core adapter and ArtifactsRoot must be separate sibling paths.'
    }
    $resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path $coreArtifactsRoot 'standard-core-validation-v2-report.json'
    }
    else {
        Assert-PathWithinRoot -Path $OutputPath -Root $coreArtifactsRoot -Context 'OutputPath'
    }
    return [pscustomobject]@{
        runId = $runId
        artifactsRoot = [IO.Path]::GetFullPath($coreArtifactsRoot)
        artifactsRootWasExplicit = $ArtifactsRootWasExplicit
        adapterRoot = [IO.Path]::GetFullPath($adapterRoot)
        adapterPath = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'standard-core-adapter-v2.json'))
        outputPath = [IO.Path]::GetFullPath($resolvedOutputPath)
    }
}

function Get-ActiveSkillIds {
    param([Parameter(Mandatory = $true)][string] $Root)
    $inventory = Read-JsonFile -Path (Join-Path $Root 'catalog/source.json') -Context 'catalog/source.json'
    Assert-ExactPropertySet -Value $inventory -Expected @('schemaVersion', 'sourceId', 'repository', 'skillsRoot', 'skills') -Context 'catalog/source.json'
    if ($inventory.schemaVersion -ne 2 -or $inventory.sourceId -cne 'darktide-translate' -or
        $inventory.repository -cne $script:SourceRepository -or $inventory.skillsRoot -cne 'skills' -or
        $inventory.skills -isnot [array] -or @($inventory.skills).Count -eq 0) {
        throw 'catalog/source.json is not the strict Darktide source inventory.'
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'catalog/skills-catalog.json') -PathType Leaf) {
        throw 'Legacy source-owned cross-source catalog must not coexist with catalog/source.json.'
    }
    $trackedProjection = @(& (Get-ResolvedGitPath) -C $Root ls-files -- .agents/skills)
    if ($LASTEXITCODE -ne 0 -or $trackedProjection.Count -ne 0) { throw 'Tracked consumer Skill projections must not coexist with canonical source packages.' }
    [string[]]$declared = @($inventory.skills | ForEach-Object {
        if ($_ -isnot [string] -or [string]$_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid Skill ID in catalog/source.json: '$_'." }
        [string]$_
    })
    [string[]]$sorted = @($declared)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skillId in $declared) { if (-not $seen.Add($skillId)) { throw "Duplicate Skill ID '$skillId'." } }
    if (($declared -join "`n") -cne ($sorted -join "`n")) { throw 'catalog/source.json skills must use ordinal ascending order.' }
    $skillsRoot = Join-Path $Root 'skills'
    if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) { throw 'Canonical skills/ source root is missing.' }
    $actual = @(Get-ChildItem -LiteralPath $skillsRoot -Directory -Force | ForEach-Object { [string]$_.Name })
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($sorted -join "`n")) { throw 'catalog/source.json inventory does not exactly match skills/ directories.' }
    return $sorted
}

$childRunnerText = @'
# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('package-adapter', 'skill-validator', 'skill-tools', 'static', 'repository-general', 'repository-pester')][string] $Mode,
    [Parameter(Mandatory = $true)][string] $ToolchainPath,
    [Parameter(Mandatory = $true)][string] $ToolchainSha256,
    [string] $SourceRepository,
    [string] $SourceRevision,
    [string] $ArchiveSha256,
    [string] $SemanticRequired = 'false'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}
function Assert-FileIdentity {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Sha256, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileSha256 -Path $Path) -cne $Sha256) { throw "$Context changed or is missing." }
}
function Get-Property {
    param([Parameter(Mandatory = $true)] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { throw "$Context is missing '$Name'." }
    return $Object.PSObject.Properties[$Name].Value
}
function Read-Json {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100) }
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
    if (-not (Test-PathWithin -Path $skillRoot -Root $skillsRoot) -or -not (Test-Path -LiteralPath $skillRoot -PathType Container)) {
        throw "Central runner supplied an unsafe or missing Skill root: $SkillId"
    }
    return $skillRoot
}
function Get-InventoryPaths {
    param([Parameter(Mandatory = $true)][string] $SkillRoot)
    $root = [IO.Path]::GetFullPath($SkillRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $paths = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            ForEach-Object { $_.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace([IO.Path]::DirectorySeparatorChar, '/') }
    )
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
$script:NativeReports = @()
function Add-NativeReport {
    param([string] $Command, [string[]] $Arguments, [int] $ExitCode, [string] $Path, [string] $SkillId)
    $script:NativeReports += [pscustomobject]@{skillId=$SkillId;command=$Command;commandSha256=(Get-FileSha256 -Path $Command);arguments=@($Arguments);exitCode=$ExitCode;path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileSha256 -Path $Path)}
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
    if ($Mode -cin @('skill-validator','skill-tools','static')) { $value.nativeReports = @($script:NativeReports) }
    if ($null -ne $Additional) {
        foreach ($key in $Additional.Keys) { $value[$key] = $Additional[$key] }
    }
    [Console]::Out.WriteLine(($value | ConvertTo-Json -Depth 100 -Compress))
    exit 0
}
function Invoke-NativeJson {
    param([Parameter(Mandatory = $true)][string] $Command, [Parameter(Mandatory = $true)][string[]] $Arguments, [Parameter(Mandatory = $true)][string] $Context)
    $stderrPath = Join-Path (Get-Location) (([guid]::NewGuid().ToString('N')) + '.stderr')
    try {
        $lines = @(& $Command @Arguments 2> $stderrPath)
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        $json = ($lines -join "`n").Trim()
        $nativePath = Join-Path (Get-Location) ("native-$Mode-$($env:STANDARD_VALIDATION_SKILL_ID).json")
        [IO.File]::WriteAllText($nativePath, $json, [Text.UTF8Encoding]::new($false))
        Add-NativeReport -Command $Command -Arguments $Arguments -ExitCode $exitCode -Path $nativePath -SkillId $env:STANDARD_VALIDATION_SKILL_ID
        if ($exitCode -ne 0) { throw "$Context returned exit code $exitCode. $stderr" }
        if ([string]::IsNullOrWhiteSpace($json)) { throw "$Context produced no JSON output." }
        return ($json | ConvertFrom-Json -Depth 100)
    }
    finally {
        if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
    }
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
    $issues = @(Get-Property -Object $Report -Name 'issues' -Context 'SkillSpector report')
    $findings = @()
    foreach ($issue in $issues) { $findings += New-Finding -Issue $issue -SkillId $SkillId -Stage 'skillspector-static' }
    return ,$findings
}

try {
    $toolchain = Read-Json -Path $ToolchainPath -Context 'run-owned validation toolchain'
    Assert-FileIdentity -Path $ToolchainPath -Sha256 $ToolchainSha256 -Context 'run-owned validation toolchain'
    $candidateRoot = [IO.Path]::GetFullPath([string]$env:STANDARD_VALIDATION_CANDIDATE_ROOT)
    if ($Mode -eq 'skill-validator') {
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
    $activeSkills = Get-ActiveSkills
    $candidateId = [string]$env:STANDARD_VALIDATION_CANDIDATE_ID
    if ([string]::IsNullOrWhiteSpace($candidateId)) { throw 'Central runner did not provide a candidate identity.' }

    switch ($Mode) {
        'package-adapter' {
            Assert-FileIdentity -Path ([string]$toolchain.upstreamAdapterValidatorPath) -Sha256 ([string]$toolchain.upstreamAdapterValidatorSha256) -Context 'upstream adapter validator'
            Assert-FileIdentity -Path ([string]$toolchain.upstreamPolicyPath) -Sha256 ([string]$toolchain.upstreamPolicySha256) -Context 'upstream adapter policy'
            $reportPath = Join-Path (Get-Location) 'upstream-adapter-report.json'
            & ([string]$toolchain.upstreamAdapterValidatorPath) -PackageRoot $candidateRoot -PolicyPath ([string]$toolchain.upstreamPolicyPath) -SourceRepository $SourceRepository -SourceRevision $SourceRevision -ArchiveSha256 $ArchiveSha256 -OutputPath $reportPath | Out-Null
            $report = Read-Json -Path $reportPath -Context 'upstream adapter report'
            $status = [string](Get-Property -Object $report -Name 'status' -Context 'upstream adapter report')
            $decision = [string](Get-Property -Object $report -Name 'decision' -Context 'upstream adapter report')
            if (($status -eq 'passed' -and $decision -ne 'PASS') -or ($status -eq 'not-applicable' -and $decision -ne 'NOT_APPLICABLE') -or $status -notin @('passed', 'not-applicable')) { throw 'Upstream adapter report did not pass or prove not-applicable.' }
            New-Envelope -ActiveSkills $activeSkills -Additional @{ adapterStatus = $status; adapterSurfaces = @($report.surfaces); semanticRequired = $false }
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
            $findings = @()
            foreach ($skillId in $activeSkills) {
                $skillRoot = Get-SkillRoot -SkillId $skillId
                $inventory = Get-InventoryPaths -SkillRoot $skillRoot
                $reportPath = Join-Path (Get-Location) ("skillspector-$skillId.json")
                $nativeArguments = @('scan', $skillRoot, '--no-llm', '--format', 'json', '--output', $reportPath)
                & ([string]$toolchain.skillSpectorPath) @nativeArguments | Out-Null
                $nativeExit = $LASTEXITCODE
                if (Test-Path -LiteralPath $reportPath -PathType Leaf) { Add-NativeReport -Command ([string]$toolchain.skillSpectorPath) -Arguments $nativeArguments -ExitCode $nativeExit -Path $reportPath -SkillId $skillId }
                if ($nativeExit -ne 0) { throw "SkillSpector scan for '$skillId' returned exit code $nativeExit." }
                $report = Read-Json -Path $reportPath -Context "SkillSpector report for '$skillId'"
                $findings += Assert-SkillSpectorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId -Inventory $inventory
            }
            $semantic = ($SemanticRequired -ceq 'true') -or $findings.Count -gt 0
            New-Envelope -ActiveSkills $activeSkills -Findings $findings -Additional @{ scannerIdentity = 'SkillSpector'; analyzerCompleteness = 'complete'; semanticRequired = $semantic }
        }
        'repository-general' {
            $validatorPath = Join-Path $candidateRoot 'scripts/Test-Repository.ps1'
            if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) { throw 'Test-Repository.ps1 is missing from the candidate snapshot.' }
            $reportPath = Join-Path (Get-Location) 'repository-general-report.json'
            & $validatorPath -RepositoryRoot $candidateRoot -OutputPath $reportPath -ReadOnlySnapshot *> $null
            $report = Read-Json -Path $reportPath -Context 'Test-Repository report'
            if ([string]$report.result -cne 'passed' -or [int]$report.activeSkillCount -ne $activeSkills.Count) { throw 'Test-Repository did not pass the complete active Skill inventory.' }
            $reportedSkills = @($report.skills | ForEach-Object { [string]$_.skillId })
            if ((@($reportedSkills | Sort-Object) -join "`n") -cne (@($activeSkills | Sort-Object) -join "`n")) { throw 'Test-Repository reported a different active Skill inventory.' }
            $testInventory = @($activeSkills | ForEach-Object { "domain-inventory:$($_)" })
            New-Envelope -ActiveSkills $activeSkills -Additional @{ testInventory = $testInventory; testResult = [ordered]@{ status = 'passed'; decision = 'PASS'; result = 'Test-Repository' }; domainAdapterResult = [ordered]@{ status = 'passed'; decision = 'PASS'; result = 'Darktide-domain-contract' } }
        }
        'repository-pester' {
            Assert-FileIdentity -Path ([string]$toolchain.pesterModulePath) -Sha256 ([string]$toolchain.pesterModuleSha256) -Context 'Pester module'
            Import-Module -Name ([string]$toolchain.pesterModulePath) -Force -ErrorAction Stop
            $loaded = Get-Module Pester | Select-Object -First 1
            if ($null -eq $loaded -or [string]$loaded.Version -cne [string]$toolchain.pesterVersion) { throw 'The resolved Pester module identity was not loaded.' }
            $testRoot = Join-Path $candidateRoot 'tests'
            # The run-owned Core snapshot is unique. A stable name lets the
            # workflow recover the last completed case after a forced timeout.
            $progressPath = Join-Path (Get-Location) 'repository-pester-progress.log'
            if (Test-Path -LiteralPath $progressPath) { throw 'Pester progress path already exists in the owned snapshot.' }
            $progressTail = [Collections.Generic.Queue[string]]::new()
            $progressLineCount = 0
            $completedCaseCount = 0
            $liveChars = 0
            $liveLimit = 120000
            function Write-PesterProgressTail {
                param([string] $Path)
                if (Test-Path -LiteralPath $Path -PathType Leaf) {
                    foreach ($line in @(Get-Content -LiteralPath $Path -Tail 24 -ErrorAction SilentlyContinue)) {
                        $boundedLine = [string]$line
                        if ($boundedLine.Length -gt 300) { $boundedLine = $boundedLine.Substring(0, 300) + '[truncated]' }
                        if ($boundedLine.Length -gt 0) { [Console]::Error.WriteLine("Pester progress: $boundedLine") }
                    }
                }
            }
            try {
                $previousErrorActionPreference = $ErrorActionPreference
                try {
                    # Tests exercise non-zero native children. Keep stderr non-terminating while
                    # Pester evaluates them; stream bounded progress without changing JSON stdout.
                    $ErrorActionPreference = 'Continue'
                    $result = Invoke-Pester -Path $testRoot -Output Detailed -PassThru 3>$null 6>&1 |
                        ForEach-Object {
                            if ($_ -is [Management.Automation.InformationRecord]) {
                                foreach ($rawLine in @(([string]$_.MessageData) -split '\r?\n')) {
                                    $line = [string]$rawLine
                                    if ($line.Length -eq 0) { continue }
                                    if ($line.Length -gt 300) { $line = $line.Substring(0, 300) + '[truncated]' }
                                    $progressLineCount++
                                    if ($line -match '^\s*\[[+-]\]') { $completedCaseCount++ }
                                    $entry = "completed=$completedCaseCount line=$progressLineCount $line"
                                    $progressTail.Enqueue($entry)
                                    if ($progressTail.Count -gt 24) { [void]$progressTail.Dequeue() }
                                    [IO.File]::WriteAllLines($progressPath, $progressTail.ToArray(), [Text.UTF8Encoding]::new($false))
                                    if ($liveChars + $entry.Length -le $liveLimit) {
                                        [Console]::Error.WriteLine("Pester progress: $entry")
                                        $liveChars += $entry.Length
                                    }
                                    elseif ($liveChars -le $liveLimit) {
                                        [Console]::Error.WriteLine('Pester live progress cap reached; run-owned tail continues.')
                                        $liveChars = $liveLimit + 1
                                    }
                                }
                            }
                            else { $_ }
                        }
                }
                catch {
                    [Console]::Error.WriteLine('Pester counts: result=exception')
                    Write-PesterProgressTail -Path $progressPath
                    throw
                }
                finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }
                $invalid = $null -eq $result -or [int64]$result.TotalCount -le 0 -or [int64]$result.PassedCount -le 0 -or
                    [int64]$result.FailedCount -ne 0 -or [int64]$result.FailedBlocksCount -ne 0 -or [int64]$result.FailedContainersCount -ne 0 -or
                    [int64]$result.PassedCount + [int64]$result.SkippedCount -ne [int64]$result.TotalCount
                if ($invalid) {
                    if ($null -eq $result) {
                        [Console]::Error.WriteLine('Pester counts: result=missing')
                    }
                    else {
                        [Console]::Error.WriteLine("Pester counts: total=$([int64]$result.TotalCount) passed=$([int64]$result.PassedCount) skipped=$([int64]$result.SkippedCount) failed=$([int64]$result.FailedCount) failedBlocks=$([int64]$result.FailedBlocksCount) failedContainers=$([int64]$result.FailedContainersCount) notRun=$([int64]$result.NotRunCount)")
                        foreach ($failedContainer in @($result.FailedContainers)) {
                            [Console]::Error.WriteLine("Pester container failed: $($failedContainer.Name)")
                            foreach ($failure in @($failedContainer.ErrorRecord)) {
                                [Console]::Error.WriteLine("Pester container error: $($failure.Exception.Message)")
                            }
                        }
                        foreach ($failedBlock in @($result.FailedBlocks)) {
                            [Console]::Error.WriteLine("Pester block failed: $($failedBlock.Name)")
                            foreach ($failure in @($failedBlock.ErrorRecord)) {
                                [Console]::Error.WriteLine("Pester block error: $($failure.Exception.Message)")
                            }
                        }
                        foreach ($failedTest in @($result.Failed)) {
                            [Console]::Error.WriteLine("Pester test failed: $($failedTest.ExpandedPath)")
                            foreach ($failure in @($failedTest.ErrorRecord)) {
                                [Console]::Error.WriteLine("Pester test error: $($failure.Exception.Message)")
                            }
                        }
                    }
                    Write-PesterProgressTail -Path $progressPath
                    throw 'Pester repository regression did not complete successfully.'
                }
            }
            finally {
                Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
            }
            $testInventory = @(
                Get-ChildItem -LiteralPath $testRoot -Recurse -File -Force |
                    ForEach-Object { [IO.Path]::GetRelativePath($candidateRoot, $_.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/') }
            )
            if ($testInventory.Count -eq 0) { throw 'Pester did not receive a non-empty test inventory.' }
            New-Envelope -ActiveSkills $activeSkills -Additional @{ testInventory = $testInventory; testResult = [ordered]@{ status = 'passed'; decision = 'PASS'; total = [int64]$result.TotalCount; passed = [int64]$result.PassedCount; skipped = [int64]$result.SkippedCount; failed = [int64]$result.FailedCount }; domainAdapterResult = [ordered]@{ status = 'passed'; decision = 'PASS'; result = 'Pester' } }
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@

function Assert-SourceValidationRequest {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $BoundParameters)
    $setup = (@($BoundParameters.Keys) -ccontains 'PrepareSourceTools') -and [bool]$BoundParameters['PrepareSourceTools']
    $source = (@($BoundParameters.Keys) -ccontains 'SourceValidation') -and [bool]$BoundParameters['SourceValidation']
    if ($setup -and $source) { throw 'PrepareSourceTools and SourceValidation must be separate requests.' }
    if (-not ($setup -or $source)) { throw 'The canonical entry requires exactly one explicit source purpose.' }
    if (@($BoundParameters.Keys) -cnotcontains 'SourceToolsPath' -or [string]::IsNullOrWhiteSpace([string]$BoundParameters['SourceToolsPath'])) {
        throw 'Explicit source setup or validation requires SourceToolsPath.'
    }
    if ($source -and (@($BoundParameters.Keys) -ccontains 'ExpectedGoRuntimeVersion')) {
        throw 'Go runtime resolution is allowed only during explicit setup.'
    }
}

function Get-ApprovedSourceAuthorityPin {
    param([AllowNull()][string] $Commit)
    if ($PSBoundParameters.ContainsKey('Commit') -and $Commit -cne $script:SourceAuthorityCommit) {
        throw 'Source authority must match the exact approved SYP-280 pin.'
    }
    return [pscustomobject]@{
        repository = $script:AuthorityRepository
        commit = $script:SourceAuthorityCommit
        archiveUrl = "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$($script:SourceAuthorityCommit)"
        archiveSha256 = $script:SourceAuthorityArchiveSha256
        files = $script:SourceAuthorityFiles
    }
}

function Assert-AuthorityConfig {
    param([Parameter(Mandatory = $true)] $Config)
    Assert-ExactPropertySet -Value $Config -Expected @('schemaVersion','standardVersion','authority','deviations') -Context 'config/standard-v1.json'
    Assert-ExactPropertySet -Value $Config.authority -Expected @('repository','commit','archiveUrl','archiveSha256','files') -Context 'authority'
    $approved = Get-ApprovedSourceAuthorityPin
    if ($Config.schemaVersion -isnot [long] -and $Config.schemaVersion -isnot [int]) {
        throw 'Source authority schemaVersion must be a JSON integer.'
    }
    foreach ($value in @($Config.standardVersion,$Config.deviations,$Config.authority.repository,
            $Config.authority.commit,$Config.authority.archiveUrl,$Config.authority.archiveSha256)) {
        if ($value -isnot [string]) { throw 'Source authority tuple fields must be JSON strings.' }
    }
    if ($Config.schemaVersion -ne 1 -or $Config.standardVersion -cne 'v1' -or $Config.deviations -cne 'None' -or
        $Config.authority.repository -cne $approved.repository -or $Config.authority.commit -cne $approved.commit -or
        $Config.authority.archiveUrl -cne $approved.archiveUrl -or $Config.authority.archiveSha256 -cne $approved.archiveSha256 -or
        $Config.authority.files -isnot [array] -or @($Config.authority.files).Count -ne $approved.files.Count) {
        throw 'Source authority must match the complete reviewed immutable tuple.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $Config.authority.files) {
        Assert-ExactPropertySet -Value $file -Expected @('path','sha256') -Context 'authority file'
        if ($file.path -isnot [string] -or $file.sha256 -isnot [string] -or -not $seen.Add([string]$file.path) -or
            -not $approved.files.Contains([string]$file.path) -or $file.sha256 -cne $approved.files[[string]$file.path]) {
            throw 'Source authority file inventory differs from the reviewed immutable tuple.'
        }
    }
    return $approved
}

Assert-SourceValidationRequest -BoundParameters $PSBoundParameters
$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
} else { [IO.Path]::GetFullPath($RepositoryRoot) }
if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { throw "RepositoryRoot does not exist: $repoRoot" }
$gitPath = Get-ResolvedGitPath
$pwshPath = Get-ResolvedPowerShellPath
$candidateCommit = Resolve-GitRevision -GitPath $gitPath -Root $repoRoot -Revision 'HEAD' -Context 'Candidate revision'
$dirty = @(& $gitPath -C $repoRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Canonical validation requires a clean immutable candidate commit.' }
$baseInput = if ([string]::IsNullOrWhiteSpace($BaseCommit)) { 'HEAD^' } else { $BaseCommit }
$baseRevision = Resolve-GitRevision -GitPath $gitPath -Root $repoRoot -Revision $baseInput -Context 'Base commit'
& $gitPath -C $repoRoot merge-base --is-ancestor $baseRevision $candidateCommit
if ($LASTEXITCODE -ne 0 -or $baseRevision -ceq $candidateCommit) { throw 'Base commit must be a distinct ancestor of the immutable candidate.' }
$driverConfig = Read-JsonFile -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/standard-v1.json') -Context 'Protected driver config'
$driverAuthority = Assert-AuthorityConfig -Config $driverConfig
$candidateConfig = Read-JsonFile -Path (Join-Path $repoRoot 'config/standard-v1.json') -Context 'Candidate config'
$candidateAuthority = Assert-AuthorityConfig -Config $candidateConfig
if (-not [string]::IsNullOrWhiteSpace($AuthorityArchivePath)) {
    Assert-NoReparseAncestors -Path $AuthorityArchivePath -Context 'Pinned authority archive'
    if ((Get-FileSha256 -Path $AuthorityArchivePath) -cne $candidateAuthority.archiveSha256) { throw 'Pinned authority archive hash differs.' }
}
$activeSkillIds = Get-ActiveSkillIds -Root $repoRoot
$eventName = Get-EventName
if ([string]::IsNullOrWhiteSpace($AuthorityRepositoryRoot)) { throw 'Source validation requires the pinned real Git AuthorityRepositoryRoot.' }
$executionAuthority = $candidateAuthority

        $authorityCheckout = Assert-StandardCoreAuthorityCheckout -GitPath $gitPath -AuthorityRoot $AuthorityRepositoryRoot -AuthorityPin $executionAuthority
        $pwshPath = Get-ResolvedPowerShellPath
        $trustedRoot = if ([string]::IsNullOrWhiteSpace($TrustedToolRoot)) { Split-Path -Parent $pwshPath } else { [IO.Path]::GetFullPath($TrustedToolRoot) }
        if (-not (Test-Path -LiteralPath $trustedRoot -PathType Container)) { throw "Trusted PowerShell root is missing: $trustedRoot" }
        Assert-NoReparseAncestors -Path $trustedRoot -Context 'Trusted PowerShell root'
        if ($PrepareSourceTools) {
            $setupRoot = [IO.Path]::GetFullPath($ArtifactsRoot)
            Assert-OutsideRoot -Path $setupRoot -Root $repoRoot -Context 'Source setup artifacts'
            Assert-OutsideRoot -Path $setupRoot -Root $authorityCheckout.root -Context 'Source setup artifacts'
            Assert-OutsideRoot -Path $setupRoot -Root $trustedRoot -Context 'Source setup artifacts'
            [void](New-Item -ItemType Directory -Path $setupRoot -Force)
            Assert-NoReparseAncestors -Path $setupRoot -Context 'Source setup artifacts'
            $preparedPath = Assert-PathWithinRoot -Path $SourceToolsPath -Root $setupRoot -Context 'Source toolset output'
            if (-not (Test-PathEqual -Left (Split-Path -Parent $preparedPath) -Right $setupRoot)) { throw 'Source toolset output must be directly within its setup root.' }
            if (Test-Path -LiteralPath $preparedPath) { throw 'Source toolset output already exists.' }
            New-SourceToolSetup -Root $setupRoot -AuthorityRoot $authorityCheckout.root -AuthorityPin $executionAuthority `
                -PowerShell $pwshPath -CandidateRevision $candidateCommit -Git $gitPath -CandidateRoot $repoRoot `
                -PreparedPath $preparedPath -GoVersion (Resolve-GoRuntimeVersion -Expected $ExpectedGoRuntimeVersion) -LimitSeconds $TimeoutSeconds
            exit 0
        }
        $preparedSource = if ($SourceValidation) {
            Read-SourceToolSetup -Path $SourceToolsPath -SourceRevision $candidateCommit -AuthorityRevision $candidateAuthority.commit -PowerShell $pwshPath -AuthorityRoot $authorityCheckout.root
        } else { $null }

        $artifactsRootPath = [IO.Path]::GetFullPath($ArtifactsRoot)
        Assert-OutsideRoot -Path $artifactsRootPath -Root $repoRoot -Context 'Artifacts root'
        Assert-OutsideRoot -Path $artifactsRootPath -Root $authorityCheckout.root -Context 'Artifacts root'
        Assert-OutsideRoot -Path $artifactsRootPath -Root $trustedRoot -Context 'Artifacts root'
        [void](New-Item -ItemType Directory -Path $artifactsRootPath -Force)
        Assert-NoReparseAncestors -Path $artifactsRootPath -Context 'Artifacts root'
        Assert-OutsideRoot -Path $trustedRoot -Root $repoRoot -Context 'Trusted tool root'
        Assert-OutsideRoot -Path $trustedRoot -Root $authorityCheckout.root -Context 'Trusted tool root'
        $coreRunPaths = Get-StandardCoreRunPaths -ArtifactsRoot $artifactsRootPath `
            -ArtifactsRootWasExplicit $PSBoundParameters.ContainsKey('ArtifactsRoot') -OutputPath $OutputPath `
            -PreparedRunId $(if ($SourceValidation) { [string]$preparedSource.runId } else { '' })
        $coreArtifactsRoot = [string]$coreRunPaths.artifactsRoot
        $adapterRoot = [string]$coreRunPaths.adapterRoot
        $adapterPath = [string]$coreRunPaths.adapterPath
        $outputFull = [string]$coreRunPaths.outputPath
        foreach ($root in @($coreArtifactsRoot, $adapterRoot)) {
            Assert-OutsideRoot -Path $root -Root $repoRoot -Context 'Core run-owned root'
            Assert-OutsideRoot -Path $root -Root $authorityCheckout.root -Context 'Core run-owned root'
            Assert-OutsideRoot -Path $root -Root $trustedRoot -Context 'Core run-owned root'
        }
        Assert-OutsideRoot -Path $adapterRoot -Root $coreArtifactsRoot -Context 'Core adapter root'
        if (-not (Test-Path -LiteralPath $coreArtifactsRoot -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $coreArtifactsRoot -ErrorAction Stop)
        }
        elseif (-not [bool]$coreRunPaths.artifactsRootWasExplicit) {
            throw 'Default Core ArtifactsRoot unexpectedly exists; run-owned paths are create-only.'
        }
        Assert-NoReparseAncestors -Path $coreArtifactsRoot -Context 'Core ArtifactsRoot'
        Assert-PathWithinRoot -Path $outputFull -Root $coreArtifactsRoot -Context 'OutputPath' | Out-Null
        if (Test-Path -LiteralPath $outputFull) { throw "OutputPath already exists and evidence is create-only: $outputFull" }

        $adapterRootCreated = $false
        $coreExitCode = 1
        try {
            if (Test-Path -LiteralPath $adapterRoot) { throw 'Core adapter sibling path unexpectedly exists.' }
            [void](New-Item -ItemType Directory -Path $adapterRoot -ErrorAction Stop)
            $adapterRootCreated = $true
            Assert-NoReparseAncestors -Path $adapterRoot -Context 'Core adapter root'
            $authoritySnapshot = New-StandardCoreAuthoritySnapshot -GitPath $gitPath -SourceRoot $authorityCheckout.root -OwnedRoot $adapterRoot -AuthorityPin $candidateAuthority
            $centralRunnerPath = [string]$authoritySnapshot.runnerPath
            $adapter = New-StandardCoreAdapterV2 -PowerShellPath $pwshPath -TrustedToolRoot $trustedRoot `
                -CandidateAuthorityAdapterRunId $coreRunPaths.runId -ActiveSkillIds $activeSkillIds
            if ($SourceValidation) { $adapter.sourceValidation = $preparedSource.sourceValidation }
            Write-Utf8NoBomCreateNew -Path $adapterPath -Text (($adapter | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
            $coreRunnerArgs = @(
                '-CandidateRoot', $repoRoot,
                '-AdapterPath', $adapterPath,
                '-ArtifactsRoot', $coreArtifactsRoot,
                '-OutputPath', $outputFull,
                '-SourceRepository', $script:SourceRepository,
                '-SourceRevision', $candidateCommit,
                '-BaseRevision', $baseRevision,
                '-EventName', $eventName,
                '-AuthorityRevision', [string]$candidateAuthority.commit,
                '-TimeoutSeconds', [string]$TimeoutSeconds,
                '-TrustedToolRoot', $trustedRoot
            )
            if ($SourceValidation) { $coreRunnerArgs += @('-SourceValidation','-RunId',[string]$preparedSource.runId) }
            Assert-NoReparseAncestors -Path $centralRunnerPath -Context 'Pinned Core runner before execution'
            if (-not (Test-AuthorityWorktreeSha256 -Path $centralRunnerPath -ExpectedSha256 ([string]$candidateAuthority.files['scripts/Invoke-StandardValidation.ps1']))) {
                throw 'Pinned Core runner worktree content changed before execution.'
            }
            & $pwshPath -NoProfile -NonInteractive -File $centralRunnerPath @coreRunnerArgs
            $coreExitCode = $LASTEXITCODE
        }
        finally {
            if ($adapterRootCreated) {
                if (-not (Test-PathEqual -Left $adapterRoot -Right ([IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $coreArtifactsRoot) ".core-v2-adapter-$($coreRunPaths.runId)")))) -or
                    -not (Test-PathWithinOrEqual -Path $adapterRoot -Root (Split-Path -Parent $coreArtifactsRoot)) -or
                    (Test-PathWithinOrEqual -Path $adapterRoot -Root $coreArtifactsRoot)) {
                    throw 'Core adapter cleanup path escaped its unique sibling boundary.'
                }
                Assert-NoReparseAncestors -Path $adapterRoot -Context 'Core adapter cleanup root'
                Remove-Item -LiteralPath $adapterRoot -Recurse -Force -ErrorAction Stop
                if (Test-Path -LiteralPath $adapterRoot) { throw 'Core adapter cleanup did not remove its run-owned sibling.' }
            }
        }
        exit $coreExitCode
