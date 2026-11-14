# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

BeforeAll {

function Get-PathSafetyAstLedger {
    param([Parameter(Mandatory)][string] $Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "Could not parse ${Path}: $($errors.Message -join '; ')" }
    $commands = @('Test-Path','Get-Item','Get-ChildItem','New-Item','Remove-Item','Copy-Item','Move-Item','Set-Content','Add-Content','Out-File')
    $ledger = [Collections.Generic.List[string]]::new()
    foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $node.GetCommandName()
        if ($name -notin $commands) { continue }
        $function = $node.Parent
        while ($null -ne $function -and $function -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
        $functionName = if ($null -eq $function) { '<script>' } else { $function.Name }
        $ledger.Add("$functionName|$name")
    }
    foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        if ($node.Expression -isnot [Management.Automation.Language.TypeExpressionAst]) { continue }
        $typeName = $node.Expression.TypeName.FullName
        if ($typeName -notin @('IO.File','System.IO.File','IO.Directory','System.IO.Directory')) { continue }
        $function = $node.Parent
        while ($null -ne $function -and $function -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
        $functionName = if ($null -eq $function) { '<script>' } else { $function.Name }
        $ledger.Add("$functionName|$typeName::$($node.Member.Value)")
    }
    foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.TypeExpressionAst] }, $true)) {
        if ($node.TypeName.FullName -notin @('IO.FileInfo','System.IO.FileInfo','IO.DirectoryInfo','System.IO.DirectoryInfo')) { continue }
        $function = $node.Parent
        while ($null -ne $function -and $function -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
        $functionName = if ($null -eq $function) { '<script>' } else { $function.Name }
        $ledger.Add("$functionName|type::$($node.TypeName.FullName)")
    }
    return $ledger.ToArray()
}

function ConvertTo-CountMap {
    param([string[]] $Entries)
    $map = @{}
    foreach ($entry in $Entries) { $map[$entry] = 1 + [int]($map[$entry]) }
    return $map
}

$scopedFiles = @(
    'scripts/Validate.ps1',
    'scripts/StandardSourceDriver.psm1',
    'scripts/Invoke-SourceChild.ps1',
    'scripts/StandardWorkflowLeg.psm1',
    'scripts/Prepare-WorkflowPowerShell.ps1',
    'scripts/Prepare-PesterRuntime.ps1',
    'scripts/PowerShellRelease.psm1',
    'scripts/Install-LatestPowerShell.ps1',
    'scripts/Invoke-CorePester.ps1',
    'scripts/CorePesterIntegrity.psm1',
    'scripts/Test-CleanRepositoryHead.ps1'
)

# Exact origin/main function-level inventory. Format: file|function|call|count.
$originMainExclusions = @'
scripts/Validate.ps1|<script>|Copy-Item|1
scripts/Validate.ps1|<script>|Get-ChildItem|2
scripts/Validate.ps1|<script>|Get-Item|11
scripts/Validate.ps1|<script>|IO.File::AppendAllText|2
scripts/Validate.ps1|<script>|IO.File::Open|1
scripts/Validate.ps1|<script>|IO.File::ReadAllBytes|2
scripts/Validate.ps1|<script>|IO.File::WriteAllBytes|1
scripts/Validate.ps1|<script>|IO.File::WriteAllText|7
scripts/Validate.ps1|<script>|New-Item|6
scripts/Validate.ps1|<script>|Remove-Item|5
scripts/Validate.ps1|<script>|Test-Path|12
scripts/Validate.ps1|Assert-ExternalReceiptFile|Test-Path|1
scripts/Validate.ps1|Assert-NoGitReplacementObjects|Get-ChildItem|1
scripts/Validate.ps1|Assert-NoGitReplacementObjects|Get-Item|2
scripts/Validate.ps1|Assert-NoGitReplacementObjects|Test-Path|2
scripts/Validate.ps1|Assert-NoReparseAncestors|Get-Item|1
scripts/Validate.ps1|Assert-NoReparseTree|Get-ChildItem|1
scripts/Validate.ps1|Assert-NoReparseTree|Get-Item|1
scripts/Validate.ps1|Assert-ReceiptFile|Test-Path|1
scripts/Validate.ps1|Assert-RunnerCommandFilesUnchanged|Test-Path|1
scripts/Validate.ps1|Assert-TrustedGitTreeFile|Get-Item|1
scripts/Validate.ps1|Expand-TrustedGitArchive|New-Item|1
scripts/Validate.ps1|Expand-TrustedGitArchive|Remove-Item|1
scripts/Validate.ps1|Expand-TrustedGitArchive|Test-Path|2
scripts/Validate.ps1|Get-FileByteSha256|IO.File::ReadAllBytes|1
scripts/Validate.ps1|Get-InstalledDirectoryClosureSha256|Get-ChildItem|1
scripts/Validate.ps1|Get-InstalledDirectoryClosureSha256|Test-Path|1
scripts/Validate.ps1|Get-InstalledDirectoryClosureSha256|type::IO.FileInfo|1
scripts/Validate.ps1|Get-RepositoryRawSnapshot|Get-ChildItem|2
scripts/Validate.ps1|Get-RunnerCommandFileSnapshot|Test-Path|1
scripts/Validate.ps1|Invoke-BootstrapTransitionValidation|Get-Item|2
scripts/Validate.ps1|Invoke-BootstrapTransitionValidation|IO.File::AppendAllText|1
scripts/Validate.ps1|Invoke-BootstrapTransitionValidation|New-Item|2
scripts/Validate.ps1|Invoke-BootstrapTransitionValidation|Test-Path|6
scripts/Validate.ps1|Invoke-NativeChecked|Get-Item|1
scripts/Validate.ps1|Invoke-NativeChecked|IO.File::Open|1
scripts/Validate.ps1|Invoke-NativeChecked|Remove-Item|1
scripts/Validate.ps1|Invoke-NativeChecked|Test-Path|6
scripts/Validate.ps1|Invoke-ProtectedPesterRunspace|Get-Item|2
scripts/Validate.ps1|Invoke-ProtectedPesterRunspace|IO.File::ReadAllBytes|1
scripts/Validate.ps1|Invoke-ProtectedPesterRunspace|Test-Path|3
scripts/Validate.ps1|Invoke-ProtectedPesterServerProxy|Test-Path|5
scripts/Validate.ps1|Invoke-ProtectedPesterSupervisor|Get-Item|2
scripts/Validate.ps1|Invoke-ProtectedPesterSupervisor|Test-Path|1
scripts/Validate.ps1|Invoke-TrustedPowerShellProcess|Test-Path|2
scripts/Validate.ps1|New-ContainedProcessEnvironment|Get-Item|2
scripts/Validate.ps1|New-ContainedProcessEnvironment|New-Item|2
scripts/Validate.ps1|Protect-ProcessCredentialEnvironment|Get-ChildItem|1
scripts/Validate.ps1|Read-JsonFile|Test-Path|1
scripts/Validate.ps1|Read-SkillSpectorJsonReport|IO.File::ReadAllText|1
scripts/Validate.ps1|Read-StrictUtf8File|IO.File::ReadAllBytes|1
scripts/Validate.ps1|Resolve-GitCommonDirectoryFromMetadata|Get-Item|4
scripts/Validate.ps1|Resolve-GitCommonDirectoryFromMetadata|Test-Path|4
scripts/Validate.ps1|Set-WindowsLowIntegrityDirectory|Get-Item|1
scripts/Validate.ps1|Set-WindowsLowIntegrityDirectory|Test-Path|1
scripts/Validate.ps1|Write-ExclusiveUtf8File|Get-Item|2
scripts/Validate.ps1|Write-ExclusiveUtf8File|IO.File::Open|1
scripts/Validate.ps1|Write-ExclusiveUtf8File|IO.File::ReadAllBytes|1
scripts/Validate.ps1|Write-ExclusiveUtf8File|New-Item|1
scripts/Validate.ps1|Write-ExclusiveUtf8File|Test-Path|2
scripts/PowerShellRelease.psm1|Assert-VerifiedPowerShellArchive|Get-Item|1
scripts/PowerShellRelease.psm1|Assert-VerifiedPowerShellArchive|Test-Path|1
scripts/Install-LatestPowerShell.ps1|<script>|Get-Item|1
scripts/Install-LatestPowerShell.ps1|<script>|IO.File::Open|1
scripts/Install-LatestPowerShell.ps1|<script>|New-Item|1
scripts/Install-LatestPowerShell.ps1|<script>|Test-Path|3
'@ -split "`r?`n" | Where-Object { $_ }

# Pure reads/non-filesystem provider operations retained under an already-held lease.
$pureReadExclusions = @'
scripts/StandardSourceDriver.psm1|Get-DarktideActiveSkillIds|Get-ChildItem|1
scripts/StandardSourceDriver.psm1|Get-DarktideSourceResolverEnvironment|Remove-Item|1
scripts/Invoke-SourceChild.ps1|Get-InventoryPaths|Get-ChildItem|1
scripts/Prepare-WorkflowPowerShell.ps1|<script>|IO.File::AppendAllText|3
scripts/Invoke-CorePester.ps1|<script>|Get-ChildItem|1
scripts/CorePesterIntegrity.psm1|Test-CorePesterClosure|Get-ChildItem|1
scripts/CorePesterIntegrity.psm1|Get-CorePesterTreeSnapshot|Get-ChildItem|1
'@ -split "`r?`n" | Where-Object { $_ }
}

Describe 'Epic pathname safety AST boundary' {
    It 'contains no unreviewed pathname command, static IO method, or FileInfo/DirectoryInfo check' {
        $allowances = @{}
        foreach ($row in @($originMainExclusions + $pureReadExclusions)) {
            $parts = $row -split '\|'
            $allowances["$($parts[0])|$($parts[1])|$($parts[2])"] = [int]$parts[3]
        }
        $violations = [Collections.Generic.List[string]]::new()
        foreach ($relative in $scopedFiles) {
            $counts = ConvertTo-CountMap -Entries @(Get-PathSafetyAstLedger -Path (Join-Path $PSScriptRoot "../$relative"))
            foreach ($entry in $counts.GetEnumerator()) {
                $key = "$relative|$($entry.Key)"
                $allowed = if ($allowances.ContainsKey($key)) { [int]$allowances[$key] } else { 0 }
                if ([int]$entry.Value -gt $allowed) { $violations.Add("$key current=$($entry.Value) allowed=$allowed") }
            }
        }
        $violations.ToArray() | Should -BeNullOrEmpty
    }

    It 'detects an injected new violation' {
        $fixture = Join-Path $TestDrive 'injected.ps1'
        Set-Content -LiteralPath $fixture -Value 'function Invoke-Injection { Test-Path -LiteralPath $args[0] }' -Encoding utf8NoBOM
        $tokens = $null
        $errors = $null
        $fixtureAst = [Management.Automation.Language.Parser]::ParseFile($fixture, [ref]$tokens, [ref]$errors)
        $injected = @($fixtureAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Test-Path' }, $true))
        $injected.Count | Should -Be 1
    }
}
