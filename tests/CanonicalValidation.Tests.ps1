# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Run-owned workflow cleanup filesystem boundary' {
    BeforeAll {
        $workflow = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/standard-v1-candidate-windows.yml') -Raw
        $block = [regex]::Match($workflow,
            '(?ms)^      - name: Remove run-owned validation directory\r?\n.*?^        run: \|\r?\n(?<code>.*?)(?=^      - name:|\z)')
        if (-not $block.Success) { throw 'The actual run-owned cleanup step is missing.' }
        $code = [regex]::Replace($block.Groups['code'].Value, '(?m)^          ', '')
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'The actual cleanup workflow PowerShell must parse.' }
        $script:RunCleanupBody = [scriptblock]::Create($code)
        function Invoke-RunCleanupFixture {
            param([string] $RunnerTemp, [string] $RunDirectory)
            $module = New-Module -ScriptBlock {}
            & $module {
                param($runnerTemp, $runDirectory, $body)
                $names = @('RUNNER_TEMP', 'SGV1_RUN_DIRECTORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')
                $before = @{}
                foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
                try {
                    [Environment]::SetEnvironmentVariable('RUNNER_TEMP', $runnerTemp, 'Process')
                    [Environment]::SetEnvironmentVariable('SGV1_RUN_DIRECTORY', $runDirectory, 'Process')
                    [Environment]::SetEnvironmentVariable('GITHUB_RUN_ID', '123', 'Process')
                    [Environment]::SetEnvironmentVariable('GITHUB_RUN_ATTEMPT', '1', 'Process')
                    & $body
                }
                finally {
                    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
                }
            } $RunnerTemp $RunDirectory $script:RunCleanupBody
        }
        function New-RunCleanupFixture {
            param([string] $Root)
            $parent = Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $owned = Join-Path $parent ('sgv1-123-1-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($owned)
            return @{ parent = $parent; owned = $owned }
        }
    }

    # Scenario: A disposable Git-style object and its ordinary directory are read-only.
    # Purpose: Delete owned validation data without changing ACLs or swallowing deletion errors.
    It 'InterT10_RemovesReadOnlyFilesAndDirectoriesUnderTheValidatedRunRoot' {
        $fixture = New-RunCleanupFixture -Root $TestDrive
        $objects = Join-Path $fixture.owned '.git/objects/81'
        [void][IO.Directory]::CreateDirectory($objects)
        $objectPath = Join-Path $objects 'b65ec5593125829b263a61a9b99efea873d2'
        [IO.File]::WriteAllText($objectPath, 'fixture object')
        [IO.File]::SetAttributes($objectPath, [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Archive)
        [IO.File]::SetAttributes($objects, [IO.File]::GetAttributes($objects) -bor [IO.FileAttributes]::ReadOnly)
        Invoke-RunCleanupFixture -RunnerTemp $fixture.parent -RunDirectory $fixture.owned
        Test-Path -LiteralPath $fixture.owned | Should -BeFalse
        Test-Path -LiteralPath $fixture.parent | Should -BeTrue
    }

    # Scenario: An owned run contains a junction to a separate read-only sentinel.
    # Purpose: Cleanup removes the link entry while preserving the target's bytes and attributes.
    It 'InterT20_DoesNotTraverseNestedReparseTargetsWhileClearingReadOnly' {
        $fixture = New-RunCleanupFixture -Root $TestDrive
        $outside = Join-Path $fixture.parent 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        $sentinel = Join-Path $outside 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'outside must survive')
        [IO.File]::SetAttributes($sentinel, [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Archive)
        $attributes = [IO.File]::GetAttributes($sentinel)
        [void](New-Item -ItemType Junction -Path (Join-Path $fixture.owned 'linked') -Value $outside)
        Invoke-RunCleanupFixture -RunnerTemp $fixture.parent -RunDirectory $fixture.owned
        Test-Path -LiteralPath $fixture.owned | Should -BeFalse
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'outside must survive'
        [IO.File]::GetAttributes($sentinel) | Should -Be $attributes
    }

    # Scenario: The requested path has the wrong name, parent, or is itself a junction.
    # Purpose: Preserve the original ownership guards before any filesystem mutation.
    It 'InterT30_RejectsUnsafeRunRoots_<kind>' -ForEach @(
        @{ kind = 'name' }, @{ kind = 'parent' }, @{ kind = 'rootReparse' }
    ) {
        $fixture = New-RunCleanupFixture -Root $TestDrive
        $outside = Join-Path $fixture.parent 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        $sentinel = Join-Path $outside 'sentinel.txt'
        [IO.File]::WriteAllText($sentinel, 'outside must survive')
        $run = $fixture.owned
        if ($kind -eq 'name') { $run = $outside }
        elseif ($kind -eq 'parent') {
            $run = Join-Path $outside ([IO.Path]::GetFileName($fixture.owned))
            [void][IO.Directory]::CreateDirectory($run)
        }
        else {
            [IO.Directory]::Delete($fixture.owned)
            [void](New-Item -ItemType Junction -Path $fixture.owned -Value $outside)
        }
        { Invoke-RunCleanupFixture -RunnerTemp $fixture.parent -RunDirectory $run } | Should -Throw '*Refusing to remove*'
        Test-Path -LiteralPath $run | Should -BeTrue
        [IO.File]::ReadAllText($sentinel) | Should -BeExactly 'outside must survive'
    }
}

Describe 'Trusted resolver API credential lifetime' {
    BeforeAll {
        $source = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Validate.ps1') -Raw
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'The actual validator must parse before its credential lifetime is exercised.' }
        $names = @('Protect-ProcessCredentialEnvironment', 'Assert-SemanticCredentialHostSupport',
            'Read-StrictUtf8File', 'Assert-NoDuplicateJsonProperties', 'Read-JsonFile')
        $functions = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
        }, $true)
        if ($functions.Count -ne $names.Count) { throw 'Missing actual credential or receipt helpers.' }
        $assignments = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst]
        }, $true))
        $protect = @($assignments | Where-Object { $_.Left.Extent.Text -ceq '$semanticCredentialEnvironment' })
        $capture = @($assignments | Where-Object {
            $_.Left.Extent.Text -ceq '$toolResolutionGitHubToken' -and
            $_.Extent.StartOffset -lt $protect[0].Extent.StartOffset
        })
        $sources = @($assignments | Where-Object { $_.Left.Extent.Text -ceq '$expectedSources' })
        $loop = @($ast.Find({ param($node)
            $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.Extent.Text -ceq '$toolName' -and
            $node.Condition.Extent.Text -ceq '$expectedSources.Keys'
        }, $true))
        if ($protect.Count -ne 1 -or $sources.Count -ne 1 -or $loop.Count -ne 1 -or $capture.Count -gt 1) {
            throw 'The actual credential capture, sanitizer and resolver loop must be unambiguous.'
        }
        $firstFunction = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst]
        })[0]
        $earlyStatements = @($ast.EndBlock.Statements | Where-Object {
            $_.Extent.StartOffset -lt $firstFunction.Extent.StartOffset
        })
        $script:CredentialEarlyBody = ($earlyStatements.Extent.Text -join "`n")
        $lateCapture = @($capture | Where-Object { $_.Extent.StartOffset -ge $firstFunction.Extent.StartOffset })
        $script:CredentialFunctions = ($functions.Extent.Text -join "`n")
        $script:CredentialSetup = (@($lateCapture + $protect) | Sort-Object { $_.Extent.StartOffset } |
            ForEach-Object { $_.Extent.Text }) -join "`n"
        $script:CredentialSources = $sources[0].Extent.Text
        $script:CredentialLoop = $loop[0].Extent.Text

        function Invoke-CredentialLifetimeFixture {
            param([string] $Root, [string] $FailTool, [bool] $WithToken)
            $module = New-Module -ScriptBlock ([scriptblock]::Create($script:CredentialFunctions))
            return & $module {
                param($root, $failTool, $withToken, $earlyBody, $setup, $sources, $loop)
                $before = [Environment]::GetEnvironmentVariables('Process')
                try {
                    $script:IsWindowsHost = $true
                    $script:Calls = [Collections.Generic.List[object]]::new()
                    $script:FailTool = $failTool
                    [Environment]::SetEnvironmentVariable('GITHUB_TOKEN',
                        $(if ($withToken) { 'fixture-read-only-api-token' } else { $null }), 'Process')
                    [Environment]::SetEnvironmentVariable('GH_TOKEN', 'fixture-unrelated-token', 'Process')
                    $toolResolutionGitHubToken = $null
                    . ([scriptblock]::Create($earlyBody))
                    $child = [Diagnostics.Process]::new()
                    try {
                        $child.StartInfo = [Diagnostics.ProcessStartInfo]::new()
                        $child.StartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
                        $child.StartInfo.UseShellExecute = $false
                        $child.StartInfo.CreateNoWindow = $true
                        $child.StartInfo.RedirectStandardOutput = $true
                        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                            "[string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GITHUB_TOKEN','Process')) -and [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GH_TOKEN','Process'))")) {
                            [void]$child.StartInfo.ArgumentList.Add($argument)
                        }
                        if (-not $child.Start()) { throw 'Could not start the credential inheritance probe.' }
                        $childOutput = $child.StandardOutput.ReadToEndAsync()
                        if (-not $child.WaitForExit(10000)) { $child.Kill($true); throw 'Credential inheritance probe timed out.' }
                        if ($child.ExitCode -ne 0) { throw 'Credential inheritance probe failed.' }
                        $preflightChildCredentialFree = ($childOutput.GetAwaiter().GetResult().Trim() -ceq 'True')
                    }
                    finally { $child.Dispose() }
                    $SemanticCredentialNames = @()
                    . ([scriptblock]::Create($setup))
                    $cleanAfterSanitizer = [string]::IsNullOrEmpty($env:GITHUB_TOKEN) -and
                        [string]::IsNullOrEmpty($env:GH_TOKEN)
                    . ([scriptblock]::Create($sources))
                    $runRoot = $root; $installRoot = $root; $policyPath = 'fixture-policy.json'
                    $ExpectedGoRuntimeVersion = 'fixture-runtime'; $receipts = [ordered]@{}
                    $resolverPath = {
                        param($PolicyPath, $ToolName, [switch] $Install, $InstallRoot,
                            $ExpectedGoRuntimeVersion, $OutputPath)
                        $script:Calls.Add([pscustomobject]@{
                            tool = $ToolName
                            hasGitHubToken = ($env:GITHUB_TOKEN -ceq 'fixture-read-only-api-token')
                            hasGhToken = -not [string]::IsNullOrEmpty($env:GH_TOKEN)
                        })
                        if ($ToolName -ceq $script:FailTool) { throw 'fixture resolver failure before its own cleanup' }
                        # Deliberately leave the token intact: the actual parent must clean it.
                        $receipt = [ordered]@{ toolName = $ToolName; source = $expectedSources[$ToolName]
                            channel = 'latest-stable'; frozenForRun = $true
                            resolvedVersion = 'fixture-version'; resolvedIdentity = 'fixture-identity' }
                        [IO.File]::WriteAllText($OutputPath, ($receipt | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
                    }
                    $failure = $null
                    try { . ([scriptblock]::Create($loop)) } catch { $failure = $_.Exception.Message }
                    [pscustomobject]@{
                        calls = @($script:Calls.ToArray()); failure = $failure
                        cleanAfterSanitizer = $cleanAfterSanitizer
                        cleanAfterResolution = [string]::IsNullOrEmpty($env:GITHUB_TOKEN) -and
                            [string]::IsNullOrEmpty($env:GH_TOKEN)
                        capturedTokenCleared = [string]::IsNullOrEmpty($toolResolutionGitHubToken)
                        semanticCredentialCount = $semanticCredentialEnvironment.Count
                        preflightChildCredentialFree = $preflightChildCredentialFree
                    }
                }
                finally {
                    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
                        if (-not $before.Contains($name)) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
                    }
                    foreach ($entry in $before.GetEnumerator()) {
                        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
                    }
                }
            } $Root $FailTool $WithToken $script:CredentialEarlyBody $script:CredentialSetup $script:CredentialSources $script:CredentialLoop
        }
    }

    # Scenario: Preflight Git or transition validation starts a native child before the full credential sanitizer.
    # Purpose: Exercise actual process inheritance after the validator's early body, exposing no credential value.
    It 'UnitT05_RemovesApiCredentialsBeforePreflightNativeChildren' {
        $result = Invoke-CredentialLifetimeFixture -Root $TestDrive -WithToken $true
        $result.preflightChildCredentialFree | Should -BeTrue
        $result.calls[0].hasGitHubToken | Should -BeTrue
        $result.cleanAfterResolution | Should -BeTrue
    }

    # Scenario: The trusted SkillSpector resolver succeeds but leaves the API token in its parent environment.
    # Purpose: Authenticate that API only, while retaining sanitization and excluding subsequent tool acquisitions.
    It 'UnitT10_AuthenticatesOnlyTheTrustedSkillSpectorResolver' {
        $result = Invoke-CredentialLifetimeFixture -Root $TestDrive -WithToken $true
        $result.failure | Should -BeNullOrEmpty
        $result.cleanAfterSanitizer | Should -BeTrue
        $result.calls.Count | Should -Be 4
        $result.calls[0].tool | Should -BeExactly 'skillspector'
        $result.calls[0].hasGitHubToken | Should -BeTrue
        @($result.calls | Select-Object -Skip 1 | Where-Object hasGitHubToken).Count | Should -Be 0
        @($result.calls | Where-Object hasGhToken).Count | Should -Be 0
        $result.cleanAfterResolution | Should -BeTrue
        $result.capturedTokenCleared | Should -BeTrue
        $result.semanticCredentialCount | Should -Be 0
    }

    # Scenario: The trusted API resolver throws before performing its own credential removal.
    # Purpose: Require the parent finally path to remove both environment and captured credentials.
    It 'UnitT20_CleansCredentialsAfterAnEarlySkillSpectorResolverFailure' {
        $result = Invoke-CredentialLifetimeFixture -Root $TestDrive -WithToken $true -FailTool 'skillspector'
        $result.failure | Should -BeExactly 'fixture resolver failure before its own cleanup'
        $result.calls.Count | Should -Be 1
        $result.calls[0].hasGitHubToken | Should -BeTrue
        $result.cleanAfterSanitizer | Should -BeTrue
        $result.cleanAfterResolution | Should -BeTrue
        $result.capturedTokenCleared | Should -BeTrue
    }

    # Scenario: A later tool acquisition fails after the trusted API resolver returned.
    # Purpose: Prevent a successful API request from leaking credentials into another installer or failure path.
    It 'UnitT30_KeepsLaterResolverFailuresCredentialFree' {
        $result = Invoke-CredentialLifetimeFixture -Root $TestDrive -WithToken $true -FailTool 'skill-validator'
        $result.failure | Should -BeExactly 'fixture resolver failure before its own cleanup'
        $result.calls.Count | Should -Be 2
        $result.calls[0].hasGitHubToken | Should -BeTrue
        $result.calls[1].hasGitHubToken | Should -BeFalse
        $result.cleanAfterResolution | Should -BeTrue
        $result.capturedTokenCleared | Should -BeTrue
    }

    # Scenario: A fork or local validation has no read-only GitHub token.
    # Purpose: Preserve anonymous resolution without introducing a secret or new authorization prerequisite.
    It 'UnitT40_PreservesAnonymousResolutionWhenTheTokenIsAbsent' {
        $result = Invoke-CredentialLifetimeFixture -Root $TestDrive -WithToken $false
        $result.failure | Should -BeNullOrEmpty
        $result.calls.Count | Should -Be 4
        @($result.calls | Where-Object hasGitHubToken).Count | Should -Be 0
        @($result.calls | Where-Object hasGhToken).Count | Should -Be 0
        $result.cleanAfterSanitizer | Should -BeTrue
        $result.cleanAfterResolution | Should -BeTrue
        $result.capturedTokenCleared | Should -BeTrue
    }
}

Describe 'Workflow resolver credential handoff' {
    BeforeAll {
        $workflow = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/standard-v1-candidate-windows.yml') -Raw
        $block = [regex]::Match($workflow,
            '(?ms)^      - name: Validate exact commit with verified PowerShell\r?\n.*?^        run: \|\r?\n(?<code>.*?)(?=^      - name:)')
        if (-not $block.Success) { throw 'The actual validation workflow step is missing.' }
        $code = [regex]::Replace($block.Groups['code'].Value, '(?m)^          ', '')
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'The actual workflow PowerShell must parse.' }
        $statements = @($ast.EndBlock.Statements)
        $firstNative = @($statements | Where-Object {
            $null -ne $_.Find({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand
            }, $true)
        })[0]
        $script:WorkflowEarlyBody = (@($statements | Where-Object {
            $_.Extent.StartOffset -lt $firstNative.Extent.StartOffset
        }).Extent.Text -join "`n")
        $invocation = @($statements | Where-Object {
            $null -ne $_.Find({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.CommandElements[0].Extent.Text -ceq '$powerShellPath'
            }, $true)
        })
        if ($invocation.Count -ne 1) { throw 'The actual verified-validator invocation is ambiguous.' }
        $script:WorkflowInvocation = $invocation[0].Extent.Text

        function Invoke-WorkflowCredentialFixture {
            param([string] $Root, [int] $ValidatorExit)
            $module = New-Module -ScriptBlock {}
            return & $module {
                param($root, $validatorExit, $earlyBody, $invocation)
                $before = [Environment]::GetEnvironmentVariables('Process')
                try {
                    [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'fixture-read-only-api-token', 'Process')
                    [Environment]::SetEnvironmentVariable('GH_TOKEN', 'fixture-unrelated-token', 'Process')
                    [Environment]::SetEnvironmentVariable('NPM_CONFIG_PREFIX', $null, 'Process')
                    $resolverGitHubToken = $null
                    . ([scriptblock]::Create($earlyBody))
                    $child = [Diagnostics.Process]::new()
                    try {
                        $child.StartInfo = [Diagnostics.ProcessStartInfo]::new()
                        $child.StartInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
                        $child.StartInfo.UseShellExecute = $false
                        $child.StartInfo.CreateNoWindow = $true
                        $child.StartInfo.RedirectStandardOutput = $true
                        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
                            "[string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GITHUB_TOKEN','Process')) -and [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GH_TOKEN','Process'))")) {
                            [void]$child.StartInfo.ArgumentList.Add($argument)
                        }
                        if (-not $child.Start()) { throw 'Could not start the workflow preflight probe.' }
                        $output = $child.StandardOutput.ReadToEndAsync()
                        if (-not $child.WaitForExit(10000)) { $child.Kill($true); throw 'Workflow preflight probe timed out.' }
                        if ($child.ExitCode -ne 0) { throw 'Workflow preflight probe failed.' }
                        $preflightCredentialFree = ($output.GetAwaiter().GetResult().Trim() -ceq 'True')
                    }
                    finally { $child.Dispose() }
                    $repositoryRoot = Join-Path $root 'workflow-fixture'
                    [void][IO.Directory]::CreateDirectory((Join-Path $repositoryRoot 'scripts'))
                    $fixture = @'
param($RepositoryRoot, $ArtifactsRoot, $BaseCommit, $TrustedTestCommit, $ExpectedGoRuntimeVersion, $OutputPath)
$result = @{ hasGitHubToken = ($env:GITHUB_TOKEN -ceq 'fixture-read-only-api-token'); hasGhToken = -not [string]::IsNullOrEmpty($env:GH_TOKEN) }
[IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
exit ([int]$env:WORKFLOW_FIXTURE_EXIT)
'@
                    [IO.File]::WriteAllText((Join-Path $repositoryRoot 'scripts/Validate.ps1'), $fixture,
                        [Text.UTF8Encoding]::new($false))
                    [Environment]::SetEnvironmentVariable('WORKFLOW_FIXTURE_EXIT', [string]$validatorExit, 'Process')
                    $powerShellPath = Join-Path $PSHOME 'pwsh.exe'
                    $runDirectory = $root; $reportPath = Join-Path $root 'credential-booleans.json'
                    $baseCommit = ('a' * 40); $checkoutHead = ('b' * 40); $expectedGoRuntimeVersion = 'fixture-runtime'
                    . ([scriptblock]::Create($invocation))
                    $nativeExit = $LASTEXITCODE
                    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
                    [pscustomobject]@{
                        preflightCredentialFree = $preflightCredentialFree
                        validatorHasGitHubToken = $report.hasGitHubToken
                        validatorHasGhToken = $report.hasGhToken
                        validatorExit = $nativeExit
                        parentCredentialFree = [string]::IsNullOrEmpty($env:GITHUB_TOKEN) -and [string]::IsNullOrEmpty($env:GH_TOKEN)
                        capturedTokenCleared = [string]::IsNullOrEmpty($resolverGitHubToken)
                    }
                }
                finally {
                    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
                        if (-not $before.Contains($name)) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
                    }
                    foreach ($entry in $before.GetEnumerator()) {
                        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
                    }
                }
            } $Root $ValidatorExit $script:WorkflowEarlyBody $script:WorkflowInvocation
        }
    }

    # Scenario: The workflow preflight launches children, then the verified validator succeeds or exits early.
    # Purpose: Exercise real process inheritance and the actual workflow handoff/finally without exposing a token.
    It 'UnitT10_ConfinesWorkflowCredentialsToTheTrustedValidator_Exit<exitCode>' -ForEach @(
        @{ exitCode = 0 }, @{ exitCode = 23 }
    ) {
        $result = Invoke-WorkflowCredentialFixture -Root $TestDrive -ValidatorExit $exitCode
        $result.preflightCredentialFree | Should -BeTrue
        $result.validatorHasGitHubToken | Should -BeTrue
        $result.validatorHasGhToken | Should -BeFalse
        $result.validatorExit | Should -Be $exitCode
        $result.parentCredentialFree | Should -BeTrue
        $result.capturedTokenCleared | Should -BeTrue
    }
}

Describe 'Canonical Standard v1 validation adapter' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $script:Validator = Get-Content -LiteralPath $script:ValidatorPath -Raw
        $script:Adapter = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw |
            ConvertFrom-Json -Depth 20

        $tokens = $null
        $parseErrors = $null
        $validatorAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:Validator, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'Validate.ps1 must parse before the SkillSpector probe is built.' }
        $probeFunctions = $validatorAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                @('Get-RequiredProperty', 'Assert-SkillSpectorReport') -contains $node.Name
        }, $true)
        if ($probeFunctions.Count -ne 2) { throw 'The SkillSpector completeness probe could not find its validator functions.' }
        $probeSource = ($probeFunctions | Sort-Object { $_.Extent.StartOffset } |
            ForEach-Object { $_.Extent.Text }) -join "`n"
        $probeSource += "`nExport-ModuleMember -Function Assert-SkillSpectorReport"
        $script:SkillSpectorProbeSource = $probeSource
    }

    It 'binds the immutable candidate before any external authority or tool acquisition' {
        $candidateIndex = $script:Validator.IndexOf('status --porcelain=v1')
        $authorityIndex = $script:Validator.IndexOf('Invoke-WebRequest -Uri $adapter.authority.archiveUrl')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $candidateIndex | Should -BeGreaterThan -1
        $authorityIndex | Should -BeGreaterThan $candidateIndex
        $resolverIndex | Should -BeGreaterThan $authorityIndex
    }

    It 'verifies bundle and authority file identities before invoking the central resolver' {
        $archiveHashIndex = $script:Validator.IndexOf('$archiveHash -cne')
        $fileHashIndex = $script:Validator.IndexOf('$fileHash -cne')
        $resolverIndex = $script:Validator.IndexOf('& $resolverPath -PolicyPath')

        $archiveHashIndex | Should -BeGreaterThan -1
        $fileHashIndex | Should -BeGreaterThan $archiveHashIndex
        $resolverIndex | Should -BeGreaterThan $fileHashIndex
    }

    It 'rejects ambiguous JSON evidence and repository-local artifact destinations' {
        $script:Validator | Should -Match 'Assert-NoDuplicateJsonProperties'
        $script:Validator | Should -Match 'not valid unambiguous UTF-8 JSON'
        $script:Validator | Should -Match 'Artifacts root must be outside the candidate repository'
        $script:Validator | Should -Match "Assert-PathWithinRoot.*-Context 'Conformance output'"
    }

    It 'normalizes the event base to one distinct immutable ancestor' {
        $script:Validator | Should -Match 'rev-parse --verify --end-of-options'
        $script:Validator | Should -Match 'merge-base --is-ancestor'
        $script:Validator | Should -Match 'Base commit must be a distinct ancestor'
        $script:Validator | Should -Match 'baseCommit = \$resolvedBaseCommit'
    }

    It 'scans the complete candidate tree when comparison base is absent' {
        # Scenario: A push or manual run has no trusted event base.
        # Purpose: Check every committed candidate path instead of only HEAD's parent.
        $script:Validator | Should -Match 'emptyTreeObject = ''4b825dc642cb6eb9a060e54bf8d69288fbee4904'''
        $script:Validator | Should -Match ([regex]::Escape("'diff'") + '.*' + [regex]::Escape("'--check'") + '.*' + [regex]::Escape('$emptyTreeObject') + '.*' + [regex]::Escape("'HEAD'"))
        $script:Validator | Should -Not -Match 'diff-tree.*--root.*HEAD'
    }

    It 'rejects reparse-backed resolved tool paths before execution' {
        $script:Validator | Should -Match 'Assert-NoReparseAncestors'
        $script:Validator | Should -Match 'Assert-NoReparseAncestors -Path \$path -Context "\$Context installed file"'
        $script:Validator | Should -Match 'is backed by a reparse point'
    }

















    It 'verifies host runtimes by absolute path and hash while keeping package files run-owned' {
        $script:Validator | Should -Match 'function Assert-ExternalReceiptFile'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ExternalReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'nodePath'"))
        $script:Validator | Should -Match 'receipt path must be absolute'
        $script:Validator | Should -Match 'runtime file changed after resolution'
        $script:Validator | Should -Match ([regex]::Escape("Assert-ReceiptFile -Receipt `$receipts.'skill-tools' -PathProperty 'entryPointPath'"))
    }

    It 'freezes all four formal tools and imports the central security gate before scanning' {
        @($script:Adapter.PSObject.Properties.Name) | Should -Not -Contain 'security'
        $script:Validator | Should -Match '\.\s+\$authorityGatePath -DefineFunctionsOnly'
        $script:Validator | Should -Match 'Assert-AuthorityValidationSecurityGate'
        $script:Validator | Should -Not -Match 'adapter\.security|blockSeverities|security\.(suppressions|exceptions)'
        $script:Validator | Should -Match "'skillspector' = 'NVIDIA/SkillSpector'"
        $script:Validator | Should -Match "'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'"
        $script:Validator | Should -Match "'skill-tools' = 'npm:skill-tools'"
        $script:Validator | Should -Match "'pester' = 'PowerShellGallery:Pester'"
        $script:Validator | Should -Match '\$resolverPath\s+-PolicyPath \$policyPath\s+-ToolName \$toolName\s+-Install\s+-InstallRoot \$installRoot\s+-ExpectedGoRuntimeVersion \$ExpectedGoRuntimeVersion'

        $freezeIndex = $script:Validator.IndexOf('foreach ($toolName in $expectedSources.Keys)')
        $packageIndex = $script:Validator.IndexOf('skill-validator package validation for')
        $staticIndex = $script:Validator.IndexOf("'--no-llm'")
        $repositoryIndex = $script:Validator.IndexOf('$repositoryReportPath')
        $staticIndex | Should -BeGreaterThan $freezeIndex
        $packageIndex | Should -BeGreaterThan $freezeIndex
        $staticIndex | Should -BeGreaterThan $packageIndex
        $repositoryIndex | Should -BeGreaterThan $staticIndex
    }

    It 'discovers every formal package invocation from catalog source inventory' {
        $script:Validator | Should -Match '\$skillIds\s*=\s*@\(\$integrityReport\.skills'
        $script:Validator | Should -Match 'Assert-SkillSpectorReport'
        $script:Validator | Should -Match 'ExpectedInventoryPaths'
        $script:Validator | Should -Match 'foreach \(\$skillId in \$skillIds\)'
        $script:Validator | Should -Match "validate', 'structure', '--allow-dirs=agents'"
        $script:Validator | Should -Match "'check', '--strict', '--allow-dirs=agents'"
        $script:Validator | Should -Match ([regex]::Escape("'check', `$skillRoot, '--format', 'sarif'"))
    }

    # Scenario: A SkillSpector report fails one completeness gate or contains hostile status text.
    # Purpose: Emit one bounded, sanitized diagnostic while preserving fail-closed rejection.
    It 'UnitT30_ReportsSanitizedSkillSpectorCompletenessFailures' {
        $completeness = [pscustomobject]@{
            execution_successful = $true
            is_complete = $true
            status = 'complete'
            coverage_percent = 100
            ledger_exceptions = @()
            scope_exclusions = @()
            limitations = @()
        }
        $report = [pscustomobject]@{
            execution_successful = $false
            analysis_completeness = $completeness
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @()
                } $report
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'execution_successful'
            $failure.Message | Should -Match 'did not prove complete static analysis'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: The report status contains an attacker-controlled long value and marker.
    # Purpose: Keep diagnostics bounded and prevent untrusted report strings from reaching output.
    It 'UnitT31_RedactsAndBoundsHostileCompletenessStrings' {
        $hostileStatus = 'partial;SECRET_MARKER=' + ('x' * 4096)
        $report = [pscustomobject]@{
            execution_successful = $true
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $true
                status = $hostileStatus
                coverage_percent = 100
                ledger_exceptions = @()
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @()
                } $report
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $diagnostic = $failure.Message
            $diagnostic | Should -Match 'analysis_completeness.status'
            $diagnostic.Length | Should -BeLessThan 500
            $diagnostic | Should -Not -Match 'SECRET_MARKER'
            $failure.Message | Should -Match 'did not prove complete static analysis'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: A required completeness gate field is absent from the report.
    # Purpose: Identify missing gate evidence safely and continue to reject the report.
    It 'UnitT32_ReportsMissingCompletenessGateFieldsAndRejects' {
        $report = [pscustomobject]@{
            execution_successful = $true
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                status = 'complete'
                coverage_percent = 100
                ledger_exceptions = @()
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @()
                } $report
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'analysis_completeness.is_complete=missing'
            $failure.Message | Should -Match 'did not prove complete static analysis'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: SkillId contains a newline and attacker-controlled marker text.
    # Purpose: Keep both the generic rejection and diagnostic free of raw SkillId content.
    It 'UnitT33_RedactsHostileSkillIdInCompletenessFailure' {
        $hostileSkillId = "bad`nSECRET_SKILL_ID" + ('x' * 4096)
        $report = [pscustomobject]@{
            execution_successful = $false
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $true
                status = 'complete'
                coverage_percent = 100
                ledger_exceptions = @()
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport, $probeSkillId)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId $probeSkillId -ExpectedInventoryPaths @()
                } $report $hostileSkillId
            }
            catch { $failure = $_.Exception }

            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'did not prove complete static analysis'
            $failure.Message | Should -Match 'skillId=\[redacted\]'
            $failure.Message | Should -Not -Match 'SECRET_SKILL_ID'
            $failure.Message | Should -Not -Match '[\r\n]'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: An exact candidate's scanner reports known parse limits for two inventory files.
    # Purpose: Preserve a bounded, candidate-bound ledger clue in the failing CI log without exposing raw report text.
    It 'UnitT34_ReportsOnlyBoundedInventoryIndicesForIncompleteStaticAnalysis' {
        $report = [pscustomobject]@{
            execution_successful = $true
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $false
                status = 'partial'
                coverage_percent = 36
                ledger_exceptions = @(
                    [pscustomobject]@{ path = 'SKILL.md'; reason_code = 'static_parse_limit'; message = 'SECRET_MARKER' },
                    [pscustomobject]@{ path = 'scripts/tool.ps1'; reason_code = 'static_parse_limit'; message = 'SECRET_MARKER' }
                )
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @('SKILL.md', 'scripts/tool.ps1') `
                        -CandidateCommit ('a' * 40) -ScannerVersion '2.12.0' -InventorySha256 ('b' * 64)
                } $report
            }
            catch { $failure = $_.Exception }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'did not prove complete static analysis'
            $failure.Message | Should -Match 'candidateCommit=a{40}'
            $failure.Message | Should -Match 'scannerVersion=2\.12\.0'
            $failure.Message | Should -Match 'inventorySha256=b{64}'
            $failure.Message | Should -Match 'inventoryCount=2'
            $failure.Message | Should -Match 'ledgerTotal=2'
            $failure.Message | Should -Match 'sampledLedgerEntries=2'
            $failure.Message | Should -Match 'staticParseLimitInSample=2'
            $failure.Message | Should -Match 'inventoryIndicesInSample=0,1'
            $failure.Message | Should -Not -Match 'SECRET_MARKER|SKILL\.md|tool\.ps1|[\r\n]'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: An untrusted scanner report contains many hostile ledger values outside the candidate inventory.
    # Purpose: Keep failure diagnostics finite and refuse to echo attacker-controlled path, reason, or message text.
    It 'UnitT35_BoundsAndRedactsHostileStaticLedgerValues' {
        $entries = @(1..40 | ForEach-Object {
            [pscustomobject]@{ path = "SECRET_MARKER`n$_"; reason_code = 'SECRET_MARKER'; message = 'SECRET_MARKER' }
        })
        $report = [pscustomobject]@{
            execution_successful = $true
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $false
                status = 'partial'
                coverage_percent = 36
                ledger_exceptions = $entries
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @('SKILL.md')
                } $report
            }
            catch { $failure = $_.Exception }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'ledgerTotal=40'
            $failure.Message | Should -Match 'sampledLedgerEntries=32'
            $failure.Message | Should -Match 'truncated=true'
            $failure.Message.Length | Should -BeLessThan 600
            $failure.Message | Should -Not -Match 'SECRET_MARKER|[\r\n]'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    It 'UnitT36_LabelsTheFirst32LedgerEntriesAsASampleWhenParseLimitsFollow' {
        $entries = @((1..32 | ForEach-Object {
            [pscustomobject]@{ path = 'SECRET_MARKER'; reason_code = 'other_reason'; message = 'SECRET_MARKER' }
        })) + @([pscustomobject]@{ path = 'SKILL.md'; reason_code = 'static_parse_limit'; message = 'SECRET_MARKER' })
        $report = [pscustomobject]@{
            execution_successful = $true
            analysis_completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $false
                status = 'partial'
                coverage_percent = 36
                ledger_exceptions = $entries
                scope_exclusions = @()
                limitations = @()
            }
        }
        $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
            -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
        try {
            $failure = $null
            try {
                & $probeModule {
                    param($probeReport)
                    Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                        -SkillId 'sample-skill' -ExpectedInventoryPaths @('SKILL.md')
                } $report
            }
            catch { $failure = $_.Exception }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Message | Should -Match 'ledgerTotal=33'
            $failure.Message | Should -Match 'sampledLedgerEntries=32'
            $failure.Message | Should -Match 'staticParseLimitInSample=0'
            $failure.Message | Should -Match 'inventoryIndicesInSample=none'
            $failure.Message | Should -Match 'truncated=true'
            $failure.Message | Should -Not -Match 'SECRET_MARKER|SKILL\.md|[\r\n]'
        }
        finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
    }

    It 'UnitT37_RedactsUnexpectedLedgerDespiteNominalCompleteness' {
        foreach ($fieldName in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
            $completeness = [pscustomobject]@{
                execution_successful = $true
                is_complete = $true
                status = 'complete'
                coverage_percent = 100
                ledger_exceptions = @()
                scope_exclusions = @()
                limitations = @()
            }
            $completeness.$fieldName = @([pscustomobject]@{
                path = "SECRET_MARKER`npath"
                reason_code = 'SECRET_MARKER'
                message = 'SECRET_MARKER'
            })
            $report = [pscustomobject]@{ execution_successful = $true; analysis_completeness = $completeness }
            $probeModule = New-Module -Name "SkillSpectorProbe_$([guid]::NewGuid().ToString('N'))" `
                -ScriptBlock ([scriptblock]::Create($script:SkillSpectorProbeSource))
            try {
                $failure = $null
                try {
                    & $probeModule {
                        param($probeReport)
                        Assert-SkillSpectorReport -Report $probeReport -SkillRoot 'C:\candidate\skills\sample' `
                            -SkillId 'sample-skill' -ExpectedInventoryPaths @('SKILL.md')
                    } $report
                }
                catch { $failure = $_.Exception }
                $failure | Should -Not -BeNullOrEmpty
                $failure.Message | Should -Match "$fieldName.*count=1"
                $failure.Message | Should -Not -Match 'SECRET_MARKER|[\r\n]'
            }
            finally { Remove-Module -Name $probeModule.Name -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'accepts a clean skill-tools SARIF report with no findings' {
        $start = $script:Validator.IndexOf('function Assert-SkillToolsReport')
        $end = $script:Validator.IndexOf('function Assert-PathWithinRoot')
        $start | Should -BeGreaterThan -1
        $end | Should -BeGreaterThan $start
        $skillToolsValidator = $script:Validator.Substring($start, $end - $start)
        $skillToolsValidator | Should -Match '\$driverName -cne ''skill-tools'''
        $skillToolsValidator | Should -Match '\$rules -isnot \[array\]'
        $skillToolsValidator | Should -Match '\$results -isnot \[array\]'
        $skillToolsValidator | Should -Not -Match '\$rules\)\.Count -le 0'
        $skillToolsValidator | Should -Not -Match '\$results\)\.Count -le 0'
        $skillToolsValidator | Should -Match 'skill-tools SARIF contains a malformed or error-level result'
    }

    # Scenario: Canonical validation emits run-owned evidence after the security preflight.
    # Purpose: Keep candidate-controlled paths out of evidence and retain every required review boundary.
    It 'UnitT70_KeepsReportsInTheRunArtifactsRootAndRecordsReviewBoundaries' {
        $script:Validator | Should -Match ([regex]::Escape("Join-Path `$runRoot 'conformance-report.json'"))
        $script:Validator | Should -Match 'canonicalGate = \[ordered\]@'
        $script:Validator | Should -Match 'executionBoundary = \[ordered\]@'
        $script:Validator | Should -Match 'assertionInventory = \[ordered\]@'
        $script:Validator | Should -Match 'security-preflight\.json'
        $script:Validator | Should -Match 'security-preflight-summary\.json'
        $script:Validator | Should -Match 'Get-SanitizedSecurityFindingValue'
        $script:Validator | Should -Match 'Select-Object -First 64'
        $script:Validator | Should -Match "policyPath = 'docs/standards/validation-security-gate.json'"
        $script:Validator | Should -Match "aiReview = 'required-before-release'"
        $script:Validator | Should -Match "humanApproval = 'required-before-release'"
        $script:Validator | Should -Match "postInstallVerification = 'required-after-install'"
        $script:Validator | Should -Match "deviations = 'None'"
    }

    # Scenario: Static candidate checks remain offline while an explicitly enabled semantic scan uses its trusted profile.
    # Purpose: Prevent optional semantic scanning from weakening deterministic failure or credential isolation.
    It 'UnitT80_ModelsSemanticScanAsADeterministicFailClosedConditionalStage' {
        $script:Validator | Should -Match 'Test-SecurityRelevantSkillChange'
        $script:Validator | Should -Match '\$staticFindingCount -gt 0'
        $script:Validator | Should -Match 'Triggered SkillSpector semantic scan did not complete'
        $script:Validator | Should -Match '\[switch\] \$EnableSemanticScan'
        $script:Validator | Should -Match '\$semanticTriggered = \[bool\]\$EnableSemanticScan -and'
        $script:Validator | Should -Match 'repository-validation-post-pester'
        $script:Validator | Should -Match 'Invoke-ProtectedPesterRunspace'
        $script:Validator | Should -Match 'CreateOutOfProcessRunspace'
        $script:Validator | Should -Match '\$trustedPesterSupervisorMarker'
        $script:Validator | Should -Match '\$completionAttestationNonce'
        $script:Validator | Should -Match "completionAttestation = 'trusted-parent-post-exit'"
        $script:Validator | Should -Not -Match 'NamedPipeServerStream|NamedPipeClientStream|CompletionPipeName|CompletionToken|workerResultMarker'
        $script:Validator | Should -Match "ValidateSet\('Offline', 'TrustedSemantic'\)"
        $script:Validator | Should -Match '-NetworkProfile Offline'
        $script:Validator | Should -Match '-NetworkProfile TrustedSemantic'
        $script:Validator | Should -Match 'IsolateRunnerCommandFiles'
        $script:Validator | Should -Match 'TerminateProcessTree'
        $script:Validator | Should -Match 'ProtectRunnerCommandFiles'
        $script:Validator | Should -Match 'function New-ContainedProcessEnvironment'
        $script:Validator | Should -Match 'function Protect-ProcessCredentialEnvironment'
        $script:Validator | Should -Match 'SemanticCredentialNames'
        $script:Validator | Should -Match 'AdditionalEnvironmentVariables'
        $script:Validator | Should -Match 'EnvironmentVariables\.Clear\(\)'
        $script:Validator | Should -Match 'ACTIONS_RUNTIME_TOKEN'
        $script:Validator | Should -Match 'Assert-RunnerCommandFilesUnchanged'
        $script:Validator | Should -Match 'standard_v1_evidence_sha256'
        $script:Validator | Should -Not -Match 'pesterResultPath'
        $script:Validator | Should -Not -Match ([regex]::Escape("'-OutputPath', `$pesterResultPath"))
        $script:Validator | Should -Match 'postPesterCandidateCommit'
        $script:Validator | Should -Match 'postPesterTree'
        $script:Validator | Should -Match 'prePesterGitIndexSha256'
        $script:Validator | Should -Match 'Get-RepositoryRawSnapshot'
        $script:Validator | Should -Match 'Assert-RepositoryRawSnapshotUnchanged'
        $script:Validator | Should -Match 'postPesterRepositoryRawSnapshot'
        $script:Validator | Should -Match 'SkillSpector semantic scanner'
        $script:Validator | Should -Match 'Assert-ReceiptFile -Receipt \$receipts\.skillspector'
        $script:Validator | Should -Match 'Assert-ReceiptInstalledClosure'
        $script:Validator | Should -Match 'installedClosureSha256'
        $script:Validator | Should -Match 'installed closure contains a reparse point'
        $script:Validator | Should -Match 'Get-ChildItem -LiteralPath \$root -Recurse -Force'
        $script:Validator | Should -Match 'GIT_CONFIG_NOSYSTEM'
        $script:Validator | Should -Match 'core\.hooksPath'
        $script:Validator | Should -Match '\$repositoryValidatorPath'
        $script:Validator | Should -Match 'pesterRunnerPath'
        $script:Validator | Should -Match 'Invoke-TrustedPowerShellProcess -Command \$powerShellPath'
        $script:Validator | Should -Match "'-NoProfile'"
        $script:Validator | Should -Match "'route'"
        $script:Validator | Should -Match 'skill-tools route did not return exactly one result'
        $script:Validator | Should -Match '\$routeResults = @\(Read-JsonFile'
        $script:Validator | Should -Not -Match '\$routeResults -isnot \[array\]'
        $script:Validator | Should -Not -Match 'semantic.*continue|continue.*semantic'
        $semanticIndex = $script:Validator.IndexOf('$semanticTriggerCandidate')
        $pesterIndex = $script:Validator.IndexOf('$pesterRunnerPath')
        $semanticIndex | Should -BeGreaterThan -1
        $pesterIndex | Should -BeGreaterThan $semanticIndex
    }

    It 'keeps required CI free of implicit LLM credentials and skipped tests' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot '.github/workflows/standard-v1-candidate-windows.yml') -Raw
        $workflow | Should -Not -Match 'EnableSemanticScan'
        $script:Validator | Should -Match 'credential-free and deterministic'
        $script:Validator | Should -Match 'SkippedCount -ne 0'
        $script:Validator | Should -Match "SKILLSPECTOR_MAX_WORKFLOW_SECONDS.*=.*'1200'"
        $script:Validator | Should -Match 'authoritative 300-second execution limit'
        $script:Validator | Should -Match '-AdditionalEnvironmentVariables \$skillSpectorRuntimeEnvironment'
        $repositoryValidator = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1') -Raw
        $repositoryValidator | Should -Match 'rawSha256'
        $repositoryValidator | Should -Match '\[string\] \$TrustedGitPath'
        $repositoryValidator | Should -Match '\[switch\] \$NoFilters'
        $repositoryValidator | Should -Match 'NoFilters:\$NoFilters'
    }

}

Describe 'Protected workflow trust binding' {
    BeforeAll {
        $script:TrustRepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:TrustValidator = Get-Content -LiteralPath (Join-Path $script:TrustRepositoryRoot 'scripts/Validate.ps1') -Raw




    }











    # Scenario: Two installed paths share an ordinal, NFC or ASCII-folded identity.
    # Purpose: Fail closed using actual production helpers, including canonically equivalent Unicode.
    It 'UnitT55_RejectsCollidingInstalledPaths_<kind>' -ForEach @(
        @{ kind = 'NFC'; first = "$([char]0xE9).txt"; second = "e$([char]0x301).txt"; message = '*Unicode-normalization-colliding*' },
        @{ kind = 'case'; first = 'A.txt'; second = 'a.txt'; message = '*ASCII-case-colliding*' },
        @{ kind = 'duplicate'; first = 'a.txt'; second = 'a.txt'; message = '*duplicate path*' }
    ) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:TrustValidator, [ref]$tokens, [ref]$errors)
        $functions = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @('Assert-InstalledClosureSafeRelativePath', 'Get-InstalledClosureAsciiCaseFold', 'Add-InstalledClosureEntry')
        }, $true)
        @($errors).Count | Should -Be 0
        @($functions).Count | Should -Be 3
        $module = New-Module -ScriptBlock ([scriptblock]::Create(($functions.Extent.Text -join "`n")))
        { & $module {
            param($one, $two)
            $entries = [Collections.Generic.List[object]]::new()
            $ordinal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $nfc = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $ascii = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            foreach ($path in @($one, $two)) {
                Add-InstalledClosureEntry -Entries $entries -OrdinalPaths $ordinal -NfcPaths $nfc -AsciiCasePaths $ascii -Entry @{ path = $path; sha256 = ('a' * 64) } -Context 'fixture'
            }
        } $first $second } | Should -Throw $message
    }


}
