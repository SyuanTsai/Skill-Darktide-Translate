# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Unix.psm1') -Scope Local -ErrorAction Stop
$script:RuntimePreparationModulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'RuntimePreparation.psm1'))
$loadedRuntimePreparationModules = @(Import-Module -Name $script:RuntimePreparationModulePath -PassThru -Scope Local -ErrorAction Stop)
if ($loadedRuntimePreparationModules.Count -ne 1 -or -not [StringComparer]::Ordinal.Equals([IO.Path]::GetFullPath([string]$loadedRuntimePreparationModules[0].Path),$script:RuntimePreparationModulePath)) { throw [IO.InvalidDataException]::new('The verified runtime preparation dependency did not load from its bound path.') }
$script:RuntimePreparationModule = $loadedRuntimePreparationModules[0]

function Invoke-LinuxRuntimePreparationCommand { param([string]$Name,[Collections.IDictionary]$Arguments) $command=$script:RuntimePreparationModule.ExportedCommands[$Name]; if($null -eq $command){throw [IO.InvalidDataException]::new("The verified runtime preparation dependency does not export '$Name'.")}; & $command @Arguments }

function New-LinuxPlatformNotImplementedError {
    param([Parameter(Mandatory = $true)][string] $Capability, [Parameter(Mandatory = $true)][string] $Step)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNotImplementedException]::new($Capability,'linux',$Step)
}

function Open-LinuxPlatformDirectory { param([Parameter(Mandatory = $true)][string] $Root, [string] $RelativePath, [switch] $CreatePrivate, [switch] $RootOnly) if ($RootOnly) { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectoryRoot($Root) } else { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectory($Root,$RelativePath,[bool]$CreatePrivate) } }
function Open-LinuxPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($ParentLease,$Leaf,$Access,$CreateMode) }
function Assert-LinuxPlatformFileIdentity { param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink, [switch] $VerifyPath) $observed = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::AssertIdentity($Lease,$Expected,[bool]$SingleLink); if ($VerifyPath) { [void][SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($Lease) }; return $observed }
function Enter-LinuxPlatformLock { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [ValidateSet('Shared','Exclusive')][string] $Mode, [TimeSpan] $Timeout) [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::EnterLock($ParentLease,$Leaf,$Mode,$Timeout) }
function Publish-LinuxPlatformFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $TransactionLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [AllowNull()] $DisplacedLeaf, [Parameter(Mandatory = $true)] $ExpectedStage, [switch] $NoReplace, $Journal) Publish-UnixPlatformFile @PSBoundParameters }
function Remove-LinuxPlatformOwnedFile { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $TransactionLease, [AllowNull()] $TombstoneLeaf, $Journal) Remove-UnixPlatformOwnedFile @PSBoundParameters }
function Get-LinuxPlatformDirectoryState { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf) throw (New-LinuxPlatformNotImplementedError 'directory-publication' 'P11') }
function Move-LinuxPlatformOwnedDirectory { param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $TransactionLease, [Parameter(Mandatory = $true)][string] $DestinationLeaf, [Parameter(Mandatory = $true)] $ExpectedIdentity, [Parameter(Mandatory = $true)][ValidateSet('ToTransaction','FromTransaction')][string] $Direction, $ExpectedState, $Journal) throw (New-LinuxPlatformNotImplementedError 'directory-publication' 'P11') }
function Remove-LinuxPlatformOwnedDirectoryTree { [CmdletBinding(DefaultParameterSetName='TransactionRoot')] param([Parameter(Mandatory = $true,ParameterSetName='TransactionRoot')] $TransactionRootLease, [Parameter(Mandatory = $true,ParameterSetName='Transaction')] $TransactionLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedIdentity) throw (New-LinuxPlatformNotImplementedError 'owned-file-removal' 'P11') }
function Get-LinuxPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease) Get-UnixPlatformPermissionSnapshot -Lease $Lease }
function Set-LinuxPlatformPermissions { param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) Set-UnixPlatformPermissions @PSBoundParameters }
function Resolve-LinuxPlatformPowerShell { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, [Parameter(Mandatory = $true)] $OfflineCache, $ReleaseMetadata) Invoke-LinuxRuntimePreparationCommand 'Resolve-VerifiedPlatformPowerShell' @{ Policy=$Policy; DestinationLease=$DestinationLease; OfflineCache=$OfflineCache; ReleaseMetadata=$ReleaseMetadata; Platform='linux' } }
function Initialize-LinuxPlatformPester { param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) Invoke-LinuxRuntimePreparationCommand 'Initialize-VerifiedPlatformPester' @{ Policy=$Policy; RuntimeReceipt=$RuntimeReceipt; DestinationLease=$DestinationLease; Platform='linux'; ResolverPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Resolve-StandardValidationTool.ps1') } }

Export-ModuleMember -Function *-LinuxPlatform*
