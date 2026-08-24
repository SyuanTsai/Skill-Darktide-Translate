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
