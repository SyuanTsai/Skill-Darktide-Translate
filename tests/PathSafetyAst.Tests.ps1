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

$prProductionPowerShellFiles = @(
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
    'scripts/Test-CleanRepositoryHead.ps1',
    'scripts/Get-SourcePin.ps1',
    'scripts/Test-Repository.ps1',
    'skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1',
    'skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1',
    'skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1',
    'skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1',
    'skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1',
    'skills/auto-update-darktide-mod/scripts/PathSafety.psm1',
    'skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1',
    'skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1',
    'skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1',
    'skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1',
    'skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1',
    'skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1',
    'skills/auto-update-darktide-mod/scripts/mod-update.ps1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/Resolve-StandardValidationTool.ps1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/WindowsDacl.psm1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/installer-safe-mutation.psm1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform-runtime.psm1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/Linux.psm1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/MacOS.psm1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/RuntimePreparation.psm1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/Unix.psm1',
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/Windows.psm1'
)

# These files are byte-exact authority fbdc793 runtime artifacts. Their hashes
# are verified by PathSafety before loading and consumer changes are forbidden,
# so they are intentionally excluded from the consumer pathname-call policy.
$vendoredAuthorityAllowlist = [ordered]@{
    'skills/auto-update-darktide-mod/scripts/platform-runtime/Resolve-StandardValidationTool.ps1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/WindowsDacl.psm1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/installer-safe-mutation.psm1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform-runtime.psm1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/Linux.psm1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/MacOS.psm1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/RuntimePreparation.psm1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/Unix.psm1' = 'authority fbdc793 immutable bytes'
    'skills/auto-update-darktide-mod/scripts/platform-runtime/platform/Windows.psm1' = 'authority fbdc793 immutable bytes'
}
$scopedFiles = @($prProductionPowerShellFiles | Where-Object { -not $vendoredAuthorityAllowlist.Contains($_) })

# Exact origin/main function-level inventory. Format: file|function|call|count.
$originMainExclusions = @'
scripts/Install-LatestPowerShell.ps1|<script>|Get-Item|1
scripts/Install-LatestPowerShell.ps1|<script>|IO.File::Open|1
scripts/Install-LatestPowerShell.ps1|<script>|New-Item|1
scripts/Install-LatestPowerShell.ps1|<script>|Test-Path|3
scripts/PowerShellRelease.psm1|Assert-VerifiedPowerShellArchive|Get-Item|1
scripts/PowerShellRelease.psm1|Assert-VerifiedPowerShellArchive|Test-Path|1
scripts/Test-Repository.ps1|<script>|Get-ChildItem|1
scripts/Test-Repository.ps1|<script>|Get-Item|1
scripts/Test-Repository.ps1|<script>|Test-Path|6
scripts/Test-Repository.ps1|Add-PublisherSkillPath|Get-Item|1
scripts/Test-Repository.ps1|Assert-BootstrapOpenAiMetadata|Get-Item|1
scripts/Test-Repository.ps1|Assert-NoReparseAncestors|Get-Item|1
scripts/Test-Repository.ps1|Get-ContentInventory|Get-ChildItem|1
scripts/Test-Repository.ps1|Get-ContentInventory|Get-Item|1
scripts/Test-Repository.ps1|Get-ManagedProjectionSnapshot|Get-ChildItem|1
scripts/Test-Repository.ps1|Get-ManagedProjectionSnapshot|Get-Item|1
scripts/Test-Repository.ps1|Get-PublisherSkillDiscoveryPaths|Get-ChildItem|9
scripts/Test-Repository.ps1|Get-PublisherSkillDiscoveryPaths|Get-Item|2
scripts/Test-Repository.ps1|Get-PublisherSkillDiscoveryPaths|Test-Path|2
scripts/Test-Repository.ps1|Get-RawFileSha256|IO.File::Open|1
scripts/Test-Repository.ps1|Invoke-BootstrapTransitionRepositoryValidation|Get-ChildItem|1
scripts/Test-Repository.ps1|Invoke-BootstrapTransitionRepositoryValidation|Get-Item|1
scripts/Test-Repository.ps1|Invoke-BootstrapTransitionRepositoryValidation|Test-Path|6
scripts/Test-Repository.ps1|Read-OpenAiMetadata|Get-Item|1
scripts/Test-Repository.ps1|Read-OpenAiMetadata|Test-Path|1
scripts/Test-Repository.ps1|Read-StrictJson|Test-Path|1
scripts/Test-Repository.ps1|Read-StrictUtf8File|IO.File::ReadAllBytes|1
scripts/Test-Repository.ps1|Write-ExclusiveUtf8File|Get-Item|1
scripts/Test-Repository.ps1|Write-ExclusiveUtf8File|IO.File::Open|1
scripts/Test-Repository.ps1|Write-ExclusiveUtf8File|IO.File::ReadAllBytes|1
scripts/Test-Repository.ps1|Write-ExclusiveUtf8File|New-Item|1
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
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|<script>|Test-Path|2
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Read-FileBytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Write-AtomicBytes|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Write-AtomicBytes|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Write-AtomicBytes|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Write-AtomicBytes|Test-Path|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Write-AtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1|Write-AtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1|<script>|Get-Item|2
skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1|<script>|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1|<script>|IO.File::OpenRead|1
skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1|<script>|Remove-Item|1
skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1|<script>|Test-Path|3
skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|<script>|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|<script>|Test-Path|5
skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|Write-AtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|Write-AtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1|Write-AtomicJson|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|<script>|Test-Path|5
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-ArchivePayloadSecurity|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-BuildMetadataPaths|Test-Path|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-FileTreeMatchesManifest|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-LocalizationWorksetDeletionEvidence|Test-Path|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|3
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-NoReparsePath|type::IO.FileInfo|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-NoReparseTree|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-NoReparseTree|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Assert-RunLocalSkillPackage|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-IncompleteClaim|Get-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-IncompleteClaim|IO.File::Move|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-IncompleteClaim|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-IncompleteClaim|Test-Path|8
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-InterruptedSourceDelivery|IO.File::Delete|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-InterruptedSourceDelivery|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-InterruptedSourceDelivery|IO.File::Open|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-InterruptedSourceDelivery|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Complete-InterruptedSourceDelivery|Test-Path|4
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Copy-DirectoryBytes|Get-ChildItem|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Copy-DirectoryBytes|New-Item|3
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Copy-FileWithHeartbeat|IO.File::Open|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservation|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservation|IO.Directory::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservation|IO.Directory::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservation|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservation|New-Item|3
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservation|Test-Path|3
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservationWorker|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Exit-RunWriterLock|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Exit-RunWriterLock|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Get-CompletedStageResult|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Get-ZipEntries|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Import-SecurityOverrides|Get-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-AcquireSource|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-AcquireSource|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-AcquireSource|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-AcquireSource|Test-Path|9
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-BuildCommits|Get-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-BuildCommits|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Claim|Get-Item|3
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Claim|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Claim|New-Item|6
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Claim|Test-Path|9
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Extract|IO.Directory::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Extract|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Extract|Move-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Extract|New-Item|3
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Extract|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Install|Test-Path|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Localization|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Localization|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Localization|Test-Path|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-LocalizationWorkset|Test-Path|4
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Publish|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-ReviewSnapshot|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|New-BuildMetadataPreview|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|New-GitEvidenceBatch|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|New-GitNormalizationManifest|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|New-GitTreeManifest|Get-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|New-Manifest|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Normalize-GitCaseVariantWorktreePaths|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Normalize-GitCaseVariantWorktreePaths|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Normalize-GitCaseVariantWorktreePaths|Test-Path|4
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Read-FileBytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Read-ModReservationOwner|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Read-State|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.Directory::Delete|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.Directory::Move|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.File::SetAttributes|3
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|Test-Path|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Test-SourceRequestPreflight|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicBytes|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicBytes|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicBytes|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicBytes|Test-Path|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicJson|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-AtomicJson|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-ByteFile|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-ByteFile|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-ByteFile|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-ByteFile|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-BytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-ModReservationOwner|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Write-ModReservationOwner|Test-Path|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|<script>|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|<script>|New-Item|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|<script>|Test-Path|5
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Read-FileBytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|New-Item|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|Test-Path|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-WindowsPathCaseSensitivity|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Test-PortableReparseItem|type::IO.DirectoryInfo|2
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Test-PortableReparseItem|type::IO.FileInfo|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|Get-Item|2
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|IO.File::Delete|2
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|Test-Path|5
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Assert-RegularDirectoryRoot|New-Item|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Assert-RegularDirectoryRoot|Test-Path|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Get-ArchiveEvidence|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Invoke-ApiDownload|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Invoke-ApiDownload|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Invoke-ApiDownload|Test-Path|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Move-ApiPartialToRetainedEvidence|Get-Item|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Move-ApiPartialToRetainedEvidence|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Move-ApiPartialToRetainedEvidence|Test-Path|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Read-SourceRequest|Test-Path|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Write-AtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Write-AtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Write-AtomicJson|New-Item|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Write-AtomicJson|Test-Path|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Assert-MergeFileTuple|Get-Item|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Assert-ModUpdateMergeFinalizationState|Test-Path|2
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Copy-ModUpdateEvidenceTree|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Copy-ModUpdateEvidenceTree|New-Item|2
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Copy-ModUpdateEvidenceTree|Test-Path|3
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Get-ModUpdateEvidenceManifest|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateChangedHeadReconciliation|New-Item|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateChangedHeadReconciliation|Test-Path|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateMergeTopologyReconciliation|Test-Path|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|IO.Directory::Move|2
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|New-Item|3
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|Test-Path|11
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Assert-CoordinationPath|Get-Item|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Assert-CoordinationPath|Test-Path|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Assert-CoordinationPath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Enter-CoordinationOwnerGuard|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Enter-SharedCoordinationLease|New-Item|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Get-CoordinationFileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Write-CoordinationAtomicJson|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Write-CoordinationAtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Write-CoordinationAtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Write-CoordinationAtomicJson|New-Item|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Write-CoordinationAtomicJson|Test-Path|2
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Write-CoordinationReceipt|New-Item|1
skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|<script>|Test-Path|1
skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|Assert-RegularFile|Get-Item|2
skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|Assert-RegularFile|Test-Path|1
skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1|Read-FileBytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|<script>|Test-Path|6
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Assert-ArchivePayloadSecurityIntegrity|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Assert-ClaimedArchiveIntegrity|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Assert-EvidenceGenerationReceiptIntegrity|Get-Item|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Assert-NoReparseTree|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Assert-NoReparseTree|Test-Path|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Read-FileBytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Write-AtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Write-AtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1|Write-AtomicJson|New-Item|1
skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|Read-FileBytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|Test-Document|Get-Item|1
skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|Test-Document|IO.File::OpenRead|1
skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1|Test-SkillSourcePin|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|<script>|Test-Path|2
skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|Get-ArchiveEvidence|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|Get-FileSha256|IO.File::Open|1
'@ -split "`r?`n" | Where-Object { $_ }

# Pure reads/non-filesystem provider operations retained under an already-held lease.
$pureReadExclusions = @'
scripts/StandardSourceDriver.psm1|Get-DarktideActiveSkillIds|Get-ChildItem|1
scripts/StandardSourceDriver.psm1|Get-DarktideOwnedProcessEnvironment|Get-ChildItem|1
scripts/StandardSourceDriver.psm1|Get-DarktideSourceResolverEnvironment|Remove-Item|1
scripts/Invoke-SourceChild.ps1|Get-InventoryPaths|Get-ChildItem|1
scripts/Invoke-SourceChild.ps1|Invoke-ChildOwnedCommand|Get-ChildItem|1
scripts/Prepare-WorkflowPowerShell.ps1|<script>|IO.File::AppendAllText|3
scripts/Invoke-CorePester.ps1|<script>|Get-ChildItem|1
scripts/CorePesterIntegrity.psm1|Test-CorePesterClosure|Get-ChildItem|1
scripts/CorePesterIntegrity.psm1|Get-CorePesterTreeSnapshot|Get-ChildItem|1
'@ -split "`r?`n" | Where-Object { $_ }

# F8 residual-risk allowance: these exact registry verification reads are the
# three pre-load operations that hash and inventory the vendored authority.
# The verified path is loaded only after these checks, then every runtime file
# is revalidated by inventory plus SingleLink identity; automation.md records
# why the remaining verification-to-load replacement interval adds no power.
$f8VerifiedImportAllowances = @'
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-VendoredPlatformRuntimeSha256|IO.File::ReadAllBytes|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Assert-VendoredPlatformRuntime|Get-Item|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Assert-VendoredPlatformRuntime|Get-ChildItem|1
'@ -split "`r?`n" | Where-Object { $_ }
}

Describe 'Epic pathname safety AST boundary' {
    It 'matches every production PowerShell file changed from origin main when Git metadata is present' {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git'))) { return }

        $branchChanged = @(& git -C $repositoryRoot diff --name-only origin/main...HEAD -- '*.ps1' '*.psm1')
        $LASTEXITCODE | Should -Be 0
        $worktreeChanged = @(& git -C $repositoryRoot diff --name-only -- '*.ps1' '*.psm1')
        $LASTEXITCODE | Should -Be 0
        $changed = @($branchChanged + $worktreeChanged | Sort-Object -Unique)
        [string[]]$expected = @($changed | Where-Object { $_ -notlike 'tests/*' })
        [string[]]$actual = @($prProductionPowerShellFiles)
        [Array]::Sort($expected, [StringComparer]::Ordinal)
        [Array]::Sort($actual, [StringComparer]::Ordinal)
        ($actual -join "`n") | Should -BeExactly ($expected -join "`n")
    }

    It 'contains no unreviewed pathname command, static IO method, or FileInfo/DirectoryInfo check' {
        $allowances = @{}
        foreach ($row in @($originMainExclusions + $pureReadExclusions + $f8VerifiedImportAllowances)) {
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
