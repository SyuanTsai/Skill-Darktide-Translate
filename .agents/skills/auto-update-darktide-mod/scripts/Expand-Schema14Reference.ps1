[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Workflow', 'ReviewBaseline')]
    [string] $Document,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$provenancePath = Join-Path $skillRoot 'references/source-provenance.json'
$integrityPath = Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1'

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    throw 'OutputDirectory must be an existing directory.'
}

$resolvedSkillRoot = [IO.Path]::GetFullPath($skillRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$resolvedOutputRoot = $outputRoot.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$skillPrefix = $resolvedSkillRoot + [IO.Path]::DirectorySeparatorChar
if (
    $resolvedOutputRoot.Equals($resolvedSkillRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedOutputRoot.StartsWith($skillPrefix, [StringComparison]::OrdinalIgnoreCase)
) {
    throw 'OutputDirectory must be outside the Skill source.'
}

$integrity = & $integrityPath -PassThru
$provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
$documentKey = if ($Document -eq 'Workflow') { 'workflow' } else { 'reviewBaseline' }
$metadata = $provenance.documents.$documentKey
$verified = $integrity.$documentKey

if ([IO.Path]::GetFileName($metadata.contentName) -ne $metadata.contentName) {
    throw 'Expanded contentName must be a filename without directory components.'
}

$packagePath = [IO.Path]::GetFullPath((Join-Path $skillRoot $metadata.packagedPath))
$outputPath = Join-Path $outputRoot $metadata.contentName
if (Test-Path -LiteralPath $outputPath) {
    throw "Refusing to replace existing output: $outputPath"
}

$created = $false
try {
    $packageStream = [IO.File]::OpenRead($packagePath)
    try {
        $gzipStream = [IO.Compression.GZipStream]::new(
            $packageStream,
            [IO.Compression.CompressionMode]::Decompress
        )
        try {
            $outputStream = [IO.File]::Open(
                $outputPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            $created = $true
            try {
                $gzipStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
            }
        }
        finally {
            $gzipStream.Dispose()
        }
    }
    finally {
        $packageStream.Dispose()
    }

    $outputFile = Get-Item -LiteralPath $outputPath
    $outputSha = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($outputFile.Length -ne [int64] $verified.sizeBytes -or $outputSha -ne $verified.sha256) {
        throw 'Expanded document failed the verified size or SHA-256 contract.'
    }
}
catch {
    if ($created -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        Remove-Item -LiteralPath $outputPath -Force
    }
    throw
}

$result = [ordered]@{
    result = 'passed'
    document = $Document
    path = $outputPath
    sourcePackage = $metadata.packagedPath
    sizeBytes = [int64] (Get-Item -LiteralPath $outputPath).Length
    sha256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

if ($PassThru) {
    [PSCustomObject] $result
}
else {
    $result | ConvertTo-Json -Depth 4
}
