# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

function Invoke-TestProcessWithEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Environment,
        [Parameter(Mandatory)][scriptblock] $ScriptBlock
    )

    $previous = [ordered]@{}
    try {
        foreach ($entry in $Environment.GetEnumerator()) {
            $name = [string]$entry.Key
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'Test process environment variable names must not be empty.' }
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $entry.Value, 'Process')
        }

        $output = @(. $ScriptBlock)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = $output
        }
    }
    finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, 'Process')
        }
    }
}

Export-ModuleMember -Function Invoke-TestProcessWithEnvironment
