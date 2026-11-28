# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $ToolRoot,
    [string] $PesterManifestPath
)

$ErrorActionPreference = 'Stop'
# Do not change [Console]::OutputEncoding: it changes the shared console code page and outlives this process.
# Windows PowerShell 5.1 does not populate $PSScriptRoot inside parameter defaults, so resolve it here.
$scriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $scriptRoot }
Import-Module (Join-Path $scriptRoot 'TestEnvironment.psm1') -Force
$root = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path)
$configPath = Join-Path $root 'config/test-environment.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$runningOnWindows = $env:OS -eq 'Windows_NT'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $overrideName = [string]$config.toolRoot.environmentOverride
    $overrideValue = if ([string]::IsNullOrWhiteSpace($overrideName)) { $null } else { [Environment]::GetEnvironmentVariable($overrideName) }
    if (-not [string]::IsNullOrWhiteSpace($overrideValue)) { $ToolRoot = $overrideValue }
    elseif ($runningOnWindows) { $ToolRoot = [string]$config.toolRoot.windows }
    else { $ToolRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/share/ai-test-env' }
}
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)

if ([string]::IsNullOrWhiteSpace($PesterManifestPath)) {
    $pesterRoot = [IO.Path]::Combine($ToolRoot, 'modules', 'Pester')
    $candidates = @()
    if (Test-Path -LiteralPath $pesterRoot -PathType Container) {
        $candidates = @(Get-ChildItem -LiteralPath $pesterRoot -Directory | ForEach-Object {
                $parsed = $null
                if ([version]::TryParse($_.Name, [ref]$parsed)) {
                    $manifest = Join-Path $_.FullName 'Pester.psd1'
                    if (Test-Path -LiteralPath $manifest -PathType Leaf) { [pscustomobject]@{ Version = $parsed; Path = $manifest } }
                }
            } | Sort-Object Version -Descending)
    }
    if ($candidates.Count -gt 0) { $PesterManifestPath = $candidates[0].Path }
}

$receiptPath = [IO.Path]::Combine($ToolRoot, 'install-receipt.json')
$expectedManifestHash = $null
if ((Test-Path -LiteralPath $receiptPath -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace($PesterManifestPath)) {
    try {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $manifestVersion = Get-TestEnvironmentManifestVersion -ManifestPath $PesterManifestPath
        if ($null -ne $receipt.pester -and [string]$receipt.pester.version -ceq [string]$manifestVersion) {
            $expectedManifestHash = [string]$receipt.pester.manifestSha256
        }
    }
    catch { $expectedManifestHash = $null }
}

$checks = New-Object Collections.Generic.List[object]
$checks.Add((Test-TestEnvironmentPowerShell -Edition $PSVersionTable.PSEdition -Version $PSVersionTable.PSVersion `
            -MinimumVersion ([version]$config.powerShell.minimumVersion) -ToolRoot $ToolRoot))
$pesterCheck = Test-TestEnvironmentPester -ManifestPath $PesterManifestPath `
    -MinimumVersion ([version]$config.pester.minimumVersion) -ExpectedSha256 $expectedManifestHash
$checks.Add($pesterCheck)
$policy = if ($runningOnWindows) { [string](Get-ExecutionPolicy) } else { 'NotApplicable' }
$checks.Add((Test-TestEnvironmentExecutionPolicy -ExecutionPolicy $policy -IsWindows $runningOnWindows))

$gitPath = $null
$gitVersion = $null
$headCommit = $null
try {
    $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    $rootResult = Invoke-TestEnvironmentGit -GitPath $gitPath -Arguments @('-C', $root, 'rev-parse', '--show-toplevel')
    $checks.Add((Test-TestEnvironmentGitResult -RepositoryRoot $root -ExitCode $rootResult.ExitCode -Output $rootResult.Output))
    $versionResult = Invoke-TestEnvironmentGit -GitPath $gitPath -Arguments @('--version')
    if ($versionResult.ExitCode -eq 0) { $gitVersion = $versionResult.StdOut.Trim() }
    $headResult = Invoke-TestEnvironmentGit -GitPath $gitPath -Arguments @('-C', $root, 'rev-parse', 'HEAD')
    if ($headResult.ExitCode -eq 0) { $headCommit = $headResult.StdOut.Trim() }
}
catch {
    $checks.Add((Test-TestEnvironmentGitResult -RepositoryRoot $root -ExitCode 127 -Output $_.Exception.Message))
}
$checks.Add((Test-TestEnvironmentSkillPackageIndex -RepositoryRoot $root -GitPath $gitPath))

$pesterVersion = if ([string]::IsNullOrWhiteSpace($PesterManifestPath)) { $null } else { Get-TestEnvironmentManifestVersion -ManifestPath $PesterManifestPath }
$pesterHash = if (-not [string]::IsNullOrWhiteSpace($PesterManifestPath) -and (Test-Path -LiteralPath $PesterManifestPath -PathType Leaf)) {
    (Get-FileHash -LiteralPath $PesterManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
} else { $null }
$powerShellPath = try { (Get-Process -Id $PID).Path } catch { $null }
$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$osDescription = [Runtime.InteropServices.RuntimeInformation]::OSDescription
$checkArray = $checks.ToArray()
$result = if (@($checkArray | Where-Object status -eq blocked).Count -eq 0) { 'READY' } else { 'BLOCKED' }
$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    report = 'darktide-test-environment-v1'
    result = $result
    checks = $checkArray
    environment = [pscustomobject][ordered]@{
        os = $osDescription
        architecture = $architecture
        user = [Environment]::UserName
        powerShell = [pscustomobject][ordered]@{ version = $PSVersionTable.PSVersion.ToString(); edition = $PSVersionTable.PSEdition; path = $powerShellPath }
        pester = [pscustomobject][ordered]@{ version = if ($null -eq $pesterVersion) { $null } else { $pesterVersion.ToString() }; manifestPath = $PesterManifestPath; sha256 = $pesterHash }
        toolRoot = $ToolRoot
        gitVersion = $gitVersion
        headCommit = $headCommit
        executionPolicy = $policy
    }
}
if ($result -ceq 'BLOCKED') {
    $blockedFormat = ConvertFrom-TestEnvironmentText '5bey5bCB6Y6W77ya5pyf5pybIHswfe+8m+WvpumamyB7MX3jgILomZXnkIbmlrnlvI/vvJp7Mn0='
    foreach ($check in @($checkArray | Where-Object status -eq blocked)) {
        [Console]::Error.WriteLine("[$($check.id)] " + ($blockedFormat -f $check.expected, $check.actual, $check.remediation))
    }
}
# Escape non-ASCII characters so the machine-readable line is pure ASCII and independent of the console code page.
$json = $report | ConvertTo-Json -Depth 10 -Compress
$json = [regex]::Replace($json, '[^\x00-\x7F]', { param($match) '\u{0:x4}' -f [int][char]$match.Value })
[Console]::Out.WriteLine($json)
if ($result -ceq 'READY') { exit 0 }
exit 2
