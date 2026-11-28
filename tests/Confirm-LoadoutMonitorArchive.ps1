# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
# Offline replay of Nexus 160 Main 8444, as recorded by Mods #388.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $ArchivePath, [string] $ModDirectory = 'LoadoutMonitor')

$ErrorActionPreference = 'Stop'
$scripts = Join-Path $PSScriptRoot '../skills/auto-update-darktide-mod/scripts'
Import-Module (Join-Path $scripts 'PathSafety.psm1') -Force
. (Join-Path $scripts 'DesktopArchive.ps1')
$file = Get-Item -LiteralPath $ArchivePath
$name = 'LoadoutMonitor 160 1.9.6 2026-09-24T19-20Z OIXCuIsQu.rar'
$sha = '4d1cc042c3baf8295a85162a7b692386e3ebc45313ec8297e85f178e28133cc7'
if ($file.Name -cne $name -or $file.Length -ne 26130 -or (Get-FileHash -LiteralPath $file.FullName).Hash -ne $sha) {
    throw 'Expected the original Loadout Monitor 1.9.6 filename, 26130 bytes, and Mods #388 SHA-256.'
}
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$run = Join-Path $temp ('loadout-rar-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $run
try {
    $incoming = (New-Item -ItemType Directory -Path (Join-Path $run '.incoming-replay')).FullName
    $copy = Join-Path $incoming $name
    Copy-Item -LiteralPath $file.FullName -Destination $copy
    $request = Join-Path $run 'source-request.json'
    $receipt = Join-Path $run 'source-receipt.json'
    @{schemaVersion=1; gameDomain='warhammer40kdarktide'; modId=160; mainFileId=8444; version='1.9.6'
      fileName=$name; pageUrl='https://www.nexusmods.com/warhammer40kdarktide/mods/160'; officialSha256=$sha} |
        ConvertTo-Json | Set-Content -LiteralPath $request
    $received = & (Join-Path $scripts 'Receive-NexusMainFile.ps1') -SourceRequestPath $request -ReceiptPath $receipt `
        -IncomingDirectory $incoming -DeliveryDirectory (Join-Path $run 'verified-source') -Provider browser `
        -DownloadedFilePath $copy -PassThru
    if ($received.status -cne 'delivered') { throw "Intake stopped: $($received.waitingReason.code)" }
    $verified = & (Join-Path $scripts 'Test-SourceReceipt.ps1') -SourceRequestPath $request -ReceiptPath $receipt -PassThru
    if ($verified.result -cne 'passed') { throw 'Source receipt failed independent verification.' }
    $reader = Open-DesktopArchive $received.deliveredPath $sha rar
    try {
        Assert-DesktopArchiveRoot $reader.entries $ModDirectory
        $stage = (New-Item -ItemType Directory -Path (Join-Path $run 'extracted')).FullName
        $hashes = @{}
        Read-DesktopArchiveData $reader $stage -Hashes $hashes
        Assert-DesktopExtractionTree $reader.entries $stage $hashes
        [pscustomobject]@{result='passed'; modId=160; mainFileId=8444; format='rar'; filename=$name
            sha256=$sha; size=$file.Length; entries=$reader.entries.Count; verifiedFiles=$hashes.Count}
    } finally { Close-DesktopArchive $reader }
} finally {
    $owned = Resolve-PortableContainedPath -Root $temp -Path $run
    if ([IO.Path]::GetDirectoryName($owned) -ne [IO.Path]::TrimEndingDirectorySeparator($temp) -or
        [IO.Path]::GetFileName($owned) -notmatch '^loadout-rar-[0-9a-f]{32}$' -or
        (Test-PortableReparseItem -Path $owned -TrustedRoot $temp)) { throw 'Cannot verify the owned replay directory for cleanup.' }
    Remove-Item -LiteralPath $owned -Recurse -Force
}
