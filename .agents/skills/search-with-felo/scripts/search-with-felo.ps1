#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $Query,

    [ValidateRange(1, 600)]
    [int] $TimeoutSeconds = 60
)

$modulePath = Join-Path $PSScriptRoot 'SearchWithFelo.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

$result = Invoke-FeloSearch -Query $Query -TimeoutSeconds $TimeoutSeconds
$result | ConvertTo-Json -Depth 5 -Compress

if ($result.status -ne 'ok') {
    exit 1
}
