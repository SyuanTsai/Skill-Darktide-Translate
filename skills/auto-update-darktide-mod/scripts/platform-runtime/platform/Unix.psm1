# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

function Assert-UnixPlatformHost {
    param([Parameter(Mandatory=$true)][string] $Capability)
    $platform = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
    if ($platform -cnotin @('linux','macos')) {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new($Capability,$platform)
    }
    return $platform
}

function New-UnixPlatformVerificationError {
    param([Parameter(Mandatory=$true)][string] $Capability,[Parameter(Mandatory=$true)][string] $Message)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new(
        $Capability,
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem(),
        $Message)
}

function Assert-UnixPlatformTargetPath {
    param([Parameter(Mandatory=$true)] $ParentLease,[Parameter(Mandatory=$true)][string] $Leaf,[Parameter(Mandatory=$true)][string] $Capability,[switch] $AllowTransactionParent)
    $parentPath=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($ParentLease)
    if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::IsTransactionStoreTarget($parentPath,$Leaf) -and -not $AllowTransactionParent) {
        throw (New-UnixPlatformVerificationError $Capability 'The target must stay outside .ai-instructions-txn and must not use the reserved .ai-instructions-txn leaf.')
    }
    return $parentPath
}

function Get-UnixContractValue {
    param([AllowNull()] $Object,[Parameter(Mandatory=$true)][string] $Name,[switch] $Required)
    if ($null -eq $Object) {
        if ($Required) { throw [ArgumentException]::new("Contract object is missing '$Name'.") }
        return $null
    }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    if ($Required) { throw [ArgumentException]::new("Contract object is missing '$Name'.") }
    return $null
}

function ConvertTo-UnixOptionalLeaf {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    $leaf = [string]$Value
    if ([string]::IsNullOrEmpty($leaf)) { return $null }
    return $leaf
}

function ConvertTo-UnixNativeNullableString {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return [NullString]::Value }
    return [string]$Value
}

function ConvertFrom-UnixIdentityNumber {
    param([Parameter(Mandatory=$true)] $Value,[Parameter(Mandatory=$true)][string] $Name)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw [ArgumentException]::new("$Name must be a journal identity string.") }
    $text = [string]$Value
    try {
        if ($text.StartsWith('0x',[StringComparison]::OrdinalIgnoreCase)) { return [Convert]::ToUInt64($text.Substring(2),16) }
        return [Convert]::ToUInt64($text,[Globalization.CultureInfo]::InvariantCulture)
    }
    catch { throw [ArgumentException]::new("$Name is outside the unsigned 64-bit identity range.",$_.Exception) }
}

function ConvertTo-UnixPlatformIdentity {
    param([AllowNull()] $Observation)
    if ($null -eq $Observation) { return $null }
    [pscustomobject][ordered]@{
        kind = 'unix-device-inode'
        device = ([uint64]$Observation.Device).ToString([Globalization.CultureInfo]::InvariantCulture)
        fileId = ([uint64]$Observation.Inode).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
}

function ConvertTo-UnixPermissionReceipt {
    param([Parameter(Mandatory=$true)] $Snapshot)
    [pscustomobject][ordered]@{ kind='unix-mode'; mode=[string]$Snapshot.Mode; uid=[uint64]$Snapshot.Uid; gid=[uint64]$Snapshot.Gid }
}

function ConvertTo-UnixFlushReceipt {
    param([Parameter(Mandatory=$true)] $Flush,[switch] $Cleanup)
    if ($Cleanup) {
        return [pscustomobject][ordered]@{
            file=$false
            fileNotRequired=$true
            directory=([string]$Flush.ParentDirectory -ceq 'confirmed')
            transactionDirectory=$null
        }
    }
    [pscustomobject][ordered]@{
        file=([string]$Flush.File -ceq 'confirmed')
        directory=([string]$Flush.ParentDirectory -ceq 'confirmed')
        transactionDirectory=([string]$Flush.TransactionDirectory -ceq 'confirmed')
    }
}

function Assert-UnixJournalOperationShape {
    param([Parameter(Mandatory=$true)] $Journal)
    $required=@('sequence','kind','method','targetRelativePath','stageLeaf','backupLeaf','quarantineLeaf','original','backupIdentity','applied','permissions','state')
    if ($Journal -is [array] -or $null -eq $Journal -or @($Journal.PSObject.Properties).Count -ne $required.Count) {
        throw [ArgumentException]::new('Journal must be one validated journal v1 operation.')
    }
    foreach ($name in $required) {
        if ($null -eq $Journal.PSObject.Properties[$name]) { throw [ArgumentException]::new("Journal is missing $name.") }
    }
    $sequence=Get-UnixContractValue $Journal sequence -Required
    if ($sequence -is [bool] -or $null -eq $sequence -or [decimal]$sequence -ne [Math]::Truncate([decimal]$sequence) -or [decimal]$sequence -lt 1 -or [decimal]$sequence -gt [long]::MaxValue) {
        throw [ArgumentException]::new('Journal sequence is invalid.')
    }
    if ($null -ne (Get-UnixContractValue $Journal quarantineLeaf)) {
        throw [ArgumentException]::new('Journal quarantineLeaf must be null for file operations.')
    }
}

function Assert-UnixExpectedState {
    param([Parameter(Mandatory=$true)] $State,[Parameter(Mandatory=$true)][string] $Context,[switch] $AllowAbsent)
    $exists = Get-UnixContractValue $State exists -Required
    if ($exists -isnot [bool]) { throw [ArgumentException]::new("$Context.exists must be boolean.") }
    if (-not $exists) {
        if (-not $AllowAbsent) { throw [ArgumentException]::new("$Context must describe an existing file.") }
        foreach ($name in @('sha256','length','identity')) {
            if ($null -ne (Get-UnixContractValue $State $name)) { throw [ArgumentException]::new("$Context.$name must be null when exists is false.") }
        }
        return [pscustomobject]@{ exists=$false; sha256=$null; length=[long]0; device=[uint64]0; inode=[uint64]0 }
    }
    $sha256 = Get-UnixContractValue $State sha256 -Required
    $length = Get-UnixContractValue $State length -Required
    $identity = Get-UnixContractValue $State identity -Required
    if ($sha256 -isnot [string] -or [string]$sha256 -cnotmatch '^[0-9a-f]{64}$') { throw [ArgumentException]::new("$Context.sha256 must be lowercase SHA-256.") }
    if ($length -is [bool] -or $null -eq $length -or [decimal]$length -ne [Math]::Truncate([decimal]$length) -or [decimal]$length -lt 0 -or [decimal]$length -gt [long]::MaxValue) { throw [ArgumentException]::new("$Context.length is invalid.") }
    if ((Get-UnixContractValue $identity kind -Required) -cne 'unix-device-inode') { throw [ArgumentException]::new("$Context.identity.kind must be unix-device-inode.") }
    [pscustomobject]@{
        exists=$true
        sha256=[string]$sha256
        length=[long]$length
        device=ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity device -Required) "$Context.identity.device"
        inode=ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity fileId -Required) "$Context.identity.fileId"
    }
}

function Assert-UnixExpectedStage {
    param([Parameter(Mandatory=$true)] $State)
    $sha256 = Get-UnixContractValue $State sha256 -Required
    $length = Get-UnixContractValue $State length -Required
    if ($sha256 -isnot [string] -or [string]$sha256 -cnotmatch '^[0-9a-f]{64}$') { throw [ArgumentException]::new('ExpectedStage.sha256 must be lowercase SHA-256.') }
    if ($length -is [bool] -or $null -eq $length -or [decimal]$length -ne [Math]::Truncate([decimal]$length) -or [decimal]$length -lt 0 -or [decimal]$length -gt [long]::MaxValue) { throw [ArgumentException]::new('ExpectedStage.length is invalid.') }
    [pscustomobject]@{ sha256=[string]$sha256; length=[long]$length }
}

function Assert-UnixJournalAppliedIdentity {
    param([Parameter(Mandatory=$true)] $Applied,[Parameter(Mandatory=$true)] $StageIdentity)
    try {
        $identity = Get-UnixContractValue $Applied identity -Required
        $required = @('kind','device','fileId')
        if ($null -eq $identity -or $identity -is [array] -or @($identity.PSObject.Properties).Count -ne $required.Count) {
            throw [ArgumentException]::new('Journal applied.identity must be one unix-device-inode identity.')
        }
        foreach ($name in $required) {
            if ($null -eq $identity.PSObject.Properties[$name]) {
                throw [ArgumentException]::new("Journal applied.identity is missing $name.")
            }
        }
        if ((Get-UnixContractValue $identity kind -Required) -cne 'unix-device-inode') {
            throw [ArgumentException]::new('Journal applied.identity.kind must be unix-device-inode.')
        }
        $device = ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity device -Required) 'Journal.applied.identity.device'
        $inode = ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity fileId -Required) 'Journal.applied.identity.fileId'
        if ($device -ne [uint64]$StageIdentity.Device -or $inode -ne [uint64]$StageIdentity.Inode) {
            throw [ArgumentException]::new('Journal applied.identity does not match the retained stage descriptor identity.')
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] { throw }
    catch { throw (New-UnixPlatformVerificationError publication $_.Exception.Message) }
}

function Assert-UnixJournalBackupIdentity {
    param([Parameter(Mandatory=$true)] $Journal,[Parameter(Mandatory=$true)] $ExpectedState,[switch] $Required,[string] $Capability='owned-file-removal')
    try {
        $identity = Get-UnixContractValue $Journal backupIdentity
        if ($null -eq $identity) {
            if ($Required) { throw [ArgumentException]::new('Journal backupIdentity must exist for removal and equal ExpectedState.identity.') }
            return
        }
        if (-not [bool]$ExpectedState.exists) { throw [ArgumentException]::new('Journal backupIdentity must be null when ExpectedState is absent.') }
        if ((Get-UnixContractValue $identity kind -Required) -cne 'unix-device-inode') {
            throw [ArgumentException]::new('Journal backupIdentity.kind must be unix-device-inode.')
        }
        $device = ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity device -Required) 'Journal.backupIdentity.device'
        $inode = ConvertFrom-UnixIdentityNumber (Get-UnixContractValue $identity fileId -Required) 'Journal.backupIdentity.fileId'
        if ($device -ne [uint64]$ExpectedState.device -or $inode -ne [uint64]$ExpectedState.inode) {
            throw [ArgumentException]::new('Journal backupIdentity must equal ExpectedState.identity.')
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] { throw }
    catch {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new(
            $Capability,
            [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem(),
            $_.Exception.Message)
    }
}

function Assert-UnixJournalBinding {
    param(
        $Journal,$ParentLease,$TransactionLease,[string]$Leaf,$StageLease,
        [AllowNull()]$DisplacedLeaf,$ExpectedState,$ExpectedStage,[switch]$Remove
    )
    if ($null -eq $Journal) {
        return [pscustomobject]@{ hasPermissions=$false; mode=[uint32]0; uid=[uint64]0; gid=[uint64]0 }
    }

    try {
        $DisplacedLeaf = ConvertTo-UnixOptionalLeaf $DisplacedLeaf
        Assert-UnixJournalOperationShape -Journal $Journal
        $capability=if($Remove){'owned-file-removal'}else{'publication'}
        $relative = Get-UnixContractValue $Journal targetRelativePath -Required
        if ($relative -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$relative) -or [string]$relative -match '\\') {
            throw [ArgumentException]::new('Journal targetRelativePath is not a canonical relative path.')
        }
        $segments = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments([string]$relative)
        if ($segments[-1] -cne $Leaf) { throw [ArgumentException]::new('Journal targetRelativePath leaf does not match Leaf.') }

        $transactionPath = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($TransactionLease).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $transactionContainer = [IO.Directory]::GetParent($transactionPath)
        if ($null -eq $transactionContainer -or $transactionContainer.Name -cne '.ai-instructions-txn' -or $null -eq $transactionContainer.Parent) {
            throw [ArgumentException]::new('TransactionLease does not expose a journal transaction root.')
        }
        $transactionId = [IO.Path]::GetFileName($transactionPath)
        if ($transactionId -cnotmatch '^[0-9a-f]{32}$') { throw [ArgumentException]::new('TransactionLease identifier is invalid.') }
        $expectedParentPath = $transactionContainer.Parent.FullName
        if ($segments.Count -gt 1) {
            $expectedParentPath = [IO.Path]::GetFullPath([IO.Path]::Combine($expectedParentPath,[string]::Join([IO.Path]::DirectorySeparatorChar,$segments[0..($segments.Count-2)])))
        }
        $parentPath = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($ParentLease).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not [string]::Equals($parentPath,$expectedParentPath,[StringComparison]::Ordinal)) {
            throw [ArgumentException]::new('Journal targetRelativePath parent does not identify ParentLease.')
        }

        $journalOriginal = Assert-UnixExpectedState (Get-UnixContractValue $Journal original -Required) 'Journal.original' -AllowAbsent
        $expectedOriginal = Assert-UnixExpectedState $ExpectedState ExpectedState -AllowAbsent
        if ($journalOriginal.exists -ne $expectedOriginal.exists -or
            $journalOriginal.sha256 -cne $expectedOriginal.sha256 -or
            $journalOriginal.length -ne $expectedOriginal.length -or
            $journalOriginal.device -ne $expectedOriginal.device -or
            $journalOriginal.inode -ne $expectedOriginal.inode) {
            throw [ArgumentException]::new('Journal original state does not match ExpectedState.')
        }
        Assert-UnixJournalBackupIdentity -Journal $Journal -ExpectedState $expectedOriginal -Required:$Remove -Capability $capability

        if ($Remove) {
            if ((Get-UnixContractValue $Journal kind -Required) -cne 'remove-file' -or
                (Get-UnixContractValue $Journal method -Required) -cne 'tombstone-rename' -or
                $null -ne (Get-UnixContractValue $Journal stageLeaf) -or
                (Get-UnixContractValue $Journal backupLeaf -Required) -cne $DisplacedLeaf) {
                throw [ArgumentException]::new('Journal removal operation does not match TombstoneLeaf and tombstone-rename.')
            }
            $journalApplied = Get-UnixContractValue $Journal applied -Required
            if ([bool](Get-UnixContractValue $journalApplied exists -Required) -or
                $null -ne (Get-UnixContractValue $journalApplied sha256) -or
                $null -ne (Get-UnixContractValue $journalApplied length) -or
                $null -ne (Get-UnixContractValue $journalApplied identity)) {
                throw [ArgumentException]::new('Journal removal applied state must be absent.')
            }
        }
        else {
            $expectedKind = if ($expectedOriginal.exists) { 'write-file' } else { 'create-file' }
            if ((Get-UnixContractValue $Journal kind -Required) -cne $expectedKind -or
                (Get-UnixContractValue $Journal method -Required) -cne 'stage-rename' -or
                (Get-UnixContractValue $Journal stageLeaf -Required) -cne [string]$StageLease.Name -or
                (Get-UnixContractValue $Journal backupLeaf) -cne $DisplacedLeaf) {
                throw [ArgumentException]::new('Journal publication operation does not match StageLease or DisplacedLeaf.')
            }
            $journalAppliedObject = Get-UnixContractValue $Journal applied -Required
            if (-not [bool](Get-UnixContractValue $journalAppliedObject exists -Required)) {
                throw [ArgumentException]::new('Journal publication applied state must exist.')
            }
            $journalApplied = Assert-UnixExpectedStage $journalAppliedObject
            $expectedApplied = Assert-UnixExpectedStage $ExpectedStage
            if ($journalApplied.sha256 -cne $expectedApplied.sha256 -or $journalApplied.length -ne $expectedApplied.length) {
                throw [ArgumentException]::new('Journal applied state does not match ExpectedStage.')
            }
            Assert-UnixJournalAppliedIdentity -Applied $journalAppliedObject -StageIdentity $StageLease.Observation
        }

        $permissions = Get-UnixContractValue $Journal permissions
        if ($null -eq $permissions) {
            if ($expectedOriginal.exists) { throw [ArgumentException]::new('Journal permissions must use unix-mode for an existing target.') }
            return [pscustomobject]@{ hasPermissions=$false; mode=[uint32]0; uid=[uint64]0; gid=[uint64]0 }
        }
        if ((Get-UnixContractValue $permissions kind -Required) -cne 'unix-mode') {
            throw [ArgumentException]::new('Journal permissions must use unix-mode.')
        }
        $mode = Get-UnixContractValue $permissions mode -Required
        $uid = Get-UnixContractValue $permissions uid -Required
        $gid = Get-UnixContractValue $permissions gid -Required
        if ($mode -isnot [string] -or [string]$mode -cnotmatch '^[0-7]{3,4}$') { throw [ArgumentException]::new('Journal permissions.mode is invalid.') }
        foreach ($entry in @(@{name='uid';value=$uid},@{name='gid';value=$gid})) {
            if ($entry.value -is [bool] -or $null -eq $entry.value -or [decimal]$entry.value -ne [Math]::Truncate([decimal]$entry.value) -or
                [decimal]$entry.value -lt 0 -or [decimal]$entry.value -gt [uint32]::MaxValue) {
                throw [ArgumentException]::new("Journal permissions.$($entry.name) is invalid.")
            }
        }
        return [pscustomobject]@{
            hasPermissions=$true
            mode=[Convert]::ToUInt32([string]$mode,8)
            uid=[uint64]$uid
            gid=[uint64]$gid
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] { throw }
    catch {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new(
            $(if($Remove){'owned-file-removal'}else{'publication'}),
            [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem(),
            $_.Exception.Message)
    }
}

function Get-UnixPlatformPermissionSnapshot {
    param([Parameter(Mandatory=$true)] $Lease)
    Assert-UnixPlatformHost permissions | Out-Null
    try {
        ConvertTo-UnixPermissionReceipt ([SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetPermissionSnapshot($Lease))
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] { throw $_.Exception }
}

function Set-UnixPlatformPermissions {
    param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot)
    Assert-UnixPlatformHost permissions | Out-Null
    try {
        if (($null -eq $Policy) -eq ($null -eq $Snapshot)) { throw [ArgumentException]::new('Specify exactly one of Policy or Snapshot.') }
        if ($null -ne $Snapshot) {
            if ((Get-UnixContractValue $Snapshot kind -Required) -cne 'unix-mode') { throw [ArgumentException]::new('Snapshot.kind must be unix-mode.') }
            $mode = [string](Get-UnixContractValue $Snapshot mode -Required)
            $uid = Get-UnixContractValue $Snapshot uid -Required
            $gid = Get-UnixContractValue $Snapshot gid -Required
        }
        else {
            if ($Policy -isnot [Collections.IDictionary] -or $Policy.Count -ne 1 -or -not $Policy.Contains('Mode')) {
                throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('permissions-policy: only Mode is supported',[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem())
            }
            if ($Policy.Mode -is [string] -or $Policy.Mode -is [bool] -or $null -eq $Policy.Mode -or [decimal]$Policy.Mode -ne [Math]::Truncate([decimal]$Policy.Mode) -or [decimal]$Policy.Mode -lt 0 -or [decimal]$Policy.Mode -gt 4095) { throw [ArgumentException]::new('Mode must be an integer from 0 through 4095.') }
            $current = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetPermissionSnapshot($Lease)
            $mode = [Convert]::ToString([int]$Policy.Mode,8).PadLeft($(if ([int]$Policy.Mode -gt 511) { 4 } else { 3 }),'0')
            $uid = $current.Uid; $gid = $current.Gid
        }
        if ($mode -cnotmatch '^[0-7]{3,4}$') { throw [ArgumentException]::new('Snapshot.mode must contain three or four octal digits.') }
        foreach ($value in @($uid,$gid)) { if ($value -is [bool] -or $null -eq $value -or [decimal]$value -ne [Math]::Truncate([decimal]$value) -or [decimal]$value -lt 0 -or [decimal]$value -gt [uint32]::MaxValue) { throw [ArgumentException]::new('Snapshot uid/gid is invalid.') } }
        ConvertTo-UnixPermissionReceipt ([SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::SetPermissionSnapshot($Lease,$mode,[uint64]$uid,[uint64]$gid))
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException] { throw $_.Exception }
}

function Publish-UnixPlatformFile {
    param(
        [Parameter(Mandatory=$true)] $ParentLease,[Parameter(Mandatory=$true)][string] $Leaf,
        [Parameter(Mandatory=$true)] $TransactionLease,[Parameter(Mandatory=$true)] $StageLease,
        [Parameter(Mandatory=$true)] $ExpectedState,[AllowNull()] $DisplacedLeaf,
        [Parameter(Mandatory=$true)] $ExpectedStage,[switch] $NoReplace,
        $Journal
    )
    Assert-UnixPlatformHost publication | Out-Null
    try {
        $DisplacedLeaf = ConvertTo-UnixOptionalLeaf $DisplacedLeaf
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
        $journalStore=[StringComparer]::OrdinalIgnoreCase.Equals($Leaf,'journal.json') -and [object]::ReferenceEquals($ParentLease,$TransactionLease)
        if($journalStore -and $PSBoundParameters.ContainsKey('Journal')){throw [ArgumentException]::new('Journal store publication must not supply Journal.')}
        [void](Assert-UnixPlatformTargetPath $ParentLease $Leaf publication -AllowTransactionParent:$journalStore)
        $expected = Assert-UnixExpectedState $ExpectedState ExpectedState -AllowAbsent
        if ($expected.exists -ne ($null -ne $DisplacedLeaf)) {
            throw [ArgumentException]::new('DisplacedLeaf must be supplied exactly when ExpectedState.exists is true.')
        }
        if ($null -ne $DisplacedLeaf) { [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($DisplacedLeaf) }
        if ($NoReplace -and $expected.exists) {
            throw [ArgumentException]::new('NoReplace requires ExpectedState.exists=false and relies on the native rename to reject a raced destination.')
        }
        $stage = Assert-UnixExpectedStage $ExpectedStage
        if($journalStore -and (-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$StageLease.Name,'journal.stage') -or
            ($expected.exists -and -not [StringComparer]::OrdinalIgnoreCase.Equals($DisplacedLeaf,'journal.prev')))){
            throw [ArgumentException]::new('Journal store publication requires journal.stage and uses journal.prev when replacing journal.json.')
        }
        $journalBinding = Assert-UnixJournalBinding $Journal $ParentLease $TransactionLease $Leaf $StageLease $DisplacedLeaf $ExpectedState $ExpectedStage
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException] { throw $_.Exception }
    catch { throw (New-UnixPlatformVerificationError publication $_.Exception.Message) }
    try {
        $nativeExpectedSha256 = ConvertTo-UnixNativeNullableString $expected.sha256
        $nativeDisplacedLeaf = ConvertTo-UnixNativeNullableString $DisplacedLeaf
        $result = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::Publish(
            $ParentLease,$Leaf,$TransactionLease,$StageLease,$expected.exists,$expected.device,$expected.inode,$nativeExpectedSha256,$expected.length,
            $nativeDisplacedLeaf,$stage.sha256,$stage.length,[bool]$NoReplace,[uint32]384,
            [bool]$journalBinding.hasPermissions,[uint32]$journalBinding.mode,[uint64]$journalBinding.uid,[uint64]$journalBinding.gid)
        [pscustomobject][ordered]@{
            completedSteps=[string[]]@($result.CompletedSteps)
            appliedIdentity=ConvertTo-UnixPlatformIdentity $result.AppliedIdentity
            displacedIdentity=ConvertTo-UnixPlatformIdentity $result.DisplacedIdentity
            permissions=ConvertTo-UnixPermissionReceipt $result.Permissions
            displacedLeaf=$result.DisplacedLeaf
            durability=[string]$result.Flush.Durability
            flush=ConvertTo-UnixFlushReceipt $result.Flush
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] {
        if ([string]$_.Exception.Capability -ceq 'publication') { throw $_.Exception }
        throw (New-UnixPlatformVerificationError publication $_.Exception.Message)
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException] {
        $native = $_.Exception
        $translated = if ($null -eq $native.Receipt) { $null } else { [pscustomobject][ordered]@{
            completedSteps=[string[]]@($native.Receipt.CompletedSteps)
            appliedIdentity=ConvertTo-UnixPlatformIdentity $native.Receipt.AppliedIdentity
            displacedIdentity=ConvertTo-UnixPlatformIdentity $native.Receipt.DisplacedIdentity
            permissions=if($null -eq $native.Receipt.Permissions){$null}else{ConvertTo-UnixPermissionReceipt $native.Receipt.Permissions}
            displacedLeaf=$native.Receipt.DisplacedLeaf
            durability=[string]$native.Receipt.Flush.Durability
            flush=ConvertTo-UnixFlushReceipt $native.Receipt.Flush
        } }
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException]::new($native.Capability,$native.Platform,$native.CurrentState,$native.Message,$translated)
    }
}

function Remove-UnixPlatformOwnedFile {
    param(
        [Parameter(Mandatory=$true)] $ParentLease,[Parameter(Mandatory=$true)][string] $Leaf,
        [Parameter(Mandatory=$true)] $ExpectedState,$TransactionLease,
        [AllowNull()] $TombstoneLeaf,$Journal
    )
    Assert-UnixPlatformHost owned-file-removal | Out-Null
    try {
        $TombstoneLeaf = ConvertTo-UnixOptionalLeaf $TombstoneLeaf
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
        $tombstone=($null -ne $TransactionLease -and $null -ne $TombstoneLeaf)
        if (($null -ne $TransactionLease) -ne ($null -ne $TombstoneLeaf)) {
            throw [ArgumentException]::new('TransactionLease and TombstoneLeaf must be supplied together.')
        }
        if (-not $tombstone -and $PSBoundParameters.ContainsKey('Journal')) {
            throw [ArgumentException]::new('Journal is forbidden in cleanup mode.')
        }
        if ($tombstone) {
            [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($TombstoneLeaf)
            [void](Assert-UnixPlatformTargetPath $ParentLease $Leaf owned-file-removal)
            if ([uint64]$ParentLease.Observation.Device -eq [uint64]$TransactionLease.Observation.Device -and
                [uint64]$ParentLease.Observation.Inode -eq [uint64]$TransactionLease.Observation.Inode) {
                throw [ArgumentException]::new('Tombstone mode requires a target parent outside TransactionLease; omit TransactionLease and TombstoneLeaf for cleanup mode.')
            }
        }
        $expected = Assert-UnixExpectedState $ExpectedState ExpectedState
        if ($tombstone) {
            $journalBinding = Assert-UnixJournalBinding $Journal $ParentLease $TransactionLease $Leaf $null $TombstoneLeaf $ExpectedState $null -Remove
        }
        else {
            $TransactionLease=$ParentLease
            $TombstoneLeaf=$Leaf
            $journalBinding=[pscustomobject]@{hasPermissions=$false;mode=[uint32]0;uid=[uint64]0;gid=[uint64]0}
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException] { throw $_.Exception }
    catch { throw (New-UnixPlatformVerificationError owned-file-removal $_.Exception.Message) }
    try {
        $result = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::Remove(
            $ParentLease,$Leaf,$TransactionLease,$TombstoneLeaf,$expected.device,$expected.inode,$expected.sha256,$expected.length,
            [bool]$journalBinding.hasPermissions,[uint32]$journalBinding.mode,[uint64]$journalBinding.uid,[uint64]$journalBinding.gid)
        [pscustomobject][ordered]@{
            completedSteps=[string[]]@($result.CompletedSteps)
            appliedIdentity=$null
            displacedIdentity=ConvertTo-UnixPlatformIdentity $result.BackupIdentity
            backupIdentity=ConvertTo-UnixPlatformIdentity $result.BackupIdentity
            permissions=ConvertTo-UnixPermissionReceipt $result.Permissions
            tombstoneLeaf=[string]$result.TombstoneLeaf
            method=[string]$result.Method
            deleted=if($tombstone){$null}else{$true}
            durability=[string]$result.Flush.Durability
            flush=ConvertTo-UnixFlushReceipt $result.Flush -Cleanup:(-not $tombstone)
        }
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException] {
        if ([string]$_.Exception.Capability -ceq 'owned-file-removal') { throw $_.Exception }
        throw (New-UnixPlatformVerificationError owned-file-removal $_.Exception.Message)
    }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformErrnoException] { throw $_.Exception }
    catch [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException] {
        $native = $_.Exception
        $translated = if ($null -eq $native.Receipt) { $null } else { [pscustomobject][ordered]@{
            completedSteps=[string[]]@($native.Receipt.CompletedSteps)
            appliedIdentity=$null
            displacedIdentity=ConvertTo-UnixPlatformIdentity $native.Receipt.BackupIdentity
            backupIdentity=ConvertTo-UnixPlatformIdentity $native.Receipt.BackupIdentity
            permissions=if($null -eq $native.Receipt.Permissions){$null}else{ConvertTo-UnixPermissionReceipt $native.Receipt.Permissions}
            tombstoneLeaf=$native.Receipt.TombstoneLeaf
            method=$native.Receipt.Method
            deleted=if($tombstone){$null}else{$true}
            durability=[string]$native.Receipt.Flush.Durability
            flush=ConvertTo-UnixFlushReceipt $native.Receipt.Flush -Cleanup:(-not $tombstone)
        } }
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformMutationException]::new($native.Capability,$native.Platform,$native.CurrentState,$native.Message,$translated)
    }
}

Export-ModuleMember -Function Set-UnixPlatformPermissions,Get-UnixPlatformPermissionSnapshot,Publish-UnixPlatformFile,Remove-UnixPlatformOwnedFile
