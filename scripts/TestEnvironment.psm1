# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

function ConvertFrom-TestEnvironmentText {
    param([Parameter(Mandatory)][string] $Base64)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function New-TestEnvironmentCheck {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][ValidateSet('pass', 'blocked')][string] $Status,
        [Parameter(Mandatory)][string] $Expected,
        [Parameter(Mandatory)][string] $Actual,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Remediation
    )
    [pscustomobject][ordered]@{
        id = $Id
        status = $Status
        expected = $Expected
        actual = $Actual
        remediation = $Remediation
    }
}

function Get-TestEnvironmentRelativePath {
    param([Parameter(Mandatory)][string] $BasePath, [Parameter(Mandatory)][string] $Path)
    $base = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath($Path)
    $baseUri = New-Object Uri($base)
    $targetUri = New-Object Uri($target)
    [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [IO.Path]::DirectorySeparatorChar)
}

function Test-TestEnvironmentPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Edition,
        [Parameter(Mandatory)][version] $Version,
        [Parameter(Mandatory)][version] $MinimumVersion,
        [string] $ToolRoot = '<ToolRoot>'
    )
    $expected = "PowerShell Core 7 >= $MinimumVersion"
    $actual = "$Edition $Version"
    $pass = $Edition -ceq 'Core' -and $Version.Major -eq 7 -and $Version -ge $MinimumVersion
    $remediation = if ($pass) { '' } else {
        ((ConvertFrom-TestEnvironmentText '5Z+36KGMIHNjcmlwdHMvSW5zdGFsbC1UZXN0RW52aXJvbm1lbnQucHMxIOWuieijne+8jOaIlueUqCB7MH1ccHdzaFw8dmVyc2lvbj5ccHdzaC5leGUgLU5vUHJvZmlsZSAtRmlsZSBzY3JpcHRzL1Rlc3QtVGVzdEVudmlyb25tZW50LnBzMSDln7fooYzjgII=') -f $ToolRoot)
    }
    New-TestEnvironmentCheck -Id 'powershell-runtime' -Status $(if ($pass) { 'pass' } else { 'blocked' }) `
        -Expected $expected -Actual $actual -Remediation $remediation
}

function Get-TestEnvironmentManifestVersion {
    param([Parameter(Mandatory)][string] $ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $null }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $ManifestPath
        return [version]$data.ModuleVersion
    }
    catch { return $null }
}

function Test-TestEnvironmentPester {
    [CmdletBinding()]
    param(
        [string] $ManifestPath,
        [Parameter(Mandatory)][version] $MinimumVersion,
        [string] $ExpectedSha256
    )
    $expected = "Pester manifest version >= $MinimumVersion"
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return New-TestEnvironmentCheck -Id 'pester-module' -Status blocked -Expected $expected `
            -Actual "manifest not found: $ManifestPath" `
            -Remediation (ConvertFrom-TestEnvironmentText '5Z+36KGMIHNjcmlwdHMvSW5zdGFsbC1UZXN0RW52aXJvbm1lbnQucHMxIC1Db21wb25lbnQgUGVzdGVy77yM5oiW5LulIC1QZXN0ZXJNYW5pZmVzdFBhdGgg5oyH5a6a5pyJ5pWI55qEIFBlc3Rlci5wc2Qx44CC')
    }
    $fullPath = [IO.Path]::GetFullPath($ManifestPath)
    $version = Get-TestEnvironmentManifestVersion -ManifestPath $fullPath
    $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($null -eq $version) {
        return New-TestEnvironmentCheck -Id 'pester-module' -Status blocked -Expected $expected `
            -Actual "invalid manifest: $fullPath" -Remediation (ConvertFrom-TestEnvironmentText '6YeN5paw5a6J6KOdIFBlc3Rlcu+8jG1hbmlmZXN0IOW/hemgiOWPr+eUsSBJbXBvcnQtUG93ZXJTaGVsbERhdGFGaWxlIOiugOWPluOAgg==')
    }
    if ($version -lt $MinimumVersion) {
        return New-TestEnvironmentCheck -Id 'pester-module' -Status blocked -Expected $expected `
            -Actual "Pester $version at $fullPath" -Remediation (ConvertFrom-TestEnvironmentText '5Z+36KGMIHNjcmlwdHMvSW5zdGFsbC1UZXN0RW52aXJvbm1lbnQucHMxIC1Db21wb25lbnQgUGVzdGVyIOWuieijneacgOaWsOepqeWumueJiOOAgg==')
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $actualHash -cne $ExpectedSha256.ToLowerInvariant()) {
        return New-TestEnvironmentCheck -Id 'pester-module' -Status blocked `
            -Expected "manifest sha256 $($ExpectedSha256.ToLowerInvariant())" -Actual "manifest sha256 $actualHash" `
            -Remediation (ConvertFrom-TestEnvironmentText 'UGVzdGVyIG1hbmlmZXN0IOiIhyBpbnN0YWxsLXJlY2VpcHQuanNvbiDkuI3kuIDoh7TvvJvoq4vph43mlrDlronoo53vvIzkuI3opoHnlaXpgY7pm5zmuYrpqZforYnjgII=')
    }
    New-TestEnvironmentCheck -Id 'pester-module' -Status pass -Expected $expected `
        -Actual "Pester $version; manifest sha256 $actualHash; $fullPath" -Remediation ''
}

function Test-TestEnvironmentExecutionPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExecutionPolicy,
        [Parameter(Mandatory)][bool] $IsWindows
    )
    $blocked = $IsWindows -and $ExecutionPolicy -in @('Restricted', 'AllSigned')
    New-TestEnvironmentCheck -Id 'execution-policy' -Status $(if ($blocked) { 'blocked' } else { 'pass' }) `
        -Expected (ConvertFrom-TestEnvironmentText '6Z2eIFdpbmRvd3PvvIzmiJbmnInmlYjln7fooYzljp/liYfkuI3mmK8gUmVzdHJpY3RlZO+8j0FsbFNpZ25lZA==') -Actual $ExecutionPolicy `
        -Remediation $(if ($blocked) { ConvertFrom-TestEnvironmentText '5pS555So5qiZ5rqWIHB3c2jvvIjlhbYgcG93ZXJzaGVsbC5jb25maWcuanNvbiDpoJDoqK0gUmVtb3RlU2lnbmVk77yJ5Z+36KGM77yM5LiN6KaB55SoIC1FeGVjdXRpb25Qb2xpY3kgQnlwYXNz44CC' } else { '' })
}

function Test-TestEnvironmentGitResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][int] $ExitCode,
        [AllowEmptyString()][string] $Output
    )
    $dubious = $Output -match '(?i)dubious ownership'
    $pass = $ExitCode -eq 0 -and -not $dubious
    $remediation = if ($dubious) {
        ((ConvertFrom-TestEnvironmentText 'R2l0IOWIpOWumiBkdWJpb3VzIG93bmVyc2hpcOOAguWPr+eUseS9v+eUqOiAheiHquihjOaxuuWumuaYr+WQpuWft+ihjCBnaXQgY29uZmlnIC0tZ2xvYmFsIC0tYWRkIHNhZmUuZGlyZWN0b3J5ICJ7MH0i44CC') -f $RepositoryRoot)
    }
    elseif (-not $pass) { ConvertFrom-TestEnvironmentText '6KuL5a6J6KOdIEdpdO+8jOS4pueiuuiqjSBSZXBvc2l0b3J5Um9vdCDmmK/lj6/oroDlj5bnmoQgR2l0IHdvcmt0cmVl44CC' } else { '' }
    New-TestEnvironmentCheck -Id git -Status $(if ($pass) { 'pass' } else { 'blocked' }) `
        -Expected "git -C $RepositoryRoot rev-parse --show-toplevel succeeds" `
        -Actual $(if ([string]::IsNullOrWhiteSpace($Output)) { "exit $ExitCode" } else { $Output.Trim() }) -Remediation $remediation
}

function ConvertTo-TestEnvironmentProcessArgument {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-TestEnvironmentGit {
    param([Parameter(Mandatory)][string] $GitPath, [Parameter(Mandatory)][string[]] $Arguments)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $GitPath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-TestEnvironmentProcessArgument -Value $_ }) -join ' ')
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo = $start
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr; Output = ($stdout + $stderr) }
    }
    finally { $process.Dispose() }
}

function Test-TestEnvironmentSkillPackageIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot, [string] $GitPath)
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    if ([string]::IsNullOrWhiteSpace($GitPath)) {
        try { $GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path }
        catch {
            return New-TestEnvironmentCheck -Id 'skill-package-index' -Status blocked -Expected (ConvertFrom-TestEnvironmentText 'U2tpbGwg5aWX5Lu26IiHIEdpdCBpbmRleCDlrozlhajkuIDoh7Q=') `
                -Actual 'git executable not found' -Remediation (ConvertFrom-TestEnvironmentText '5YWI5a6J6KOdIEdpdO+8jOWGjeWft+ihjOmgkOaqouOAgg==')
        }
    }
    $skillRelative = 'skills/auto-update-darktide-mod'
    $skillRoot = Join-Path $root $skillRelative
    $listed = Invoke-TestEnvironmentGit -GitPath $GitPath -Arguments @('-C', $root, 'ls-files', '-s', '-z', '--', $skillRelative)
    if ($listed.ExitCode -ne 0) {
        return New-TestEnvironmentCheck -Id 'skill-package-index' -Status blocked -Expected (ConvertFrom-TestEnvironmentText 'U2tpbGwg5aWX5Lu26IiHIEdpdCBpbmRleCDlrozlhajkuIDoh7Q=') `
            -Actual $listed.Output.Trim() -Remediation (ConvertFrom-TestEnvironmentText '5YWI5L+u5q2jIEdpdCBpbmRleCDoroDlj5bllY/poYzvvJvmraTmop3ku7bmmK8gSW50ZXJUMjAg55qE5YmN572u5qKd5Lu244CC')
    }
    $tracked = @{}
    foreach ($record in @($listed.StdOut.Split([char]0) | Where-Object { $_ })) {
        if ($record -match '^(?<mode>\d+) (?<oid>[0-9a-f]+) 0\t(?<path>.+)$') { $tracked[$Matches.path.Replace('\', '/')] = $Matches.oid }
    }
    $problems = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $skillRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force)) {
            $relative = (Get-TestEnvironmentRelativePath -BasePath $root -Path $file.FullName).Replace('\', '/')
            if (-not $tracked.ContainsKey($relative)) { $problems.Add("untracked: $relative"); continue }
            $hashed = Invoke-TestEnvironmentGit -GitPath $GitPath -Arguments @('-C', $root, 'hash-object', "--path=$relative", '--', $file.FullName)
            $oid = $hashed.StdOut.Trim()
            if ($hashed.ExitCode -ne 0 -or $oid -cne [string]$tracked[$relative]) { $problems.Add("unstaged: $relative") }
        }
    }
    foreach ($path in @($tracked.Keys)) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $path) -PathType Leaf)) { $problems.Add("missing: $path") }
    }
    $expected = ConvertFrom-TestEnvironmentText 'c2tpbGxzL2F1dG8tdXBkYXRlLWRhcmt0aWRlLW1vZCDnmoTlt6XkvZzljYDmqpTmoYjoiIcgR2l0IGluZGV4IOS4gOiHtA=='
    if ($problems.Count -eq 0) {
        return New-TestEnvironmentCheck -Id 'skill-package-index' -Status pass -Expected $expected -Actual 'clean against index' -Remediation ''
    }
    $actual = ($problems.ToArray() | Sort-Object) -join '; '
    $remediation = ConvertFrom-TestEnvironmentText '5q2k5qKd5Lu25pivIEludGVyVDIwIOeahOWJjee9ruaineS7tu+8jOWll+S7tuWkluiuiuabtOS4jeWPl+W9semfv+OAguimgee0jeWFpeaZguWft+ihjCBnaXQgYWRkIDxwYXRoPu+8m+imgeaaq+WtmOaZguWft+ihjCBnaXQgc3Rhc2ggcHVzaCAtdSAtbSA8dGFnPiAtLSA8cGF0aD7jgII='
    New-TestEnvironmentCheck -Id 'skill-package-index' -Status blocked -Expected $expected -Actual $actual -Remediation $remediation
}

Export-ModuleMember -Function ConvertFrom-TestEnvironmentText, New-TestEnvironmentCheck, Test-TestEnvironmentPowerShell, Get-TestEnvironmentManifestVersion, `
    Test-TestEnvironmentPester, Test-TestEnvironmentExecutionPolicy, Test-TestEnvironmentGitResult, Invoke-TestEnvironmentGit, `
    Test-TestEnvironmentSkillPackageIndex
