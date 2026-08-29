function ConvertFrom-TestJsonToken {
    param([AllowNull()][Newtonsoft.Json.Linq.JToken] $Token, [switch] $AsHashtable)
    if ($null -eq $Token -or $Token.Type -in @(
        [Newtonsoft.Json.Linq.JTokenType]::Null,
        [Newtonsoft.Json.Linq.JTokenType]::Undefined
    )) { return $null }
    if ($Token -is [Newtonsoft.Json.Linq.JObject]) {
        $properties = [ordered]@{}
        foreach ($property in $Token.Properties()) {
            $properties[[string]$property.Name] = ConvertFrom-TestJsonToken -Token $property.Value -AsHashtable:$AsHashtable
        }
        if ($AsHashtable) { return $properties }
        return [pscustomobject]$properties
    }
    if ($Token -is [Newtonsoft.Json.Linq.JArray]) {
        $items = [object[]]::new($Token.Count)
        for ($index = 0; $index -lt $Token.Count; $index++) {
            $items[$index] = ConvertFrom-TestJsonToken -Token $Token[$index] -AsHashtable:$AsHashtable
        }
        Write-Output -NoEnumerate $items
        return
    }
    ([Newtonsoft.Json.Linq.JValue]$Token).Value
}

function ConvertFrom-TestJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $InputObject,
        [switch] $AsHashtable
    )
    process {
        $parameters = @{ InputObject = $InputObject }
        if ($AsHashtable) { $parameters.AsHashtable = $true }
        $nativeCommand = Get-Command -Name 'Microsoft.PowerShell.Utility\ConvertFrom-Json'
        if ($nativeCommand.Parameters.ContainsKey('DateKind')) {
            $parameters.DateKind = 'String'
            Microsoft.PowerShell.Utility\ConvertFrom-Json @parameters
            return
        }
        $settings = [Newtonsoft.Json.JsonSerializerSettings]::new()
        $settings.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
        $token = [Newtonsoft.Json.JsonConvert]::DeserializeObject($InputObject, $settings)
        ConvertFrom-TestJsonToken -Token $token -AsHashtable:$AsHashtable
    }
}

function New-TestSkillSourcePin {
    param(
        [Parameter(Mandatory)][string] $SkillRoot,
        [Parameter(Mandatory)][string] $OutputPath
    )

    $skillPath = '.agents/skills/auto-update-darktide-mod'
    $files = @(
        Get-ChildItem -LiteralPath $SkillRoot -File -Recurse | ForEach-Object {
            $bytes = [IO.File]::ReadAllBytes($_.FullName)
            $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.LongLength)`0")
            [ordered]@{
                repositoryPath = $skillPath + '/' + [IO.Path]::GetRelativePath($SkillRoot, $_.FullName).Replace('\', '/')
                mode = '100644'
                blobOid = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header + $bytes))).ToLowerInvariant()
                size = $bytes.LongLength
                sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            }
        } | Sort-Object { $_.repositoryPath } -CaseSensitive
    )
    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes(($files | ConvertTo-Json -Depth 10 -Compress))
    $pin = [ordered]@{
        schemaVersion = 1
        sourceId = 'darktide-translate'
        repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
        requestedRef = 'test-fixture'
        resolvedCommit = '1111111111111111111111111111111111111111'
        resolvedVersion = '0.3.0-test.1'
        contentSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
        skillPath = $skillPath
        skillFiles = $files
    }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $pin | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -NoNewline
    [IO.Path]::GetFullPath($OutputPath)
}

function Set-TestRunSkillSourcePin {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][string] $SourcePinPath
    )

    $pinDirectory = Join-Path ([string]$State.runRoot) 'review-artifacts'
    New-Item -ItemType Directory -Path $pinDirectory -Force | Out-Null
    $runPinPath = [IO.Path]::GetFullPath((Join-Path $pinDirectory 'skill-source-pin.json'))
    $sourcePinFull = [IO.Path]::GetFullPath($SourcePinPath)
    if ($sourcePinFull -cne $runPinPath) {
        [IO.File]::Copy($sourcePinFull, $runPinPath, $true)
    }
    $pin = Get-Content -LiteralPath $runPinPath -Raw | ConvertFrom-TestJson -AsHashtable
    $State.workflowRef = [string]$pin.requestedRef
    $State.workflowCommitOid = [string]$pin.resolvedCommit
    $State.workflowSourceRepository = [string]$pin.repository
    $State.workflowSourceVersion = [string]$pin.resolvedVersion
    $State.workflowSourceContentSha256 = [string]$pin.contentSha256
    $State.workflowSourcePinPath = $runPinPath
    $State.workflowSourcePinSha256 = (Get-FileHash -LiteralPath $runPinPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $runPinPath
}

function New-TestPinnedCompletedStageRun {
    param(
        [Parameter(Mandatory)][string] $SkillRoot,
        [Parameter(Mandatory)][string] $FixtureRoot
    )

    $installedParent = Join-Path $FixtureRoot 'installed'
    $installedSkillRoot = Join-Path $installedParent 'auto-update-darktide-mod'
    New-Item -ItemType Directory -Path $installedParent -Force | Out-Null
    Copy-Item -LiteralPath $SkillRoot -Destination $installedSkillRoot -Recurse

    $repository = Join-Path $FixtureRoot 'repository'
    $runId = [guid]::NewGuid().ToString()
    $short = $runId.Replace('-', '').Substring(0, 8)
    $runRoot = Join-Path $repository "AI Auto Update/In Progress/examplemod-$short"
    $artifactsRoot = Join-Path $runRoot 'artifacts'
    $sourceRoot = Join-Path $runRoot 'source'
    $modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
    $lockKeyBytes = [Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant())
    $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($lockKeyBytes)).ToLowerInvariant()
    $modLockPath = Join-Path $repository "AI Auto Update/In Progress/.locks/mod/$lockKey.lock"
    New-Item -ItemType Directory -Path $artifactsRoot, $sourceRoot, $modLockPath -Force | Out-Null

    $artifactPath = Join-Path $artifactsRoot 'archive-listing.json'
    [IO.File]::WriteAllText($artifactPath, '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
    $sourcePath = Join-Path $sourceRoot 'ExampleMod.zip'
    [IO.File]::WriteAllText($sourcePath, 'immutable source evidence', [Text.UTF8Encoding]::new($false))
    $statePath = Join-Path $runRoot 'state.json'
    $state = [ordered]@{
        schemaVersion = 15
        workflowSchemaVersion = 15
        runId = $runId
        statePath = [IO.Path]::GetFullPath($statePath)
        repositoryRoot = [IO.Path]::GetFullPath($repository)
        status = 'source-verified'
        runRoot = [IO.Path]::GetFullPath($runRoot)
        artifactsRoot = [IO.Path]::GetFullPath($artifactsRoot)
        mod = 'ExampleMod'
        repoModDirectory = 'ExampleMod'
        modRelativePath = $modRelativePath
        modLockPath = [IO.Path]::GetFullPath($modLockPath)
        modLockKey = $lockKey
        completedStages = @('verify-source')
        stageTimings = [ordered]@{
            'verify-source' = [ordered]@{
                result = 'passed'
                artifactSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
    $runPinPath = New-TestSkillSourcePin -SkillRoot $installedSkillRoot `
        -OutputPath (Join-Path $runRoot 'review-artifacts/skill-source-pin.json')
    $null = Set-TestRunSkillSourcePin -State $state -SourcePinPath $runPinPath
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

    $ownerPath = Join-Path $modLockPath 'owner.json'
    $owner = [ordered]@{
        schemaVersion = 2
        runId = $runId
        canonicalModRelativePath = $modRelativePath
        modLockKey = $lockKey
        plannedStatePath = [IO.Path]::GetFullPath($statePath)
        statePath = [IO.Path]::GetFullPath($statePath)
        reservationToken = [guid]::NewGuid().ToString('N')
        workerToken = $null
        machineName = $null
        workerId = $null
        workerProcessStartTicks = $null
        leaseMode = 'reserved'
        reservationState = 'between-stages'
        heartbeat = [DateTimeOffset]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($ownerPath, ($owner | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        SkillRoot = $installedSkillRoot
        RunnerPath = Join-Path $installedSkillRoot 'scripts/mod-update.ps1'
        RepositoryRoot = $repository
        RunRoot = $runRoot
        StatePath = $statePath
        PinPath = $runPinPath
        OwnerPath = $ownerPath
        ArtifactPath = $artifactPath
        SourcePath = $sourcePath
    }
}
