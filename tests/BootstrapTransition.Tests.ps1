# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide bootstrap transition' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryValidator = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:Supervisor = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:ProtectedWorkflow = Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-protected.yml'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:Layout = Get-TestRepositoryLayout -RepositoryRoot $script:RepositoryRoot

        function Invoke-ContainedEnvironmentProbe {
            param([string] $DiagnosticRoot, [bool] $LinuxHost)

            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -ne 0) { throw 'The supervisor must parse before constructing the environment probe.' }
            $source = [Collections.Generic.List[string]]::new()
            foreach ($name in @('Test-PathEqual', 'Assert-NoReparseAncestors', 'New-ContainedProcessEnvironment')) {
                $functionAst = $ast.Find({ param($node)
                        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
                    }, $true)
                if ($null -eq $functionAst) { throw "Missing production environment function: $name" }
                $source.Add($functionAst.Extent.Text)
            }
            # Environment behavior uses the actual directory guards; native Windows ACL handling has separate coverage.
            $source.Add('function Set-WindowsLowIntegrityDirectory { param([string] $Path) }')
            $source.Add('Export-ModuleMember -Function @()')
            $module = New-Module -ScriptBlock ([scriptblock]::Create($source -join [Environment]::NewLine))
            try {
                & $module {
                    param($Root, $Linux)
                    $script:IsLinuxHost = $Linux
                    New-ContainedProcessEnvironment -DiagnosticRoot $Root
                } $DiagnosticRoot $LinuxHost
            }
            finally { Remove-Module $module -Force }
        }

        function New-LinuxReadOnlyBindProbe {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -ne 0) { throw 'The production supervisor must parse before constructing the bind probe.' }
            $nativeFunction = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
                }, $true)
            $parameters = @($nativeFunction.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'ReadOnlyPaths' })
            $loops = @($nativeFunction.FindAll({ param($node)
                    $node -is [Management.Automation.Language.ForEachStatementAst] -and
                    $node.Variable.VariablePath.UserPath -ceq 'readOnlyPath' -and
                    $node.Condition.Extent.Text.Contains('$ReadOnlyPaths')
                }, $true))
            if ($parameters.Count -ne 1 -or $loops.Count -ne 1) { throw 'Expected one production read-only path parameter and loop.' }
            $source = [Collections.Generic.List[string]]::new()
            foreach ($name in @('Test-PathEqual', 'Assert-NoReparseAncestors')) {
                $functionAst = $ast.Find({ param($node)
                        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
                    }, $true)
                if ($null -eq $functionAst) { throw "Missing production path guard: $name" }
                $source.Add($functionAst.Extent.Text)
            }
            $source.Add('function Invoke-LinuxReadOnlyBindProbe {')
            $source.Add('param(' + $parameters[0].Extent.Text + ')')
            $source.Add('$ErrorActionPreference = ''Stop''')
            $source.Add('$Context = ''Linux read-only bind regression''')
            $source.Add('$linuxReadonlyBindPaths = [Collections.Generic.List[string]]::new()')
            $source.Add($loops[0].Extent.Text)
            $source.Add('$linuxReadonlyBindPaths.ToArray()')
            $source.Add('}')
            $source.Add('Export-ModuleMember -Function @()')
            New-Module -ScriptBlock ([scriptblock]::Create($source -join [Environment]::NewLine))
        }

        function New-LinuxChildReapingProbe {
            param(
                [Parameter(Mandatory = $true)][hashtable] $Records,
                [Parameter()][int] $OpenResult = 71,
                [Parameter()][int] $SendResult = 0,
                [Parameter()][int] $ReapResult = 0,
                [Parameter()][bool] $ReapRemovesIdentity = $true,
                [Parameter()][bool] $IdentityChangesAfterOpen = $false,
                [Parameter()][int] $ZombieAfterFinalSignalProcessId = 0,
                [Parameter()][int] $ZombieAfterFinalSignalParentProcessId = 0
            )

            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -ne 0) { throw 'The production supervisor must parse before constructing the child-reaping probe.' }
            $stopUnix = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Stop-UnixProcessByIdentity'
                }, $true)
            $stopTree = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Stop-ProcessTree'
                }, $true)
            if ($null -eq $stopUnix -or $null -eq $stopTree) { throw 'Missing production process-cleanup function.' }

            $typeSuffix = [guid]::NewGuid().ToString('N')
            $className = "FakeUnixBoundary_$typeSuffix"
            $typeName = "Syp158.TestDoubles.$className"
            $nativeSource = @"
namespace Syp158.TestDoubles {
    public static class $className {
        public static int OpenResult { get; set; }
        public static int SendResult { get; set; }
        public static int ReapResult { get; set; }
        public static int OpenCount { get; set; }
        public static int SendCount { get; set; }
        public static int ReapCount { get; set; }
        public static int CloseCount { get; set; }
        public static int LastOpenedProcessId { get; set; }
        public static int LastReapedProcessId { get; set; }
        public static System.Collections.Generic.List<int> SignalValues { get; } = new System.Collections.Generic.List<int>();
        public static System.Collections.Generic.List<int> SignalProcessIds { get; } = new System.Collections.Generic.List<int>();
        public static int OpenProcessFileDescriptor(int processId) { OpenCount++; LastOpenedProcessId = processId; return OpenResult; }
        public static int SendProcessSignal(int fileDescriptor, int signal) { SendCount++; SignalValues.Add(signal); SignalProcessIds.Add(LastOpenedProcessId); return SendResult; }
        public static int ReapExitedProcessFileDescriptor(int fileDescriptor) { ReapCount++; LastReapedProcessId = LastOpenedProcessId; return ReapResult; }
        public static int CloseProcessFileDescriptor(int fileDescriptor) { CloseCount++; return 0; }
    }
}
"@
            $nativeType = @(Add-Type -TypeDefinition $nativeSource -PassThru)[0]
            $nativeType::OpenResult = $OpenResult
            $nativeType::SendResult = $SendResult
            $nativeType::ReapResult = $ReapResult

            $source = [Collections.Generic.List[string]]::new()
            $source.Add(@'
function Enable-UnixChildSubreaper { }
function Test-ProcessIdentity {
    param([int] $ProcessId, [string] $Identity)
    $record = $script:FakeRecords[[int]$ProcessId]
    if ($null -eq $record -or -not [bool]$record.exists) { return $false }
    if ($script:ReapRemovesIdentity -and $script:FakeNativeType::ReapResult -eq 0 -and
        $script:FakeNativeType::LastReapedProcessId -eq $ProcessId) { return $false }
    return ([string]$record.identity -ceq $Identity)
}
function Get-ProcessIdentity {
    param([int] $ProcessId)
    $record = $script:FakeRecords[[int]$ProcessId]
    if ($null -eq $record -or -not [bool]$record.exists -or
        ($script:ReapRemovesIdentity -and $script:FakeNativeType::ReapResult -eq 0 -and
            $script:FakeNativeType::LastReapedProcessId -eq $ProcessId)) {
        throw "Process $ProcessId is absent."
    }
    if ($script:IdentityChangesAfterOpen -and $script:FakeNativeType::OpenCount -gt 0) {
        return ([string]$record.identity + '-replaced')
    }
    return [string]$record.identity
}
function Get-UnixProcessInfo {
    param([int] $ProcessId)
    $record = $script:FakeRecords[[int]$ProcessId]
    if ($null -eq $record -or -not [bool]$record.exists) { throw "Process $ProcessId is absent." }
    return [pscustomobject]@{
        processId = $ProcessId
        parentProcessId = [int]$record.parentProcessId
        processGroupId = [int]$record.processGroupId
        startTime = 'fake-start'
        state = [string]$record.state
    }
}
function Test-ProcessIdExists {
    param([int] $ProcessId)
    $record = $script:FakeRecords[[int]$ProcessId]
    return ($null -ne $record -and [bool]$record.exists -and
        -not ($script:ReapRemovesIdentity -and $script:FakeNativeType::ReapResult -eq 0 -and
            $script:FakeNativeType::LastReapedProcessId -eq $ProcessId))
}
function Get-UnixProcessGroupId { param([int] $ProcessId) return 0 }
function Get-UnixProcessGroupProcessIds { param([int] $ProcessGroupId) return @() }
function Add-ObservedProcessIds { param([int] $RootProcessId, $ObservedProcessIdentities, [int] $ProcessGroupId) }
function Start-Sleep {
    param([int] $Milliseconds)
    if ($script:ZombieAfterFinalSignalProcessId -gt 0 -and
        $script:FakeNativeType::SignalValues.Count -gt 0 -and
        $script:FakeNativeType::SignalValues[$script:FakeNativeType::SignalValues.Count - 1] -eq 9) {
        $record = $script:FakeRecords[[int]$script:ZombieAfterFinalSignalProcessId]
        if ($null -ne $record) {
            $record.state = 'Z'
            $record.parentProcessId = if ($script:ZombieAfterFinalSignalParentProcessId -gt 0) {
                $script:ZombieAfterFinalSignalParentProcessId
            }
            else { $PID }
        }
    }
}
'@)
            $source.Add($stopUnix.Extent.Text.Replace('Codex.Validation.UnixProcessBoundary', $typeName))
            $source.Add($stopTree.Extent.Text)
            $source.Add('Export-ModuleMember -Function @()')
            $module = New-Module -ScriptBlock ([scriptblock]::Create($source -join [Environment]::NewLine))
            return [pscustomobject]@{
                Module = $module; NativeType = $nativeType; Records = $Records
                ReapRemovesIdentity = $ReapRemovesIdentity; IdentityChangesAfterOpen = $IdentityChangesAfterOpen
                ZombieAfterFinalSignalProcessId = $ZombieAfterFinalSignalProcessId
                ZombieAfterFinalSignalParentProcessId = $ZombieAfterFinalSignalParentProcessId
            }
        }

        function Invoke-LinuxChildReapingProbe {
            param(
                [Parameter(Mandatory = $true)] $Probe,
                [Parameter(Mandatory = $true)][scriptblock] $Action,
                [Parameter()][object[]] $Arguments = @()
            )
            & $Probe.Module {
                param($Records, $NativeType, $ReapRemovesIdentity, $IdentityChangesAfterOpen, $ZombieAfterFinalSignalProcessId, $ZombieAfterFinalSignalParentProcessId, $ActionText, $Arguments)
                $script:IsWindowsHost = $false
                $script:IsLinuxHost = $true
                $script:IsSupportedProcessBoundaryHost = $true
                $script:FakeRecords = $Records
                $script:FakeNativeType = $NativeType
                $script:ReapRemovesIdentity = $ReapRemovesIdentity
                $script:IdentityChangesAfterOpen = $IdentityChangesAfterOpen
                $script:ZombieAfterFinalSignalProcessId = $ZombieAfterFinalSignalProcessId
                $script:ZombieAfterFinalSignalParentProcessId = $ZombieAfterFinalSignalParentProcessId
                & ([scriptblock]::Create($ActionText)) @Arguments
            } $Probe.Records $Probe.NativeType $Probe.ReapRemovesIdentity $Probe.IdentityChangesAfterOpen $Probe.ZombieAfterFinalSignalProcessId $Probe.ZombieAfterFinalSignalParentProcessId $Action.ToString() $Arguments
        }

        function Invoke-LinuxEtcProjectionProbe {
            param(
                [Parameter(Mandatory = $true)][string] $SourceRoot,
                [Parameter(Mandatory = $true)][string] $DestinationRoot,
                [Parameter(Mandatory = $true)]
                [ValidateSet('DirectorySelection', 'FileSelection', 'DirectoryCopy', 'FileCopy')][string] $Mode
            )

            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -ne 0) { throw 'The supervisor must parse before constructing the etc probe.' }
            $nativeFunction = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-NativeChecked'
                }, $true)
            $payloads = @($nativeFunction.FindAll({ param($node)
                    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Value.Contains('for system_root in /usr ')
                }, $true))
            if ($payloads.Count -ne 1) { throw 'Expected one actual Linux native launcher payload.' }
            $blocks = @([regex]::Matches($payloads[0].Value,
                    '(?ms)^ {12}"\$find_path" "\$system_root" [^\r\n]* -exec /bin/sh -eu -c ''\r?\n.*?^ {12}'' sh "\$system_root" "\$target" \{\} \+[^\r\n]*'))
            if ($blocks.Count -ne 2) { throw 'Expected the actual directory and file projection batches.' }
            $blockIndex = if ($Mode.StartsWith('Directory')) { 0 } else { 1 }
            $commandText = $blocks[$blockIndex].Value
            if ($Mode.EndsWith('Selection')) {
                $commandText = ($commandText -split ' -exec ', 2)[0] + ' -print'
            }
            $shellPath = $null
            if ($IsWindows) {
                $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $gitParent = Split-Path -Parent $gitCommand.Path
                for ($depth = 0; $depth -lt 3 -and $null -eq $shellPath; $depth++) {
                    $candidateShell = Join-Path $gitParent 'usr/bin/sh.exe'
                    if (Test-Path -LiteralPath $candidateShell -PathType Leaf) { $shellPath = $candidateShell }
                    $gitParent = Split-Path -Parent $gitParent
                }
                if ($null -eq $shellPath) { throw 'The etc regression requires the POSIX shell included with Git for Windows.' }
            }
            else {
                $shellPath = (Get-Command sh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
            }
            $probePath = Join-Path $TestDrive ('etc-probe-' + [guid]::NewGuid().ToString('N') + '.sh')
            $header = @'
set -eu
PATH=/usr/bin:/bin
export PATH
system_root="$1"
target="$2"
find_path=/usr/bin/find
'@
            [IO.File]::WriteAllText($probePath, ($header + "`n" + $commandText + "`n").Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
            $priorErrorAction = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = @(& $shellPath $probePath.Replace('\', '/') $SourceRoot.Replace('\', '/') $DestinationRoot.Replace('\', '/') 2>&1)
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $priorErrorAction }
            [pscustomobject]@{ ExitCode = $exitCode; Output = @($output | ForEach-Object { [string]$_ }) }
        }

        function New-ValidatorGitSnapshot {
            param([Parameter(Mandatory = $true)][string] $Destination)

            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            foreach ($item in @(Get-ChildItem -LiteralPath $script:RepositoryRoot -Force |
                    Where-Object { $_.Name -cne '.git' })) {
                Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
            }
            & git -C $Destination init --quiet --initial-branch=main
            if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the validator Git snapshot.' }
            & git -C $Destination config user.name 'Protected Validator Snapshot'
            & git -C $Destination config user.email 'protected-validator@example.invalid'
            & git -C $Destination add --all
            & git -C $Destination commit --quiet -m 'protected validator snapshot'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to commit the validator Git snapshot.' }
            return $Destination
        }

        $script:ValidatorRepositoryRoot = New-ValidatorGitSnapshot `
            -Destination (Join-Path $TestDrive 'validator-repository-snapshot')
    }

    It 'UnitT10_ValidatesExactlyOneBoundedRepositoryLayout' {
        # Scenario: The protected suite runs against either the current legacy tree or a Standard v1 migration candidate.
        # Purpose: Keep both accepted structures explicit while requiring the matching validator mode.
        if ($script:Layout.Name -ceq 'legacy') {
            $reportPath = Join-Path $TestDrive 'bootstrap-repository-report.json'
            $output = @(& $script:RepositoryValidator `
                    -RepositoryRoot $script:ValidatorRepositoryRoot `
                    -BootstrapTransition `
                    -OutputPath $reportPath)
            $result = ($output | Select-Object -Last 1) | ConvertFrom-Json

            $result.result | Should -Be 'passed'
            $result.validationMode | Should -Be 'bootstrap-transition'
            $result.skillsRoot | Should -Be '.agents/skills'
            $result.activeSkillCount | Should -Be 1
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
        }
        else {
            $reportPath = Join-Path $TestDrive 'standard-v1-repository-report.json'
            $output = @(& $script:RepositoryValidator `
                    -RepositoryRoot $script:ValidatorRepositoryRoot `
                    -OutputPath $reportPath)
            $result = ($output | Select-Object -Last 1) | ConvertFrom-Json

            $result.result | Should -Be 'passed'
            $result.sourceId | Should -Be 'darktide-translate'
            $result.skillsRoot | Should -Be 'skills'
            $result.activeSkillCount | Should -Be 1
            Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
        }
    }

    It 'UnitT20_RejectsAnUnauthorizedValidatorMode' {
        # Scenario: A caller selects a validator mode that does not belong to the repository's bounded layout.
        # Purpose: Prevent legacy authorization from being reused after Standard v1 promotion and prevent normal validation from bypassing legacy transition authorization.
        if ($script:Layout.Name -ceq 'legacy') {
            { & $script:RepositoryValidator -RepositoryRoot $script:ValidatorRepositoryRoot } |
                Should -Throw '*Standard v1*'
        }
        else {
            { & $script:RepositoryValidator -RepositoryRoot $script:ValidatorRepositoryRoot -BootstrapTransition } |
                Should -Throw '*catalog/skills-catalog.json fixture*'
        }
    }

    It 'UnitT25_RejectsMixedMissingAndUnauthorizedLayouts' {
        # Scenario: A migration candidate has both layout markers, only part of a layout, or an unrelated source root.
        # Purpose: Prove the protected test resolver does not widen the migration path to arbitrary directories or silently accept missing configuration.
        $mixedRoot = Join-Path $TestDrive 'mixed-layout'
        New-Item -ItemType Directory -Path (Join-Path $mixedRoot 'catalog'), (Join-Path $mixedRoot 'config'),
            (Join-Path $mixedRoot '.agents/skills/auto-update-darktide-mod'), (Join-Path $mixedRoot 'skills/auto-update-darktide-mod') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mixedRoot 'catalog/skills-catalog.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $mixedRoot 'catalog/source.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $mixedRoot 'config/standard-v1.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $mixedRoot } |
            Should -Throw '*mixed*'

        $incompleteRoot = Join-Path $TestDrive 'incomplete-layout'
        New-Item -ItemType Directory -Path (Join-Path $incompleteRoot 'catalog') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $incompleteRoot 'catalog/source.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $incompleteRoot } |
            Should -Throw '*incomplete or unauthorized*'

        $unauthorizedRoot = Join-Path $TestDrive 'unauthorized-layout'
        New-Item -ItemType Directory -Path (Join-Path $unauthorizedRoot 'catalog'), (Join-Path $unauthorizedRoot 'extensions/skills/auto-update-darktide-mod') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $unauthorizedRoot 'catalog/source.json') -Value '{}'
        { Get-TestRepositoryLayout -RepositoryRoot $unauthorizedRoot } |
            Should -Throw '*incomplete or unauthorized*'

        if ($script:Layout.Name -ceq 'standard-v1') {
            $missingConfigRoot = New-ValidatorGitSnapshot `
                -Destination (Join-Path $TestDrive 'standard-v1-missing-config')
            Remove-Item -LiteralPath (Join-Path $missingConfigRoot 'config/standard-v1.json') -Force
            { & $script:RepositoryValidator -RepositoryRoot $missingConfigRoot } |
                Should -Throw '*standard-v1.json*'

            $mixedCandidateRoot = New-ValidatorGitSnapshot `
                -Destination (Join-Path $TestDrive 'standard-v1-mixed-candidate')
            Set-Content -LiteralPath (Join-Path $mixedCandidateRoot 'catalog/skills-catalog.json') -Value '{}'
            { & $script:RepositoryValidator -RepositoryRoot $mixedCandidateRoot } |
                Should -Throw '*must not coexist*'
        }
    }

    It 'UnitT30_SelectsBootstrapOnlyWhenTheCandidateHasNotMigratedToStandardV1' {
        # Scenario: The protected workflow sees either the current bootstrap layout or the migrated layout.
        # Purpose: Keep transition success explicit and prevent a mixed or post-migration tree from taking the legacy path.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match '\[switch\] \$BootstrapTransition'
        $workflow | Should -Match 'BootstrapTransition'
        $workflow | Should -Match 'config/standard-v1\.json'
        $workflow | Should -Match 'catalog/skills-catalog\.json'
    }

    It 'UnitT40_UsesAnOSNativeWindowsProcessSnapshotForCleanup' {
        # Scenario: The host denies WMI process enumeration even though native process controls are available.
        # Purpose: Keep process-tree cleanup bound to an OS-native snapshot instead of weakening identity or cleanup assertions.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'CreateToolhelp32Snapshot'
        $supervisor | Should -Match 'Process32FirstW'
        $supervisor | Should -Match 'Process32NextW'
        $supervisor | Should -Not -Match 'Get-CimInstance\s+-ClassName\s+Win32_Process'
    }

    It 'UnitT50_BindsBootstrapToTheExpectedChangedPathSetAndBaseCommit' {
        # Scenario: A bootstrap candidate could otherwise select the legacy path while changing arbitrary repository content.
        # Purpose: Require an immutable base comparison and a narrow transition-only changed-path contract.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'Bootstrap transition requires a distinct base commit'
        $supervisor | Should -Match 'Bootstrap transition changed-path allowlist'
        $supervisor | Should -Match '\.github/workflows/standard-v1-protected\.yml'
        $supervisor | Should -Match 'scripts/Test-Repository\.ps1'
        $supervisor | Should -Match 'scripts/Validate\.ps1'
        $supervisor | Should -Match 'tests/validate-windows-powershell\.ps1'
        $supervisor | Should -Match 'Bootstrap transition bounded cancellation probe'
    }

    It 'UnitT52_AllowsExactBootstrapMaintenancePathsWithoutRequiringAnchorEdits' {
        # Scenario: A reviewed maintenance PR changes exactly one trusted test while every anchor remains a regular blob in both commits.
        # Purpose: Permit the fixed twelve-suite and TestSupport foundation without widening bootstrap to catalog, config, or Skill content.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-BootstrapTransitionChangedPaths'
        }, $true))
        $functionAst.Count | Should -Be 1
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst[0].Extent.Text))

        $gitPath = [IO.Path]::GetFullPath([string](Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path)
        $maintenancePaths = @(
            'tests/BootstrapTransition.Tests.ps1', 'tests/CanonicalValidation.Tests.ps1',
            'tests/LocalizationWorkset.Tests.ps1', 'tests/ModUpdateAutomation.Tests.ps1',
            'tests/RepositoryContract.Tests.ps1', 'tests/RepositoryValidation.Tests.ps1',
            'tests/Schema15Coordination.Tests.ps1', 'tests/Schema15SourceAcquisition.Tests.ps1',
            'tests/SkillContract.Tests.ps1', 'tests/SourcePin.Tests.ps1',
            'tests/StandardV1Conformance.Tests.ps1', 'tests/Test-Repository.Tests.ps1',
            'tests/TestSupport.ps1'
        )
        try {
            foreach ($maintenancePath in $maintenancePaths) {
                $fixture = Join-Path $TestDrive ("bootstrap-maintenance-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fixture -Force | Out-Null
                foreach ($anchor in @(
                    '.github/workflows/standard-v1-protected.yml', 'scripts/Test-Repository.ps1',
                    'scripts/Validate.ps1', 'tests/validate-windows-powershell.ps1'
                )) {
                    $anchorPath = Join-Path $fixture $anchor
                    New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                    [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
                }
                $path = Join-Path $fixture $maintenancePath
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                [IO.File]::WriteAllText($path, 'base test', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture init --quiet --initial-branch=main
                & $gitPath -C $fixture config user.name 'Bootstrap fixture'
                & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
                & $gitPath -C $fixture add --all
                & $gitPath -C $fixture commit --quiet -m base
                $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                [IO.File]::WriteAllText($path, 'maintenance update', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture add -- $maintenancePath
                & $gitPath -C $fixture commit --quiet -m maintenance
                $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                {
                    & $guardModule {
                        param($GitPath, $RepositoryRoot, $BaseCommit, $CandidateCommit)
                        Assert-BootstrapTransitionChangedPaths -GitPath $GitPath -RepositoryRoot $RepositoryRoot -BaseCommit $BaseCommit -CandidateCommit $CandidateCommit
                    } $gitPath $fixture $baseCommit $candidateCommit
                } | Should -Not -Throw
            }
        }
        finally {
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT54_RejectsBootstrapPathsAndStatusesOutsideTheExactContract' {
        # Scenario: A bootstrap range contains a catalog, Skill, or unknown path change, a deletion, or a rename.
        # Purpose: Keep maintenance within the exact allowed paths and A/M statuses.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-BootstrapTransitionChangedPaths'
        }, $true))
        $functionAst.Count | Should -Be 1
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst[0].Extent.Text))
        $gitPath = [IO.Path]::GetFullPath([string](Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path)
        try {
            foreach ($case in @(
                [pscustomobject]@{ Name = 'catalog'; Path = 'catalog/source.json'; Action = 'modify' },
                [pscustomobject]@{ Name = 'skill'; Path = 'skills/auto-update-darktide-mod/SKILL.md'; Action = 'modify' },
                [pscustomobject]@{ Name = 'unknown'; Path = 'docs/unrelated.md'; Action = 'modify' },
                [pscustomobject]@{ Name = 'delete'; Path = 'tests/TestSupport.ps1'; Action = 'delete' },
                [pscustomobject]@{ Name = 'rename'; Path = 'tests/TestSupport.ps1'; Action = 'rename' }
            )) {
                $fixture = Join-Path $TestDrive ("bootstrap-reject-$($case.Name)-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fixture -Force | Out-Null
                foreach ($anchor in @(
                    '.github/workflows/standard-v1-protected.yml', 'scripts/Test-Repository.ps1',
                    'scripts/Validate.ps1', 'tests/validate-windows-powershell.ps1'
                )) {
                    $anchorPath = Join-Path $fixture $anchor
                    New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                    [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
                }
                $casePath = Join-Path $fixture $case.Path
                New-Item -ItemType Directory -Path (Split-Path -Parent $casePath) -Force | Out-Null
                [IO.File]::WriteAllText($casePath, 'base payload', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture init --quiet --initial-branch=main
                & $gitPath -C $fixture config user.name 'Bootstrap fixture'
                & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
                & $gitPath -C $fixture add --all
                & $gitPath -C $fixture commit --quiet -m base
                $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                switch ($case.Action) {
                    'modify' { [IO.File]::WriteAllText($casePath, 'changed payload', [Text.UTF8Encoding]::new($false)) }
                    'delete' { Remove-Item -LiteralPath $casePath -Force }
                    'rename' { Move-Item -LiteralPath $casePath -Destination ($casePath + '.renamed') }
                }
                & $gitPath -C $fixture add --all
                & $gitPath -C $fixture commit --quiet -m $case.Name
                $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
                {
                    & $guardModule {
                        param($GitPath, $RepositoryRoot, $BaseCommit, $CandidateCommit)
                        Assert-BootstrapTransitionChangedPaths -GitPath $GitPath -RepositoryRoot $RepositoryRoot -BaseCommit $BaseCommit -CandidateCommit $CandidateCommit
                    } $gitPath $fixture $baseCommit $candidateCommit
                } | Should -Throw
            }
        }
        finally {
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT55_RejectsCredentialBackedSemanticValidationOnWindowsBeforeEnvironmentCapture' {
        # Scenario: A Windows protected-Pester boundary receives a nonblank semantic credential name.
        # Purpose: Reject the request before any environment value is read, because that boundary does not establish credential confidentiality.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $protectorAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Protect-ProcessCredentialEnvironment'
        }, $true))
        $protectorAst.Count | Should -Be 1
        $hostSupportAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-SemanticCredentialHostSupport'
        }, $true))
        $expectedError = 'Credential-backed semantic validation is not supported on Windows because the protected Pester boundary does not establish credential confidentiality.'
        $syntheticCredentialName = 'SEMANTIC_CREDENTIAL_TEST_' + [guid]::NewGuid().ToString('N')
        (Test-Path -LiteralPath ("Env:$syntheticCredentialName")) | Should -BeFalse

        $moduleSource = '$script:IsWindowsHost = $true' + [Environment]::NewLine
        if ($hostSupportAst.Count -eq 1) { $moduleSource += $hostSupportAst[0].Extent.Text + [Environment]::NewLine }
        $moduleSource += $protectorAst[0].Extent.Text
        $credentialModule = New-Module -ScriptBlock ([scriptblock]::Create($moduleSource))
        $failures = [Collections.Generic.List[string]]::new()
        try {
            if ($hostSupportAst.Count -ne 1) {
                $failures.Add('Assert-SemanticCredentialHostSupport must exist exactly once.')
            }
            else {
                $hostSupportText = $hostSupportAst[0].Extent.Text
                if ($hostSupportText -notmatch '(?s)\[string\[\]\]\s+\$SemanticCredentialNames') {
                    $failures.Add('Assert-SemanticCredentialHostSupport must declare [string[]] $SemanticCredentialNames.')
                }
                foreach ($case in @(
                    [pscustomobject]@{ Name = 'null'; Names = $null },
                    [pscustomobject]@{ Name = 'empty'; Names = [string[]]@() },
                    [pscustomobject]@{ Name = 'whitespace'; Names = [string[]]@('', ' ', "`t") }
                )) {
                    try {
                        & $credentialModule {
                            param($names)
                            $script:IsWindowsHost = $true
                            Assert-SemanticCredentialHostSupport -SemanticCredentialNames $names
                        } $case.Names
                    }
                    catch {
                        $failures.Add("Windows $($case.Name) semantic credential names must be accepted: $($_.Exception.Message)")
                    }
                }
                $windowsFailure = $null
                try {
                    & $credentialModule {
                        $script:IsWindowsHost = $true
                        Assert-SemanticCredentialHostSupport -SemanticCredentialNames @('SEMANTIC_CREDENTIAL_TEST')
                    }
                }
                catch { $windowsFailure = $_ }
                if ($null -eq $windowsFailure -or $windowsFailure.Exception.Message -cne $expectedError) {
                    $actual = if ($null -eq $windowsFailure) { 'no error' } else { $windowsFailure.Exception.Message }
                    $failures.Add("Windows nonblank semantic credential names must throw the exact unsupported-host error; actual=$actual")
                }
                try {
                    & $credentialModule {
                        $script:IsWindowsHost = $false
                        Assert-SemanticCredentialHostSupport -SemanticCredentialNames @('SEMANTIC_CREDENTIAL_TEST')
                    }
                }
                catch {
                    $failures.Add("Linux semantic credential names must be accepted: $($_.Exception.Message)")
                }
            }

            $protectorFailure = $null
            try {
                & $credentialModule {
                    param($name)
                    $script:IsWindowsHost = $true
                    Protect-ProcessCredentialEnvironment -SemanticCredentialNames @($name)
                } $syntheticCredentialName
            }
            catch { $protectorFailure = $_ }
            if ($null -eq $protectorFailure -or $protectorFailure.Exception.Message -cne $expectedError) {
                $actual = if ($null -eq $protectorFailure) { 'no error' } else { $protectorFailure.Exception.Message }
                $failures.Add("Protect-ProcessCredentialEnvironment must reject before reading the absent synthetic environment name; actual=$actual")
            }

            if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
        }
        finally {
            Remove-Module $credentialModule -Force
        }
    }

    It 'UnitT56_RequiresEveryBootstrapAnchorToBeARegularTrackedBlobAtBothRangeEnds' {
        # Scenario: A maintenance-only diff retains an absent, directory, or symbolic-link anchor at both range ends; a separate legacy-shaped range restores a missing base anchor while changing all four anchors.
        # Purpose: Keep all four trust anchors as tracked regular blobs at both endpoints of maintenance and legacy four-anchor updates.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-BootstrapTransitionChangedPaths'
        }, $true))
        $functionAst.Count | Should -Be 1
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst[0].Extent.Text))
        $gitPath = [IO.Path]::GetFullPath([string](Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path)
        $anchors = @(
            '.github/workflows/standard-v1-protected.yml', 'scripts/Test-Repository.ps1',
            'scripts/Validate.ps1', 'tests/validate-windows-powershell.ps1'
        )
        $invokeGuard = {
            param($GitPath, $GuardModule, $Fixture, $BaseCommit, $CandidateCommit)
            & $GuardModule {
                param($InnerGitPath, $RepositoryRoot, $InnerBaseCommit, $InnerCandidateCommit)
                Assert-BootstrapTransitionChangedPaths -GitPath $InnerGitPath -RepositoryRoot $RepositoryRoot -BaseCommit $InnerBaseCommit -CandidateCommit $InnerCandidateCommit
            } $GitPath $Fixture $BaseCommit $CandidateCommit
        }
        try {
            foreach ($case in @('missing', 'tree', 'symlink')) {
                $fixture = Join-Path $TestDrive ("bootstrap-anchor-$case-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $fixture -Force | Out-Null
                foreach ($anchor in $anchors) {
                    $anchorPath = Join-Path $fixture $anchor
                    New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                    [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
                }
                $supportPath = Join-Path $fixture 'tests/TestSupport.ps1'
                [IO.File]::WriteAllText($supportPath, 'base support', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture init --quiet --initial-branch=main
                & $gitPath -C $fixture config user.name 'Bootstrap fixture'
                & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
                $anchorPath = Join-Path $fixture 'scripts/Validate.ps1'
                $symlinkObjectId = ''
                switch ($case) {
                    'missing' { Remove-Item -LiteralPath $anchorPath -Force }
                    'tree' {
                        Remove-Item -LiteralPath $anchorPath -Force
                        New-Item -ItemType Directory -Path $anchorPath -Force | Out-Null
                        [IO.File]::WriteAllText((Join-Path $anchorPath 'nested.ps1'), 'nested', [Text.UTF8Encoding]::new($false))
                    }
                    'symlink' {
                        $symlinkObjectId = ('symlink-target' | & $gitPath -C $fixture hash-object -w --stdin).Trim()
                    }
                }
                & $gitPath -C $fixture add --all
                if ($case -ceq 'symlink') {
                    & $gitPath -C $fixture update-index --add --cacheinfo "120000,$symlinkObjectId,scripts/Validate.ps1"
                }
                & $gitPath -C $fixture commit --quiet -m "base-$case"
                $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()

                [IO.File]::WriteAllText($supportPath, 'maintenance support', [Text.UTF8Encoding]::new($false))
                & $gitPath -C $fixture add -- 'tests/TestSupport.ps1'
                & $gitPath -C $fixture commit --quiet -m "maintenance-$case"
                $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
                $failure = $null
                try {
                    & $invokeGuard $gitPath $guardModule $fixture $baseCommit $candidateCommit
                }
                catch {
                    $failure = $_
                }
                $failure | Should -Not -BeNullOrEmpty
                $failure.Exception.Message | Should -Match 'tracked regular trust anchor'
            }

            $fixture = Join-Path $TestDrive ('bootstrap-anchor-base-missing-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            foreach ($anchor in $anchors) {
                $anchorPath = Join-Path $fixture $anchor
                New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
            }
            $supportPath = Join-Path $fixture 'tests/TestSupport.ps1'
            [IO.File]::WriteAllText($supportPath, 'base support', [Text.UTF8Encoding]::new($false))
            Remove-Item -LiteralPath (Join-Path $fixture 'scripts/Validate.ps1') -Force
            & $gitPath -C $fixture init --quiet --initial-branch=main
            & $gitPath -C $fixture config user.name 'Bootstrap fixture'
            & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m base-missing-anchor
            $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            foreach ($anchor in $anchors) {
                $anchorPath = Join-Path $fixture $anchor
                New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                [IO.File]::WriteAllText($anchorPath, "candidate $anchor", [Text.UTF8Encoding]::new($false))
            }
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m candidate-restores-anchor
            $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            $failure = $null
            try {
                & $invokeGuard $gitPath $guardModule $fixture $baseCommit $candidateCommit
            }
            catch {
                $failure = $_
            }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -Match 'tracked regular trust anchor'

            $fixture = Join-Path $TestDrive ('bootstrap-anchor-legacy-success-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            foreach ($anchor in $anchors) {
                $anchorPath = Join-Path $fixture $anchor
                New-Item -ItemType Directory -Path (Split-Path -Parent $anchorPath) -Force | Out-Null
                [IO.File]::WriteAllText($anchorPath, "base $anchor", [Text.UTF8Encoding]::new($false))
            }
            & $gitPath -C $fixture init --quiet --initial-branch=main
            & $gitPath -C $fixture config user.name 'Bootstrap fixture'
            & $gitPath -C $fixture config user.email 'bootstrap@example.invalid'
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m base
            $baseCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            foreach ($anchor in $anchors) {
                [IO.File]::WriteAllText((Join-Path $fixture $anchor), "candidate $anchor", [Text.UTF8Encoding]::new($false))
            }
            & $gitPath -C $fixture add --all
            & $gitPath -C $fixture commit --quiet -m candidate-all-anchors
            $candidateCommit = (& $gitPath -C $fixture rev-parse HEAD).Trim()
            {
                & $invokeGuard $gitPath $guardModule $fixture $baseCommit $candidateCommit
            } | Should -Not -Throw
        }
        finally {
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT57_BindsCanonicalWorkflowValidatorArgumentsByNameForBothLayouts' {
        # Scenario: The protected workflow invokes the trusted validator from candidate roots and runner paths containing spaces.
        # Purpose: Require its real call-site fragment to bind the repository, artifacts, comparison base, Go runtime, output, and bootstrap switch by their declared parameter names.
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw
        $snippetStart = $workflow.IndexOf("`$outputPath = Join-Path `$env:RUNNER_TEMP 'darktide-translate-conformance-report.json'", [StringComparison]::Ordinal)
        $snippetEndMarker = '& $trustedValidator @validatorArguments'
        $snippetEnd = $workflow.IndexOf($snippetEndMarker, $snippetStart, [StringComparison]::Ordinal)
        $snippetStart | Should -BeGreaterOrEqual 0
        $snippetEnd | Should -BeGreaterThan $snippetStart
        $workflowSnippet = [scriptblock]::Create($workflow.Substring($snippetStart, $snippetEnd + $snippetEndMarker.Length - $snippetStart))

        $tokens = $null
        $parseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $validatorParamBlock = $validatorAst.ParamBlock.Extent.Text
        $validatorParamBlock | Should -Match '\[switch\] \$BootstrapTransition'

        $environmentNames = @('RUNNER_TEMP', 'TRUSTED_SUPERVISOR_ROOT', 'STANDARD_GO_RUNTIME_VERSION')
        $environmentBefore = @{}
        foreach ($name in $environmentNames) {
            $environmentBefore[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        }

        try {
            foreach ($fixture in @(
                [pscustomobject]@{ Name = 'legacy bootstrap'; BootstrapTransition = $true },
                [pscustomobject]@{ Name = 'standard v1'; BootstrapTransition = $false }
            )) {
                $fixtureRoot = Join-Path $TestDrive ("workflow binding $($fixture.Name) with spaces")
                $candidateRoot = Join-Path $fixtureRoot 'candidate repository with spaces'
                $runnerTemp = Join-Path $fixtureRoot 'runner temp with spaces'
                $trustedRoot = Join-Path $fixtureRoot 'trusted supervisor with spaces'
                $trustedScriptsRoot = Join-Path $trustedRoot 'scripts'
                New-Item -ItemType Directory -Path $candidateRoot, $runnerTemp, $trustedScriptsRoot -Force | Out-Null

                if ($fixture.BootstrapTransition) {
                    $legacyCatalog = Join-Path $candidateRoot 'catalog'
                    New-Item -ItemType Directory -Path $legacyCatalog -Force | Out-Null
                    [IO.File]::WriteAllText((Join-Path $legacyCatalog 'skills-catalog.json'), '{}', [Text.UTF8Encoding]::new($false))
                }
                else {
                    $standardCatalog = Join-Path $candidateRoot 'catalog'
                    $standardConfig = Join-Path $candidateRoot 'config'
                    New-Item -ItemType Directory -Path $standardCatalog, $standardConfig -Force | Out-Null
                    [IO.File]::WriteAllText((Join-Path $standardCatalog 'source.json'), '{}', [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText((Join-Path $standardConfig 'standard-v1.json'), '{}', [Text.UTF8Encoding]::new($false))
                }

                $collectorPath = Join-Path $trustedScriptsRoot 'Validate.ps1'
                $collectorBody = @'
$bound = [ordered]@{
    RepositoryRoot = $RepositoryRoot
    ArtifactsRoot = $ArtifactsRoot
    BaseCommit = $BaseCommit
    ExpectedGoRuntimeVersion = $ExpectedGoRuntimeVersion
    OutputPath = $OutputPath
    BootstrapTransition = [bool]$BootstrapTransition
}
$bound | ConvertTo-Json -Compress
'@
                [IO.File]::WriteAllText($collectorPath, $validatorParamBlock + [Environment]::NewLine + $collectorBody, [Text.UTF8Encoding]::new($false))

                $baseCommit = '0123456789abcdef0123456789abcdef01234567'
                $runtimeVersion = '1.24.3'
                [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $runnerTemp, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable('TRUSTED_SUPERVISOR_ROOT', $trustedRoot, [EnvironmentVariableTarget]::Process)
                [Environment]::SetEnvironmentVariable('STANDARD_GO_RUNTIME_VERSION', $runtimeVersion, [EnvironmentVariableTarget]::Process)
                Push-Location -LiteralPath $candidateRoot
                try {
                    $bound = (@(& $workflowSnippet) | Select-Object -Last 1) | ConvertFrom-Json
                }
                finally {
                    Pop-Location
                }

                $bound.RepositoryRoot | Should -Be $candidateRoot
                $bound.ArtifactsRoot | Should -Be $runnerTemp
                $bound.BaseCommit | Should -Be $baseCommit
                $bound.ExpectedGoRuntimeVersion | Should -Be $runtimeVersion
                $bound.OutputPath | Should -Be (Join-Path $runnerTemp 'darktide-translate-conformance-report.json')
                $bound.BootstrapTransition | Should -Be $fixture.BootstrapTransition
            }
        }
        finally {
            foreach ($name in $environmentNames) {
                [Environment]::SetEnvironmentVariable($name, $environmentBefore[$name], [EnvironmentVariableTarget]::Process)
            }
        }
    }

    It 'UnitT58_BindsTheCanonicalEvidenceDigestInsideTheNamedExportStep' {
        # Scenario: Workflow text omits, changes, or places the canonical evidence digest outside its clean export step.
        # Purpose: Bind the exported evidence bytes to the canonical-validation digest at the only step allowed to publish them.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1'),
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $assertTrueAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-True'
        }, $true))
        $bindingAst = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-WorkflowEvidenceDigestBinding'
        }, $true))
        $assertTrueAst.Count | Should -Be 1
        $bindingAst.Count | Should -Be 1
        $contractSource = @($assertTrueAst[0].Extent.Text, $bindingAst[0].Extent.Text) -join [Environment]::NewLine
        $contractModule = New-Module -ScriptBlock ([scriptblock]::Create($contractSource))
        try {
            $validWorkflow = @'
steps:
  - name: Export canonical evidence for clean upload
    id: export-evidence
    if: ${{ success() }}
    shell: pwsh
    env:
      EXPECTED_EVIDENCE_SHA256: ${{ steps.canonical-validation.outputs.standard_v1_evidence_sha256 }}
    run: echo export
'@
            {
                & $contractModule { param($Workflow) Assert-WorkflowEvidenceDigestBinding -Workflow $Workflow } $validWorkflow
            } | Should -Not -Throw
            foreach ($invalidWorkflow in @(
                ($validWorkflow -replace '(?m)^\s*EXPECTED_EVIDENCE_SHA256:.*\r?\n', ''),
                ($validWorkflow -replace 'steps\.canonical-validation\.outputs\.standard_v1_evidence_sha256', 'steps.other.outputs.evidence_sha256'),
@'
steps:
  - name: Verify canonical validation evidence
    env:
      EXPECTED_EVIDENCE_SHA256: ${{ steps.canonical-validation.outputs.standard_v1_evidence_sha256 }}
    run: echo verify
  - name: Export canonical evidence for clean upload
    id: export-evidence
    if: ${{ success() }}
    shell: pwsh
    run: echo export
'@
            )) {
                {
                    & $contractModule { param($Workflow) Assert-WorkflowEvidenceDigestBinding -Workflow $Workflow } $invalidWorkflow
                } | Should -Throw
            }
        }
        finally {
            Remove-Module $contractModule -Force
        }
    }

    It 'UnitT59_ValidatesTheCanonicalDigestBeforeExportingEvidence' {
        # Scenario: A normal JSON evidence file is exported with the correct, wrong, absent, and malformed canonical digest values.
        # Purpose: Bind both exported values to the exact bytes and canonical digest emitted by validation.
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw
        $stepMatch = [regex]::Match(
            $workflow,
            '(?ms)^ {6}- name: Export canonical evidence for clean upload\r?\n(?<step>.*?)(?=^ {6}- name:|\z)'
        )
        $stepMatch.Success | Should -BeTrue
        $runMatch = [regex]::Match(
            $stepMatch.Groups['step'].Value,
            '(?ms)^ {8}run:\s*\|\r?\n(?<script>(?:^ {10}.*(?:\r?\n|$))+)'
        )
        $runMatch.Success | Should -BeTrue
        $exportScript = [regex]::Replace($runMatch.Groups['script'].Value, '(?m)^ {10}', '')
        $exportBlock = [scriptblock]::Create($exportScript)

        $evidencePath = Join-Path $TestDrive 'darktide-translate-conformance-report.json'
        $githubOutputPath = Join-Path $TestDrive 'github-output.txt'
        $evidenceBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"result":"passed"}')
        [IO.File]::WriteAllBytes($evidencePath, $evidenceBytes)
        [IO.File]::WriteAllText($githubOutputPath, '', [Text.UTF8Encoding]::new($false))
        $expectedDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $evidencePath).Hash.ToLowerInvariant()
        $wrongDigest = if ($expectedDigest -ceq ('0' * 64)) { '1' * 64 } else { '0' * 64 }

        $savedRunnerTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP', [EnvironmentVariableTarget]::Process)
        $savedGithubOutput = [Environment]::GetEnvironmentVariable('GITHUB_OUTPUT', [EnvironmentVariableTarget]::Process)
        $savedExpectedDigest = [Environment]::GetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $TestDrive, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $githubOutputPath, [EnvironmentVariableTarget]::Process)

            [Environment]::SetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', $expectedDigest, [EnvironmentVariableTarget]::Process)
            { & $exportBlock } | Should -Not -Throw
            $exportOutput = Get-Content -LiteralPath $githubOutputPath -Raw
            $base64Matches = @([regex]::Matches($exportOutput, '(?m)^evidence_base64=(?<value>[A-Za-z0-9+/=]*)\r?$'))
            $digestMatches = @([regex]::Matches($exportOutput, '(?m)^evidence_sha256=(?<value>[0-9a-f]{64})\r?$'))
            $base64Matches.Count | Should -Be 1
            $digestMatches.Count | Should -Be 1
            $decodedEvidenceBytes = [Convert]::FromBase64String($base64Matches[0].Groups['value'].Value)
            [BitConverter]::ToString($decodedEvidenceBytes) | Should -Be ([BitConverter]::ToString($evidenceBytes))
            $digestMatches[0].Groups['value'].Value | Should -Be $expectedDigest

            foreach ($invalidCase in @(
                [pscustomobject]@{ Digest = $wrongDigest; ExpectedMessage = 'Canonical evidence digest does not match the canonical validation output.' },
                [pscustomobject]@{ Digest = $null; ExpectedMessage = 'Canonical validation did not emit one lowercase evidence SHA-256 output.' },
                [pscustomobject]@{ Digest = 'not-a-sha256'; ExpectedMessage = 'Canonical validation did not emit one lowercase evidence SHA-256 output.' }
            )) {
                [IO.File]::WriteAllText($githubOutputPath, '', [Text.UTF8Encoding]::new($false))
                [Environment]::SetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', $invalidCase.Digest, [EnvironmentVariableTarget]::Process)
                $failure = $null
                try {
                    & $exportBlock
                }
                catch {
                    $failure = $_
                }
                $failure | Should -Not -BeNullOrEmpty
                $failure.Exception.Message | Should -Be $invalidCase.ExpectedMessage
                (Get-Item -LiteralPath $githubOutputPath -Force).Length | Should -Be 0
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $savedRunnerTemp, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $savedGithubOutput, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('EXPECTED_EVIDENCE_SHA256', $savedExpectedDigest, [EnvironmentVariableTarget]::Process)
        }
    }

    It 'UnitT60_UsesAWindowsLowIntegrityBoundaryForCandidateWrites' {
        # Scenario: The candidate runs under the same runner account as the trusted supervisor.
        # Purpose: Require a mandatory-integrity boundary so candidate code cannot write up into supervisor-owned roots.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'S-1-16-4096'
        $supervisor | Should -Match 'TokenIntegrityLevel'
        $supervisor | Should -Match 'SetTokenInformation'
        $supervisor | Should -Match 'SetLowIntegrityKernelObject'
        $supervisor | Should -Match 'CreateRestrictedToken'
        $supervisor | Should -Match 'Set-WindowsLowIntegrityDirectory'
        $supervisor | Should -Match "'/setintegritylevel'"
    }

    It 'UnitT70_PinsTheTrustedPesterRegressionInventory' {
        # Scenario: Candidate code removes a protected regression file before the isolated run.
        # Purpose: Require the base-owned supervisor to invoke a fixed, non-empty test inventory.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match "'BootstrapTransition\.Tests\.ps1'"
        $supervisor | Should -Match "'RepositoryValidation\.Tests\.ps1'"
        $supervisor | Should -Match '\$requiredPesterPaths'
        $supervisor | Should -Match '\$pesterConfiguration = New-PesterConfiguration'
        $supervisor | Should -Match '\$pesterConfiguration\.Run\.Path = \$requiredPesterPaths'
        $supervisor | Should -Match '\$pesterConfiguration\.Run\.PassThru = \$true'
        $supervisor | Should -Match '\$pesterConfiguration\.TestRegistry\.Enabled = \$false'
        $supervisor | Should -Match 'Invoke-Pester -Configuration \$pesterConfiguration'
        $supervisor | Should -Not -Match '\$requiredPesterTests = @\(\)'
    }

    It 'UnitT75_IgnoresUnavailableOptionalLinuxModuleDirectories' {
        # Scenario: Linux PSModulePath includes missing, unreadable, blank, and readable directories under Stop error policy.
        # Purpose: Keep inherited optional paths from aborting containment setup while retaining every readable bind source.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $moduleLoops = @($ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.ForEachStatementAst] -and
                    $node.Variable.VariablePath.UserPath -ceq 'modulePath' -and
                    $node.Condition.Extent.Text.Contains('$env:PSModulePath')
                }, $true))
        $moduleLoops.Count | Should -Be 1
        $moduleLoop = [scriptblock]::Create($moduleLoops[0].Extent.Text)
        $probeModule = New-Module -ScriptBlock {
            $script:ErrorActionPreference = 'Stop'
            $script:RecordedBinds = [Collections.Generic.List[string]]::new()
            function Test-Path {
                [CmdletBinding()]
                param([string] $LiteralPath, [string] $PathType)
                if ($LiteralPath -ceq '/root/.local/share/powershell/Modules') {
                    Write-Error -Exception ([UnauthorizedAccessException]::new('Optional module directory is inaccessible.')) -Category PermissionDenied
                    return $false
                }
                return $PathType -ceq 'Container' -and $LiteralPath -cin @('/modules/first', '/modules/last')
            }
            $script:addLinuxReadonlyBindPath = {
                param([string] $Path)
                [void]$script:RecordedBinds.Add($Path)
            }
            Export-ModuleMember -Function @()
        }
        $originalModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('PSModulePath', '/modules/missing:/modules/first:/root/.local/share/powershell/Modules::/modules/last', [EnvironmentVariableTarget]::Process)
            $actual = @(& $probeModule {
                    param([scriptblock] $Loop)
                    & $Loop
                    $script:RecordedBinds.ToArray()
                } $moduleLoop)
            $actual | Should -Be @('/modules/first', '/modules/last')
        }
        finally {
            [Environment]::SetEnvironmentVariable('PSModulePath', $originalModulePath, [EnvironmentVariableTarget]::Process)
            Remove-Module $probeModule -Force
        }
    }

    It 'UnitT76_AllowsOmittedOptionalLinuxReadOnlyPathCollection' {
        # Scenario: Bootstrap supplies no extra read-only paths, or supplies an empty collection.
        # Purpose: Treat absence as zero bind requests instead of converting a null entry into an invalid empty path.
        $probeModule = New-LinuxReadOnlyBindProbe
        try {
            @(& $probeModule { Invoke-LinuxReadOnlyBindProbe }).Count | Should -Be 0
            @(& $probeModule { Invoke-LinuxReadOnlyBindProbe -ReadOnlyPaths @() }).Count | Should -Be 0
            @(& $probeModule { Invoke-LinuxReadOnlyBindProbe -ReadOnlyPaths $null }).Count | Should -Be 0
        }
        finally {
            Remove-Module $probeModule -Force
        }
    }

    It 'UnitT77_PreservesExplicitLinuxReadOnlyPathValidation' {
        # Scenario: Extra read-only paths contain regular entries, duplicates, a missing entry, a blank entry, or a reparse point.
        # Purpose: Preserve ordered unique binds and fail closed for every invalid explicitly requested path.
        $probeModule = New-LinuxReadOnlyBindProbe
        $directory = Join-Path $TestDrive 'readonly-directory'
        $file = Join-Path $TestDrive 'readonly-file.txt'
        $missing = Join-Path $TestDrive 'readonly-missing'
        $link = Join-Path $TestDrive 'readonly-link'
        [void](New-Item -ItemType Directory -Path $directory)
        [IO.File]::WriteAllText($file, 'read-only fixture')
        New-TestReparsePoint -Path $link -Target $directory | Out-Null
        try {
            $actual = @(& $probeModule {
                    param([string[]] $Paths)
                    Invoke-LinuxReadOnlyBindProbe -ReadOnlyPaths $Paths
                } @($directory, $file, $directory))
            $actual | Should -Be @([IO.Path]::GetFullPath($directory), [IO.Path]::GetFullPath($file))
            { & $probeModule { param($Path) Invoke-LinuxReadOnlyBindProbe -ReadOnlyPaths @($Path) } $missing } |
                Should -Throw '*trusted read-only child path is missing*'
            { & $probeModule { Invoke-LinuxReadOnlyBindProbe -ReadOnlyPaths @('') } } |
                Should -Throw '*GetFullPath*empty*'
            { & $probeModule { param($Path) Invoke-LinuxReadOnlyBindProbe -ReadOnlyPaths @($Path) } $link } |
                Should -Throw '*backed by a reparse point*'
        }
        finally {
            Remove-Module $probeModule -Force
        }
    }

    It 'UnitT78_UsesSupportedCapabilityDropArgumentsInBothLinuxLaunchers' {
        # Scenario: Native and Pester-proxy Linux launchers hand their real shell payloads to util-linux setpriv.
        # Purpose: Reject unsupported CLI options while preserving no-new-privileges and all three capability-set removals.
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Supervisor, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        foreach ($functionName in @('Invoke-NativeChecked', 'Invoke-ProtectedPesterServerProxy')) {
            $functionAst = $ast.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
                }, $true)
            $functionAst | Should -Not -BeNullOrEmpty
            $payloads = @($functionAst.FindAll({ param($node)
                    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Value.Contains('exec /usr/bin/setpriv ')
                }, $true))
            $payloads.Count | Should -Be 1
            $calls = @([regex]::Matches($payloads[0].Value, 'exec /usr/bin/setpriv (?<options>[^\r\n]+?) -- "\$@"'))
            $calls.Count | Should -Be 1
            $options = @($calls[0].Groups['options'].Value -split '\s+')
            $options.Count | Should -Be 4
            foreach ($requiredOption in @('--no-new-privs', '--bounding-set=-all', '--inh-caps=-all', '--ambient-caps=-all')) {
                $options | Should -Contain $requiredOption -Because "$functionName must use the supported privilege-dropping interface"
            }
        }
    }

    It 'UnitT80_ProjectsLinuxEtcWithoutArchiveOwnershipCopy' {
        # Scenario: A user namespace cannot read every host /etc file or preserve host-root ownership.
        # Purpose: Build a private readable projection without mutating the host bind or aborting on archive metadata.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw

        $supervisor | Should -Match 'system_root.*=.*"/etc"'
        $supervisor | Should -Match '-type f -readable'
        $supervisor | Should -Match '/bin/cat -- "\$source"'
        $supervisor | Should -Not -Match '/bin/cp -a'
    }

    It 'UnitT81_ExcludesAccountSkeletonFromActualLinuxProjectionSelections' {
        # Scenario: Host configuration includes account skeleton descendants and a similarly named ordinary configuration directory.
        # Purpose: Execute both real find selections so a home template cannot consume the private etc tmpfs while other configuration remains visible.
        $sourceRoot = Join-Path $TestDrive 'etc-selection-source'
        $targetRoot = Join-Path $TestDrive 'etc-selection-target'
        New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'skel/nested'),
            (Join-Path $sourceRoot 'skel-extra'), (Join-Path $sourceRoot 'ssl/certs'), $targetRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceRoot 'skel/nested/template.bin') -Value 'excluded template'
        Set-Content -LiteralPath (Join-Path $sourceRoot 'skel-extra/retained.conf') -Value 'retained configuration'
        Set-Content -LiteralPath (Join-Path $sourceRoot 'ssl/certs/ca.crt') -Value 'fixture certificate'
        $normalizedRoot = $sourceRoot.Replace('\', '/')

        $directories = Invoke-LinuxEtcProjectionProbe -SourceRoot $sourceRoot -DestinationRoot $targetRoot -Mode DirectorySelection
        $directories.ExitCode | Should -Be 0
        $directories.Output | Should -Contain "$normalizedRoot/ssl/certs"
        $directories.Output | Should -Contain "$normalizedRoot/skel-extra"
        $directories.Output | Should -Not -Contain "$normalizedRoot/skel"
        $directories.Output | Should -Not -Contain "$normalizedRoot/skel/nested"

        $files = Invoke-LinuxEtcProjectionProbe -SourceRoot $sourceRoot -DestinationRoot $targetRoot -Mode FileSelection
        $files.ExitCode | Should -Be 0
        $files.Output | Should -Contain "$normalizedRoot/ssl/certs/ca.crt"
        $files.Output | Should -Contain "$normalizedRoot/skel-extra/retained.conf"
        $files.Output | Should -Not -Contain "$normalizedRoot/skel/nested/template.bin"
    }

    It 'UnitT82_PropagatesActualLinuxFileProjectionCopyFailures' {
        # Scenario: The actual file batch copies normal and empty files, then encounters a directory where an output file belongs.
        # Purpose: A failed selected copy must make the launcher fail instead of leaving an incomplete configuration projection marked successful.
        $sourceRoot = Join-Path $TestDrive 'etc-copy-source'
        $targetRoot = Join-Path $TestDrive 'etc-copy-target'
        $collisionRoot = Join-Path $TestDrive 'etc-copy-collision'
        New-Item -ItemType Directory -Path $sourceRoot, $targetRoot, (Join-Path $collisionRoot 'config') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'config'), 'configuration bytes')
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'empty'), '')

        $success = Invoke-LinuxEtcProjectionProbe -SourceRoot $sourceRoot -DestinationRoot $targetRoot -Mode FileCopy
        $success.ExitCode | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $targetRoot 'config')) | Should -BeExactly 'configuration bytes'
        (Get-Item -LiteralPath (Join-Path $targetRoot 'empty')).Length | Should -Be 0
        $failure = Invoke-LinuxEtcProjectionProbe -SourceRoot $sourceRoot -DestinationRoot $collisionRoot -Mode FileCopy
        $failure.ExitCode | Should -Not -Be 0
    }

    It 'UnitT83_PropagatesActualLinuxDirectoryProjectionCopyFailures' {
        # Scenario: A selected source directory collides with a regular file in the private destination.
        # Purpose: Prove the directory batch propagates mkdir failure through find and the outer set-e launcher.
        $sourceRoot = Join-Path $TestDrive 'etc-directory-source'
        $targetRoot = Join-Path $TestDrive 'etc-directory-collision'
        New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'nested'), $targetRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $targetRoot 'nested') -Value 'directory collision'

        $failure = Invoke-LinuxEtcProjectionProbe -SourceRoot $sourceRoot -DestinationRoot $targetRoot -Mode DirectoryCopy
        $failure.ExitCode | Should -Not -Be 0
    }

    It 'UnitT84_PinsLinuxMallocArenasWithoutInheritingParentTuning' {
        # Scenario: Linux child environments are created with absent or excessive parent allocator settings.
        # Purpose: Keep runtime startup within the existing address-space bound without importing parent GC tuning.
        $previousArena = [Environment]::GetEnvironmentVariable('MALLOC_ARENA_MAX')
        $previousHeap = [Environment]::GetEnvironmentVariable('DOTNET_GCHeapHardLimit')
        try {
            [Environment]::SetEnvironmentVariable('DOTNET_GCHeapHardLimit', '10000000')
            foreach ($parentArena in @($null, '64')) {
                if ($null -eq $parentArena) {
                    [Environment]::SetEnvironmentVariable('MALLOC_ARENA_MAX', [NullString]::Value)
                }
                else { [Environment]::SetEnvironmentVariable('MALLOC_ARENA_MAX', $parentArena) }
                $environment = Invoke-ContainedEnvironmentProbe -DiagnosticRoot $TestDrive -LinuxHost $true
                $environment['MALLOC_ARENA_MAX'] | Should -BeExactly '2'
                $environment.Contains('DOTNET_GCHeapHardLimit') | Should -BeFalse
                $environment.Contains('DOTNET_GCRegionRange') | Should -BeFalse
                Test-Path -LiteralPath $environment['HOME'] -PathType Container | Should -BeTrue
                [Environment]::GetEnvironmentVariable('MALLOC_ARENA_MAX') | Should -Be $parentArena
                [Environment]::GetEnvironmentVariable('DOTNET_GCHeapHardLimit') | Should -BeExactly '10000000'
            }
        }
        finally {
            if ($null -eq $previousArena) { $previousArena = [NullString]::Value }
            if ($null -eq $previousHeap) { $previousHeap = [NullString]::Value }
            [Environment]::SetEnvironmentVariable('MALLOC_ARENA_MAX', $previousArena)
            [Environment]::SetEnvironmentVariable('DOTNET_GCHeapHardLimit', $previousHeap)
        }
    }

    It 'UnitT85_PreservesNonLinuxAllocatorEnvironmentBehavior' {
        # Scenario: The same production environment builder runs for a non-Linux host with parent allocator tuning.
        # Purpose: Avoid adding Linux-specific allocator or GC settings to Windows child processes.
        $previousArena = [Environment]::GetEnvironmentVariable('MALLOC_ARENA_MAX')
        try {
            [Environment]::SetEnvironmentVariable('MALLOC_ARENA_MAX', '64')
            $environment = Invoke-ContainedEnvironmentProbe -DiagnosticRoot $TestDrive -LinuxHost $false
            $environment.Contains('MALLOC_ARENA_MAX') | Should -BeFalse
            $environment.Contains('DOTNET_GCHeapHardLimit') | Should -BeFalse
            $environment.Contains('DOTNET_GCRegionRange') | Should -BeFalse
            [Environment]::GetEnvironmentVariable('MALLOC_ARENA_MAX') | Should -BeExactly '64'
        }
        finally {
            if ($null -eq $previousArena) { $previousArena = [NullString]::Value }
            [Environment]::SetEnvironmentVariable('MALLOC_ARENA_MAX', $previousArena)
        }
    }

    It 'UnitT86_ReapsAnObservedLinuxZombieThroughTheCompleteProcessTree' {
        # Scenario: An observed descendant has exited, remains a zombie, and has been adopted by the supervisor.
        # Purpose: Make the actual tree cleanup opt in to pidfd reaping without sending a signal to that exited child.
        $childProcessId = 7293
        $childIdentity = 'child-start-time'
        $records = @{
            $childProcessId = [pscustomobject]@{
                exists = $true; identity = $childIdentity; state = 'Z'; parentProcessId = $PID; processGroupId = 0
            }
        }
        $probe = New-LinuxChildReapingProbe -Records $records
        try {
            $observed = @{$childProcessId = $childIdentity}
            {
                Invoke-LinuxChildReapingProbe -Probe $probe -Action {
                    param($RootProcessId, $Observed)
                    Stop-ProcessTree -RootProcessId $RootProcessId -RootProcessIdentity 'root-start-time' -ObservedProcessIdentities $Observed
                } -Arguments @(7292, $observed)
            } | Should -Not -Throw
            $probe.NativeType::OpenCount | Should -Be 1
            $probe.NativeType::ReapCount | Should -Be 1
            $probe.NativeType::SendCount | Should -Be 0
            $probe.NativeType::CloseCount | Should -Be 1
        }
        finally {
            Remove-Module $probe.Module -Force
        }
    }

    It 'UnitT87_ReapsOnlyEligibleLinuxExitedChildren <Name>' -TestCases @(
        @{ Name = 'default-is-disabled'; State = 'Z'; ParentProcessId = $PID; ReapExitedChild = $false; OpenResult = 71; ReapResult = 0; ReapRemovesIdentity = $true; IdentityChangesAfterOpen = $false; Exists = $true; ExpectedResult = $true; ExpectedOpen = 1; ExpectedReap = 0; ExpectedSignal = 1; ExpectedClose = 1 },
        @{ Name = 'active-process'; State = 'R'; ParentProcessId = $PID; ReapExitedChild = $true; OpenResult = 71; ReapResult = 0; ReapRemovesIdentity = $true; IdentityChangesAfterOpen = $false; Exists = $true; ExpectedResult = $true; ExpectedOpen = 1; ExpectedReap = 0; ExpectedSignal = 1; ExpectedClose = 1 },
        @{ Name = 'foreign-parent-zombie'; State = 'Z'; ParentProcessId = ($PID + 1); ReapExitedChild = $true; OpenResult = 71; ReapResult = 0; ReapRemovesIdentity = $true; IdentityChangesAfterOpen = $false; Exists = $true; ExpectedResult = $true; ExpectedOpen = 1; ExpectedReap = 0; ExpectedSignal = 1; ExpectedClose = 1 },
        @{ Name = 'identity-changes-after-pidfd-open'; State = 'Z'; ParentProcessId = $PID; ReapExitedChild = $true; OpenResult = 71; ReapResult = 0; ReapRemovesIdentity = $true; IdentityChangesAfterOpen = $true; Exists = $true; ExpectedResult = $false; ExpectedOpen = 1; ExpectedReap = 0; ExpectedSignal = 0; ExpectedClose = 1 },
        @{ Name = 'pidfd-open-fails'; State = 'Z'; ParentProcessId = $PID; ReapExitedChild = $true; OpenResult = -1; ReapResult = 0; ReapRemovesIdentity = $true; IdentityChangesAfterOpen = $false; Exists = $true; ExpectedResult = $false; ExpectedOpen = 1; ExpectedReap = 0; ExpectedSignal = 0; ExpectedClose = 0 },
        @{ Name = 'reap-fails'; State = 'Z'; ParentProcessId = $PID; ReapExitedChild = $true; OpenResult = 71; ReapResult = -1; ReapRemovesIdentity = $true; IdentityChangesAfterOpen = $false; Exists = $true; ExpectedResult = $false; ExpectedOpen = 1; ExpectedReap = 1; ExpectedSignal = 0; ExpectedClose = 1 },
        @{ Name = 'reap-leaves-identity-present'; State = 'Z'; ParentProcessId = $PID; ReapExitedChild = $true; OpenResult = 71; ReapResult = 0; ReapRemovesIdentity = $false; IdentityChangesAfterOpen = $false; Exists = $true; ExpectedResult = $false; ExpectedOpen = 1; ExpectedReap = 1; ExpectedSignal = 0; ExpectedClose = 1 },
        @{ Name = 'identity-is-already-absent'; State = 'Z'; ParentProcessId = $PID; ReapExitedChild = $true; OpenResult = 71; ReapResult = 0; ReapRemovesIdentity = $true; IdentityChangesAfterOpen = $false; Exists = $false; ExpectedResult = $true; ExpectedOpen = 0; ExpectedReap = 0; ExpectedSignal = 0; ExpectedClose = 0 }
    ) {
        # Scenario: pidfd cleanup sees an exited child, a live or foreign process, or a race at one of its identity boundaries.
        # Purpose: Reap only an opt-in supervisor-owned zombie and fail closed whenever identity or reaping cannot prove completion.
        param($Name, $State, $ParentProcessId, $ReapExitedChild, $OpenResult, $ReapResult, $ReapRemovesIdentity, $IdentityChangesAfterOpen, $Exists, $ExpectedResult, $ExpectedOpen, $ExpectedReap, $ExpectedSignal, $ExpectedClose)
        $childProcessId = 7293
        $childIdentity = 'child-start-time'
        $records = @{
            $childProcessId = [pscustomobject]@{
                exists = $Exists; identity = $childIdentity; state = $State; parentProcessId = $ParentProcessId; processGroupId = 0
            }
        }
        $probe = New-LinuxChildReapingProbe -Records $records -OpenResult $OpenResult -ReapResult $ReapResult `
            -ReapRemovesIdentity $ReapRemovesIdentity -IdentityChangesAfterOpen $IdentityChangesAfterOpen
        try {
            $actual = Invoke-LinuxChildReapingProbe -Probe $probe -Action {
                param($ProcessId, $Identity, $Reap)
                Stop-UnixProcessByIdentity -ProcessId $ProcessId -Identity $Identity -Signal 15 -ReapExitedChild:$Reap
            } -Arguments @($childProcessId, $childIdentity, $ReapExitedChild)
            $actual | Should -Be $ExpectedResult
            $probe.NativeType::OpenCount | Should -Be $ExpectedOpen
            $probe.NativeType::ReapCount | Should -Be $ExpectedReap
            $probe.NativeType::SendCount | Should -Be $ExpectedSignal
            $probe.NativeType::CloseCount | Should -Be $ExpectedClose
        }
        finally {
            Remove-Module $probe.Module -Force
        }
    }

    It 'UnitT88_RejectsAForeignLinuxZombieFromTheCompleteProcessTree' {
        # Scenario: An observed zombie is parented by a process other than the trusted supervisor.
        # Purpose: Keep complete-tree cleanup fail closed instead of reaping or accepting a foreign descendant.
        $childProcessId = 7293
        $childIdentity = 'foreign-child-start-time'
        $records = @{
            $childProcessId = [pscustomobject]@{
                exists = $true; identity = $childIdentity; state = 'Z'; parentProcessId = ($PID + 1); processGroupId = 0
            }
        }
        $probe = New-LinuxChildReapingProbe -Records $records
        try {
            $observed = @{$childProcessId = $childIdentity}
            {
                Invoke-LinuxChildReapingProbe -Probe $probe -Action {
                    param($RootProcessId, $Observed)
                    Stop-ProcessTree -RootProcessId $RootProcessId -RootProcessIdentity 'root-start-time' -ObservedProcessIdentities $Observed
                } -Arguments @(7292, $observed)
            } | Should -Throw '*Could not terminate the complete candidate process boundary*'
            $probe.NativeType::ReapCount | Should -Be 0
        }
        finally {
            Remove-Module $probe.Module -Force
        }
    }

    It 'UnitT89_ReapsOnlySupervisorZombiesThatAppearAfterTheFinalSignal <Name>' -TestCases @(
        @{ Name = 'supervisor-zombie-after-signal-9'; Transition = $true; TransitionParentProcessId = 0; ReapResult = 0; ReapRemovesIdentity = $true; ShouldComplete = $true; ExpectedReap = 1 },
        @{ Name = 'still-live-after-signal-9'; Transition = $false; TransitionParentProcessId = 0; ReapResult = 0; ReapRemovesIdentity = $true; ShouldComplete = $false; ExpectedReap = 0 },
        @{ Name = 'foreign-zombie-after-signal-9'; Transition = $true; TransitionParentProcessId = ($PID + 1); ReapResult = 0; ReapRemovesIdentity = $true; ShouldComplete = $false; ExpectedReap = 0 },
        @{ Name = 'wait-fails-after-signal-9'; Transition = $true; TransitionParentProcessId = 0; ReapResult = -1; ReapRemovesIdentity = $true; ShouldComplete = $false; ExpectedReap = 1 },
        @{ Name = 'wait-leaves-identity-after-signal-9'; Transition = $true; TransitionParentProcessId = 0; ReapResult = 0; ReapRemovesIdentity = $false; ShouldComplete = $false; ExpectedReap = 1 }
    ) {
        # Scenario: An observed child is live through the existing TERM rounds and changes state only after the final KILL signal.
        # Purpose: Reap only a supervisor-owned final-round zombie without changing signal rounds, touching the root, or accepting an unproved cleanup.
        param($Name, $Transition, $TransitionParentProcessId, $ReapResult, $ReapRemovesIdentity, $ShouldComplete, $ExpectedReap)
        $rootProcessId = 7215
        $childProcessId = 7216
        $childIdentity = 'delayed-child-start-time'
        $records = @{
            $childProcessId = [pscustomobject]@{
                exists = $true; identity = $childIdentity; state = 'S'; parentProcessId = ($PID + 1); processGroupId = 0
            }
        }
        $transitionProcessId = if ($Transition) { $childProcessId } else { 0 }
        $probe = New-LinuxChildReapingProbe -Records $records -ReapResult $ReapResult `
            -ReapRemovesIdentity $ReapRemovesIdentity -ZombieAfterFinalSignalProcessId $transitionProcessId `
            -ZombieAfterFinalSignalParentProcessId $TransitionParentProcessId
        try {
            $observed = @{
                $rootProcessId = 'root-start-time'
                $childProcessId = $childIdentity
            }
            $cleanup = {
                Invoke-LinuxChildReapingProbe -Probe $probe -Action {
                    param($RootProcessId, $Observed)
                    Stop-ProcessTree -RootProcessId $RootProcessId -RootProcessIdentity 'root-start-time' -ObservedProcessIdentities $Observed
                } -Arguments @($rootProcessId, $observed)
            }
            if ($ShouldComplete) {
                $cleanup | Should -Not -Throw
            }
            else {
                $cleanup | Should -Throw '*Could not terminate the complete candidate process boundary*'
            }
            @($probe.NativeType::SignalValues) | Should -Be @(15, 15, 9)
            @($probe.NativeType::SignalProcessIds) | Should -Be @($childProcessId, $childProcessId, $childProcessId)
            $probe.NativeType::ReapCount | Should -Be $ExpectedReap
            $probe.NativeType::LastReapedProcessId | Should -Be $(if ($ExpectedReap -eq 1) { $childProcessId } else { 0 })
        }
        finally {
            Remove-Module $probe.Module -Force
        }
    }

    It 'UnitT90SeparatesChildOutputAndTrustedPesterContent' {
        # Scenario: Low-integrity children must write only to a labeled output root, while tests come from trusted Git bytes.
        # Purpose: Keep scanner receipts and Pester content outside candidate-writable paths and out of the worker's authority.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match "'low-integrity-output'"
        $supervisor | Should -Match '''-PesterChildWritableRoot'', \$childOutputRoot'
        $supervisor | Should -Match '-ChildWritableRoot \$ChildWritableRoot'
        $supervisor | Should -Match 'Expand-TrustedGitArchive'
        $supervisor | Should -Match 'Assert-TrustedGitTreeFile'
        $supervisor | Should -Match '\$trustedPesterCommit'
        $supervisor | Should -Match '(?s)Expand-TrustedGitArchive.*?-Revision \$trustedPesterCommit.*?-PathSpec @\(''tests''\).*?-Context ''Trusted base Pester tests'''
        $supervisor | Should -Match '(?s)\$candidateMirrorTestsRoot.*?Remove-Item'
        $supervisor | Should -Match '\$readOnlyPaths = @\('
        $supervisor | Should -Match 'Invoke-ProtectedPesterRunspace'
        $supervisor | Should -Match 'CreateOutOfProcessRunspace'
        $supervisor | Should -Match 'AddScript\(\$workerScriptText\)'
        $supervisor | Should -Match 'InvocationStateInfo\.State'
        $supervisor | Should -Match 'Assert-LinuxAggregateResourceUsage'
        $supervisor | Should -Match 'Get-LinuxAggregateClockTicksPerSecond'
        $supervisor | Should -Match 'Get-LinuxCgroupCpuUsage'
        $supervisor | Should -Match '\$fields\[13\].*\$fields\[14\]'
        $supervisor | Should -Match 'CODEX_PESTER_CGROUP_ROOT'
        $supervisor | Should -Match 'Get-LinuxPesterCgroupRoot'
        $supervisor | Should -Match '/proc/\$PID/cgroup'
        $supervisor | Should -Match 'New-LinuxPesterCgroup'
        $supervisor | Should -Match 'memory\.max'
        $supervisor | Should -Match 'cpu\.stat'
        $supervisor | Should -Match 'usage_usec'
        $supervisor | Should -Match 'cgroup\.procs'
        $supervisor | Should -Match 'cgroup\.events'
        $supervisor | Should -Match 'populated'
        $supervisor | Should -Match 'Start-Sleep -Milliseconds 25'
        $supervisor | Should -Match 'linuxPesterCgroupCleanupException'
        $supervisor | Should -Match 'Add-LinuxProcessTreeToCgroup'
        $workflow | Should -Match 'Delegate Linux cgroup v2 subtree'
        $workflow | Should -Match 'CODEX_PESTER_CGROUP_ROOT'
        $workflow | Should -Match 'CODEX_PESTER_VALIDATOR_CGROUP'
        $workflow | Should -Match 'root_subtree_control'
        $workflow | Should -Match '\+cpu \+memory'
        $workflow | Should -Match 'cgroup\.subtree_control'
        $workflow | Should -Match 'cgroup\.threads'
        $workflow | Should -Match 'cgroup_parent/cgroup\.procs'
        $workflow | Should -Match 'sudo -n chown'
        $workflow | Should -Match 'trusted-validator'
        $workflow | Should -Match 'Remove delegated Linux cgroup subtree'
        $supervisor | Should -Match 'Start-WindowsSuspendedProcess'
        $supervisor | Should -Match '\.CopyToAsync\('
        $supervisor | Should -Match '--kill-child'
        $supervisor | Should -Match '--as=2147483648'
        $supervisor | Should -Match '--cpu=300'
        $supervisor | Should -Match '\[switch\] \$ProtectedPesterServerProxy'
        $supervisor | Should -Match '\$PesterProxyReadOnlyPathsJson'
        $supervisor | Should -Match 'EnvironmentVariables\.Remove\(\$gateEnvironmentName\)'
        $supervisor | Should -Match '\[ ! -e "\$target" \]'
        $supervisor | Should -Match 'exec "\$chroot_path"'
        $supervisor | Should -Match 'exec chroot "\$sandbox_root"'
        $supervisor | Should -Match 'SGV1-Pester-Result:'
        $supervisor | Should -Match 'Invoke-TrustedPowerShellProcess'
        $supervisor | Should -Match 'Invoke-ProtectedPesterSupervisor'
        $supervisor | Should -Match '\$trustedPesterSupervisorMarker'
        $supervisor | Should -Match '\$completionMarker = \(\[Console\]::In\.ReadToEnd\(\)\)'
        $supervisor | Should -Match 'trusted-parent-post-exit'
        $supervisor | Should -Match '\$completionAttestationNonce'
        $supervisor | Should -Not -Match '\$workerMarkerVariableName'
        $supervisor | Should -Not -Match '\$workerResultLines'
        $supervisor | Should -Not -Match '-StandardInput \$pesterWorkerMarker'
        $supervisor | Should -Not -Match '\$pesterSupervisorPath\s*='
    }

    It 'UnitT100_BindsReplacementObjectDiscoveryToTheCandidateWorktree' {
        # Scenario: Git does not trust the runner checkout through ambient global configuration.
        # Purpose: Make the replacement-object preflight use the same explicit repository trust boundary as every later Git read.
        $supervisor = Get-Content -LiteralPath $script:Supervisor -Raw
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $supervisor | Should -Match '(?s)function Assert-NoGitReplacementObjects.*?safe\.directory=\$RepositoryRoot.*?core\.worktree=\$RepositoryRoot.*?rev-parse --git-path refs/replace'
        $workflow | Should -Match '(?s)\$gitPath\s*=.*?\$gitArguments\s*=\s*@\(.*?safe\.directory=\$repositoryRoot.*?core\.worktree=\$repositoryRoot.*?rev-parse HEAD.*?merge-base --is-ancestor'

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:Supervisor,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Assert-NoGitReplacementObjects'
            }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))

        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
        $emptyGitConfig = Join-Path $TestDrive 'empty-git-config'
        New-Item -ItemType File -Path $emptyGitConfig -Force | Out-Null
        $savedAssumeDifferentOwner = $env:GIT_TEST_ASSUME_DIFFERENT_OWNER
        $savedGlobalConfig = $env:GIT_CONFIG_GLOBAL
        $savedSystemConfig = $env:GIT_CONFIG_SYSTEM
        $savedNoSystemConfig = $env:GIT_CONFIG_NOSYSTEM
        try {
            $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = '1'
            $env:GIT_CONFIG_GLOBAL = $emptyGitConfig
            $env:GIT_CONFIG_SYSTEM = $emptyGitConfig
            $env:GIT_CONFIG_NOSYSTEM = '1'

            & $gitPath -C $script:ValidatorRepositoryRoot rev-parse --git-path refs/replace 2>$null | Out-Null
            $LASTEXITCODE | Should -Not -Be 0

            {
                & $guardModule {
                    param($ResolvedGitPath, $RepositoryRoot)
                    Assert-NoGitReplacementObjects `
                        -GitPath $ResolvedGitPath `
                        -RepositoryRoot $RepositoryRoot `
                        -Context 'Unit test candidate'
                } $gitPath $script:ValidatorRepositoryRoot
            } | Should -Not -Throw
        }
        finally {
            $env:GIT_TEST_ASSUME_DIFFERENT_OWNER = $savedAssumeDifferentOwner
            $env:GIT_CONFIG_GLOBAL = $savedGlobalConfig
            $env:GIT_CONFIG_SYSTEM = $savedSystemConfig
            $env:GIT_CONFIG_NOSYSTEM = $savedNoSystemConfig
            Remove-Module $guardModule -Force
        }
    }

    It 'UnitT110_RejectsNonUtf8PowerShellSourceBytes' {
        # Scenario: Windows PowerShell 5.1 parses trusted local source fixtures encoded as UTF-8 with or without a BOM, while UTF-16 and UTF-32 source is rejected.
        # Purpose: Prevent host ANSI source interpretation from accepting malformed candidate PowerShell while preserving non-ASCII UTF-8 code.
        $workflow = Get-Content -LiteralPath $script:ProtectedWorkflow -Raw

        $workflow | Should -Match '\[IO\.File\]::ReadAllBytes\(\$candidatePath\)'
        $workflow | Should -Not -Match '\$candidateSource\s*=\s*\[IO\.File\]::ReadAllText\('
        $workflow | Should -Match '(?s)\$candidateBytes\[0\] -eq 0xEF.*?\$candidateBytes\[1\] -eq 0xBB.*?\$candidateBytes\[2\] -eq 0xBF'
        $workflow | Should -Match '(?s)\[Text\.UTF8Encoding\]::new\(\$false, \$true\)\.GetString\(.*?\$candidateBytes.*?\$candidateOffset.*?\$candidateBytes\.Length - \$candidateOffset'

        $compatibilityTokens = $null
        $compatibilityParseErrors = $null
        $compatibilityAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepositoryRoot 'tests/validate-windows-powershell.ps1'),
            [ref]$compatibilityTokens,
            [ref]$compatibilityParseErrors
        )
        @($compatibilityParseErrors).Count | Should -Be 0
        $sourceParserAst = $compatibilityAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Assert-StrictUtf8PowerShellFile'
            }, $true)
        $sourceParserAst | Should -Not -BeNullOrEmpty

        $fixtureRoot = Join-Path $TestDrive 'windows-powershell-utf8-fixtures'
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        $plainPath = Join-Path $fixtureRoot 'plain-utf8.ps1'
        $bomPath = Join-Path $fixtureRoot 'bom-utf8.ps1'
        $utf16Path = Join-Path $fixtureRoot 'utf16.ps1'
        $utf32Path = Join-Path $fixtureRoot 'utf32.ps1'
        $malformedPath = Join-Path $fixtureRoot 'malformed-utf8.ps1'
        $fixtureSource = "`$message = '" + [string][char]0x6E2C + [char]0x8A66 + "'"
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $utf16 = [Text.Encoding]::Unicode
        $utf32 = [Text.UTF32Encoding]::new($false, $true)
        [IO.File]::WriteAllBytes($plainPath, $utf8.GetBytes($fixtureSource))
        [IO.File]::WriteAllBytes($bomPath, ([byte[]]@(0xEF, 0xBB, 0xBF) + $utf8.GetBytes($fixtureSource)))
        [IO.File]::WriteAllBytes($utf16Path, ($utf16.GetPreamble() + $utf16.GetBytes($fixtureSource)))
        [IO.File]::WriteAllBytes($utf32Path, ($utf32.GetPreamble() + $utf32.GetBytes($fixtureSource)))
        [IO.File]::WriteAllBytes($malformedPath, $utf8.GetBytes('if ('))

        $sourceParserModule = New-Module -ScriptBlock ([scriptblock]::Create($sourceParserAst.Extent.Text))
        try {
            foreach ($validPath in @($plainPath, $bomPath)) {
                {
                    & $sourceParserModule {
                        param($Path)
                        Assert-StrictUtf8PowerShellFile -Path $Path
                    } $validPath
                } | Should -Not -Throw
            }
            foreach ($invalidPath in @($utf16Path, $utf32Path, $malformedPath)) {
                {
                    & $sourceParserModule {
                        param($Path)
                        Assert-StrictUtf8PowerShellFile -Path $Path
                    } $invalidPath
                } | Should -Throw
            }
        }
        finally {
            Remove-Module $sourceParserModule -Force
        }

        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
            $systemRoot | Should -Not -BeNullOrEmpty
            $windowsPowerShellPath = [IO.Path]::GetFullPath((Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
            Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf | Should -BeTrue
            $runnerPath = Join-Path $fixtureRoot 'parse-fixtures.ps1'
            $runnerSource = @(
                'param([string] $PlainPath, [string] $BomPath, [string] $Utf16Path, [string] $Utf32Path, [string] $MalformedPath)'
                '$ErrorActionPreference = ''Stop'''
                $sourceParserAst.Extent.Text
                'Assert-StrictUtf8PowerShellFile -Path $PlainPath'
                'Assert-StrictUtf8PowerShellFile -Path $BomPath'
                'foreach ($invalidPath in @($Utf16Path, $Utf32Path, $MalformedPath)) { try { Assert-StrictUtf8PowerShellFile -Path $invalidPath; throw "Expected strict UTF-8 parsing to reject $invalidPath." } catch { if ($_.Exception.Message -like "Expected strict UTF-8 parsing*") { throw } } }'
            ) -join [Environment]::NewLine
            [IO.File]::WriteAllText($runnerPath, $runnerSource, [Text.UTF8Encoding]::new($false))
            & $windowsPowerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runnerPath $plainPath $bomPath $utf16Path $utf32Path $malformedPath
            $LASTEXITCODE | Should -Be 0
        }

        foreach ($validatorPath in @($script:Supervisor, $script:RepositoryValidator)) {
            $validatorSource = Get-Content -LiteralPath $validatorPath -Raw
            $validatorSource | Should -Match 'Read-StrictUtf8File -Path'
            $validatorSource | Should -Not -Match '\[IO\.File\]::ReadAllText\([^\r\n]+\[Text\.UTF8Encoding\]::new\(\$false,\s*\$true\)\)'
            $tokens = $null
            $parseErrors = $null
            $validatorAst = [Management.Automation.Language.Parser]::ParseFile(
                $validatorPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            @($parseErrors).Count | Should -Be 0
            $readerAst = $validatorAst.Find({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -eq 'Read-StrictUtf8File'
                }, $true)
            $readerAst | Should -Not -BeNullOrEmpty
            $readerAst.Extent.Text | Should -Match '\[IO\.File\]::ReadAllBytes\(\$Path\)'
            $readerAst.Extent.Text | Should -Match '(?s)\$bytes\[0\] -eq 0xEF.*?\$bytes\[1\] -eq 0xBB.*?\$bytes\[2\] -eq 0xBF'
            $readerAst.Extent.Text | Should -Match '\[Text\.UTF8Encoding\]::new\(\$false, \$true\)\.GetString\('

            $readerModule = New-Module -ScriptBlock ([scriptblock]::Create($readerAst.Extent.Text))
            try {
                $validatorName = [IO.Path]::GetFileNameWithoutExtension($validatorPath)
                $invalidPath = Join-Path $TestDrive "$validatorName-utf16.txt"
                $plainPath = Join-Path $TestDrive "$validatorName-utf8.txt"
                $bomPath = Join-Path $TestDrive "$validatorName-utf8-bom.txt"
                [IO.File]::WriteAllBytes($invalidPath, [byte[]]@(0xFF, 0xFE, 0x23, 0x00))
                [IO.File]::WriteAllBytes($plainPath, [byte[]]@(0x23, 0x20, 0x6F, 0x6B))
                [IO.File]::WriteAllBytes($bomPath, [byte[]]@(0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x6F, 0x6B))

                { & $readerModule { param($Path) Read-StrictUtf8File -Path $Path } $invalidPath } |
                    Should -Throw
                (& $readerModule { param($Path) Read-StrictUtf8File -Path $Path } $plainPath) |
                    Should -Be '# ok'
                (& $readerModule { param($Path) Read-StrictUtf8File -Path $Path } $bomPath) |
                    Should -Be '# ok'
            }
            finally {
                Remove-Module $readerModule -Force
            }
        }

        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        { $strictUtf8.GetString([byte[]]@(0xFF, 0xFE, 0x23, 0x00), 0, 4) } |
            Should -Throw
        { $strictUtf8.GetString([byte[]]@(0xFE, 0xFF, 0x00, 0x23), 0, 4) } |
            Should -Throw
        { $strictUtf8.GetString([byte[]]@(0xFF, 0xFE, 0x00, 0x00, 0x23, 0x00, 0x00, 0x00), 0, 8) } |
            Should -Throw
        { $strictUtf8.GetString([byte[]]@(0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x23), 0, 8) } |
            Should -Throw
        $strictUtf8.GetString([byte[]]@(0x23, 0x20, 0x6F, 0x6B), 0, 4) |
            Should -Be '# ok'
        $strictUtf8.GetString([byte[]]@(0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x6F, 0x6B), 3, 4) |
            Should -Be '# ok'
    }

}
