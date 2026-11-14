# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-WindowsDaclEquivalent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $FirstSddl,
        [Parameter(Mandatory = $true)][string] $SecondSddl
    )

    function Get-ComparableDacl {
        param([Parameter(Mandatory = $true)][string] $Sddl)

        if ([string]::IsNullOrEmpty($Sddl) -or -not $Sddl.StartsWith('D:',[StringComparison]::Ordinal) -or
            $Sddl.IndexOf('O:',[StringComparison]::Ordinal) -ge 0 -or
            $Sddl.IndexOf('G:',[StringComparison]::Ordinal) -ge 0 -or
            $Sddl.IndexOf('S:',[StringComparison]::Ordinal) -ge 0) {
            throw [ArgumentException]::new('Only a DACL-only SDDL policy is supported.','Sddl')
        }

        $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
        if ($null -eq $descriptor.DiscretionaryAcl) {
            throw [ArgumentException]::new('An explicit non-null DACL is required.','Sddl')
        }

        $genericRead = [Convert]::ToUInt32('80000000',16)
        $genericWrite = [Convert]::ToUInt32('40000000',16)
        $genericExecute = [Convert]::ToUInt32('20000000',16)
        $genericAll = [Convert]::ToUInt32('10000000',16)
        $specificRights = [Convert]::ToUInt32('0fffffff',16)
        $fileGenericRead = [Convert]::ToUInt32('00120089',16)
        $fileGenericWrite = [Convert]::ToUInt32('00120116',16)
        $fileGenericExecute = [Convert]::ToUInt32('001200a0',16)
        $fileAllAccess = [Convert]::ToUInt32('001f01ff',16)
        $aces = [Collections.Generic.List[string]]::new()
        foreach ($ace in $descriptor.DiscretionaryAcl) {
            if ($ace -isnot [Security.AccessControl.KnownAce] -or $ace.BinaryLength -lt 8) {
                throw [ArgumentException]::new("Unsupported DACL ACE type '$($ace.AceType)'.",'Sddl')
            }
            [byte[]]$binary = New-Object byte[] $ace.BinaryLength
            $ace.GetBinaryForm($binary,0)
            [uint32]$mask = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ace.AccessMask),0)
            if (($mask -band $genericRead) -ne 0) { $mask = [uint32]($mask -bor $fileGenericRead) }
            if (($mask -band $genericWrite) -ne 0) { $mask = [uint32]($mask -bor $fileGenericWrite) }
            if (($mask -band $genericExecute) -ne 0) { $mask = [uint32]($mask -bor $fileGenericExecute) }
            if (($mask -band $genericAll) -ne 0) { $mask = [uint32]($mask -bor $fileAllAccess) }
            [byte[]]$normalizedMask = [BitConverter]::GetBytes([uint32]($mask -band $specificRights))
            [Array]::Copy($normalizedMask,0,$binary,4,$normalizedMask.Length)
            $aces.Add([Convert]::ToBase64String($binary))
        }
        return [pscustomobject][ordered]@{
            protected = ($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
            aces = $aces.ToArray()
        }
    }

    try {
        $first = Get-ComparableDacl -Sddl $FirstSddl
        $second = Get-ComparableDacl -Sddl $SecondSddl
        if ([bool]$first.protected -ne [bool]$second.protected -or $first.aces.Count -ne $second.aces.Count) { return $false }
        for ($index = 0; $index -lt $first.aces.Count; $index++) {
            if ([string]$first.aces[$index] -cne [string]$second.aces[$index]) {
                return $false
            }
        }
        return $true
    }
    catch { return $false }
}

Export-ModuleMember -Function 'Test-WindowsDaclEquivalent'
