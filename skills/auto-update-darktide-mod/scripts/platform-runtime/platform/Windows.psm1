# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$script:WindowsDaclModulePath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'WindowsDacl.psm1'))
$loadedWindowsDaclModules = @(Import-Module -Name $script:WindowsDaclModulePath -PassThru -Scope Local -ErrorAction Stop)
if ($loadedWindowsDaclModules.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$loadedWindowsDaclModules[0].Path),$script:WindowsDaclModulePath)) { throw [IO.InvalidDataException]::new('The verified Windows DACL comparison dependency did not load from its bound path.') }
$script:WindowsDaclCompareCommand = $loadedWindowsDaclModules[0].ExportedCommands['Test-WindowsDaclEquivalent']
if ($null -eq $script:WindowsDaclCompareCommand) { throw [IO.InvalidDataException]::new('The verified Windows DACL comparison dependency does not export its required helper.') }
$script:RuntimePreparationModulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RuntimePreparation.psm1'))
$script:WindowsPublicationPostRenameTestHook = $null
$script:WindowsPublicationDurabilityTestHook = $null
$script:WindowsPublicationPreReopenTestHook = $null
$script:WindowsPostRenamePermissionReadbackTestHook = $null
$loadedRuntimePreparationModules = @(Import-Module -Name $script:RuntimePreparationModulePath -PassThru -Scope Local -ErrorAction Stop)
if ($loadedRuntimePreparationModules.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath([string]$loadedRuntimePreparationModules[0].Path),$script:RuntimePreparationModulePath)) { throw [IO.InvalidDataException]::new('The verified runtime preparation dependency did not load from its bound path.') }
$script:RuntimePreparationModule = $loadedRuntimePreparationModules[0]

function Invoke-WindowsRuntimePreparationCommand {
    param([string]$Name,[Collections.IDictionary]$Arguments)
    $command = $script:RuntimePreparationModule.ExportedCommands[$Name]
    if ($null -eq $command) { throw [IO.InvalidDataException]::new("The verified runtime preparation dependency does not export '$Name'.") }
    return & $command @Arguments
}

function New-WindowsPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'windows',$Step)
}

function Open-WindowsPlatformDirectory {
    param([Parameter(Mandatory = $true)][string] $Root, [string] $RelativePath, [switch] $CreatePrivate, [switch] $RootOnly)
    $parts = if ($RootOnly) { @() } else { [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath) }
    # Restrict anchors to absolute local drive roots. UNC/device paths need a separate probe.
    if ($Root -notmatch '^[A-Za-z]:[\\/]') {
        throw [ArgumentException]::new('An absolute local drive root is required.')
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $driveRoot = [IO.Path]::GetPathRoot($rootPath)
    $rawTail = $Root.Substring(3).TrimEnd('\','/')
    if ($rawTail.Length -gt 0) { [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($rawTail) }
    $tail = $rootPath.Substring($driveRoot.Length).TrimEnd('\','/')
    $guards = [Collections.Generic.List[IDisposable]]::new()
    $transferred = $false
    try {
        # The legacy helper trims a drive root's final slash. Keep the actual drive
        # root with a native guard; delegate every ordinary component to the verified module.
        $guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::WrapDirectory($driveRoot,[IDisposable[]]@()))
        $current = $driveRoot
        if ($tail.Length -gt 0) {
            foreach ($part in [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($tail)) {
                if ($current -eq $driveRoot) {
                    $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard((Join-Path $current $part),''))
                } else {
                    $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($current,$part))
                }
                $current = Join-Path $current $part
            }
        }
        foreach ($part in $parts) {
            $next = Join-Path $current $part
            if ($CreatePrivate) {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                try { $sddl = 'D:P(A;OICI;FA;;;' + $identity.User.Value + ')' } finally { $identity.Dispose() }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::CreatePrivateDirectory($next,$sddl)
            }
            if ($current -eq $driveRoot) {
                $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($next,''))
            } else {
                $guards.Add([CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($current,$part))
            }
            $current = $next
        }
        $lease = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::WrapDirectory($current,$guards.ToArray())
        $transferred = $true
        return $lease
    }
    finally { if (-not $transferred) { for ($i = $guards.Count - 1; $i -ge 0; $i--) { $guards[$i].Dispose() } } }
}

function Assert-WindowsPlatformFileIdentity {
    param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink, [switch] $VerifyPath)
    $observed = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($Lease,$Expected,[bool]$SingleLink)
    if ($VerifyPath) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetVerifiedPath($Lease) }
    return $observed
}

function Open-WindowsPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($ParentLease,$Leaf,$Access,$CreateMode) }
function Enter-WindowsPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::EnterLock($ParentLease,$Leaf,$Mode,$Timeout) }
function New-WindowsPlatformVerificationError {
    param([string]$Capability,[string]$Message)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new($Capability,'windows',$Message)
}

function Get-WindowsPlatformLeasePath { param($Lease) [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetVerifiedPath($Lease) }
function Assert-WindowsPlatformTargetPath {
    param($ParentLease,[string]$Leaf,[string]$Capability,[switch]$AllowTransactionParent)
    $parentPath=Get-WindowsPlatformLeasePath $ParentLease
    if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::IsTransactionStoreTarget($parentPath,$Leaf) -and -not $AllowTransactionParent) {
        throw (New-WindowsPlatformVerificationError $Capability 'The target must stay outside .ai-instructions-txn and must not use the reserved .ai-instructions-txn leaf.')
    }
    return $parentPath
}
function Get-WindowsPlatformIdentity {
    param($Observation)
    [pscustomobject][ordered]@{ kind='windows-file-id'; device=('0x{0:x}' -f [uint64]$Observation.Device); fileId=('0x{0:x}' -f [uint64]$Observation.Inode) }
}
function ConvertTo-WindowsPlatformIdentityNumber {
    param([string]$Value)
    if ($Value -notmatch '^(?:0x)?[0-9a-fA-F]+$') { throw [ArgumentException]::new('Windows file identity values must be hexadecimal strings.') }
    return [Convert]::ToUInt64(($Value -replace '^0x',''),16)
}
function Assert-WindowsPlatformExpectedState {
    param($Lease,$Expected,[string]$Capability)
    if ($Expected -isnot [object] -or $Expected.exists -isnot [bool]) { throw (New-WindowsPlatformVerificationError $Capability 'ExpectedState is invalid.') }
    if (-not [bool]$Expected.exists) { if ($null -ne $Lease) { throw (New-WindowsPlatformVerificationError $Capability 'The target exists but ExpectedState.exists is false.') }; return }
    if ($null -eq $Lease -or [string]$Expected.sha256 -cnotmatch '^[0-9a-f]{64}$' -or [int64]$Expected.length -lt 0 -or
        $null -eq $Expected.identity -or [string]$Expected.identity.kind -cne 'windows-file-id') { throw (New-WindowsPlatformVerificationError $Capability 'ExpectedState does not describe an existing Windows file.') }
    $observation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($Lease,$Lease.Observation,$true)
    if ([uint64]$observation.Device -ne (ConvertTo-WindowsPlatformIdentityNumber ([string]$Expected.identity.device)) -or
        [uint64]$observation.Inode -ne (ConvertTo-WindowsPlatformIdentityNumber ([string]$Expected.identity.fileId)) -or
        [int64]$observation.Size -ne [int64]$Expected.length -or
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ComputeSha256($Lease) -cne [string]$Expected.sha256) {
        throw (New-WindowsPlatformVerificationError $Capability 'The target identity, hash, or length differs from ExpectedState.')
    }
}
function Assert-WindowsPlatformExpectedContent {
    param($Lease,$Expected,[string]$Capability,[string]$Context)
    try {
        if ($null -eq $Lease -or $null -eq $Expected -or $Expected.sha256 -isnot [string] -or
            [string]$Expected.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $null -eq $Expected.length -or [int64]$Expected.length -lt 0) {
            throw [ArgumentException]::new("$Context content expectation is invalid.")
        }
        $observation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($Lease,$Lease.Observation,$true)
        if ([int64]$observation.Size -ne [int64]$Expected.length -or
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ComputeSha256($Lease) -cne [string]$Expected.sha256) {
            throw [IO.InvalidDataException]::new("$Context hash or length differs from the bound expectation.")
        }
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-WindowsPlatformVerificationError $Capability $_.Exception.Message)
    }
}
function Assert-WindowsPlatformTransactionLease {
    param($ParentLease,$TransactionLease,[string]$Capability,[switch]$AllowSameTransactionParent)
    $parentPath=Get-WindowsPlatformLeasePath $ParentLease
    $transactionPath=Get-WindowsPlatformLeasePath $TransactionLease
    $transactionId=[IO.Path]::GetFileName($transactionPath)
    $transactionContainer=[IO.Path]::GetDirectoryName($transactionPath)
    $rootPath=[IO.Path]::GetDirectoryName($transactionContainer)
    $normalizedParentPath=[IO.Path]::GetFullPath($parentPath).TrimEnd('\')
    $normalizedTransactionPath=[IO.Path]::GetFullPath($transactionPath).TrimEnd('\')
    $normalizedTransactionContainer=[IO.Path]::GetFullPath($transactionContainer).TrimEnd('\')
    $sameLeaseIdentity=[uint64]$ParentLease.Observation.Device -eq [uint64]$TransactionLease.Observation.Device -and
        [uint64]$ParentLease.Observation.Inode -eq [uint64]$TransactionLease.Observation.Inode
    $insideTransaction=[StringComparer]::OrdinalIgnoreCase.Equals($normalizedParentPath,$normalizedTransactionPath) -or
        $normalizedParentPath.StartsWith($normalizedTransactionPath+'\',[StringComparison]::OrdinalIgnoreCase)
    $insideTransactionContainer=[StringComparer]::OrdinalIgnoreCase.Equals($normalizedParentPath,$normalizedTransactionContainer) -or
        $normalizedParentPath.StartsWith($normalizedTransactionContainer+'\',[StringComparison]::OrdinalIgnoreCase)
    $validParentTopology=if($AllowSameTransactionParent){$sameLeaseIdentity -and [StringComparer]::OrdinalIgnoreCase.Equals($normalizedParentPath,$normalizedTransactionPath)}else{-not $sameLeaseIdentity -and -not $insideTransaction -and -not $insideTransactionContainer}
    if ([string]::IsNullOrEmpty($rootPath) -or $transactionId -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName($transactionContainer) -cne '.ai-instructions-txn' -or
        [uint64]$ParentLease.Observation.Device -ne [uint64]$TransactionLease.Observation.Device -or -not $validParentTopology) {
        throw (New-WindowsPlatformVerificationError $Capability 'TransactionLease must be .ai-instructions-txn/<32 lowercase hex> on the target volume, and the target must be outside it.')
    }
    return [pscustomobject][ordered]@{parentPath=$parentPath;transactionPath=$transactionPath;rootPath=$rootPath;transactionId=$transactionId}
}
function ConvertTo-WindowsPlatformPermissionSnapshot {
    param($Snapshot,[string]$Capability,[string]$Context)
    try {
        if ($null -eq $Snapshot -or [string]$Snapshot.kind -cne 'windows-sddl' -or $Snapshot.sddl -isnot [string] -or
            [string]$Snapshot.sddl -notmatch '^D:' -or [string]$Snapshot.sddl -match '[OGS]:' -or $Snapshot.readOnly -isnot [bool]) {
            throw [ArgumentException]::new('A DACL-only windows-sddl snapshot with Boolean readOnly is required.')
        }
        [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::NormalizeDaclSddl([string]$Snapshot.sddl)
        return [pscustomobject][ordered]@{
            kind='windows-sddl'
            sddl=[string]$Snapshot.sddl
            readOnly=[bool]$Snapshot.readOnly
        }
    }
    catch { throw (New-WindowsPlatformVerificationError $Capability "$Context permissions are invalid: $($_.Exception.Message)") }
}
function Test-WindowsPlatformIdentityMatch {
    param($First,$Second)
    if ($null -eq $First -or $null -eq $Second -or [string]$First.kind -cne 'windows-file-id' -or [string]$Second.kind -cne 'windows-file-id') { return $false }
    try {
        return (ConvertTo-WindowsPlatformIdentityNumber ([string]$First.device)) -eq (ConvertTo-WindowsPlatformIdentityNumber ([string]$Second.device)) -and
            (ConvertTo-WindowsPlatformIdentityNumber ([string]$First.fileId)) -eq (ConvertTo-WindowsPlatformIdentityNumber ([string]$Second.fileId))
    } catch { return $false }
}
function Test-WindowsPlatformStateMatch {
    param($First,$Second)
    $stateProperties=@('exists','sha256','length','identity')
    if ($null -eq $First -or $null -eq $Second -or @($First.PSObject.Properties).Count -ne 4 -or @($Second.PSObject.Properties).Count -ne 4) { return $false }
    foreach($name in $stateProperties){if($null -eq $First.PSObject.Properties[$name] -or $null -eq $Second.PSObject.Properties[$name]){return $false}}
    if ($First.exists -isnot [bool] -or $Second.exists -isnot [bool] -or [bool]$First.exists -ne [bool]$Second.exists) { return $false }
    if (-not [bool]$First.exists) {
        return $null -eq $First.sha256 -and $null -eq $Second.sha256 -and $null -eq $First.length -and $null -eq $Second.length -and $null -eq $First.identity -and $null -eq $Second.identity
    }
    if($First.sha256 -isnot [string] -or $Second.sha256 -isnot [string] -or [string]$First.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$Second.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $null -eq $First.length -or $null -eq $Second.length){return $false}
    try {
        return [string]$First.sha256 -ceq [string]$Second.sha256 -and [int64]$First.length -eq [int64]$Second.length -and
            (Test-WindowsPlatformIdentityMatch $First.identity $Second.identity)
    } catch { return $false }
}
function Assert-WindowsPlatformLeasePaths {
    param($ParentLease,$TransactionLease,[string]$Capability)
    [void](Get-WindowsPlatformLeasePath $ParentLease)
    [void](Get-WindowsPlatformLeasePath $TransactionLease)
}
function New-WindowsPlatformRecoveryError {
    param([string]$Capability,[string]$Message,$Receipt)
    $error=New-WindowsPlatformVerificationError $Capability $Message
    $error.Data['Receipt']=$Receipt
    return $error
}
function Get-WindowsPlatformPostRenamePermissionEvidence {
    param([string]$Operation,[string]$Role,$Before,$Lease)
    $beforeSnapshot=ConvertTo-WindowsPlatformPermissionSnapshot $Before $Operation 'Pre-rename permissions'
    try {
        $afterSnapshot=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $Lease) $Operation 'Post-rename permissions'
        if ($null -ne $script:WindowsPostRenamePermissionReadbackTestHook) {
            $afterSnapshot=ConvertTo-WindowsPlatformPermissionSnapshot (& $script:WindowsPostRenamePermissionReadbackTestHook $Operation $Role $afterSnapshot) $Operation 'Post-rename permission readback hook'
        }
        $matches=(& $script:WindowsDaclCompareCommand -FirstSddl ([string]$afterSnapshot.sddl) -SecondSddl ([string]$beforeSnapshot.sddl)) -and [bool]$afterSnapshot.readOnly -eq [bool]$beforeSnapshot.readOnly
        return [pscustomobject][ordered]@{
            detected=[bool](-not $matches)
            readbackAvailable=$true
            beforeSddl=[string]$beforeSnapshot.sddl
            afterSddl=[string]$afterSnapshot.sddl
            beforeReadOnly=[bool]$beforeSnapshot.readOnly
            afterReadOnly=[bool]$afterSnapshot.readOnly
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            detected=$null
            readbackAvailable=$false
            beforeSddl=[string]$beforeSnapshot.sddl
            afterSddl=$null
            beforeReadOnly=[bool]$beforeSnapshot.readOnly
            afterReadOnly=$null
        }
    }
}
function Get-WindowsPlatformPermissionDiagnostic {
    param($Evidence)
    if ($null -eq $Evidence) { return '' }
    return " Rename permission readback before SDDL='$($Evidence.beforeSddl)'/readOnly=$($Evidence.beforeReadOnly), after SDDL='$($Evidence.afterSddl)'/readOnly=$($Evidence.afterReadOnly)."
}
function Invoke-WindowsPlatformDurabilityHook {
    param([string]$Point,[string]$Operation,[string]$Role,$Lease)
    if ($null -ne $script:WindowsPublicationDurabilityTestHook) {
        & $script:WindowsPublicationDurabilityTestHook $Point $Operation $Role $Lease
    }
}
function Invoke-WindowsPlatformPreReopenHook {
    param([string]$Point,[string]$Operation,[string]$Role,[string]$Path)
    if ($null -ne $script:WindowsPublicationPreReopenTestHook) {
        & $script:WindowsPublicationPreReopenTestHook $Point $Operation $Role $Path
    }
}
function Invoke-WindowsPlatformFileFlush {
    param($Lease,[string]$Operation,[string]$Point='file-flush')
    try {
        Invoke-WindowsPlatformDurabilityHook $Point $Operation 'file' $Lease
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::Flush($Lease)
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] -and
            [string]$_.Exception.Capability -ceq 'publication-durability') { throw }
        throw (New-WindowsPlatformVerificationError 'publication-durability' "$Operation $Point failed before durability was confirmed: $($_.Exception.Message)")
    }
}
function Invoke-WindowsPlatformDirectoryFlush {
    param($Lease,[string]$Operation,[string]$Point,[string]$Role)
    try {
        Invoke-WindowsPlatformDurabilityHook $Point $Operation $Role $Lease
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::FlushDirectory($Lease)
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] -and
            [string]$_.Exception.Capability -ceq 'publication-durability') { throw }
        throw (New-WindowsPlatformVerificationError 'publication-durability' "$Operation $Point flush failed for the $Role directory: $($_.Exception.Message)")
    }
}
function Get-WindowsPlatformInheritedPermissions {
    param($ParentLease,[string]$Capability)
    try {
        $value=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetInheritedFilePermissions($ParentLease)
        return ConvertTo-WindowsPlatformPermissionSnapshot ([pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$value.Sddl;readOnly=[bool]$value.ReadOnly}) $Capability 'Inherited target'
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-WindowsPlatformVerificationError $Capability "CreatePrivateObjectSecurityEx inheritance calculation failed: $($_.Exception.Message)")
    }
}
function Open-WindowsPlatformMutationFile {
    param($ParentLease,[string]$Leaf,$Identity,[string]$Capability,[switch]$AllowMissing,[switch]$Writable,[switch]$PermissionWritable,[switch]$DaclWritable)
    try {
        if ($null -eq $Identity) {
            if (-not $AllowMissing) { throw [ArgumentException]::new('An expected file identity is required.') }
            return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenMutationFile($ParentLease,$Leaf)
        }
        $device=ConvertTo-WindowsPlatformIdentityNumber ([string]$Identity.device)
        $fileId=ConvertTo-WindowsPlatformIdentityNumber ([string]$Identity.fileId)
        if ($PermissionWritable) {
            if ($AllowMissing) { throw [ArgumentException]::new('A permission-writable mutation file must exist.') }
            return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPermissionMutationFile($ParentLease,$Leaf,$device,$fileId)
        }
        if ($DaclWritable) {
            if ($AllowMissing) { throw [ArgumentException]::new('A DACL-writable mutation file must exist.') }
            return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPublicationStageFile($ParentLease,$Leaf,$device,$fileId)
        }
        if ($Writable) {
            if ($AllowMissing) { throw [ArgumentException]::new('A writable mutation file must exist.') }
            return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenWritableMutationFile($ParentLease,$Leaf,$device,$fileId)
        }
        if ($AllowMissing) { return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryOpenMutationFile($ParentLease,$Leaf,$device,$fileId) }
        return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenMutationFile($ParentLease,$Leaf,$device,$fileId)
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-WindowsPlatformVerificationError $Capability "The DELETE-scoped file handle could not be opened and identity-verified: $($_.Exception.Message)")
    }
}
function Open-WindowsPlatformMutationDirectory {
    param($ParentLease,[string]$Leaf,$Identity,[string]$Capability)
    try {
        if ($null -eq $Identity -or [string]$Identity.kind -cne 'windows-file-id') { throw [ArgumentException]::new('An expected Windows directory identity is required.') }
        $device=ConvertTo-WindowsPlatformIdentityNumber ([string]$Identity.device)
        $fileId=ConvertTo-WindowsPlatformIdentityNumber ([string]$Identity.fileId)
        return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenMutationDirectory($ParentLease,$Leaf,$device,$fileId)
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-WindowsPlatformVerificationError $Capability "The DELETE-scoped directory handle could not be opened and identity-verified: $($_.Exception.Message)")
    }
}
function Get-WindowsPlatformDirectoryState {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $Leaf)
    try {
        [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
        $state=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::TryGetDirectoryState($ParentLease,$Leaf)
        if($null -eq $state){return [pscustomobject][ordered]@{exists=$false;identity=$null;inventorySha256=$null;entryCount=$null}}
        return [pscustomobject][ordered]@{
            exists=$true
            identity=(Get-WindowsPlatformIdentity $state.Observation)
            inventorySha256=[string]$state.InventorySha256
            entryCount=[int64]$state.EntryCount
        }
    }
    catch {
        if($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]){throw}
        throw (New-WindowsPlatformVerificationError 'directory-publication' "Directory state could not be captured: $($_.Exception.Message)")
    }
}
function Test-WindowsPlatformDirectoryStateMatch {
    param($First,$Second)
    if($null -eq $First -or $null -eq $Second){return $false}
    return ($First.exists -is [bool] -and $Second.exists -is [bool] -and [bool]$First.exists -eq [bool]$Second.exists -and
        (Test-WindowsPlatformIdentityMatch $First.identity $Second.identity) -and
        [string]$First.inventorySha256 -ceq [string]$Second.inventorySha256 -and
        $null -ne $First.entryCount -and $null -ne $Second.entryCount -and [int64]$First.entryCount -eq [int64]$Second.entryCount)
}
function Assert-WindowsPlatformExpectedDirectoryState {
    param($Lease,$ExpectedState,$ExpectedIdentity,[string]$Capability)
    if ($null -eq $ExpectedState) { return }
    try {
        $required=@('exists','identity','inventorySha256','entryCount')
        if ($ExpectedState -is [array] -or @($ExpectedState.PSObject.Properties).Count -ne $required.Count) { throw [ArgumentException]::new('ExpectedState must be an exact directory state.') }
        foreach($name in $required){if($null -eq $ExpectedState.PSObject.Properties[$name]){throw [ArgumentException]::new("ExpectedState is missing $name.")}}
        if($ExpectedState.exists -isnot [bool] -or -not [bool]$ExpectedState.exists){throw [ArgumentException]::new('ExpectedState.exists must be true for a moved source directory.')}
        if($ExpectedState.inventorySha256 -isnot [string] -or [string]$ExpectedState.inventorySha256 -cnotmatch '^[0-9a-f]{64}$'){throw [ArgumentException]::new('ExpectedState.inventorySha256 must be a lowercase SHA-256 value.')}
        if(($ExpectedState.entryCount -isnot [int] -and $ExpectedState.entryCount -isnot [long]) -or [int64]$ExpectedState.entryCount -lt 0){throw [ArgumentException]::new('ExpectedState.entryCount must be a non-negative integer.')}
        if(-not (Test-WindowsPlatformIdentityMatch $ExpectedState.identity $ExpectedIdentity)){throw [ArgumentException]::new('ExpectedState.identity does not match ExpectedIdentity.')}
        $nativeState=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetDirectoryState($Lease)
        $observed=[pscustomobject][ordered]@{exists=$true;identity=(Get-WindowsPlatformIdentity $nativeState.Observation);inventorySha256=[string]$nativeState.InventorySha256;entryCount=[int64]$nativeState.EntryCount}
        if(-not (Test-WindowsPlatformDirectoryStateMatch $observed $ExpectedState)){throw [IO.IOException]::new('The source directory identity or complete-tree inventory differs from ExpectedState.')}
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-WindowsPlatformVerificationError $Capability $_.Exception.Message)
    }
}
function Assert-WindowsPlatformJournalOperation {
    param($Journal,$ParentLease,$TransactionLease,$TransactionContext,[string]$Leaf,[AllowNull()][string]$StageLeaf,[AllowNull()][string]$BackupLeaf,$ExpectedState,$ExpectedStage,[string]$Method,[string]$Capability,[switch]$Removal)
    if ($null -eq $Journal) { return }
    try {
        $boundStageLeaf=if([string]::IsNullOrEmpty($StageLeaf)){$null}else{$StageLeaf}
        $boundBackupLeaf=if([string]::IsNullOrEmpty($BackupLeaf)){$null}else{$BackupLeaf}
        $required=@('sequence','kind','method','targetRelativePath','stageLeaf','backupLeaf','quarantineLeaf','original','backupIdentity','applied','permissions','state')
        if ($Journal -is [array] -or $null -eq $Journal -or @($Journal.PSObject.Properties).Count -ne $required.Count) { throw [ArgumentException]::new('must be one validated journal v1 operation') }
        foreach($name in $required){ if($null -eq $Journal.PSObject.Properties[$name]){ throw [ArgumentException]::new("is missing $name") } }
        if ([string]$Journal.method -cne $Method) { throw [ArgumentException]::new("method does not match $Method") }
        if ($Removal) {
            if ([string]$Journal.kind -cne 'remove-file') { throw [ArgumentException]::new('kind must be remove-file') }
        }
        elseif (([string]$Journal.kind -cne 'write-file' -and [string]$Journal.kind -cne 'create-file') -or
            ([string]$Journal.kind -ceq 'write-file' -and -not [bool]$ExpectedState.exists) -or
            ([string]$Journal.kind -ceq 'create-file' -and [bool]$ExpectedState.exists)) {
            throw [ArgumentException]::new('kind must be write-file for an existing target or create-file for a missing target')
        }
        $segments=@(([string]$Journal.targetRelativePath).Split('/'))
        if($segments.Count -lt 1 -or @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0){ throw [ArgumentException]::new('targetRelativePath is invalid') }
        foreach($segment in $segments){ [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($segment) }
        if(-not [StringComparer]::OrdinalIgnoreCase.Equals($segments[-1],$Leaf)){ throw [ArgumentException]::new('targetRelativePath leaf does not match Leaf') }
        $parentRelative=[IO.Path]::GetRelativePath([string]$TransactionContext.rootPath,[string]$TransactionContext.parentPath).Replace('\','/')
        if($parentRelative -eq '.'){ $parentRelative='' }
        if([IO.Path]::IsPathRooted($parentRelative) -or $parentRelative -eq '..' -or $parentRelative.StartsWith('../',[StringComparison]::Ordinal)){ throw [ArgumentException]::new('ParentLease is outside the transaction root') }
        $expectedTarget=if([string]::IsNullOrEmpty($parentRelative)){$Leaf}else{$parentRelative+'/'+$Leaf}
        $roundTrip=[IO.Path]::GetFullPath((Join-Path ([string]$TransactionContext.rootPath) ([string]$Journal.targetRelativePath).Replace('/','\')))
        $expectedFull=[IO.Path]::GetFullPath((Join-Path ([string]$TransactionContext.parentPath) $Leaf))
        if(-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.targetRelativePath,$expectedTarget) -or -not [StringComparer]::OrdinalIgnoreCase.Equals($roundTrip,$expectedFull)){ throw [ArgumentException]::new('targetRelativePath parent does not match ParentLease') }
        if((($null -eq $boundStageLeaf) -ne ($null -eq $Journal.stageLeaf)) -or ($null -ne $boundStageLeaf -and -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.stageLeaf,$boundStageLeaf))){ throw [ArgumentException]::new('stageLeaf does not match StageLease') }
        if((($null -eq $boundBackupLeaf) -ne ($null -eq $Journal.backupLeaf)) -or ($null -ne $boundBackupLeaf -and -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.backupLeaf,$boundBackupLeaf))){ throw [ArgumentException]::new('backupLeaf does not match the displaced leaf') }
        if($null -ne $Journal.quarantineLeaf){ throw [ArgumentException]::new('quarantineLeaf must be null for file operations') }
        if(-not (Test-WindowsPlatformStateMatch $Journal.original $ExpectedState)){ throw [ArgumentException]::new('original does not match ExpectedState') }
        if([bool]$ExpectedState.exists -and $null -eq $Journal.permissions){ throw [ArgumentException]::new('permissions do not match original existence') }
        if($Removal){
            if($Journal.applied.exists -isnot [bool] -or [bool]$Journal.applied.exists -or $null -ne $Journal.applied.sha256 -or $null -ne $Journal.applied.length -or $null -ne $Journal.applied.identity){ throw [ArgumentException]::new('applied must describe a missing target for removal') }
        }
        elseif($null -eq $ExpectedStage -or $Journal.applied.exists -isnot [bool] -or -not [bool]$Journal.applied.exists -or $Journal.applied.sha256 -isnot [string] -or
            [string]$Journal.applied.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $null -eq $Journal.applied.length -or $null -eq $ExpectedStage.length -or
            [string]$Journal.applied.sha256 -cne [string]$ExpectedStage.sha256 -or [int64]$Journal.applied.length -ne [int64]$ExpectedStage.length){ throw [ArgumentException]::new('applied does not match ExpectedStage') }
    }
    catch { throw (New-WindowsPlatformVerificationError $Capability "Journal operation mismatch: $($_.Exception.Message)") }
}

function Assert-WindowsPlatformDirectoryJournalOperation {
    param($Journal,$TransactionContext,$ParentLease,[string]$Leaf,[string]$DestinationLeaf,$ExpectedIdentity,[string]$Direction,$ExpectedState)
    if ($null -eq $Journal) { return }
    try {
        $required=@('sequence','kind','method','targetRelativePath','stageLeaf','backupLeaf','quarantineLeaf','original','backupIdentity','applied','permissions','state')
        if($Journal -is [array] -or @($Journal.PSObject.Properties).Count -ne $required.Count){throw [ArgumentException]::new('must be one validated journal v1 operation')}
        foreach($name in $required){if($null -eq $Journal.PSObject.Properties[$name]){throw [ArgumentException]::new("is missing $name")}}
        if([string]$Journal.kind -cnotin @('swap-directory','create-directory')){throw [ArgumentException]::new('kind must be swap-directory or create-directory')}
        if([string]$Journal.method -cne 'stage-rename'){throw [ArgumentException]::new('method must be stage-rename')}

        $targetLeaf=if($Direction -ceq 'ToTransaction'){$Leaf}else{$DestinationLeaf}
        $segments=@(([string]$Journal.targetRelativePath).Split('/'))
        if($segments.Count -lt 1 -or @($segments|Where-Object{[string]::IsNullOrWhiteSpace($_)}).Count -gt 0){throw [ArgumentException]::new('targetRelativePath is invalid')}
        foreach($segment in $segments){[void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($segment)}
        if(-not [StringComparer]::OrdinalIgnoreCase.Equals($segments[-1],$targetLeaf)){throw [ArgumentException]::new('targetRelativePath leaf does not match the target leaf')}
        $parentPath=Get-WindowsPlatformLeasePath $ParentLease
        $parentRelative=[IO.Path]::GetRelativePath([string]$TransactionContext.rootPath,$parentPath).Replace('\','/')
        if($parentRelative -eq '.'){$parentRelative=''}
        if([IO.Path]::IsPathRooted($parentRelative) -or $parentRelative -eq '..' -or $parentRelative.StartsWith('../',[StringComparison]::Ordinal)){throw [ArgumentException]::new('ParentLease is outside the transaction root')}
        $expectedTarget=if([string]::IsNullOrEmpty($parentRelative)){$targetLeaf}else{$parentRelative+'/'+$targetLeaf}
        if(-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.targetRelativePath,$expectedTarget)){throw [ArgumentException]::new('targetRelativePath parent does not match ParentLease')}

        if($null -eq $ExpectedState){throw [ArgumentException]::new('ExpectedState is required when Journal is supplied')}
        $journalIdentity=$null
        $journalState=$null
        if($Direction -ceq 'ToTransaction'){
            if($null -ne $Journal.backupLeaf -and [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.backupLeaf,$DestinationLeaf)){
                if([string]$Journal.kind -cne 'swap-directory' -or -not [bool]$Journal.original.exists){throw [ArgumentException]::new('backupLeaf is incompatible with the directory operation')}
                $journalIdentity=$Journal.original.identity
                $journalState=$Journal.original
            }
            elseif($null -ne $Journal.quarantineLeaf -and [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.quarantineLeaf,$DestinationLeaf)){
                $journalIdentity=$Journal.applied.identity
                $journalState=$Journal.applied
            }
            else{throw [ArgumentException]::new('DestinationLeaf must match backupLeaf or quarantineLeaf')}
        }
        else{
            if($null -ne $Journal.stageLeaf -and [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.stageLeaf,$Leaf)){$journalIdentity=$Journal.applied.identity;$journalState=$Journal.applied}
            elseif($null -ne $Journal.backupLeaf -and [StringComparer]::OrdinalIgnoreCase.Equals([string]$Journal.backupLeaf,$Leaf)){
                if([string]$Journal.kind -cne 'swap-directory'){throw [ArgumentException]::new('backupLeaf is incompatible with create-directory')}
                $journalIdentity=$Journal.backupIdentity
                $journalState=$Journal.original
            }
            else{throw [ArgumentException]::new('Leaf must match stageLeaf or backupLeaf')}
        }
        if(-not (Test-WindowsPlatformIdentityMatch $journalIdentity $ExpectedIdentity)){throw [ArgumentException]::new('ExpectedIdentity does not match the journal identity for this rename')}
        if(-not (Test-WindowsPlatformDirectoryStateMatch $journalState $ExpectedState)){throw [ArgumentException]::new('ExpectedState does not match the journal directory state for this rename')}
    }
    catch { throw (New-WindowsPlatformVerificationError 'directory-publication' "Journal operation mismatch: $($_.Exception.Message)") }
}

function Publish-WindowsPlatformFile {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $Leaf,[Parameter(Mandatory = $true)] $TransactionLease,[Parameter(Mandatory = $true)] $StageLease,[Parameter(Mandatory = $true)] $ExpectedState,[AllowNull()] $DisplacedLeaf,[Parameter(Mandatory = $true)] $ExpectedStage,[switch] $NoReplace,$Journal)
    if ([string]::IsNullOrEmpty($DisplacedLeaf)) { $DisplacedLeaf=$null }
    [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    if ($null -ne $DisplacedLeaf) { [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($DisplacedLeaf) }
    if ($NoReplace -and [bool]$ExpectedState.exists) { throw (New-WindowsPlatformVerificationError 'publication' 'NoReplace requires ExpectedState.exists=false and relies on the native rename to reject a raced destination.') }
    $journalStore=[StringComparer]::OrdinalIgnoreCase.Equals($Leaf,'journal.json') -and [object]::ReferenceEquals($ParentLease,$TransactionLease)
    if ($journalStore -and $PSBoundParameters.ContainsKey('Journal')) { throw (New-WindowsPlatformVerificationError 'publication' 'Journal store publication must not supply Journal.') }
    [void](Assert-WindowsPlatformTargetPath $ParentLease $Leaf 'publication' -AllowTransactionParent:$journalStore)
    $transactionContext=Assert-WindowsPlatformTransactionLease $ParentLease $TransactionLease 'publication' -AllowSameTransactionParent:$journalStore
    Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'publication'
    $stagePath=Get-WindowsPlatformLeasePath $StageLease
    $stageLeaf=[IO.Path]::GetFileName($stagePath)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($stagePath),[string]$transactionContext.transactionPath)) { throw (New-WindowsPlatformVerificationError 'publication' 'StageLease is not an immediate child of TransactionLease.') }
    if ($journalStore -and (-not [StringComparer]::OrdinalIgnoreCase.Equals($stageLeaf,'journal.stage') -or
        ([bool]$ExpectedState.exists -and -not [StringComparer]::OrdinalIgnoreCase.Equals($DisplacedLeaf,'journal.prev')))) {
        throw (New-WindowsPlatformVerificationError 'publication' 'Journal store publication requires journal.stage and uses journal.prev when replacing journal.json.')
    }
    $stageObservation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($StageLease,$StageLease.Observation,$true)
    $stageIdentity=Get-WindowsPlatformIdentity $stageObservation
    Assert-WindowsPlatformExpectedContent $StageLease $ExpectedStage 'publication' 'Stage'
    if ([bool]$ExpectedState.exists -ne ($null -ne $DisplacedLeaf)) { throw (New-WindowsPlatformVerificationError 'publication' 'DisplacedLeaf must be supplied exactly when ExpectedState.exists is true.') }
    Assert-WindowsPlatformJournalOperation $Journal $ParentLease $TransactionLease $transactionContext $Leaf $stageLeaf $DisplacedLeaf $ExpectedState $ExpectedStage 'stage-rename' 'publication'
    # In NoReplace mode do not probe the destination name. The handle-bound native
    # rename is the authority that rejects an existing or raced destination.
    $target=$null
    $mutationStage=$null
    $displaced=$false
    $applied=$false
    $stagePermissions=$null
    $permissionsApplied=$false
    $targetReadOnlyCleared=$false
    $preserveForRecovery=$false
    $permissions=$null
    $verifyCreatePermissionsAfterRename=$false
    $aclFrozenAfterRename=$false
    $receipt=$null
    try {
        $target=if($NoReplace){$null}elseif([bool]$ExpectedState.exists){Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'publication' -AllowMissing}else{Open-WindowsPlatformMutationFile $ParentLease $Leaf $null 'publication' -AllowMissing}
        $stagePermissions=Get-WindowsPlatformPermissions $StageLease
        Assert-WindowsPlatformExpectedState $target $ExpectedState 'publication'
        if ($null -ne $target) {
            $permissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $target) 'publication' 'Live target'
            if ($null -ne $Journal) {
                $journalPermissions=ConvertTo-WindowsPlatformPermissionSnapshot $Journal.permissions 'publication' 'Journal original'
                if (-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$permissions.sddl) -SecondSddl ([string]$journalPermissions.sddl)) -or [bool]$permissions.readOnly -ne [bool]$journalPermissions.readOnly) {
                    throw (New-WindowsPlatformVerificationError 'publication' 'Journal permissions do not match the live target.')
                }
            }
        }
        else {
            if($null -ne $Journal -and $null -ne $Journal.permissions){
                $permissions=ConvertTo-WindowsPlatformPermissionSnapshot $Journal.permissions 'publication' 'Journal create-file stage'
                $verifyCreatePermissionsAfterRename=$true
            }
            else{
                $permissions=Get-WindowsPlatformInheritedPermissions $ParentLease 'publication'
            }
        }
        # OpenFile intentionally preserves origin/main's read-only share mode, which
        # blocks a second DELETE request.  Publication therefore consumes the caller's
        # validated stage lease, then reopens the same identity relative to TransactionLease.
        $StageLease.Dispose()
        Invoke-WindowsPlatformPreReopenHook 'after-dispose-before-reopen' 'publication' 'stage' $stagePath
        if ([bool]$stagePermissions.readOnly) {
            $mutationStage=Open-WindowsPlatformMutationFile $TransactionLease $stageLeaf $stageIdentity 'publication' -PermissionWritable
            Assert-WindowsPlatformExpectedContent $mutationStage $ExpectedStage 'publication' 'Permission-opened stage ExpectedStage'
            if ($null -ne $Journal) { Assert-WindowsPlatformExpectedContent $mutationStage $Journal.applied 'publication' 'Permission-opened stage journal applied state' }
            $permissionsApplied=$true
            [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($mutationStage,$null,$false)
            $mutationStage.Dispose();$mutationStage=$null
        }
        $mutationStage=Open-WindowsPlatformMutationFile $TransactionLease $stageLeaf $stageIdentity 'publication' -DaclWritable
        Assert-WindowsPlatformExpectedContent $mutationStage $ExpectedStage 'publication' 'Reopened stage ExpectedStage'
        if ($null -ne $Journal) { Assert-WindowsPlatformExpectedContent $mutationStage $Journal.applied 'publication' 'Reopened stage journal applied state' }
        if ($null -ne $Journal -and -not (Test-WindowsPlatformIdentityMatch $Journal.applied.identity (Get-WindowsPlatformIdentity $mutationStage.Observation))) {
            throw (New-WindowsPlatformVerificationError 'publication' 'Journal applied.identity does not match the reopened stage identity.')
        }
        $permissionsApplied=$true
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ApplyPublicationDacl($mutationStage,[string]$permissions.sddl)
        $nativeStagePermissions=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($mutationStage,$null,[bool]$permissions.readOnly)
        $canonicalStagePermissions=ConvertTo-WindowsPlatformPermissionSnapshot ([pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$nativeStagePermissions.Sddl;readOnly=[bool]$nativeStagePermissions.ReadOnly}) 'publication' 'Applied stage'
        if (-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$canonicalStagePermissions.sddl) -SecondSddl ([string]$permissions.sddl)) -or [bool]$canonicalStagePermissions.readOnly -ne [bool]$permissions.readOnly) {
            throw (New-WindowsPlatformVerificationError 'publication' 'Applied stage permissions do not match the target snapshot.')
        }
        Invoke-WindowsPlatformFileFlush $mutationStage 'publication' 'stage-flush'
        Invoke-WindowsPlatformDirectoryFlush $ParentLease 'publication' 'preflight' 'parent'
        Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'publication' 'preflight' 'transaction'
        if ($null -ne $target) {
            Assert-WindowsPlatformExpectedState $target $ExpectedState 'publication'
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false);$targetReadOnlyCleared=$true }
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$TransactionLease,$DisplacedLeaf)
            $displaced=$true
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$targetReadOnlyCleared=$false }
        }
        Invoke-WindowsPlatformDurabilityHook 'before-applied-rename' 'publication' 'stage' $mutationStage
        try { [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($mutationStage,$ParentLease,$Leaf) }
        catch {
            if ($displaced) {
                try { if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }; [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf); if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }; $targetReadOnlyCleared=$false;$displaced=$false }
                catch { throw (New-WindowsPlatformVerificationError 'publication' "Publication failed and rename rollback also failed; inspect target '$Leaf', stage '$stageLeaf', and displaced '$DisplacedLeaf'.") }
            }
            throw
        }
        $applied=$true
        [string[]]$completedSteps=@($(if($null -ne $target){'displaced-rename'})) + @('applied-rename','file-flush')
        $receipt=[pscustomobject][ordered]@{
            completedSteps=$completedSteps
            appliedIdentity=(Get-WindowsPlatformIdentity $mutationStage.Observation)
            displacedIdentity=$(if($null -eq $target){$null}else{Get-WindowsPlatformIdentity $target.Observation})
            permissions=$permissions
            permissionsDrift=$null
            displacedLeaf=$DisplacedLeaf
            durability='unconfirmed'
            flush=[pscustomobject][ordered]@{file=$true;directory=$false;transactionDirectory=$false}
        }
        if ($null -ne $target) {
            $receipt.permissionsDrift=Get-WindowsPlatformPostRenamePermissionEvidence -Operation publication -Role displaced -Before $permissions -Lease $target
        }
        if($verifyCreatePermissionsAfterRename){
            $aclFrozenAfterRename=$true
            try {
                Invoke-WindowsPlatformDurabilityHook 'after-applied-rename-before-permission-readback' 'publication' 'stage' $mutationStage
                $publishedCreatePermissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $mutationStage) 'publication' 'Published create-file target'
                if(-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$publishedCreatePermissions.sddl) -SecondSddl ([string]$permissions.sddl)) -or [bool]$publishedCreatePermissions.readOnly -ne [bool]$permissions.readOnly){
                    throw (New-WindowsPlatformVerificationError 'publication' 'Published create-file permissions do not match the journal snapshot.')
                }
            }
            catch {
                $preserveForRecovery=$true
                throw (New-WindowsPlatformRecoveryError 'publication' "Post-rename create-file permission verification failed; journal recovery is required. $($_.Exception.Message)" $receipt)
            }
        }
        try {
            Invoke-WindowsPlatformDirectoryFlush $ParentLease 'publication' 'post-rename' 'parent'
            $receipt.flush.directory=$true
            Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'publication' 'post-rename' 'transaction'
            $receipt.flush.transactionDirectory=$true
            $receipt.completedSteps=[string[]]@($receipt.completedSteps)+@('directory-flush')
            $receipt.durability='confirmed'
        }
        catch {
            $preserveForRecovery=$true
            throw (New-WindowsPlatformRecoveryError 'publication-durability' "Post-rename directory flush failed; journal recovery is required. $($_.Exception.Message)" $receipt)
        }
        try {
            if ($null -ne $script:WindowsPublicationPostRenameTestHook) { & $script:WindowsPublicationPostRenameTestHook 'publication' $transactionContext.parentPath $transactionContext.transactionPath $ParentLease $TransactionLease $mutationStage $target }
            Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'publication'
            $published=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenValidationFile($ParentLease,$Leaf)
            try {
                Assert-WindowsPlatformExpectedState $published ([pscustomobject]@{exists=$true;sha256=[string]$ExpectedStage.sha256;length=[int64]$ExpectedStage.length;identity=(Get-WindowsPlatformIdentity $mutationStage.Observation)}) 'publication'
                $actualPermissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $published) 'publication' 'Published target'
                if (-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$actualPermissions.sddl) -SecondSddl ([string]$permissions.sddl)) -or [bool]$actualPermissions.readOnly -ne [bool]$permissions.readOnly) { throw (New-WindowsPlatformVerificationError 'publication' "Published permissions do not match the expected snapshot (expected '$($permissions.sddl)'/$($permissions.readOnly), observed '$($actualPermissions.sddl)'/$($actualPermissions.readOnly)).") }
            } finally { if($null -ne $published){$published.Dispose()} }
        }
        catch {
            $preserveForRecovery=$true
            $permissionDiagnostic=Get-WindowsPlatformPermissionDiagnostic $receipt.permissionsDrift
            throw (New-WindowsPlatformRecoveryError 'publication' "Post-publication path verification failed; journal recovery is required.$permissionDiagnostic $($_.Exception.Message)" $receipt)
        }
        return $receipt
    }
    catch {
        $publicationFailure=$_
        if ($preserveForRecovery) { throw $publicationFailure }
        try {
            if ($applied) {
                if(-not $aclFrozenAfterRename){[void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($mutationStage,$null,$false)}
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($mutationStage,$TransactionLease,$stageLeaf)
                $applied=$false
            }
            if ($displaced) {
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf)
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }
                $restoredTargetPermissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $target) 'publication' 'Rollback target'
                if (-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$restoredTargetPermissions.sddl) -SecondSddl ([string]$permissions.sddl)) -or [bool]$restoredTargetPermissions.readOnly -ne [bool]$permissions.readOnly) { throw [IO.IOException]::new('Rollback target permissions do not match the original snapshot.') }
                $displaced=$false
            }
            elseif ($targetReadOnlyCleared) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$targetReadOnlyCleared=$false }
            if ($permissionsApplied -and -not $aclFrozenAfterRename) {
                if ($null -eq $mutationStage) { $mutationStage=Open-WindowsPlatformMutationFile $TransactionLease $stageLeaf $stageIdentity 'publication' -PermissionWritable }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::ApplyPublicationDacl($mutationStage,[string]$stagePermissions.sddl)
                [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($mutationStage,$null,[bool]$stagePermissions.readOnly)
                $restoredStagePermissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $mutationStage) 'publication' 'Rollback stage'
                if (-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$restoredStagePermissions.sddl) -SecondSddl ([string]$stagePermissions.sddl)) -or [bool]$restoredStagePermissions.readOnly -ne [bool]$stagePermissions.readOnly) { throw [IO.IOException]::new('Rollback stage permissions do not match the original snapshot.') }
            }
        }
        catch { throw (New-WindowsPlatformVerificationError 'publication' "Publication failed and rollback could not restore every rename; target='$Leaf', stage='$stageLeaf', displaced='$DisplacedLeaf'.") }
        throw $publicationFailure
    }
    finally {
        if ($null -ne $mutationStage) { $mutationStage.Dispose() }
        if ($null -ne $target) { $target.Dispose() }
    }
}

function Remove-WindowsPlatformOwnedFile {
    param([Parameter(Mandatory = $true)] $ParentLease,[Parameter(Mandatory = $true)][string] $Leaf,[Parameter(Mandatory = $true)] $ExpectedState,$TransactionLease,[AllowNull()] $TombstoneLeaf,$Journal)
    if ([string]::IsNullOrEmpty($TombstoneLeaf)) { $TombstoneLeaf=$null }
    [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    $tombstone=($null -ne $TransactionLease -and $null -ne $TombstoneLeaf)
    if (($null -ne $TransactionLease) -ne ($null -ne $TombstoneLeaf)) { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'TransactionLease and TombstoneLeaf must be supplied together.') }
    if (-not $tombstone -and $PSBoundParameters.ContainsKey('Journal')) { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Journal is forbidden in cleanup mode.') }
    $transactionContext=$null
    if ($tombstone) {
        [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($TombstoneLeaf)
        [void](Assert-WindowsPlatformTargetPath $ParentLease $Leaf 'owned-file-removal')
        $transactionContext=Assert-WindowsPlatformTransactionLease $ParentLease $TransactionLease 'owned-file-removal'
        Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'owned-file-removal'
        Assert-WindowsPlatformJournalOperation $Journal $ParentLease $TransactionLease $transactionContext $Leaf $null $TombstoneLeaf $ExpectedState $null 'tombstone-rename' 'owned-file-removal' -Removal
    }
    else {
        $path=Assert-WindowsPlatformTargetPath $ParentLease $Leaf 'owned-file-removal' -AllowTransactionParent
        if ([IO.Path]::GetFileName($path) -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path)) -cne '.ai-instructions-txn') { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Cleanup is restricted to a transaction-private directory.') }
    }
    $target=$null
    $renamed=$false
    $readOnlyCleared=$false
    $preserveForRecovery=$false
    $permissions=$null
    $receipt=$null
    try {
        $target=if([bool]$ExpectedState.exists){Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'owned-file-removal'}else{Open-WindowsPlatformMutationFile $ParentLease $Leaf $null 'owned-file-removal' -AllowMissing}
        Assert-WindowsPlatformExpectedState $target $ExpectedState 'owned-file-removal'
        $permissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $target) 'owned-file-removal' 'Live target'
        if ($null -ne $Journal) {
            $journalPermissions=ConvertTo-WindowsPlatformPermissionSnapshot $Journal.permissions 'owned-file-removal' 'Journal original'
            if (-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$permissions.sddl) -SecondSddl ([string]$journalPermissions.sddl)) -or [bool]$permissions.readOnly -ne [bool]$journalPermissions.readOnly) {
                throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Journal permissions do not match the live target.')
            }
        }
        $identity=Get-WindowsPlatformIdentity $target.Observation
        if ($tombstone) {
            Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal' 'preflight' 'parent'
            Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'owned-file-removal' 'preflight' 'transaction'
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false);$readOnlyCleared=$true }
            $targetPath=Get-WindowsPlatformLeasePath $target
            $target.Dispose();$target=$null
            Invoke-WindowsPlatformPreReopenHook 'after-dispose-before-reopen' 'owned-file-removal' 'target' $targetPath
            $target=Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'owned-file-removal' -Writable
            Assert-WindowsPlatformExpectedState $target $ExpectedState 'owned-file-removal'
            Invoke-WindowsPlatformFileFlush $target 'owned-file-removal' 'file-flush'
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$TransactionLease,$TombstoneLeaf)
            $renamed=$true
            if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true);$readOnlyCleared=$false }
            $receipt=[pscustomobject][ordered]@{
                completedSteps=[string[]]@('tombstone-rename','file-flush')
                appliedIdentity=$null
                displacedIdentity=$identity
                backupIdentity=$identity
                permissions=$permissions
                permissionsDrift=$null
                tombstoneLeaf=$TombstoneLeaf
                durability='unconfirmed'
                flush=[pscustomobject][ordered]@{file=$true;directory=$false;transactionDirectory=$false}
            }
            $receipt.permissionsDrift=Get-WindowsPlatformPostRenamePermissionEvidence -Operation owned-file-removal -Role tombstone -Before $permissions -Lease $target
            try {
                Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal' 'post-rename' 'parent'
                $receipt.flush.directory=$true
                Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'owned-file-removal' 'post-rename' 'transaction'
                $receipt.flush.transactionDirectory=$true
                $receipt.completedSteps=[string[]]@($receipt.completedSteps)+@('directory-flush')
                $receipt.durability='confirmed'
            }
            catch {
                $preserveForRecovery=$true
                throw (New-WindowsPlatformRecoveryError 'publication-durability' "Post-rename directory flush failed; journal recovery is required. $($_.Exception.Message)" $receipt)
            }
            try {
                if ($null -ne $script:WindowsPublicationPostRenameTestHook) { & $script:WindowsPublicationPostRenameTestHook 'removal' $transactionContext.parentPath $transactionContext.transactionPath $ParentLease $TransactionLease $null $target }
                Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'owned-file-removal'
                $remaining=Open-WindowsPlatformMutationFile $ParentLease $Leaf $null 'owned-file-removal' -AllowMissing
                if($null -ne $remaining){ try { throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'Removed target name still exists.') } finally { $remaining.Dispose() } }
                $tombstoneValidation=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenValidationFile($TransactionLease,$TombstoneLeaf)
                try {
                    Assert-WindowsPlatformExpectedState $tombstoneValidation $ExpectedState 'owned-file-removal'
                }
                finally { $tombstoneValidation.Dispose() }
            }
            catch {
                $preserveForRecovery=$true
                $permissionDiagnostic=Get-WindowsPlatformPermissionDiagnostic $receipt.permissionsDrift
                throw (New-WindowsPlatformRecoveryError 'owned-file-removal' "Post-removal path verification failed; journal recovery is required.$permissionDiagnostic $($_.Exception.Message)" $receipt)
            }
            return $receipt
        }
        Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal-cleanup' 'preflight' 'parent'
        if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false);$readOnlyCleared=$true }
        Invoke-WindowsPlatformDurabilityHook 'delete-on-close' 'owned-file-removal-cleanup' 'file' $target
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::DeleteOnClose($target)
        $receipt=[pscustomobject][ordered]@{
            completedSteps=[string[]]@('delete-on-close')
            appliedIdentity=$null
            displacedIdentity=$identity
            backupIdentity=$identity
            permissions=$permissions
            deleted=$true
            durability='unconfirmed'
            flush=[pscustomobject][ordered]@{file=$false;fileNotRequired=$true;directory=$false;transactionDirectory=$null}
        }
        $target.Dispose();$target=$null
        try {
            Invoke-WindowsPlatformDirectoryFlush $ParentLease 'owned-file-removal-cleanup' 'post-delete' 'parent'
            $receipt.flush.directory=$true
            $receipt.completedSteps=[string[]]@($receipt.completedSteps)+@('directory-flush')
            $receipt.durability='confirmed'
        }
        catch {
            $preserveForRecovery=$true
            throw (New-WindowsPlatformRecoveryError 'publication-durability' "Post-delete directory flush failed; manual recovery verification is required. $($_.Exception.Message)" $receipt)
        }
        return $receipt
    }
    catch {
        $removalFailure=$_
        if ($preserveForRecovery) { throw $removalFailure }
        if ($renamed) {
            try {
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$false) }
                [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameNoReplace($target,$ParentLease,$Leaf)
                if ($permissions.readOnly) { [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($target,$null,$true) }
                $restoredPermissions=ConvertTo-WindowsPlatformPermissionSnapshot (Get-WindowsPlatformPermissions $target) 'owned-file-removal' 'Rollback target'
                if (-not (& $script:WindowsDaclCompareCommand -FirstSddl ([string]$restoredPermissions.sddl) -SecondSddl ([string]$permissions.sddl)) -or [bool]$restoredPermissions.readOnly -ne [bool]$permissions.readOnly) { throw [IO.IOException]::new('Rollback target permissions do not match the original snapshot.') }
                $renamed=$false;$readOnlyCleared=$false
            }
            catch { throw (New-WindowsPlatformVerificationError 'owned-file-removal' "Removal failed and rollback could not restore the tombstone rename; target='$Leaf', tombstone='$TombstoneLeaf'.") }
        }
        elseif ($readOnlyCleared) {
            $restoreTarget=$null
            try {
                $restoreTarget=if($null -ne $target){$target}else{Open-WindowsPlatformMutationFile $ParentLease $Leaf $ExpectedState.identity 'owned-file-removal'}
                [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($restoreTarget,$null,$true)
                $readOnlyCleared=$false
            }
            catch { throw (New-WindowsPlatformVerificationError 'owned-file-removal' "Removal failed before rename and the read-only attribute could not be restored for '$Leaf'.") }
            finally { if($null -eq $target -and $null -ne $restoreTarget){$restoreTarget.Dispose()} }
        }
        throw $removalFailure
    }
    finally { if($null -ne $target){$target.Dispose()} }
}
function Move-WindowsPlatformOwnedDirectory {
    param(
        [Parameter(Mandatory = $true)] $ParentLease,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $DestinationLeaf,
        [Parameter(Mandatory = $true)] $ExpectedIdentity,
        [Parameter(Mandatory = $true)][ValidateSet('ToTransaction','FromTransaction')][string] $Direction,
        $ExpectedState,
        $Journal
    )
    $source=$null
    $renamed=$false
    $receipt=$null
    try {
        if($null -ne $Journal -and $null -eq $ExpectedState){throw (New-WindowsPlatformVerificationError 'directory-publication' 'ExpectedState is required when Journal is supplied.')}
        [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
        [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($DestinationLeaf)
        $targetLeaf=if($Direction -ceq 'ToTransaction'){$Leaf}else{$DestinationLeaf}
        [void](Assert-WindowsPlatformTargetPath $ParentLease $targetLeaf 'directory-publication')
        $transactionContext=Assert-WindowsPlatformTransactionLease $ParentLease $TransactionLease 'directory-publication'
        Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'directory-publication'
        Assert-WindowsPlatformDirectoryJournalOperation $Journal $transactionContext $ParentLease $Leaf $DestinationLeaf $ExpectedIdentity $Direction $ExpectedState
        $sourceParent=if($Direction -ceq 'ToTransaction'){$ParentLease}else{$TransactionLease}
        $destinationParent=if($Direction -ceq 'ToTransaction'){$TransactionLease}else{$ParentLease}
        $sourcePath=Join-Path (Get-WindowsPlatformLeasePath $sourceParent) $Leaf
        Invoke-WindowsPlatformPreReopenHook 'before-directory-open' 'directory-publication' 'source' $sourcePath
        $source=Open-WindowsPlatformMutationDirectory $sourceParent $Leaf $ExpectedIdentity 'directory-publication'
        Assert-WindowsPlatformExpectedDirectoryState $source $ExpectedState $ExpectedIdentity 'directory-publication'
        Invoke-WindowsPlatformDirectoryFlush $ParentLease 'directory-publication' 'preflight' 'parent'
        Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'directory-publication' 'preflight' 'transaction'
        Invoke-WindowsPlatformDurabilityHook 'before-directory-rename' 'directory-publication' 'source' $source
        [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::RenameDirectoryNoReplace($source,$destinationParent,$DestinationLeaf)
        $renamed=$true
        $receipt=[pscustomobject][ordered]@{
            capability='directory-publication'
            sourceLeaf=$Leaf
            destinationLeaf=$DestinationLeaf
            direction=$Direction
            identity=(Get-WindowsPlatformIdentity $source.Observation)
        }
        try {
            Invoke-WindowsPlatformDirectoryFlush $ParentLease 'directory-publication' 'post-rename' 'parent'
            Invoke-WindowsPlatformDirectoryFlush $TransactionLease 'directory-publication' 'post-rename' 'transaction'
            Assert-WindowsPlatformLeasePaths $ParentLease $TransactionLease 'directory-publication'
            $movedIdentity=Get-WindowsPlatformIdentity ([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($source,$source.Observation,$false))
            if(-not (Test-WindowsPlatformIdentityMatch $movedIdentity $ExpectedIdentity)){throw (New-WindowsPlatformVerificationError 'directory-publication' 'The moved directory identity changed after rename.')}
            $source.Dispose()
            $source=$null
            $publishedState=Get-WindowsPlatformDirectoryState $destinationParent $DestinationLeaf
            if(-not [bool]$publishedState.exists -or -not (Test-WindowsPlatformIdentityMatch $publishedState.identity $ExpectedIdentity)){throw (New-WindowsPlatformVerificationError 'directory-publication' 'The destination directory identity changed after rename.')}
            if($null -ne $ExpectedState){
                if(-not (Test-WindowsPlatformDirectoryStateMatch $publishedState $ExpectedState)){throw (New-WindowsPlatformVerificationError 'directory-publication' 'The destination directory identity or complete-tree inventory differs from ExpectedState after rename.')}
            }
        }
        catch { throw (New-WindowsPlatformRecoveryError 'directory-publication' "Post-rename durability or complete-state verification failed; journal recovery is required. $($_.Exception.Message)" $receipt) }
        return $receipt
    }
    catch {
        if($renamed){throw}
        if($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] -and [string]$_.Exception.Capability -ceq 'directory-publication'){throw}
        throw (New-WindowsPlatformVerificationError 'directory-publication' $_.Exception.Message)
    }
    finally { if($null -ne $source){$source.Dispose()} }
}

function Remove-WindowsPlatformOwnedDirectoryTree {
    [CmdletBinding(DefaultParameterSetName='TransactionRoot')]
    param(
        [Parameter(Mandatory = $true,ParameterSetName='TransactionRoot')] $TransactionRootLease,
        [Parameter(Mandatory = $true,ParameterSetName='Transaction')] $TransactionLease,
        [Parameter(Mandatory = $true)][string] $Leaf,
        [Parameter(Mandatory = $true)] $ExpectedIdentity
    )
    $parentLease=if($PSCmdlet.ParameterSetName -ceq 'TransactionRoot'){$TransactionRootLease}else{$TransactionLease}
    $receipt=$null
    try {
        [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
        $parentPath=Get-WindowsPlatformLeasePath $parentLease
        if($PSCmdlet.ParameterSetName -ceq 'TransactionRoot'){
            if([IO.Path]::GetFileName($parentPath) -cne '.ai-instructions-txn' -or $Leaf -cnotmatch '^[0-9a-f]{32}$'){
                throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'TransactionRootLease must name .ai-instructions-txn and Leaf must be a 32 lowercase hexadecimal transaction ID.')
            }
        }
        elseif([IO.Path]::GetFileName($parentPath) -cnotmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($parentPath)) -cne '.ai-instructions-txn'){
            throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'TransactionLease must name .ai-instructions-txn/<32 lowercase hex>.')
        }
        if($null -eq $ExpectedIdentity -or [string]$ExpectedIdentity.kind -cne 'windows-file-id'){
            throw (New-WindowsPlatformVerificationError 'owned-file-removal' 'ExpectedIdentity must be a Windows file identity.')
        }
        $expectedDevice=ConvertTo-WindowsPlatformIdentityNumber ([string]$ExpectedIdentity.device)
        $expectedFileId=ConvertTo-WindowsPlatformIdentityNumber ([string]$ExpectedIdentity.fileId)
        Invoke-WindowsPlatformDirectoryFlush $parentLease 'owned-directory-tree-removal' 'preflight' 'parent'
        Invoke-WindowsPlatformDurabilityHook 'before-owned-directory-tree-delete' 'owned-directory-tree-removal' 'directory' $parentLease
        $removed=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::DeleteOwnedDirectoryTree($parentLease,$Leaf,$expectedDevice,$expectedFileId)
        $receipt=[pscustomobject][ordered]@{capability='owned-file-removal';removedEntryCount=[int]$removed;leaf=$Leaf}
        try { Invoke-WindowsPlatformDirectoryFlush $parentLease 'owned-directory-tree-removal' 'post-delete' 'parent' }
        catch { throw (New-WindowsPlatformRecoveryError 'owned-file-removal' "Post-delete directory flush failed; manual recovery verification is required. $($_.Exception.Message)" $receipt) }
        return $receipt
    }
    catch {
        if($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] -and [string]$_.Exception.Capability -ceq 'owned-file-removal'){throw}
        throw (New-WindowsPlatformVerificationError 'owned-file-removal' $_.Exception.Message)
    }
}
function Get-WindowsPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease)
    $value=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetPermissions($Lease)
    [pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$value.Sddl;readOnly=[bool]$value.ReadOnly}
}
function Set-WindowsPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot)
    if ($null -ne $Snapshot) {
        if ($null -ne $Policy -or [string]$Snapshot.kind -cne 'windows-sddl' -or [string]$Snapshot.sddl -notmatch '^D:' -or [string]$Snapshot.sddl -match '[OGS]:' -or $Snapshot.readOnly -isnot [bool]) {
            throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('permissions-snapshot: a DACL-only windows-sddl snapshot is required','windows')
        }
        $Policy=@{Sddl=[string]$Snapshot.sddl;ReadOnly=[bool]$Snapshot.readOnly}
    }
    if ($Policy -isnot [Collections.IDictionary] -or $Policy.Count -eq 0 -or @($Policy.Keys | Where-Object { $_ -cnotin @('Sddl','ReadOnly') }).Count -gt 0) {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('permissions-policy: only DACL Sddl and ReadOnly are supported','windows')
    }
    $sddl = $null
    $readOnly = $null
    if ($Policy.Contains('Sddl')) {
        $sddl = [string]$Policy.Sddl
        if ($sddl -notmatch '^D:' -or $sddl -match '[OGS]:') { throw [ArgumentException]::new('Only a DACL SDDL policy is supported.') }
    }
    if ($Policy.Contains('ReadOnly')) {
        if ($Policy.ReadOnly -isnot [bool]) { throw [ArgumentException]::new('ReadOnly must be Boolean.') }
        $readOnly = $Policy.ReadOnly
    }
    $value=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::SetPermissions($Lease,$sddl,$readOnly)
    [pscustomobject][ordered]@{kind='windows-sddl';sddl=[string]$value.Sddl;readOnly=[bool]$value.ReadOnly}
}
function Resolve-WindowsPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, [Parameter(Mandatory = $true)] $OfflineCache, $ReleaseMetadata) Invoke-WindowsRuntimePreparationCommand 'Resolve-VerifiedPlatformPowerShell' @{ Policy=$Policy; DestinationLease=$DestinationLease; OfflineCache=$OfflineCache; ReleaseMetadata=$ReleaseMetadata; Platform='windows' } }
function Initialize-WindowsPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) Invoke-WindowsRuntimePreparationCommand 'Initialize-VerifiedPlatformPester' @{ Policy=$Policy; RuntimeReceipt=$RuntimeReceipt; DestinationLease=$DestinationLease; Platform='windows'; ResolverPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Resolve-StandardValidationTool.ps1') } }

Export-ModuleMember -Function *-WindowsPlatform*
