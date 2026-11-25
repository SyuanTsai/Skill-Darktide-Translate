# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest

function Get-ImmutableWorksetContractSha256 {
    param([Collections.IDictionary] $Workset)

    $unitContracts = @($Workset.units | ForEach-Object {
        [ordered]@{
            unitId = $_.unitId; sourceId = $_.sourceId; containerPath = $_.containerPath
            key = $_.key; occurrence = $_.occurrence; old = $_.old; new = $_.new
            changeType = $_.changeType; action = $_.action; blockedReason = $_.blockedReason
        }
    })
    $contract = [ordered]@{
        schemaVersion = $Workset.schemaVersion
        workflowSchemaVersion = $Workset.workflowSchemaVersion
        generatorVersion = $Workset.generatorVersion
        baseOid = $Workset.baseOid
        sourceId = $Workset.sourceId
        modRelativePath = $Workset.modRelativePath
        old = $Workset.old
        new = $Workset.new
        counts = $Workset.counts
        units = $unitContracts
    }
    switch ($Workset.generatorVersion) {
        1 {
            if ($Workset.Contains('translationBinding')) { throw 'Version 1 immutable contract cannot contain a translation binding.' }
        }
        2 {
            $binding = $Workset['translationBinding']
            if ($binding -isnot [Collections.IDictionary] -or $binding.Count -ne 6 -or
                ($binding['bindingVersion'] -isnot [int] -and $binding['bindingVersion'] -isnot [long]) -or
                $binding.bindingVersion -ne 1 -or $binding['mode'] -cnotin @('update', 'improve') -or
                $binding['modelId'] -isnot [string] -or [string]::IsNullOrWhiteSpace($binding.modelId) -or
                $binding['rulesSha256'] -isnot [string] -or $binding.rulesSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $binding['glossarySha256'] -isnot [string] -or $binding.glossarySha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $binding['rulesManifest'] -isnot [array]) {
                throw 'Version 2 immutable contract requires a valid translation binding.'
            }
            $contract.translationBinding = $binding
        }
        default { throw 'Localization workset generator version is unsupported.' }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($contract | ConvertTo-Json -Depth 40 -Compress))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-LocalizationGitBlobBytes {
    param([string] $WorkingDirectory, [string] $Object, [scriptblock] $HeartbeatAction)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $memory = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw 'Unable to start Git for immutable localization blob.' }
        $process.StandardInput.Close()
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
            if ($HeartbeatAction) { $null = & $HeartbeatAction }
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Unable to read immutable localization blob: $errorText" }
        return ,$memory.ToArray()
    }
    finally { $memory.Dispose(); $process.Dispose() }
}

function Read-LocalizationRuleFile {
    param([string] $SkillRoot, [string] $RelativePath)

    $path = $SkillRoot
    foreach ($part in @('.') + $RelativePath.Split('/')) {
        $path = Join-Path $path $part
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Skill translation rule path is a reparse point: $path"
        }
    }
    return ,[IO.File]::ReadAllBytes($path)
}

function Get-LocalizationTranslationBinding {
    param(
        [Parameter(Mandatory)][string] $SkillRoot,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $BaseOid,
        [Parameter(Mandatory)][ValidateSet('update', 'improve')][string] $Mode,
        [Parameter(Mandatory)][string] $ModRelativePath,
        [string] $ModelId,
        [scriptblock] $HeartbeatAction
    )

    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $manifestBytes = Read-LocalizationRuleFile -SkillRoot $skillRoot -RelativePath 'assets/api-rules-manifest.json'
    $manifest = $utf8.GetString($manifestBytes).TrimStart([char]0xfeff) | ConvertFrom-Json -AsHashtable
    if ($manifest.manifestVersion -ne 1) { throw 'Translation rules manifest version is unsupported.' }
    if ([string]::IsNullOrEmpty($ModelId)) {
        $configBytes = Read-LocalizationRuleFile -SkillRoot $skillRoot -RelativePath 'assets/api-translation.json'
        $config = $utf8.GetString($configBytes).TrimStart([char]0xfeff) | ConvertFrom-Json -AsHashtable
        $ModelId = $config.model
    }
    if ([string]::IsNullOrWhiteSpace($ModelId)) { throw 'Translation model ID is required.' }
    $Mode = $Mode.ToLowerInvariant()
    $modName = $ModRelativePath.Split('/')[-1]
    $prefix = 'skills/auto-update-darktide-mod/'
    $selected = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $manifest.files) {
        if ($Mode -cnotin $entry.modes -or
            ($null -ne $entry.modFilter -and -not [string]::Equals($entry.modFilter, $modName, [StringComparison]::OrdinalIgnoreCase))) {
            continue
        }
        $path = [string]$entry.path
        if ($entry.repo -cnotin @('skill', 'mods') -or $path -cmatch '[\\:\x00-\x1f]' -or
            @($path.Split('/') | Where-Object { $_ -cin @('', '.', '..') }).Count -ne 0 -or
            ($entry.repo -ceq 'skill' -and -not $path.StartsWith($prefix, [StringComparison]::Ordinal))) {
            throw "Invalid translation rule path: $path"
        }
        $key = "$($entry.repo)`t$path"
        if ($selected.ContainsKey($key)) { throw "Duplicate translation rule: $key" }
        $selected.Add($key, $entry)
    }
    $payload = [Text.StringBuilder]::new()
    $rows = @(foreach ($key in $selected.Keys) {
        $entry = $selected[$key]
        [byte[]]$bytes = if ($entry.repo -ceq 'skill') {
            Read-LocalizationRuleFile -SkillRoot $skillRoot -RelativePath $entry.path.Substring($prefix.Length)
        }
        else {
            Get-LocalizationGitBlobBytes -WorkingDirectory $RepositoryRoot -Object ("${BaseOid}:" + $entry.path) -HeartbeatAction $HeartbeatAction
        }
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $null = $payload.Append("$key`t$sha256`n")
        [ordered]@{ repo = $entry.repo; path = $entry.path; sha256 = $sha256 }
    })
    $glossary = Get-LocalizationGitBlobBytes -WorkingDirectory $RepositoryRoot -Object "${BaseOid}:Referneces/Translation.md" -HeartbeatAction $HeartbeatAction
    [ordered]@{
        bindingVersion = 1
        mode = $Mode
        modelId = $ModelId
        rulesSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($payload.ToString()))).ToLowerInvariant()
        glossarySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($glossary)).ToLowerInvariant()
        rulesManifest = $rows
    }
}

Export-ModuleMember -Function Get-ImmutableWorksetContractSha256, Get-LocalizationTranslationBinding, Get-LocalizationGitBlobBytes
