# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Capture the bundle binding once; validator loading later hashes and parses the
# SAME private snapshot, rather than trusting an earlier pathname inventory check.
$bundle = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'platform-runtime.psd1')
$script:PesterResolverSha256 = [string](@($bundle.PrivateData.PlatformRuntime.Inventory | Where-Object Path -CEQ 'Resolve-StandardValidationTool.ps1')[0].Sha256)

function New-PlatformPreparationSession {
    return [pscustomobject]@{ Guards=[Collections.Generic.List[IDisposable]]::new(); Files=[Collections.Generic.List[object]]::new() }
}

# Resolve only caller-selected entry paths. P2 subsequently walks the physical
# path without following links; payload inventories keep their stricter rules.
function Resolve-PlatformPhysicalPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $current=[IO.Path]::GetPathRoot($full)
    foreach($part in $full.Substring($current.Length).Split([char[]]@('/','\'),[StringSplitOptions]::RemoveEmptyEntries)) {
        $item=Get-Item -Force -LiteralPath (Join-Path $current $part) -ErrorAction Stop
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $item=$item.ResolveLinkTarget($true)
            if($null -eq $item){throw 'Selected path has an unresolved link.'}
        }
        $current=$item.FullName
    }
    return $current
}

function Open-PlatformPreparationRoot {
    param([string]$Path,[string]$Platform)
    if($Platform -ceq 'windows') { return [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot($Path) }
    return [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenDirectoryRoot($Path)
}

function New-PlatformPrivateRoot {
    param([Parameter(Mandatory=$true)][string]$Parent,[Parameter(Mandatory=$true)][string]$Leaf)
    [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Leaf($Leaf)
    $platform=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
    $physical=Resolve-PlatformPhysicalPath $Parent
    $root=Open-PlatformPreparationRoot $physical $platform
    $child=$null
    try {
        $path=Join-Path $physical $Leaf
        if($platform -ceq 'windows') {
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
            try {$sddl='D:P(A;OICI;FA;;;'+$identity.User.Value+')'} finally {$identity.Dispose()}
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::CreatePrivateDirectory($path,$sddl,$true)
            $child=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationDirectory($root,$Leaf)
        } else {
            $child=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::CreatePrivateDirectory($physical,$Leaf)
        }
        return Get-VerifiedPlatformLeasePath $child $platform
    } finally {if($null -ne $child){$child.Dispose()};$root.Dispose()}
}

# Shared bounded launch for resolver acquisition, authority helpers and P4 probes.
# Environment policy belongs to each caller; the native API receives only strings.
function Invoke-PlatformPreparationCommand {
    param([Parameter(Mandatory=$true)][string]$Command,
        [AllowEmptyCollection()][string[]]$Arguments=@(),
        [Parameter(Mandatory=$true)][Collections.IDictionary]$Environment,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [ValidateRange(1,3600000)][int]$TimeoutMilliseconds=900000,
        $PreparationReceipt)
    $platform=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
    $physical=Resolve-PlatformPhysicalPath $Command
    $cwd=Resolve-PlatformPhysicalPath $WorkingDirectory
    $capture=New-PlatformPrivateRoot -Parent ([IO.Path]::GetTempPath()) -Leaf ('platform-command-'+[guid]::NewGuid().ToString('N'))
    $guards=New-PlatformPreparationSession
    $process=$null;$out=$null;$err=$null;$runtimeGuards=$null;$moduleGuards=$null
    $outPath=Join-Path $capture 'stdout';$errPath=Join-Path $capture 'stderr'
    try {
        if($null -ne $PreparationReceipt){
            if($physical -cne (Resolve-PlatformPhysicalPath $PreparationReceipt.executablePath)){throw 'Prepared runtime does not match the selected command.'}
            $runtimeGuards=Open-PlatformClosureGuards $PreparationReceipt.runtimeClosure $platform
            $moduleGuards=Open-PlatformClosureGuards $PreparationReceipt.moduleClosure $platform
            Assert-PlatformAuthorityPester $PreparationReceipt
        }
        $directory=Open-PlatformPreparationRoot $cwd $platform;$guards.Guards.Add($directory)
        $captureRoot=Open-PlatformPreparationRoot $capture $platform;$guards.Guards.Add($captureRoot)
        $parent=Open-PlatformPreparationRoot ([IO.Path]::GetDirectoryName($physical)) $platform;$guards.Guards.Add($parent)
        if($platform -ceq 'windows') {
            $exe=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($parent,[IO.Path]::GetFileName($physical),'Read','OpenExisting')
            $guards.Guards.Add($exe)
            [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::AssertIdentity($exe,$exe.Observation,$true)
            [void][SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetVerifiedPath($exe)
            $out=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($captureRoot,'stdout','Write','CreateNew')
            $err=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($captureRoot,'stderr','Write','CreateNew')
        } else {
            $exe=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($parent,[IO.Path]::GetFileName($physical),'Read','OpenExisting')
            $guards.Guards.Add($exe)
            [void][SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::AssertIdentity($exe,$exe.Observation,$true)
            [void][SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($exe)
            $out=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($captureRoot,'stdout','Write','CreateNew')
            $err=[SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($captureRoot,'stderr','Write','CreateNew')
        }
        $values=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach($key in $Environment.Keys){$values.Add([string]$key,[string]$Environment[$key])}
        $deadline=[DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        $process=[SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]::Start($null,$exe,$Arguments,$values,$directory,$deadline,'cooperative',$out,$err,1048576,[IO.Path]::GetFullPath($Command))
        $out=$null;$err=$null
        $directExitObserved=$false
        while(-not ($process.HasExited -and $process.CaptureCompletedNaturally) -and $null -eq $process.Cleanup -and [DateTimeOffset]::UtcNow -lt $deadline){
            $directExitObserved=$process.HasExited
            Start-Sleep -Milliseconds 10
        }
        $timedOut= [DateTimeOffset]::UtcNow -ge $deadline -or $process.TerminationReason -ceq 'deadline'
        $timeoutPhase=if($directExitObserved){'output'}else{'execution'}
        $reason=$process.TerminationReason
        $cleanup=$process.Stop([TimeSpan]::FromMilliseconds(100),[DateTimeOffset]::UtcNow.AddSeconds(2),$process.StartIdentity)
        $receipt=[pscustomobject]@{schemaVersion=1;commandPath=$Command;resolvedCommandPath=$physical;pid=$process.Pid;startIdentity=$process.StartIdentity;isolation=$process.Isolation;isolationCapability=$(if($platform -ceq 'windows'){'strong'}else{'cooperative'});limitations=@('same-account-adversarial-writer-out-of-scope','no-filesystem-isolation')+@($process.Limitations);cleanup=$cleanup}
        if(-not $cleanup.CleanedUp){throw ('Owned process cleanup is unconfirmed: '+$cleanup.Uncertainty)}
        if($timedOut){
            # Deadline/cleanup takes precedence over interpreting probe payloads.
            # Keep bounded stderr as well, including a child's JSON parse failure.
            $diagnostic=Get-PlatformProcessOutputSummary -Text ([IO.File]::ReadAllText($errPath))
            throw "Command exceeded the acquisition deadline ($TimeoutMilliseconds ms); $timeoutPhase deadline exceeded. stderr: $diagnostic"
        }
        if($process.OutputLimitExceeded -or $reason -notin @($null,'')){throw ('Owned command capture failed: '+$reason)}
        if($null -ne $PreparationReceipt){Assert-PlatformAuthorityPester $PreparationReceipt}
        return [pscustomobject]@{exitCode=$process.ExitCode;stdout=[IO.File]::ReadAllText($outPath);stderr=[IO.File]::ReadAllText($errPath);processOwnership=$receipt}
    } finally {
        if($null -ne $process){$process.Dispose()}
        if($null -ne $out){$out.Dispose()};if($null -ne $err){$err.Dispose()}
        Close-PlatformPreparationSession $guards
        Close-PlatformPreparationSession $moduleGuards
        Close-PlatformPreparationSession $runtimeGuards
        # Only these create-only captures can exist; a substituted/nonempty root
        # fails cleanup instead of recursively removing unknown content.
        foreach($file in @($outPath,$errPath)){if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
        [IO.Directory]::Delete($capture)
    }
}

function Close-PlatformPreparationSession {
    param($Session)
    if ($null -ne $Session) { for ($i=$Session.Guards.Count-1; $i -ge 0; $i--) { $Session.Guards[$i].Dispose() }; $Session.Guards.Clear() }
}

function Get-PlatformProtectionBoundary {
    param([string]$Platform)
    if ($Platform -ceq 'windows') { return 'deny-write-delete guards held through verification and process exit; reacquire and revalidate on reuse' }
    return 'A1: archive/payload snapshot hashes and pre-execution revalidation; same-account uncooperative writers cannot be excluded between verification and use'
}

function New-PlatformVerifiedProcessEnvironment {
    param([string]$Executable,$PesterClosure,[string]$Platform)
    $runtimeRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Executable))
    $moduleRoots=[Collections.Generic.List[string]]::new()
    $moduleRoots.Add([IO.Path]::GetFullPath((Join-Path $runtimeRoot 'Modules')))
    if($null -ne $PesterClosure){$moduleRoots.Add([IO.Path]::GetFullPath([string]$PesterClosure.rootPath))}
    $modulePath=$moduleRoots -join [IO.Path]::PathSeparator
    $values=[ordered]@{PATH=$runtimeRoot;PSModulePath=$modulePath}
    # These placeholders are filled with a fresh private directory by the launch
    # owner. Building receipt metadata must not allocate or expose a real profile.
    $profileNames=@('HOME','USERPROFILE','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_CACHE_HOME','XDG_STATE_HOME','XDG_RUNTIME_DIR','TMP','TEMP')
    foreach($name in $profileNames){$values[$name]=''}
    if($Platform -ceq 'windows') {
        $values['SystemRoot']=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        $profileNames+=@('APPDATA','LOCALAPPDATA')
        $values['APPDATA']='';$values['LOCALAPPDATA']=''
    } else {
        $profileNames+=@('TMPDIR');$values['TMPDIR']=''
        $values['LANG']=$(if($Platform -ceq 'macos'){'en_US.UTF-8'}else{'C.UTF-8'})
    }
    return [pscustomobject]@{Values=$values;Names=@($values.Keys);ProfileNames=$profileNames}
}

function New-PlatformExpectedClosure {
    param([string]$Root,$Files)
    $ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $Files) { $ordered.Add([string]$file.path,[pscustomobject]@{path=[string]$file.path;sha256=[string]$file.sha256}) }
    if ($ordered.Count -eq 0) { throw [IO.InvalidDataException]::new('Expected closure is empty.') }
    $canonical=($ordered.Values | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $digest=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar);sha256=$digest;files=@($ordered.Values)}
}

function Open-PlatformClosureGuards {
    param($Closure,[string]$Platform)
    $session=New-PlatformPreparationSession
    try {
        if ($null -eq $Closure) { throw 'Runtime closure receipt is required.' }
        if ($Platform -ceq 'windows') {
            $root=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot([string]$Closure.rootPath)
            $session.Guards.Add($root)
            foreach ($file in $Closure.files) {
                $relative=Assert-SafePlatformArchivePath ([string]$file.path) $Platform
                $parts=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($relative)
                $parent=$root
                for ($i=0; $i -lt $parts.Length-1; $i++) {
                    $parent=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationDirectory($parent,$parts[$i])
                    $session.Guards.Add($parent)
                }
                $session.Guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($parent,$parts[$parts.Length-1],'Read','OpenExisting'))
            }
        }
        return $session
    } catch {
        Close-PlatformPreparationSession $session
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform ('Runtime closure protection failed: '+$_.Exception.Message))
    }
}

function Get-PlatformPreparationProperty {
    param([Parameter(Mandatory = $true)] $Value, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $matches = @($Value.Keys | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals([string]$_,$Name) })
        if ($matches.Count -gt 1) { throw [IO.InvalidDataException]::new("Property '$Name' is ambiguous by case.") }
        if ($matches.Count -eq 1) { return $Value[$matches[0]] }
        return $null
    }
    $properties = @($Value.PSObject.Properties | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name,$Name) })
    if ($properties.Count -gt 1) { throw [IO.InvalidDataException]::new("Property '$Name' is ambiguous by case.") }
    if ($properties.Count -eq 0) { return $null }
    return $properties[0].Value
}

function New-PlatformPreparationFailure {
    param([string] $Capability, [string] $Platform, [string] $Message)
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]::new($Capability,$Platform,$Message)
}

function Get-VerifiedPlatformLeasePath {
    param($Lease,[string]$Platform)
    try {
        $path = if ($Platform -ceq 'windows') {
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::GetVerifiedPath($Lease)
        } else {
            [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::GetVerifiedPath($Lease)
        }
        if ($Lease.Observation.Kind -cne 'directory') { throw [ArgumentException]::new('A live directory lease is required.') }
        return [IO.Path]::GetFullPath($path)
    }
    catch { throw (New-PlatformPreparationFailure 'destination-lease' $Platform $_.Exception.Message) }
}

function Get-PlatformSha256 {
    param([string]$LiteralPath)
    if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem() -cne 'windows') {
        $snapshot = New-PlatformArchiveSnapshot $LiteralPath
        try { return Get-PlatformArchiveSha256 $snapshot } finally { $snapshot.Dispose() }
    }
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function New-PlatformArchiveSnapshot {
    param([string]$ArchivePath)
    # Copy once into a private buffer, then expose only a read-only, non-publicly
    # visible stream. Even Unix writers/renames cannot alter the bytes subsequently
    # hashed and extracted. A concurrent change during the copy must still pass
    # the approved hash of this exact snapshot. No disk staging or cache reopen.
    if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem() -cne 'windows') {
        return [IO.MemoryStream]::new([SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::ReadPreparationFileBytes($ArchivePath),$false)
    }
    return [IO.MemoryStream]::new([IO.File]::ReadAllBytes($ArchivePath),$false)
}

function Get-PlatformRuntimeClosure {
    param([string]$Root,[string]$Platform)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($rootPath)
    $files = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        $directoryRelative=[IO.Path]::GetRelativePath($rootPath,$directory).Replace('\','/')
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) {
            throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Runtime closure requires physical directories: '$directoryRelative'.")
        }
        # Do not recurse through an unchecked directory or junction.
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            $relative = $child.FullName.Substring($rootPath.Length+1).Replace([IO.Path]::DirectorySeparatorChar,'/')
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $child.LinkType) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Runtime closure contains a link: '$relative' (LinkType='$($child.LinkType)').")
            }
            if ($child.PSIsContainer) { $pending.Enqueue($child.FullName); continue }
            [void](Test-PhysicalPlatformFile $child.FullName $Platform 'powershell-runtime')
            [void](Assert-SafePlatformArchivePath $relative $Platform)
            $files.Add($relative,[pscustomobject]@{path=$relative;sha256=(Get-PlatformSha256 $child.FullName)})
        }
    }
    if ($files.Count -eq 0) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Runtime closure is empty.') }
    $canonical = ($files.Values | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{rootPath=$rootPath;sha256=$digest;files=@($files.Values)}
}

function Assert-PlatformRuntimeClosure {
    param([string]$ExecutablePath,$Expected,[string]$Platform)
    try {
        if ($null -eq $Expected) { throw 'Runtime closure receipt is required.' }
        $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ExecutablePath))
        $comparison = if ($Platform -ceq 'windows') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not [string]::Equals($root,[string]$Expected.rootPath,$comparison) -or [string]$Expected.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Runtime closure root or digest is invalid.' }
        $actual = Get-PlatformRuntimeClosure $root $Platform
        $expectedFiles = @($Expected.files)
        if ($actual.sha256 -cne [string]$Expected.sha256 -or $actual.files.Count -ne $expectedFiles.Count) { throw 'Runtime closure content or file list changed.' }
        for ($i=0; $i -lt $actual.files.Count; $i++) {
            if ($actual.files[$i].path -cne [string]$expectedFiles[$i].path -or $actual.files[$i].sha256 -cne [string]$expectedFiles[$i].sha256) { throw 'Runtime closure inventory differs from its receipt.' }
        }
        $leaf = [IO.Path]::GetFileName($ExecutablePath)
        # Inventory bytes and ordering stay ordinal. Binding a caller's spelling
        # follows the platform path comparison, and still requires one match.
        if (@($actual.files | Where-Object { [string]::Equals([string]$_.path,$leaf,$comparison) }).Count -ne 1) { throw 'Runtime closure does not bind the executable.' }
    } catch { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform ("Runtime closure verification failed: " + $_.Exception.Message)) }
}

function Get-PlatformArchiveSha256 {
    param([IO.MemoryStream]$Snapshot)
    if (-not $Snapshot.CanRead -or -not $Snapshot.CanSeek -or $Snapshot.CanWrite) { throw [IO.InvalidDataException]::new('A read-only archive snapshot is required.') }
    $Snapshot.Position = 0
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Snapshot)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $Snapshot.Position = 0 }
}

function Assert-SafePlatformArchivePath {
    param([string]$Path,[string]$Platform)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.StartsWith('/',[StringComparison]::Ordinal) -or
        $Path -match '^[A-Za-z]:' -or @($Path.Split('/') | Where-Object { $_ -ceq '.' -or $_ -ceq '..' -or $_ -ceq '' }).Count -gt 0) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member has an unsafe path: '$Path'.")
    }
    return ($Path.Split('/') -join [IO.Path]::DirectorySeparatorChar)
}

function Expand-VerifiedPlatformZip {
    param([IO.MemoryStream]$Snapshot,$DestinationLease,[string]$Platform,$Session)
    [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $archive = [IO.Compression.ZipArchive]::new($Snapshot,[IO.Compression.ZipArchiveMode]::Read,$true)
    $entries = New-Object Collections.Generic.List[object]
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        foreach ($entry in $archive.Entries) {
            $raw = [string]$entry.FullName
            $directory = $raw.EndsWith('/',[StringComparison]::Ordinal)
            $name = if ($directory) { $raw.TrimEnd('/') } else { $raw }
            $relative = Assert-SafePlatformArchivePath $name $Platform
            $attributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes),0)
            $unixType = ($attributes -shr 16) -band 0xf000
            if ($unixType -eq 0xa000 -or ($attributes -band [uint32][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member is a link: '$raw'.")
            }
            if (($unixType -ne 0 -and $unixType -cnotin @(0x4000,0x8000)) -or ($unixType -eq 0x4000 -and -not $directory) -or ($unixType -eq 0x8000 -and $directory)) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member has an unsupported type: '$raw'.")
            }
            if (-not $seen.Add($relative)) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive has a duplicate member: '$raw'.") }
            $entries.Add([pscustomobject]@{ Entry=$entry; Relative=$relative; Directory=$directory })
        }
        foreach ($item in @($entries | Sort-Object { $_.Relative.Split([IO.Path]::DirectorySeparatorChar).Count })) {
            if ($item.Directory) { New-PlatformPreparationDirectory $DestinationLease $item.Relative $Platform $Session; continue }
            $source = $item.Entry.Open()
            try {
                Write-PlatformPreparationFile $DestinationLease $item.Relative $source $Platform $Session
            } finally { $source.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Expand-VerifiedPlatformTarGz {
    param([IO.MemoryStream]$Snapshot,$DestinationLease,[string]$Platform,$Session)
    [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
    $tarReaderType = [Type]::GetType('System.Formats.Tar.TarReader, System.Formats.Tar',$false)
    if ($null -eq $tarReaderType) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The runtime does not provide System.Formats.Tar for verified extraction.') }
    $gzip = [IO.Compression.GZipStream]::new($Snapshot,[IO.Compression.CompressionMode]::Decompress,$true)
    $reader = $null
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        $reader = [Activator]::CreateInstance($tarReaderType,@($gzip,$false))
        while ($null -ne ($entry = $reader.GetNextEntry())) {
            $kind = $entry.EntryType.ToString()
            if ($kind -cnotin @('RegularFile','V7RegularFile','Directory')) {
                throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member '$($entry.Name)' has forbidden type '$kind'.")
            }
            # tar -C <root> . emits ./ and ./name. Strip only leading ./;
            # interior dot segments, traversal, and absolute paths remain errors.
            $name = [string]$entry.Name
            if ($name.StartsWith('./',[StringComparison]::Ordinal)) { $name = $name.Substring(2) }
            if ($kind -ceq 'Directory' -and ([string]$entry.Name -ceq '.' -or ($name -ceq '' -and ([string]$entry.Name).StartsWith('./',[StringComparison]::Ordinal)))) { continue }
            if ($kind -ceq 'Directory') { $name = $name.TrimEnd('/') }
            $relative = Assert-SafePlatformArchivePath $name $Platform
            if (-not $seen.Add($relative)) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive has a duplicate member: '$($entry.Name)'.") }
            if ($kind -ceq 'Directory') { New-PlatformPreparationDirectory $DestinationLease $relative $Platform $Session; continue }
            if ($null -eq $entry.DataStream) {
                if ($entry.Length -ne 0) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Archive member '$($entry.Name)' has no content stream for its nonzero length.") }
                $empty = [IO.MemoryStream]::new([byte[]]@(),$false)
                try { Write-PlatformPreparationFile $DestinationLease $relative $empty $Platform $Session }
                finally { $empty.Dispose() }
            } else { Write-PlatformPreparationFile $DestinationLease $relative $entry.DataStream $Platform $Session }
        }
    }
    finally { if ($null -ne $reader) { $reader.Dispose() }; $gzip.Dispose() }
}

function Get-PlatformPowerShellAsset {
    param($Policy,[string]$Platform,[string]$Architecture,$ReleaseMetadata)
    $root = Get-PlatformPreparationProperty $Policy 'powerShell'
    if ($null -eq $root) { $root = $Policy }
    $version = [string](Get-PlatformPreparationProperty $root 'version')
    if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $Architecture -cnotin @('x64','arm64')) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Policy version or host architecture is unsupported.')
    }
    $token = if ($Platform -ceq 'windows') { "win-$Architecture" } elseif ($Platform -ceq 'linux') { "linux-$Architecture" } else { "osx-$Architecture" }
    $expectedName = if ($Platform -ceq 'windows') { "PowerShell-$version-$token.zip" } else { "powershell-$version-$token.tar.gz" }
    $assetsValue = Get-PlatformPreparationProperty $root 'assets'
    $assets = @($assetsValue)
    if ($assetsValue -is [Collections.IDictionary]) {
        $keyedAsset = Get-PlatformPreparationProperty $assetsValue $token
        if ($null -eq $keyedAsset) { $keyedAsset = Get-PlatformPreparationProperty $assetsValue "$Platform-$Architecture" }
        if ($null -ne $keyedAsset) { $assets = @($keyedAsset) }
    }
    $matches = @($assets | Where-Object { [string](Get-PlatformPreparationProperty $_ 'name') -ceq $expectedName })
    if ($matches.Count -ne 1) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform "Policy must bind exactly one official asset '$expectedName'.") }
    $policyHash = [string](Get-PlatformPreparationProperty $matches[0] 'sha256')
    $metadataHash = $null
    if ($null -ne $ReleaseMetadata) {
        $metadataAssets = @(Get-PlatformPreparationProperty $ReleaseMetadata 'assets')
        $metadataMatches = @($metadataAssets | Where-Object { [string](Get-PlatformPreparationProperty $_ 'name') -ceq $expectedName })
        if ($metadataMatches.Count -ne 1) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Release metadata does not bind the selected asset exactly once.') }
        $metadataHash = [string](Get-PlatformPreparationProperty $metadataMatches[0] 'sha256')
        if ([string]::IsNullOrWhiteSpace($metadataHash)) {
            $digest = [string](Get-PlatformPreparationProperty $metadataMatches[0] 'digest')
            if ($digest -cmatch '^sha256:([a-f0-9]{64})$') { $metadataHash = [string]$Matches[1] }
        }
    }
    if ($policyHash -match '^[a-f0-9]{64}$' -and $metadataHash -match '^[a-f0-9]{64}$' -and $policyHash -cne $metadataHash) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Policy and release metadata hashes disagree.')
    }
    $hash = if ($policyHash -match '^[a-f0-9]{64}$') { $policyHash } else { $metadataHash }
    if ($hash -cnotmatch '^[a-f0-9]{64}$') { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'No approved lowercase SHA-256 binds the selected asset.') }
    return [pscustomobject]@{ Version=$version; Name=$expectedName; Sha256=$hash }
}

function Test-PhysicalPlatformFile {
    param([string]$Path,[string]$Platform,[string]$Capability)
    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) {
        throw (New-PlatformPreparationFailure $Capability $Platform "A physical regular file is required: '$Path'.")
    }
    if ($Platform -cne 'windows') { [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::AssertRegularSourceFile($Path) }
    return $item
}

function Test-PlatformPowerShellIdentity {
    param([string]$ExecutablePath,[string]$ExpectedVersion,[string]$ExpectedPlatform,[string]$ExpectedArchitecture,$RuntimeClosure)
    [void](Test-PhysicalPlatformFile $ExecutablePath $ExpectedPlatform 'powershell-runtime')
    $probe = '$o=[ordered]@{version=$PSVersionTable.PSVersion.ToString();architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant();os=if($IsWindows){"windows"}elseif($IsLinux){"linux"}elseif($IsMacOS){"macos"}else{"unknown"}};$o|ConvertTo-Json -Compress'
    $output = Invoke-PlatformVerifiedProcess $ExecutablePath $RuntimeClosure $ExpectedPlatform $probe
    try { $identity = ([string]$output | ConvertFrom-Json -ErrorAction Stop) } catch { throw (New-PlatformPreparationFailure 'powershell-runtime' $ExpectedPlatform 'The selected pwsh returned invalid identity evidence.') }
    if ([string]$identity.version -cne $ExpectedVersion -or [string]$identity.os -cne $ExpectedPlatform -or [string]$identity.architecture -cne $ExpectedArchitecture) {
        throw (New-PlatformPreparationFailure 'powershell-runtime' $ExpectedPlatform 'The selected pwsh version, OS, or architecture does not match policy.')
    }
    return $identity
}

function Resolve-VerifiedPlatformPowerShell {
    param($Policy,$DestinationLease,$OfflineCache,$ReleaseMetadata,[string]$Platform)
    $session=New-PlatformPreparationSession
    try {
        $architecture = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()
        $asset = Get-PlatformPowerShellAsset $Policy $Platform $architecture $ReleaseMetadata
        $cachePath = if ($OfflineCache -is [string]) { $OfflineCache } else {
            $candidate = Get-PlatformPreparationProperty $OfflineCache 'archivePath'
            if ($null -eq $candidate) { $candidate = Get-PlatformPreparationProperty $OfflineCache 'path' }
            [string]$candidate
        }
        if ([string]::IsNullOrWhiteSpace($cachePath)) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'An already-downloaded archive or offline cache path is required.') }
        $cachePath = [IO.Path]::GetFullPath($cachePath)
        if (Test-Path -LiteralPath $cachePath -PathType Container) { $cachePath = Join-Path $cachePath $asset.Name }
        [void](Test-PhysicalPlatformFile $cachePath $Platform 'powershell-runtime')
        if ([IO.Path]::GetFileName($cachePath) -cne $asset.Name) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The cache file name does not match the selected official asset.') }
        $snapshot = New-PlatformArchiveSnapshot $cachePath
        try {
            $actualHash = Get-PlatformArchiveSha256 $snapshot
            if ($actualHash -cne $asset.Sha256) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The archive SHA-256 does not match policy.') }
            $destination = Get-VerifiedPlatformLeasePath $DestinationLease $Platform
            if ($Platform -ceq 'windows') {
                $session.Guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot($destination))
                [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            }
            if (@(Get-ChildItem -Force -LiteralPath $destination).Count -ne 0) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'The destination lease directory must be empty.') }
            if ($Platform -ceq 'windows') { Expand-VerifiedPlatformZip $snapshot $DestinationLease $Platform $session } else { Expand-VerifiedPlatformTarGz $snapshot $DestinationLease $Platform $session }
        } finally { $snapshot.Dispose() }
        $destination = Get-VerifiedPlatformLeasePath $DestinationLease $Platform
        $executable = Join-Path $destination $(if ($Platform -ceq 'windows') { 'pwsh.exe' } else { 'pwsh' })
        if ($Platform -cne 'windows') {
            $lease = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::OpenFile($DestinationLease,'pwsh','Read','OpenExisting')
            try { [void][SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::SetPermissions($lease,448) } finally { $lease.Dispose() }
        }
        # The trust baseline consists exclusively of hashes computed from member
        # bytes in the approved archive snapshot, NEVER the post-extraction disk.
        $runtimeClosure = New-PlatformExpectedClosure $destination $session.Files
        Assert-PlatformRuntimeClosure $executable $runtimeClosure $Platform
        $identity=Test-PlatformPowerShellIdentity $executable $asset.Version $Platform $architecture $runtimeClosure
        [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        $executableHash=[string](@($runtimeClosure.files | Where-Object path -CEQ ([IO.Path]::GetFileName($executable)))[0].sha256)
        $environment=New-PlatformVerifiedProcessEnvironment $executable $null $Platform
        $warningEvidence=Get-PlatformVerifiedWarningEvidence $identity
        return [pscustomobject][ordered]@{ apiVersion='1.0'; version=$asset.Version; assetName=$asset.Name; archiveSha256=$actualHash; executablePath=[IO.Path]::GetFullPath($executable); executableSha256=$executableHash; runtimeClosure=$runtimeClosure; environmentAllowlist=$environment.Names; warningCount=$warningEvidence.count; warnings=@($warningEvidence.summaries); protectionBoundary=(Get-PlatformProtectionBoundary $Platform); os=$Platform; architecture=$architecture }
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform $_.Exception.Message)
    }
    finally { Close-PlatformPreparationSession $session }
}

function Import-VerifiedPesterResolverModule {
    param([string]$ResolverPath,[string]$Platform)
    [void](Test-PhysicalPlatformFile $ResolverPath $Platform 'pester-module')
    # The resolver is already hash-bound by the bundle inventory. Take only the
    # validator definitions and their helpers, verbatim; never run its entrypoint
    # (even -ValidatePolicyOnly reads a repository-relative policy outside closure).
    $tokens = $null; $errors = $null
    $snapshot=New-PlatformArchiveSnapshot $ResolverPath
    try {
        $bytes=$snapshot.ToArray()
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Resolver has a forbidden UTF-8 BOM.' }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).Replace("`r`n","`n")
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($hash -cne $script:PesterResolverSha256) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Resolver snapshot differs from its bundle inventory.') }
        $ast = [Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    } finally { $snapshot.Dispose() }
    if (@($errors).Count -ne 0) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'The verified resolver could not be parsed.') }
    $required = @(
        'Get-FileSha256','Get-ResolverAsciiCaseFold','Assert-ResolverSafeRelativePath',
        'Get-ResolverSymlinkTarget','Get-ResolverSymlinkIdentitySha256','Get-ResolverSafeUnixSymlinkEntry',
        'Get-ResolverOrderedClosureEntries','Get-ResolverParallelFileHashes','Get-DirectoryClosureIdentity',
        'Get-ApprovedPesterPayloadSha256','Assert-ApprovedPesterManifest'
    )
    $definitions = foreach ($name in $required) {
        $matches = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name })
        if ($matches.Count -ne 1) { throw (New-PlatformPreparationFailure 'pester-module' $Platform "The verified resolver must define '$name' exactly once.") }
        $matches[0].Extent.Text
    }
    $body = "Set-StrictMode -Version Latest`n" + ($definitions -join "`n") + "`nExport-ModuleMember -Function Get-DirectoryClosureIdentity,Get-ApprovedPesterPayloadSha256,Assert-ApprovedPesterManifest"
    $module = New-Module -Name ('PlatformPesterResolver-' + [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($body))
    if ($null -eq $module -or @($module.ExportedCommands.Keys).Count -ne 3) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'The verified resolver module did not expose the required Pester validators.') }
    return $module
}

function Open-WindowsPreparationDirectoryGuards {
    param($DestinationLease,[string]$RelativePath)
    $current = Get-VerifiedPlatformLeasePath $DestinationLease 'windows'
    $parts = if ($RelativePath.Length -eq 0) { @() } else { [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath) }
    $parentLease = $DestinationLease
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sddl = 'D:P(A;OICI;FA;;;' + $identity.User.Value + ')' } finally { $identity.Dispose() }
    $guards = [Collections.Generic.List[IDisposable]]::new()
    try {
        foreach ($part in $parts) {
            $next = Join-Path $current $part
            [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::CreatePrivateDirectory($next,$sddl)
            # Retain EVERY no-reparse, deny-write/delete guard. No descendant is
            # created or opened until its parent has been guarded. If an attacker
            # replaces the new directory before this open, validation rejects it.
            $parentLease = [SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationDirectory($parentLease,$part)
            $guards.Add($parentLease)
            $current = $next
        }
        return [pscustomobject]@{ Path=$current; Guards=$guards; Parent=$parentLease }
    } catch {
        for ($i=$guards.Count-1; $i -ge 0; $i--) { $guards[$i].Dispose() }
        throw
    }
}

function New-PlatformPreparationDirectory {
    param($DestinationLease,[string]$RelativePath,[string]$Platform,$Session)
    if ($Platform -cne 'windows') {
        [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::CreatePreparationDirectory($DestinationLease,$RelativePath)
    } else {
        $owned = Open-WindowsPreparationDirectoryGuards $DestinationLease $RelativePath
        try {
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            if ($null -ne $Session) { foreach($guard in $owned.Guards) { $Session.Guards.Add($guard) }; $owned.Guards.Clear() }
        }
        finally { for ($i=$owned.Guards.Count-1; $i -ge 0; $i--) { $owned.Guards[$i].Dispose() } }
    }
}

function Write-PlatformPreparationFile {
    param($DestinationLease,[string]$RelativePath,[IO.Stream]$Source,[string]$Platform,$Session)
    $owned=$null; $guard=$null; $buffer=[IO.MemoryStream]::new(); $snapshot=$null
    try {
        if ($Platform -ceq 'windows') {
            $parts = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($RelativePath)
            $parent = if ($parts.Length -gt 1) { ($parts[0..($parts.Length-2)] -join [IO.Path]::DirectorySeparatorChar) } else { '' }
            $owned = Open-WindowsPreparationDirectoryGuards $DestinationLease $parent
        }
        # Hash input bytes in memory, before the destination can influence the
        # expected inventory. This also works for non-seekable tar entry streams.
        $Source.CopyTo($buffer)
        $snapshot=[IO.MemoryStream]::new($buffer.ToArray(),$false)
        $expected=Get-PlatformArchiveSha256 $snapshot
        if ($null -ne $Session) { $Session.Files.Add([pscustomobject]@{path=$RelativePath.Replace('\','/');sha256=$expected}) }
        if ($Platform -cne 'windows') {
            [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::WritePreparationFile($DestinationLease,$RelativePath,$snapshot)
        } else {
            $target = Join-Path $owned.Path $parts[$parts.Length-1]
            $output = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $snapshot.CopyTo($output) } finally { $output.Dispose() }
            # Read-only guards allow the loader's ordinary read sharing. The
            # writer-to-reader handoff is NOT trusted: acquire deny-write/delete,
            # then compare to the input hash. A racing writer either blocks the
            # guard or causes a mismatch. No disk bytes become a trust baseline.
            $guard=[SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenFile($owned.Parent,$parts[$parts.Length-1],'Read','OpenExisting')
            if ((Get-PlatformSha256 $target) -cne $expected) { throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform 'Written member differs from its source snapshot.') }
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            if ($null -ne $Session) {
                foreach($directoryGuard in $owned.Guards) { $Session.Guards.Add($directoryGuard) }; $owned.Guards.Clear()
                $Session.Guards.Add($guard); $guard=$null
            }
        }
    } finally {
        if ($null -ne $guard) { $guard.Dispose() }
        if ($null -ne $owned) { for ($i=$owned.Guards.Count-1; $i -ge 0; $i--) { $owned.Guards[$i].Dispose() } }
        if ($null -ne $snapshot) { $snapshot.Dispose() }; $buffer.Dispose()
    }
}

function New-PlatformPesterSnapshot {
    param([string]$SourceVersionRoot,[string]$VersionRelativePath,[string]$Destination,[string]$Platform)
    $sourceItem = Get-Item -Force -LiteralPath $SourceVersionRoot -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $sourceItem.LinkType) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester source must be a physical directory.') }
    $members=[Collections.Generic.List[object]]::new()
    $pending=[Collections.Generic.Queue[string]]::new(); $pending.Enqueue($sourceItem.FullName)
    try {
        while ($pending.Count -gt 0) {
            foreach ($item in @(Get-ChildItem -Force -LiteralPath $pending.Dequeue())) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) { throw (New-PlatformPreparationFailure 'pester-module' $Platform "Pester payload contains a link: '$($item.FullName)'.") }
                if ($item.PSIsContainer) { $pending.Enqueue($item.FullName); continue }
                [void](Test-PhysicalPlatformFile $item.FullName $Platform 'pester-module')
                $relative=($VersionRelativePath+'/'+$item.FullName.Substring($sourceItem.FullName.Length).TrimStart('\','/')).Replace('\','/')
                [void](Assert-SafePlatformArchivePath $relative $Platform)
                $stream=New-PlatformArchiveSnapshot $item.FullName
                try { $members.Add([pscustomobject]@{path=$relative;sha256=(Get-PlatformArchiveSha256 $stream);stream=$stream}) }
                catch { $stream.Dispose(); throw }
            }
        }
        return [pscustomobject]@{ Members=$members; Closure=(New-PlatformExpectedClosure $Destination $members) }
    } catch { foreach($member in $members) { $member.stream.Dispose() }; throw }
}

function Copy-PhysicalPesterPayload {
    param([string]$SourceVersionRoot,$DestinationLease,[string]$VersionRelativePath,[string]$Platform,$Snapshot,$Session)
    $destination=Get-VerifiedPlatformLeasePath $DestinationLease $Platform
    $ownsSnapshot=$null -eq $Snapshot
    if ($ownsSnapshot) { $Snapshot=New-PlatformPesterSnapshot $SourceVersionRoot $VersionRelativePath $destination $Platform }
    try {
        New-PlatformPreparationDirectory $DestinationLease $VersionRelativePath $Platform $Session
        foreach ($member in $Snapshot.Members) {
            $member.stream.Position=0
            Write-PlatformPreparationFile $DestinationLease $member.path $member.stream $Platform $Session
        }
    } finally { if ($ownsSnapshot) { foreach ($member in $Snapshot.Members) { $member.stream.Dispose() } } }
}

function Assert-PlatformPesterClosure {
    param([string]$Destination,$Expected,[string]$Platform)
    try {
        $actual=Get-PlatformRuntimeClosure $Destination $Platform
        if ($actual.sha256 -cne $Expected.sha256 -or $actual.files.Count -ne $Expected.files.Count) { throw 'Pester payload differs from its approved snapshot.' }
        for ($i=0; $i -lt $actual.files.Count; $i++) {
            if ($actual.files[$i].path -cne $Expected.files[$i].path -or $actual.files[$i].sha256 -cne $Expected.files[$i].sha256) { throw 'Pester payload inventory differs from its approved snapshot.' }
        }
    } catch { throw (New-PlatformPreparationFailure 'pester-module' $Platform ('Pester closure verification failed: '+$_.Exception.Message)) }
}

function Assert-PlatformPesterSnapshotInventory {
    param($Resolver,$Entries)
    # Apply the resolver's path and collision contract to in-memory entries.
    # Do not rescan a mutable tree to manufacture the approved baseline.
    & $Resolver {
        param($Entries)
        $nfcPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $casePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $Entries) {
            Assert-ResolverSafeRelativePath -Value ([string]$entry.path)
            $nfc=([string]$entry.path).Normalize([Text.NormalizationForm]::FormC)
            if (-not $nfcPaths.Add($nfc) -or -not $casePaths.Add((Get-ResolverAsciiCaseFold $nfc))) { throw 'Pester snapshot contains normalization/case-colliding paths.' }
        }
    } $Entries
}

# Build the child from an empty environment, then add only the fixed allowlist.
# In particular no caller-controlled loader, host, or module-search setting is
# copied into the verified runtime process.
function Get-PlatformProcessOutputSummary {
    param($Task,[string]$Incomplete='[incomplete]',[AllowEmptyString()][string]$Text)
    if(-not $PSBoundParameters.ContainsKey('Text')) {
        if($null -eq $Task -or $Task.Status -ne [Threading.Tasks.TaskStatus]::RanToCompletion){return $Incomplete}
        $Text=[string]$Task.GetAwaiter().GetResult()
    }
    $text=[regex]::Replace($text,'\x1b\[[0-?]*[ -/]*[@-~]','')
    # Probe output is controlled, but failure diagnostics may include local
    # absolute paths. Retain only the leaf so CI can expose the unexpected line.
    $text=[regex]::Replace($text,'(?i)(?<path>(?:[a-z]:[\\/]|\\\\|/)[^"''\r\n,;}\]]+)',{
        param($match)
        $path=$match.Groups['path'].Value.Trim().TrimEnd('/','\')
        $leaf=[IO.Path]::GetFileName($path)
        if([string]::IsNullOrWhiteSpace($leaf)){return '[path]'}
        return '[path:'+$leaf+']'
    })
    $text=[regex]::Replace($text,'\r?\n',' | ')
    $text=[regex]::Replace($text,'[\x00-\x20\x7f]+',' ').Trim()
    if($text.Length -eq 0){return '[empty]'}
    if($text.Length -gt 2048){return $text.Substring(0,2048)+' [truncated]'}
    return $text
}

function Get-PlatformProcessStderrSummary {
    param($Task)
    return Get-PlatformProcessOutputSummary $Task '[stderr incomplete]'
}

function Get-PlatformProcessStdoutSummary {
    param($Task)
    return Get-PlatformProcessOutputSummary $Task '[stdout incomplete]'
}

function Get-PlatformVerifiedWarningEvidence {
    param($Evidence)
    if($null -eq $Evidence){return [pscustomobject][ordered]@{count=0;summaries=@()}}
    $warnings=Get-PlatformPreparationProperty $Evidence 'warnings'
    if($null -eq $warnings){return [pscustomobject][ordered]@{count=0;summaries=@()}}
    $count=Get-PlatformPreparationProperty $warnings 'count'
    $summaryValue=Get-PlatformPreparationProperty $warnings 'summaries'
    $summaries=if($null -eq $summaryValue){@()}else{@($summaryValue)}
    if($null -eq $count){$count=0}
    return [pscustomobject][ordered]@{count=[int]$count;summaries=@($summaries | ForEach-Object {[string]$_})}
}

function Start-PlatformVerifiedProcess {
    param([string]$Executable,[string]$Probe,$Environment,[string]$Platform,
        [ValidateRange(1,300000)][int]$TimeoutMilliseconds=30000)
    # PowerShell adds default module paths during startup. Reset them inside the
    # child before resolving any non-Core command; never rely on env alone.
    $modulePath=([string]$Environment.Values['PSModulePath']).Replace("'","''")
    $command="`$PSModuleAutoLoadingPreference='None';`$env:PSModulePath='$modulePath';`$ErrorActionPreference='Stop';`$__bootstrapWarnings=@();"
    $runtimeRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Executable))
    foreach($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')) {
        $manifest=[IO.Path]::Combine($runtimeRoot,'Modules',$module,($module+'.psd1')).Replace("'","''")
        $command+="Microsoft.PowerShell.Core\Import-Module -Name '$manifest' -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable +__bootstrapWarnings;"
    }
    # Capture the warning stream as data before the host can render it to native
    # stdout. The verified probe must still produce exactly one JSON value; the
    # wrapper attaches bounded, redacted warning evidence and emits one JSON line.
    $escapedProbe=$Probe.Replace("'","''")
    $wrapper=@'
$__probe=[scriptblock]::Create('__PROBE__')
$__records=@(& $__probe 3>&1)
$__payload=@()
$__warnings=@($__bootstrapWarnings)
foreach($__record in $__records){if($__record -is [Management.Automation.WarningRecord]){$__warnings+=$__record}else{$__payload+=$__record}}
if($__payload.Count-ne 1){throw 'Verified probe must produce exactly one JSON value.'}
$__evidence=$__payload[0]|ConvertFrom-Json -ErrorAction Stop
if($null-eq $__evidence -or $null-ne $__evidence.PSObject.Properties['warnings']){throw 'Verified probe returned an invalid or reserved JSON value.'}
$__summaries=@()
foreach($__warning in $__warnings){
    if($__summaries.Count-ge 16){break}
    $__text=[string]$__warning.Message
    $__text=[regex]::Replace($__text,'\x1b\[[0-?]*[ -/]*[@-~]','')
    $__text=[regex]::Replace($__text,'(?i)(?<path>(?:[a-z]:[\\/]|\\\\|/)[^"''\r\n,;}\]]+)',{
        param($m)
        $__path=$m.Groups['path'].Value.Trim().TrimEnd('/','\')
        $__leaf=[IO.Path]::GetFileName($__path)
        if([string]::IsNullOrWhiteSpace($__leaf)){'[path]'}else{'[path:'+$__leaf+']'}
    })
    $__text=[regex]::Replace($__text,'[\x00-\x20\x7f]+',' ').Trim()
    if($__text.Length-gt 512){$__text=$__text.Substring(0,512)+' [truncated]'}
    $__summaries+=$__text
}
$__evidence|Add-Member -NotePropertyName warnings -NotePropertyValue ([pscustomobject][ordered]@{count=$__warnings.Count;summaries=@($__summaries)}) -ErrorAction Stop
$__evidence|ConvertTo-Json -Compress -Depth 16
'@
    $command+=$wrapper.Replace('__PROBE__',$escapedProbe)
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive')
    if($Platform -ceq 'windows'){$arguments+=@('-ExecutionPolicy','Bypass')}
    $arguments+=@('-Command',$command)
    $profileRoot=$null;$primaryFailure=$null
    try {
        $profileRoot=New-PlatformPrivateRoot -Parent ([IO.Path]::GetTempPath()) -Leaf ('platform-verified-profile-'+[guid]::NewGuid().ToString('N'))
        $values=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach($name in $Environment.Names){$values[[string]$name]=[string]$Environment.Values[$name]}
        foreach($name in $Environment.ProfileNames){$values[[string]$name]=$profileRoot}
        try {$result=Invoke-PlatformPreparationCommand -Command $Executable -Arguments $arguments -Environment $values -WorkingDirectory $profileRoot -TimeoutMilliseconds $TimeoutMilliseconds}
        catch {
            if($_.Exception.Message -match 'acquisition deadline'){throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform ('Verified runtime '+$_.Exception.Message))}
            throw
        }
        $output=@($result.stdout.TrimEnd("`r","`n") -split "`r?`n")
        if($result.exitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($result.stderr) -or $output.Count -ne 1){
            throw "Verified runtime process failed (exit code $($result.exitCode), stdout lines $($output.Count)); stdout: $(Get-PlatformProcessOutputSummary -Text $result.stdout); stderr: $(Get-PlatformProcessOutputSummary -Text $result.stderr)"
        }
        $payload=$output[0]|ConvertFrom-Json -ErrorAction Stop
        $payload|Add-Member -NotePropertyName processOwnership -NotePropertyValue $result.processOwnership -ErrorAction Stop
        return $payload|ConvertTo-Json -Depth 16 -Compress
    } catch {
        $primaryFailure=$_.Exception
        if($primaryFailure -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]){throw}
        throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform $primaryFailure.Message)
    } finally {
        # Only the exact fresh private profile owned by this invocation is removed.
        # Kernel-confirmed process exit can precede the final filesystem release.
        # Bound that retry and retain the workload failure if reclamation fails.
        if($null -ne $profileRoot){
            $cleanupDeadline=[DateTimeOffset]::UtcNow.AddSeconds(1)
            while($true){
                try {[IO.Directory]::Delete($profileRoot,$true);break}
                catch {
                    if($_.Exception.InnerException -is [IO.IOException] -and [DateTimeOffset]::UtcNow -lt $cleanupDeadline){Start-Sleep -Milliseconds 50;continue}
                    $message='Private profile cleanup failed: '+$_.Exception.Message
                    if($null -ne $primaryFailure){$message=$primaryFailure.Message+'; '+$message}
                    throw (New-PlatformPreparationFailure 'powershell-runtime' $Platform $message)
                }
            }
        }
    }
}

# All launches use this boundary. Windows callers already hold preparation guards
# and this independently reacquires receipt guards for subsequent uses. On Unix,
# checking both closures immediately before launch detects changes, not a hostile
# same-UID writer in the final check-to-use interval (A1).
function Invoke-PlatformVerifiedProcess {
    param([string]$Executable,$RuntimeClosure,[string]$Platform,[string]$Probe,$PesterClosure)
    $guards=Open-PlatformClosureGuards $RuntimeClosure $Platform
    $moduleGuards=$null
    try {
        if ($null -ne $PesterClosure) {
            try { $moduleGuards=Open-PlatformClosureGuards $PesterClosure $Platform }
            catch { throw (New-PlatformPreparationFailure 'pester-module' $Platform ('Pester closure protection failed: '+$_.Exception.Message)) }
        }
        Assert-PlatformRuntimeClosure $Executable $RuntimeClosure $Platform
        if ($null -ne $PesterClosure) { Assert-PlatformPesterClosure $PesterClosure.rootPath $PesterClosure $Platform }
        $environment=New-PlatformVerifiedProcessEnvironment $Executable $PesterClosure $Platform
        $output=Start-PlatformVerifiedProcess $Executable $Probe $environment $Platform
        Assert-PlatformRuntimeClosure $Executable $RuntimeClosure $Platform
        if ($null -ne $PesterClosure) { Assert-PlatformPesterClosure $PesterClosure.rootPath $PesterClosure $Platform }
        return $output
    } finally { Close-PlatformPreparationSession $moduleGuards; Close-PlatformPreparationSession $guards }
}

function Close-PlatformPesterSnapshot {
    param($Snapshot)
    if ($null -ne $Snapshot) {
        foreach ($member in $Snapshot.Members) { $member.stream.Dispose() }
    }
}

function Assert-RegressionPesterManifest {
    param([string]$Path)
    # The approved 4.10.1 payload uses ModuleToProcess (the legacy RootModule
    # alias). Keep this compatibility in P4; the formal resolver stays unchanged.
    $manifest = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    $root = Get-PlatformPreparationProperty $manifest 'RootModule'
    $legacyRoot = Get-PlatformPreparationProperty $manifest 'ModuleToProcess'
    if ($null -ne $root -and $null -ne $legacyRoot -and [string]$root -cne [string]$legacyRoot) { throw 'Conflicting Pester root module declarations.' }
    if ($null -eq $root) { $root = $legacyRoot }
    if ([string](Get-PlatformPreparationProperty $manifest 'ModuleVersion') -cne '4.10.1' -or
        [string]$root -cne 'Pester.psm1' -or
        @((Get-PlatformPreparationProperty $manifest 'FunctionsToExport') | Where-Object { [string]$_ -ceq 'Invoke-Pester' }).Count -ne 1) {
        throw 'Regression Pester manifest does not bind Pester@4.10.1.'
    }
    foreach ($hook in @('ScriptsToProcess','NestedModules','RequiredModules','RequiredAssemblies')) {
        if ($manifest.Contains($hook) -and @($manifest[$hook]).Count -gt 0) { throw "Regression Pester manifest contains initialization hooks: $hook." }
    }
}

function Assert-PlatformPesterImportIdentity {
    param($Import,[string]$Version,[string]$ModuleBase,[string]$Platform)
    $comparison = if ($Platform -ceq 'windows') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $rootModule = Join-Path $ModuleBase 'Pester.psm1'
    if ([string]$Import.version -cne $Version -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Import.path),[IO.Path]::GetFullPath($rootModule),$comparison) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Import.moduleBase),[IO.Path]::GetFullPath($ModuleBase),$comparison)) {
        throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Imported Pester identity differs from the verified physical root module or module base.')
    }
}

# Ordinary authority already trusts the provisioned 4.10.1 installation. Capture
# that local baseline through P4; this is not a Gallery download or a new pin.
function Initialize-PlatformAuthorityPester {
    param([Parameter(Mandatory=$true)][string]$ModulePath,[Parameter(Mandatory=$true)][string]$Executable)
    $platform=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
    $Executable=Resolve-PlatformPhysicalPath $Executable
    # The provisioned source is captured as bytes, never executed in place.
    # P4 rejects links in that payload and verifies the physical destination.
    $ModulePath=[IO.Path]::GetFullPath($ModulePath)
    Assert-RegressionPesterManifest $ModulePath
    $runtimeClosure=Get-PlatformRuntimeClosure ([IO.Path]::GetDirectoryName($Executable)) $platform
    $identity=Test-PlatformPowerShellIdentity $Executable $PSVersionTable.PSVersion.ToString() $platform ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()) $runtimeClosure
    $root=New-PlatformPrivateRoot -Parent ([IO.Path]::GetTempPath()) -Leaf ('authority-pester-'+[guid]::NewGuid().ToString('N'))
    $lease=$null;$snapshot=$null;$session=New-PlatformPreparationSession
    try {
        $lease=Open-PlatformPreparationRoot $root $platform
        $snapshot=New-PlatformPesterSnapshot ([IO.Path]::GetDirectoryName($ModulePath)) 'Pester/4.10.1' $root $platform
        Copy-PhysicalPesterPayload ([IO.Path]::GetDirectoryName($ModulePath)) $lease 'Pester/4.10.1' $platform $snapshot $session
        Assert-PlatformPesterClosure $root $snapshot.Closure $platform
        $manifest=Join-Path $root 'Pester/4.10.1/Pester.psd1'
        Assert-RegressionPesterManifest $manifest
        $probe="`$m=Import-Module -Name '$($manifest.Replace("'","''"))' -Force -PassThru -ErrorAction Stop;[pscustomobject]@{version=`$m.Version.ToString();path=[IO.Path]::GetFullPath(`$m.Path);moduleBase=[IO.Path]::GetFullPath(`$m.ModuleBase)}|ConvertTo-Json -Compress"
        $import=(Invoke-PlatformVerifiedProcess $Executable $runtimeClosure $platform $probe $snapshot.Closure)|ConvertFrom-Json
        Assert-PlatformPesterImportIdentity $import '4.10.1' ([IO.Path]::GetDirectoryName($manifest)) $platform
        return [pscustomobject]@{modulePath=$manifest;rootPath=$root;moduleClosure=$snapshot.Closure;runtimeClosure=$runtimeClosure;executablePath=$Executable;processOwnership=@($identity.processOwnership,$import.processOwnership);protectionBoundary=(Get-PlatformProtectionBoundary $platform)}
    } catch {
        Close-PlatformPreparationSession $session
        if($null -ne $lease){$lease.Dispose();$lease=$null}
        [IO.Directory]::Delete($root,$true)
        throw
    } finally {
        Close-PlatformPesterSnapshot $snapshot
        Close-PlatformPreparationSession $session
        if($null -ne $lease){$lease.Dispose()}
    }
}

function Assert-PlatformAuthorityPester {
    param([Parameter(Mandatory=$true)]$Receipt)
    $platform=[SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
    Assert-PlatformRuntimeClosure $Receipt.executablePath $Receipt.runtimeClosure $platform
    Assert-PlatformPesterClosure $Receipt.rootPath $Receipt.moduleClosure $platform
}

function Initialize-VerifiedPlatformPester {
    param($Policy,$RuntimeReceipt,$DestinationLease,[string]$Platform,[string]$ResolverPath)
    $session=New-PlatformPreparationSession; $runtimeGuards=$null; $payloadSnapshot=$null
    try {
        if ([string]$RuntimeReceipt.os -cne $Platform -or [string]$RuntimeReceipt.architecture -cne [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Runtime receipt does not match the current platform.') }
        if ([string]$RuntimeReceipt.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [string]$RuntimeReceipt.executableSha256 -cnotmatch '^[a-f0-9]{64}$') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Runtime receipt lacks a verified version or executable identity.') }
        if ((Get-PlatformSha256 ([string]$RuntimeReceipt.executablePath)) -cne [string]$RuntimeReceipt.executableSha256) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Runtime executable changed after its receipt was issued.') }
        $runtimeClosure = Get-PlatformPreparationProperty $RuntimeReceipt 'runtimeClosure'
        $runtimeGuards=Open-PlatformClosureGuards $runtimeClosure $Platform
        $runtimeIdentity=Test-PlatformPowerShellIdentity ([string]$RuntimeReceipt.executablePath) ([string]$RuntimeReceipt.version) $Platform ([string]$RuntimeReceipt.architecture) $runtimeClosure
        $purpose = [string](Get-PlatformPreparationProperty $Policy 'pesterPurpose')
        $modulePath = [string](Get-PlatformPreparationProperty $Policy 'pesterModulePath')
        if ($purpose -ceq 'formal-gate') {
            $tools = Get-PlatformPreparationProperty $Policy 'tools'; $pester = Get-PlatformPreparationProperty $tools 'pester'; $approved = Get-PlatformPreparationProperty $pester 'approvedPayload'
            if ([string](Get-PlatformPreparationProperty $pester 'source') -cne 'PowerShellGallery:Pester' -or [string](Get-PlatformPreparationProperty $pester 'channel') -cne 'latest-stable') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Formal-gate Pester must use the approved PowerShellGallery latest-stable policy lane.') }
        } elseif ($purpose -ceq 'regression') {
            $approved = Get-PlatformPreparationProperty $Policy 'approvedPayload'
        } else { throw (New-PlatformPreparationFailure 'pester-module' $Platform "Pester purpose must be exactly 'regression' or 'formal-gate'.") }
        $version = [string](Get-PlatformPreparationProperty $approved 'version'); $approvedHash = [string](Get-PlatformPreparationProperty $approved 'sha256')
        if ($purpose -ceq 'regression' -and $version -cne '4.10.1') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Regression Pester must be exactly 4.10.1.') }
        if ($version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $approvedHash -cnotmatch '^[a-f0-9]{64}$') { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester policy lacks an approved immutable payload identity.') }
        $sourceManifest = [IO.Path]::GetFullPath($modulePath)
        [void](Test-PhysicalPlatformFile $sourceManifest $Platform 'pester-module')
        if ([IO.Path]::GetFileName($sourceManifest) -cne 'Pester.psd1' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($sourceManifest)) -cne $version) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester manifest path does not match the approved version layout.') }
        $destination = Get-VerifiedPlatformLeasePath $DestinationLease $Platform
        if ($Platform -ceq 'windows') {
            $session.Guards.Add([SyuanTsai.AIInstructions.PlatformRuntime.WindowsNative]::OpenPreparationRoot($destination))
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        }
        if (@(Get-ChildItem -Force -LiteralPath $destination).Count -ne 0) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'The Pester destination lease directory must be empty.') }
        $targetVersionRoot = Join-Path (Join-Path $destination 'Pester') $version
        $targetManifest = Join-Path $targetVersionRoot 'Pester.psd1'
        $resolver = Import-VerifiedPesterResolverModule $ResolverPath $Platform
        try {
            $payloadCommand = $resolver.ExportedCommands['Get-ApprovedPesterPayloadSha256']; $manifestCommand = $resolver.ExportedCommands['Assert-ApprovedPesterManifest']
            $payloadSnapshot=New-PlatformPesterSnapshot ([IO.Path]::GetDirectoryName($sourceManifest)) "Pester/$version" $destination $Platform
            # Validate the captured member inventory against policy BEFORE copying.
            # Generated PSGetModuleInfo.xml remains excluded by the existing
            # resolver's approved-payload contract, but bound in the full receipt.
            $expectedPayload=$payloadSnapshot.Closure
            Assert-PlatformPesterSnapshotInventory $resolver $expectedPayload.files
            $closure=[pscustomobject]@{sha256=$expectedPayload.sha256;entries=$expectedPayload.files}
            $payloadHash = & $payloadCommand -Closure $closure -Version $version
            if ([string]$payloadHash -cne $approvedHash) { throw (New-PlatformPreparationFailure 'pester-module' $Platform 'Pester payload identity is not approved for this lane.') }
            Copy-PhysicalPesterPayload ([IO.Path]::GetDirectoryName($sourceManifest)) $DestinationLease "Pester/$version" $Platform $payloadSnapshot $session
            [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
            Assert-PlatformPesterClosure $destination $expectedPayload $Platform
            if ($purpose -ceq 'regression') { Assert-RegressionPesterManifest $targetManifest }
            else { & $manifestCommand -Path $targetManifest -Version $version }
            Assert-PlatformPesterClosure $destination $expectedPayload $Platform
        } finally { Remove-Module $resolver -Force -ErrorAction SilentlyContinue }
        $escaped = $targetManifest.Replace("'","''")
        [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        $probe = "`$ProgressPreference='SilentlyContinue';`$m=Import-Module -Name '$escaped' -Force -PassThru -ErrorAction Stop;if(@(`$m).Count-ne 1){throw 'count'};[pscustomobject]@{version=`$m.Version.ToString();path=[IO.Path]::GetFullPath(`$m.Path);moduleBase=[IO.Path]::GetFullPath(`$m.ModuleBase)}|ConvertTo-Json -Compress"
        $output = Invoke-PlatformVerifiedProcess ([string]$RuntimeReceipt.executablePath) $runtimeClosure $Platform $probe $expectedPayload
        $import = [string]$output | ConvertFrom-Json -ErrorAction Stop
        $targetRootModule = Join-Path $targetVersionRoot 'Pester.psm1'
        [void](Test-PhysicalPlatformFile $targetRootModule $Platform 'pester-module')
        Assert-PlatformPesterImportIdentity $import $version $targetVersionRoot $Platform
        [void](Get-VerifiedPlatformLeasePath $DestinationLease $Platform)
        $environment=New-PlatformVerifiedProcessEnvironment ([string]$RuntimeReceipt.executablePath) $expectedPayload $Platform
        $runtimeWarningEvidence=Get-PlatformVerifiedWarningEvidence $runtimeIdentity
        $importWarningEvidence=Get-PlatformVerifiedWarningEvidence $import
        $warningSummaries=@($runtimeWarningEvidence.summaries)+@($importWarningEvidence.summaries)
        return [pscustomobject][ordered]@{ apiVersion='1.0'; purpose=$purpose; version=$version; modulePath=[IO.Path]::GetFullPath($targetManifest); approvedPayloadSha256=$payloadHash; dependencyClosureSha256=[string]$closure.sha256; moduleClosure=$expectedPayload; environmentAllowlist=$environment.Names; warningCount=([int]$runtimeWarningEvidence.count+[int]$importWarningEvidence.count); warnings=@($warningSummaries); protectionBoundary=(Get-PlatformProtectionBoundary $Platform); runtimePath=[string]$RuntimeReceipt.executablePath; os=$Platform; architecture=[string]$RuntimeReceipt.architecture }
    }
    catch {
        if ($_.Exception -is [SyuanTsai.AIInstructions.PlatformRuntime.PlatformVerificationException]) { throw }
        throw (New-PlatformPreparationFailure 'pester-module' $Platform $_.Exception.Message)
    }
    finally { Close-PlatformPesterSnapshot $payloadSnapshot; Close-PlatformPreparationSession $session; Close-PlatformPreparationSession $runtimeGuards }
}

Export-ModuleMember -Function Resolve-VerifiedPlatformPowerShell,Initialize-VerifiedPlatformPester,Test-PlatformPowerShellIdentity,New-PlatformVerifiedProcessEnvironment,Start-PlatformVerifiedProcess,Resolve-PlatformPhysicalPath,New-PlatformPrivateRoot,Invoke-PlatformPreparationCommand,Initialize-PlatformAuthorityPester,Assert-PlatformAuthorityPester
