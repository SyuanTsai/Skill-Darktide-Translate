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

$runtimePowerShellFiles = @(
    'skills/auto-update-darktide-mod/scripts/DesktopArchive.ps1',
    'skills/auto-update-darktide-mod/scripts/Apply-LocalizationWorkset.ps1',
    'skills/auto-update-darktide-mod/scripts/Expand-Schema14Reference.ps1',
    'skills/auto-update-darktide-mod/scripts/Finalize-LocalizationWorksetEvidence.ps1',
    'skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1',
    'skills/auto-update-darktide-mod/scripts/Invoke-ModUpdateQueue.ps1',
    'skills/auto-update-darktide-mod/scripts/LocalizationWorksetContract.psm1',
    'skills/auto-update-darktide-mod/scripts/LuaLocalizationScanner.psm1',
    'skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1',
    'skills/auto-update-darktide-mod/scripts/PathSafety.psm1',
    'skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1',
    'skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1',
    'skills/auto-update-darktide-mod/scripts/Test-LocalizationWorksetReceipt.ps1',
    'skills/auto-update-darktide-mod/scripts/Test-ModUpdateCandidate.ps1',
    'skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1',
    'skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1',
    'skills/auto-update-darktide-mod/scripts/mod-update.ps1'
)
$protectedRuntimePowerShellInventorySha256 = '5a0cce2f7eb034b02625a6bbd3b0d81c59d98da7faa7b8c21be5b9c221235d86'
$scopedFiles = @($runtimePowerShellFiles)

# Exact reviewed runtime function-level inventory. Format: file|function|call|count.
$reviewedPathnameCallAllowances = @'
skills/auto-update-darktide-mod/scripts/LocalizationWorksetContract.psm1|Read-LocalizationRuleFile|Get-Item|1
skills/auto-update-darktide-mod/scripts/LocalizationWorksetContract.psm1|Read-LocalizationRuleFile|IO.File::ReadAllBytes|1
skills/auto-update-darktide-mod/scripts/LocalizationWorksetContract.psm1|Read-ReviewedTerminologyRequest|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/LocalizationWorksetContract.psm1|Test-LocalizationWorksetStagedSidecarAbsent|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Get-PrBody|Test-Path|1
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
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservation|New-Item|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-ModReservationWorker|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Enter-RunWriterLock|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Exit-RunWriterLock|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Exit-RunWriterLock|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Get-CompletedStageResult|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Resolve-InitialState|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/DesktopArchive.ps1|Get-DesktopArchiveEvidence|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/DesktopArchive.ps1|Open-DesktopArchiveSource|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/DesktopArchive.ps1|Read-DesktopArchiveData|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/DesktopArchive.ps1|Read-DesktopArchiveData|IO.Directory::CreateDirectory|2
skills/auto-update-darktide-mod/scripts/DesktopArchive.ps1|Assert-DesktopExtractionTree|Get-ChildItem|1
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
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Install|Test-Path|4
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Localization|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Localization|New-Item|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-Localization|Test-Path|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Invoke-LocalizationWorkset|Test-Path|5
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
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Read-State|Test-Path|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.Directory::Delete|2
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.Directory::Move|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.File::SetAttributes|3
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
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|<script>|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|<script>|New-Item|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|<script>|Test-Path|6
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Assert-NoReparsePath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Get-FileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Read-FileBytesWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|IO.File::WriteAllText|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|New-Item|1
skills/auto-update-darktide-mod/scripts/New-LocalizationWorkset.ps1|Write-AtomicJson|Test-Path|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Enter-PortableFileLock|IO.Directory::Exists|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Enter-PortableFileLock|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortableLeaseFileState|IO.Directory::Exists|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortableLeaseFileState|IO.File::Exists|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortableLeaseFileState|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Publish-PortableLeaseFile|IO.File::Delete|2
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Publish-PortableLeaseFile|IO.File::Exists|5
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Publish-PortableLeaseFile|IO.File::Move|2
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Resolve-PortableTrustedRoot|IO.Directory::Exists|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Test-PortablePhysicalIdentity|IO.Directory::Exists|2
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Test-PortablePhysicalIdentity|IO.File::Exists|2
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Test-PortableReparseItem|Get-Item|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Test-PortableReparseItem|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Write-PortableTemporaryFile|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|Get-Item|2
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|IO.File::Delete|2
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|<script>|Test-Path|5
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Assert-NoReparsePath|Get-Item|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Assert-RegularDirectoryRoot|New-Item|1
skills/auto-update-darktide-mod/scripts/Receive-NexusMainFile.ps1|Assert-RegularDirectoryRoot|Test-Path|1
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
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Get-ReleasedModUpdateFinalizationResult|Test-Path|2
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateChangedHeadReconciliation|New-Item|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateChangedHeadReconciliation|Test-Path|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateMergeTopologyReconciliation|Test-Path|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|IO.Directory::Move|2
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|IO.File::Move|1
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|New-Item|3
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Invoke-ModUpdateReviewedHeadFinalization|Test-Path|9
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Remove-ModUpdateOwnedDirectory|Test-Path|3
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Resolve-ModUpdateFinalizationStateFromOwner|Get-ChildItem|1
skills/auto-update-darktide-mod/scripts/Invoke-ModUpdateQueue.ps1|<script>|Test-Path|3
skills/auto-update-darktide-mod/scripts/Invoke-ModUpdateQueue.ps1|Read-QueueTextWithHeartbeat|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/LuaLocalizationScanner.psm1|Get-LuaLocalizationDocument|Test-Path|1
skills/auto-update-darktide-mod/scripts/LuaLocalizationScanner.psm1|Read-LuaScannerFileBytes|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Assert-CoordinationPath|Get-Item|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Assert-CoordinationPath|Test-Path|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Assert-CoordinationPath|type::IO.DirectoryInfo|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Enter-SharedCoordinationLease|New-Item|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Get-CoordinationFileSha256|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Open-CoordinationPrivateDirectory|IO.Directory::CreateDirectory|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Open-CoordinationPrivateDirectory|IO.Directory::Exists|1
skills/auto-update-darktide-mod/scripts/SharedCoordinationLock.psm1|Start-SharedCoordinationAcquisitionAttempt|Test-Path|1
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
skills/auto-update-darktide-mod/scripts/Test-SourceReceipt.ps1|Get-FileSha256|IO.File::Open|1
'@ -split "`r?`n" | Where-Object { $_ }

# Pure reads/non-filesystem provider operations retained under an already-held owner guard.
$reviewedPureReadAllowances = @'
skills/auto-update-darktide-mod/scripts/Finalize-ModUpdateMerge.ps1|Test-ModUpdateWorktreeRegistered|IO.Directory::Exists|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortablePathComparison|IO.Directory::Exists|4
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortablePathComparison|IO.Directory::GetFileSystemEntries|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortablePathComparison|IO.File::Delete|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortablePathComparison|IO.File::Exists|5
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortablePathComparison|IO.File::Open|1
skills/auto-update-darktide-mod/scripts/PathSafety.psm1|Get-PortableTransactionResidue|IO.Directory::GetFileSystemEntries|1
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.Directory::Exists|4
skills/auto-update-darktide-mod/scripts/mod-update.ps1|Remove-DirectoryTreeWithHeartbeat|IO.File::Exists|4
'@ -split "`r?`n" | Where-Object { $_ }

}

Describe 'Epic pathname safety AST boundary' {
    # Scenario: The runtime is tested in a developer worktree or a tracked-only snapshot with no Git metadata.
    # Purpose: Keep the complete reviewed Skill runtime scope deterministic in both environments.
    It 'matches the complete protected Skill runtime PowerShell inventory' {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        [string[]]$expected = @($runtimePowerShellFiles)
        [Array]::Sort($expected, [StringComparer]::Ordinal)
        $runtimeRoot = Join-Path $repositoryRoot 'skills/auto-update-darktide-mod/scripts'
        [string[]]$actual = @(Get-ChildItem -LiteralPath $runtimeRoot -File -Force |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
            ForEach-Object { [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName).Replace('\', '/') })
        [Array]::Sort($actual, [StringComparer]::Ordinal)
        $inventoryBytes = [Text.UTF8Encoding]::new($false).GetBytes($expected -join "`n")
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inventoryBytes)).ToLowerInvariant() |
            Should -BeExactly $protectedRuntimePowerShellInventorySha256
        ($actual -join "`n") | Should -BeExactly ($expected -join "`n")
    }

    It 'contains no unreviewed pathname command, static IO method, or FileInfo/DirectoryInfo check' {
        $allowances = @{}
        $reviewedRows = @($reviewedPathnameCallAllowances) + @($reviewedPureReadAllowances)
        foreach ($row in $reviewedRows) {
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
