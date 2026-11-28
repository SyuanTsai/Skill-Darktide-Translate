# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
function Get-DesktopArchiveSignature {
    param([byte[]] $Bytes, [int] $Count, [switch] $LegacyUnsupportedRar)
    $hex = [Convert]::ToHexString($Bytes, 0, $Count)
    if ($hex -match '^(504B0304|504B0506|504B0708)') { return 'zip' }
    if ($hex -match '^526172211A07(00|0100)') { return 'rar' }
    # Original ZIP-only receipts classified RAR5 from seven prefix bytes.
    # Use that classification solely to replay an already-undelivered artifact.
    if ($LegacyUnsupportedRar -and $hex.StartsWith('526172211A0701')) { return 'rar' }
    if ($hex.StartsWith('377ABCAF271C')) { return '7z' }
    'unknown'
}

function Get-DesktopArchiveEvidenceFromStream {
    param([IO.Stream] $Stream, [scriptblock] $Heartbeat, [switch] $LegacyUnsupportedRar)
    if (!$Stream.CanSeek) { throw 'Archive evidence requires a seekable source stream.' }
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
    try {
        $buffer = [byte[]]::new(1MB)
        $Stream.Position = 0
        $count = $Stream.Read($buffer,0,8)
        $format = Get-DesktopArchiveSignature $buffer $count -LegacyUnsupportedRar:$LegacyUnsupportedRar
        $Stream.Position = 0
        while (($count = $Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer,0,$count)
            if ($Heartbeat) { & $Heartbeat }
        }
        $evidence = @{size=$Stream.Length; archiveFormat=$format
            sha256=[Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()}
        $Stream.Position = 0
        $evidence
    } finally { $hasher.Dispose() }
}

function Get-DesktopArchiveEvidence {
    param([string] $Path, [scriptblock] $Heartbeat, [switch] $LegacyUnsupportedRar)
    $stream = [IO.File]::Open($Path,'Open','Read','Read')
    try { Get-DesktopArchiveEvidenceFromStream -Stream $stream -Heartbeat $Heartbeat -LegacyUnsupportedRar:$LegacyUnsupportedRar }
    finally { $stream.Dispose() }
}

function Open-DesktopArchiveSource {
    param([string] $Path, [scriptblock] $Heartbeat, [switch] $LegacyUnsupportedRar)
    $stream = [IO.File]::Open($Path,'Open','Read','Read')
    try {
        $source = @{evidence=(Get-DesktopArchiveEvidenceFromStream -Stream $stream -Heartbeat $Heartbeat -LegacyUnsupportedRar:$LegacyUnsupportedRar); stream=$stream}
        $stream = $null
        $source
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Close-DesktopArchiveSource {
    param($Source)
    if ($Source -and $Source.stream) { $Source.stream.Dispose() }
}

function Assert-DesktopArchiveManifest {
    param([object[]] $Entries)
    if ($Entries.Count -gt 100000) { throw 'Archive entry count exceeds the 100,000 entry limit.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directories = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::OrdinalIgnoreCase)
    $total = 0L
    foreach ($entry in $Entries) {
        foreach ($field in @('path','size','compressedSize','externalAttributes','directory')) {
            if (!$entry.Contains($field) -or $null -eq $entry[$field]) { throw "Archive manifest is missing $field." }
        }
        $path = [string]$entry.path
        $dir = $entry.directory
        if ($dir -isnot [bool] -or $dir -ne $path.EndsWith('/')) { throw "Invalid archive entry type: $path" }
        $name = if ($dir) { $path.Substring(0, $path.Length - 1) } else { $path }
        $prefix = ''
        if ($name.Length -gt 4096) { throw 'Archive path exceeds the supported path length.' }
        $parts = $name.Split('/')
        for ($i = 0; $i -lt $parts.Length; $i++) {
            $part = $parts[$i]
            if ($part.Length -gt 255) { throw "Archive component exceeds portable name limits: $part" }
            if ($part -eq '..') { throw "Archive path traversal rejected: $path" }
            if (!$part -or $part -match '[\x00-\x1f<>:"|?*\\]|[. ]$') { throw "Unsafe archive path component: $path" }
            if ($part -match '^(?i:con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
                throw "Archive path uses a reserved Windows device name: $path"
            }
            $prefix = if ($i) { "$prefix/$part" } else { $part }
            $key = $prefix.Normalize([Text.NormalizationForm]::FormC)
            $isDirectory = $i -lt $parts.Length - 1 -or $dir
            if ($names.ContainsKey($key)) {
                if ($directories[$key] -ne $isDirectory) { throw "File/ancestor archive path collision rejected: $prefix" }
                if (!$names[$key].Equals($prefix,[StringComparison]::Ordinal)) { throw "Unicode/case-colliding archive path rejected: $prefix" }
            } else {
                $names.Add($key, $prefix)
                $directories.Add($key, $isDirectory)
            }
        }
        if (!$seen.Add($key)) { throw "Duplicate archive path rejected: $name" }
        $attr = [long]$entry.externalAttributes
        $type = ($attr -shr 16) -band 0xf000
        if ($type -eq 0xa000) { throw "Archive symlink rejected: $path" }
        if ($attr -band 0x400) { throw "Archive reparse point rejected: $path" }
        if (($attr -band 0x48) -or $type -notin @(0,0x4000,0x8000) -or
            ($type -eq 0x4000 -and !$dir) -or ($type -eq 0x8000 -and $dir) -or (($attr -band 16) -and !$dir)) {
            throw "Archive special entry type rejected: $path"
        }
        $size = [long]$entry.size
        $packed = [long]$entry.compressedSize
        if ($size -lt 0 -or $packed -lt 0 -or $size -gt 1GB -or ($dir -and $size) -or
            ($size -gt 0 -and (!$packed -or $size / $packed -gt 1000))) { throw "Archive expansion limit rejected: $path" }
        $total += $size
        if ($total -gt 4GB) { throw 'Archive exceeds 4 GiB total size limit.' }
    }
}

function Assert-DesktopArchiveRoot {
    param([object[]] $Entries, [string] $ModDirectory)
    $files = 0
    foreach ($entry in $Entries) {
        if ($entry.directory) { continue }
        $parts = $entry.path.Split('/',2)
        if ($parts.Length -ne 2 -or !$parts[0].Equals($ModDirectory,[StringComparison]::Ordinal)) {
            throw 'Invalid archive root; files must belong to the canonical MOD directory.'
        }
        $files++
    }
    if (!$files) { throw 'Archive contains no files.' }
}

function Get-StateArchiveFormat {
    param($Archive)
    $extension = [IO.Path]::GetExtension($Archive.path).TrimStart('.').ToLowerInvariant()
    $format = if ($Archive.Contains('format')) { $Archive.format } else { 'zip' }
    if ($format -cnotin @('zip','rar') -or $format -cne $extension) { throw 'Claimed archive filename and format disagree.' }
    $format
}

function Assert-DesktopExtractionTree {
    param([object[]] $Entries, [string] $Root, $Hashes)
    $expected = [Collections.Generic.Dictionary[string,long]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Entries) {
        $path = $entry.path.TrimEnd('/')
        $expected[$path] = if ($entry.directory) { -1 } else { $entry.size }
        while ($path.Contains('/')) {
            $path = $path.Substring(0,$path.LastIndexOf('/'))
            $expected[$path] = -1
        }
    }
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        $relative = [IO.Path]::GetRelativePath($Root,$item.FullName).Replace('\','/')
        $size = if ($item.PSIsContainer) { -1 } else { $item.Length }
        if (Test-PortableReparseItem -Path $item.FullName -Item $item -TrustedRoot $Root -Label 'Extraction tree') { throw "Extracted link rejected: $relative" }
        if (!$expected.ContainsKey($relative) -or $size -ne $expected[$relative]) { throw "Unexpected extracted entry: $relative" }
        if ($Hashes -and !$item.PSIsContainer -and (Get-FileHash -LiteralPath $item.FullName).Hash -ne $Hashes[$relative]) {
            throw "Extracted bytes differ from archive: $relative"
        }
        [void]$expected.Remove($relative)
    }
    if ($expected.Count) { throw 'Extracted tree is missing archive entries.' }
}

function Close-DesktopArchive {
    param($Reader)
    try {
        if ($Reader.process) {
            $Reader.process.StandardInput.Close()
            if (!$Reader.process.HasExited) { $Reader.process.Kill() }
            $Reader.process.WaitForExit()
        }
    } finally {
        if ($Reader.process) { $Reader.process.Dispose() }
        if ($Reader.archive) { $Reader.archive.Dispose() }
        if ($Reader.source) { Close-DesktopArchiveSource $Reader.source }
        elseif ($Reader.stream) { $Reader.stream.Dispose() }
    }
}

function Wait-DesktopDecoderRead {
    param([Threading.Tasks.Task] $Task, [scriptblock] $Heartbeat)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (!$Task.Wait(1000)) {
        if ($Heartbeat) { & $Heartbeat }
        if ($clock.Elapsed.TotalMinutes -ge 2) { throw 'RAR decoder made no progress for two minutes.' }
    }
    $Task.GetAwaiter().GetResult()
}

function Open-DesktopArchive {
    param([string] $Path, [string] $ExpectedSha256, [string] $Format, [scriptblock] $Heartbeat)
    $source = Open-DesktopArchiveSource $Path $Heartbeat
    $evidence = $source.evidence
    $reader = @{archive=$null; process=$null; entries=@(); format=$Format; source=$source; stream=$source.stream}
    try {
        if ($evidence.archiveFormat -cne $Format -or $Format -cnotin @('zip','rar')) {
            throw 'Archive format differs from recorded evidence.'
        }
        if ($evidence.sha256 -cne $ExpectedSha256) {
            throw "Claimed archive SHA-256 changed before $($Format.ToUpperInvariant()) processing."
        }
        if ($Format -ceq 'rar') {
            $python = Get-Command -CommandType Application -Name $(if ($IsWindows) { 'python.exe' } else { 'python3' }) -ErrorAction Stop | Select-Object -First 1
            $info = [Diagnostics.ProcessStartInfo]::new($python.Source)
            $info.UseShellExecute = $false
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($arg in @('-I', '-B', (Join-Path $PSScriptRoot 'rar_reader.py'), $Path, $ExpectedSha256)) { $info.ArgumentList.Add($arg) }
            $reader.process = [Diagnostics.Process]::Start($info)
            $reader.errors = $reader.process.StandardError.ReadToEndAsync()
            $line = Wait-DesktopDecoderRead ($reader.process.StandardOutput.ReadLineAsync()) $Heartbeat
            if (!$line) { throw "RAR manifest unavailable. $(Wait-DesktopDecoderRead $reader.errors $Heartbeat)" }
            if (!$line.StartsWith('[') -or !$line.EndsWith(']')) { throw 'RAR helper returned an invalid manifest.' }
            $reader.entries = @(Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $line -AsHashtable)
            if (!$reader.entries.Count) { throw 'RAR contains no entries.' }
        } else {
            $reader.archive = [IO.Compression.ZipArchive]::new($reader.stream, 'Read', $true)
            if ($reader.archive.Entries.Count -gt 100000) { throw 'Archive entry count exceeds the 100,000 entry limit.' }
            $reader.entries = @(foreach ($item in $reader.archive.Entries) {
                $pathName = $item.FullName.Replace('\','/')
                [ordered]@{path=$pathName; size=$item.Length; compressedSize=$item.CompressedLength
                    externalAttributes=$item.ExternalAttributes; directory=$pathName.EndsWith('/')}
            })
        }
        Assert-DesktopArchiveManifest $reader.entries
        return $reader
    } catch {
        Close-DesktopArchive $reader
        throw
    }
}

function Read-DesktopArchiveData {
    param($Reader, [string] $DestinationRoot, [scriptblock] $Heartbeat, $Hashes)
    $rar = $Reader.format -ceq 'rar'
    if ($rar) {
        $Reader.process.StandardInput.WriteLine('stream')
    }
    if (!$rar -and !('DarktideArchiveCrc' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'DarktideArchiveCrc.cs')
    }
    $buffer = [byte[]]::new(1MB)
    for ($i = 0; $i -lt $Reader.entries.Count; $i++) {
        $entry = $Reader.entries[$i]
        $destination = $null
        if ($DestinationRoot) {
            $destination = Resolve-PortableContainedPath -Path $entry.path -Root $DestinationRoot
            if (Test-PortableReparseItem -Path $destination -TrustedRoot $DestinationRoot -Label 'Archive entry') {
                throw "Archive destination contains a link: $destination"
            }
            if ($entry.directory) { [void][IO.Directory]::CreateDirectory($destination) }
            else { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) }
        }
        if ($entry.directory -and $rar) { continue }
        $source = if ($rar) { $Reader.process.StandardOutput.BaseStream } else { $Reader.archive.Entries[$i].Open() }
        $digest = [Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
        try {
            $output = if ($destination -and !$entry.directory) {
                [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            } else { [IO.Stream]::Null }
            try {
                $crc = [uint32]::MaxValue
                $remaining = [long]$entry.size
                while ($remaining -gt 0) {
                    $capacity = [int][Math]::Min($remaining,$buffer.Length)
                    $n = if ($rar) { Wait-DesktopDecoderRead ($source.ReadAsync($buffer,0,$capacity)) $Heartbeat }
                         else { $source.Read($buffer,0,$capacity) }
                    if (!$n) { throw "Archive entry shorter than declared: $($entry.path)" }
                    $output.Write($buffer,0,$n)
                    if ($null -ne $Hashes) { $digest.AppendData($buffer,0,$n) }
                    if (!$rar) { $crc = [DarktideArchiveCrc]::Append($crc,$buffer,$n) }
                    $remaining -= $n
                    if ($Heartbeat) { & $Heartbeat }
                }
                if (!$rar -and $source.ReadByte() -ne -1) { throw "Archive entry longer than declared: $($entry.path)" }
                if (!$rar -and ([uint32]::MaxValue -bxor $crc) -ne $Reader.archive.Entries[$i].Crc32) { throw "Archive CRC mismatch: $($entry.path)" }
                if ($null -ne $Hashes -and !$entry.directory) { $Hashes[$entry.path] = [Convert]::ToHexString($digest.GetHashAndReset()) }
            } finally { $output.Dispose() }
        } finally { $digest.Dispose(); if (!$rar) { $source.Dispose() } }
    }
    if ($rar) {
        if ((Wait-DesktopDecoderRead ($Reader.process.StandardOutput.BaseStream.ReadAsync($buffer,0,1)) $Heartbeat) -ne 0) { throw 'RAR helper produced unexpected trailing bytes.' }
        if (!$Reader.process.WaitForExit(5000)) { throw 'RAR helper failed to exit after the last entry.' }
        if ($Reader.process.ExitCode) { throw "RAR integrity check failed. $($Reader.errors.GetAwaiter().GetResult())" }
    }
}

function Test-DesktopRarData {
    param([string] $Path, [string] $Sha256, [scriptblock] $Heartbeat)
    $reader = Open-DesktopArchive $Path $Sha256 rar $Heartbeat
    try { Read-DesktopArchiveData $reader -Heartbeat $Heartbeat } finally { Close-DesktopArchive $reader }
}

function Get-VerifiedExtractionEvidence {
    param($State, [scriptblock] $Heartbeat)
    $path = Assert-NoReparsePath -Path $State.archive.path -Root $State.runRoot -Label 'Claimed archive'
    $root = Assert-NoReparseTree -Path $State.extractionRoot -Root $State.runRoot -Label 'Extraction tree'
    $reader = Open-DesktopArchive $path $State.archive.sha256 (Get-StateArchiveFormat $State.archive) $Heartbeat
    try {
        Assert-DesktopArchiveRoot $reader.entries $State.repoModDirectory
        $hashes = @{}
        Read-DesktopArchiveData $reader -Heartbeat $Heartbeat -Hashes $hashes
        Assert-DesktopExtractionTree $reader.entries $root $hashes
        @{entries=$reader.entries; hashes=$hashes}
    } finally { Close-DesktopArchive $reader }
}
