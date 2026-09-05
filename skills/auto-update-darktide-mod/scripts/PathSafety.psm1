# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PortableReparseItem {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][object] $Item,
        [string] $Label = 'path'
    )

    $inspectProviderItem = {
        param([AllowNull()][object] $Candidate)
        if ($null -eq $Candidate) { return $false }
        try {
            $attributesProperty = $Candidate.PSObject.Properties['Attributes']
            if ($null -ne $attributesProperty -and
                (($attributesProperty.Value -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                return $true
            }
            $modeProperty = $Candidate.PSObject.Properties['Mode']
            if ($null -ne $modeProperty -and [string]$modeProperty.Value -match '^l') {
                return $true
            }
            foreach ($propertyName in @('LinkType', 'LinkTarget', 'Target')) {
                $property = $Candidate.PSObject.Properties[$propertyName]
                if ($null -eq $property) { continue }
                if ($propertyName -eq 'LinkType') {
                    if (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $true }
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    return $true
                }
            }
        }
        catch {
            throw "Unable to inspect $Label reparse metadata: $($_.Exception.Message)"
        }
        $false
    }

    if (& $inspectProviderItem $Item) { return $true }

    # FileInfo/DirectoryInfo.LinkTarget reads the directory entry itself and does
    # not follow a symlink. Walk lexical ancestors so a missing child below a
    # symlink is still rejected before it can be treated as ordinary absence.
    $probe = [IO.Path]::GetFullPath($Path)
    for ($depth = 0; $depth -lt 2048; $depth++) {
        foreach ($info in @([IO.FileInfo]::new($probe), [IO.DirectoryInfo]::new($probe))) {
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$info.LinkTarget)) { return $true }
                if ($info.Exists -and (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $true }
            }
            catch [IO.FileNotFoundException] { }
            catch [IO.DirectoryNotFoundException] { }
            catch {
                throw "Unable to inspect $Label physical containment component: $($_.Exception.Message)"
            }
        }

        $parent = [IO.DirectoryInfo]::new($probe).Parent
        if ($null -eq $parent -or $parent.FullName.Equals($probe, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $probe = $parent.FullName
    }
    $false
}

Export-ModuleMember -Function Test-PortableReparseItem
