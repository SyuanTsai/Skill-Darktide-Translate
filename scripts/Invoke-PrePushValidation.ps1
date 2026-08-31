[CmdletBinding()]
param([switch] $PassThru)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$initialState = & (Join-Path $repoRoot 'scripts/Test-CleanRepositoryHead.ps1') `
    -RepositoryRoot $repoRoot `
    -PassThru

$testOutput = @(& (Join-Path $repoRoot 'tests/Invoke-Tests.ps1'))
$testSummary = @($testOutput | Where-Object {
        $_.PSObject.Properties.Name -contains 'result' -and $_.result -ceq 'passed'
    } | Select-Object -Last 1)
if ($testSummary.Count -ne 1) {
    throw 'Repository tests did not return one passing summary.'
}

$integrity = & (Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1') `
    -PassThru
if ($integrity.result -cne 'passed') {
    throw 'Packaged reference integrity validation did not pass.'
}

$pinJson = @(& (Join-Path $repoRoot 'scripts/Get-SourcePin.ps1') -Ref $initialState.headOid) -join "`n"
$pin = $pinJson | ConvertFrom-Json
if ($pin.sourceId -cne 'darktide-translate' -or
    $pin.resolvedCommit -cne $initialState.headOid -or
    $pin.contentSha256 -notmatch '^[0-9a-f]{64}$' -or
    $pin.resolvedVersion -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw 'The reproducible source pin does not match the validated repository HEAD.'
}

$finalState = & (Join-Path $repoRoot 'scripts/Test-CleanRepositoryHead.ps1') `
    -RepositoryRoot $repoRoot `
    -ExpectedHeadOid $initialState.headOid `
    -PassThru

$result = [ordered]@{
    result = 'passed'
    headOid = $finalState.headOid
    resolvedVersion = $pin.resolvedVersion
    contentSha256 = $pin.contentSha256
    testCount = $testSummary[0].testCount
    passedCount = $testSummary[0].passedCount
}

if ($PassThru) { [PSCustomObject]$result }
else { $result | ConvertTo-Json }
