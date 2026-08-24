Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-LuaToken {
    param(
        [Collections.Generic.List[object]] $Tokens,
        [string] $Type,
        [string] $Text,
        [int] $Start
    )
    $Tokens.Add([pscustomobject]@{ type = $Type; text = $Text; start = $Start; length = $Text.Length })
}

function Get-LuaTokens {
    param([Parameter(Mandatory)][string] $Text)
    $tokens = [Collections.Generic.List[object]]::new()
    $index = 0
    while ($index -lt $Text.Length) {
        $character = $Text[$index]
        if ([char]::IsWhiteSpace($character)) { $index++; continue }

        if ($character -eq '-' -and ($index + 1) -lt $Text.Length -and $Text[$index + 1] -eq '-') {
            $longComment = [regex]::Match($Text.Substring($index), '^--\[(=*)\[')
            if ($longComment.Success) {
                $closing = ']' + $longComment.Groups[1].Value + ']'
                $closingIndex = $Text.IndexOf($closing, $index + $longComment.Length, [StringComparison]::Ordinal)
                $index = if ($closingIndex -lt 0) { $Text.Length } else { $closingIndex + $closing.Length }
            }
            else {
                $lineEnd = $Text.IndexOf("`n", $index, [StringComparison]::Ordinal)
                $index = if ($lineEnd -lt 0) { $Text.Length } else { $lineEnd + 1 }
            }
            continue
        }

        if ($character -in @('"', "'")) {
            $start = $index
            $quote = $character
            $index++
            $closed = $false
            while ($index -lt $Text.Length) {
                if ($Text[$index] -eq '\') {
                    $index += [Math]::Min(2, $Text.Length - $index)
                    continue
                }
                if ($Text[$index] -eq $quote) {
                    $index++
                    $closed = $true
                    break
                }
                $index++
            }
            if (-not $closed) { throw "Unterminated Lua quoted string at character $start." }
            Add-LuaToken -Tokens $tokens -Type 'string' -Text $Text.Substring($start, $index - $start) -Start $start
            continue
        }

        if ($character -eq '[') {
            $longString = [regex]::Match($Text.Substring($index), '^\[(=*)\[')
            if ($longString.Success) {
                $start = $index
                $closing = ']' + $longString.Groups[1].Value + ']'
                $closingIndex = $Text.IndexOf($closing, $index + $longString.Length, [StringComparison]::Ordinal)
                if ($closingIndex -lt 0) { throw "Unterminated Lua long string at character $start." }
                $index = $closingIndex + $closing.Length
                Add-LuaToken -Tokens $tokens -Type 'string' -Text $Text.Substring($start, $index - $start) -Start $start
                continue
            }
        }

        if ([char]::IsLetter($character) -or $character -eq '_') {
            $start = $index
            $index++
            while ($index -lt $Text.Length -and ([char]::IsLetterOrDigit($Text[$index]) -or $Text[$index] -eq '_')) { $index++ }
            Add-LuaToken -Tokens $tokens -Type 'identifier' -Text $Text.Substring($start, $index - $start) -Start $start
            continue
        }

        if ([char]::IsDigit($character)) {
            $start = $index
            $index++
            while ($index -lt $Text.Length -and ($Text[$index] -match '[A-Za-z0-9._]')) { $index++ }
            Add-LuaToken -Tokens $tokens -Type 'number' -Text $Text.Substring($start, $index - $start) -Start $start
            continue
        }

        $operatorLength = 1
        foreach ($candidateLength in @(3, 2)) {
            if (($index + $candidateLength) -le $Text.Length -and $Text.Substring($index, $candidateLength) -in @('...', '..', '==', '~=', '<=', '>=', '//', '<<', '>>', '::')) {
                $operatorLength = $candidateLength
                break
            }
        }
        Add-LuaToken -Tokens $tokens -Type 'symbol' -Text $Text.Substring($index, $operatorLength) -Start $index
        $index += $operatorLength
    }
    @($tokens)
}

function Get-IoDofileLoaderCallCount {
    param([object[]] $Tokens)
    $count = 0
    for ($index = 0; $index -le ($Tokens.Count - 4); $index++) {
        if ($Tokens[$index].type -ceq 'identifier' -and $Tokens[$index].text -ceq 'mod' -and
            $Tokens[$index + 1].text -ceq ':' -and
            $Tokens[$index + 2].type -ceq 'identifier' -and $Tokens[$index + 2].text -ceq 'io_dofile' -and
            $Tokens[$index + 3].text -ceq '(') {
            $count++
        }
    }
    $count
}

function Test-IoDofileOnlyLoaderTokens {
    param([object[]] $Tokens)
    if ($Tokens.Count -eq 0) { return $false }
    $index = 0
    $localName = $null
    if ($Tokens.Count -ge 5 -and
        $Tokens[0].type -ceq 'identifier' -and $Tokens[0].text -ceq 'local' -and
        $Tokens[1].type -ceq 'identifier' -and $Tokens[2].text -ceq '=' -and
        $Tokens[3].text -ceq '{' -and $Tokens[4].text -ceq '}') {
        $localName = [string]$Tokens[1].text
        $index = 5
        if ($index -lt $Tokens.Count -and $Tokens[$index].text -ceq ';') { $index++ }
    }

    $callCount = 0
    while (($index + 5) -lt $Tokens.Count -and
        $Tokens[$index].type -ceq 'identifier' -and $Tokens[$index].text -ceq 'mod' -and
        $Tokens[$index + 1].text -ceq ':' -and
        $Tokens[$index + 2].type -ceq 'identifier' -and $Tokens[$index + 2].text -ceq 'io_dofile' -and
        $Tokens[$index + 3].text -ceq '(' -and
        $Tokens[$index + 4].type -ceq 'string' -and
        $Tokens[$index + 5].text -ceq ')') {
        $callCount++
        $index += 6
        if ($index -lt $Tokens.Count -and $Tokens[$index].text -ceq ';') { $index++ }
    }
    if ($callCount -eq 0) { return $false }

    if ($null -ne $localName) {
        if (($index + 1) -ge $Tokens.Count -or
            $Tokens[$index].type -cne 'identifier' -or $Tokens[$index].text -cne 'return' -or
            $Tokens[$index + 1].type -cne 'identifier' -or $Tokens[$index + 1].text -cne $localName) {
            return $false
        }
        $index += 2
        if ($index -lt $Tokens.Count -and $Tokens[$index].text -ceq ';') { $index++ }
    }
    $index -eq $Tokens.Count
}

function ConvertFrom-LuaKeyString {
    param([string] $Literal)
    if ($Literal.StartsWith('[', [StringComparison]::Ordinal)) {
        $longString = [regex]::Match($Literal, '^\[(=*)\[(.*)\]\1\]$', [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $longString.Success) { throw 'Lua long-string key literal is malformed.' }
        $content = $longString.Groups[2].Value
        if ($content.StartsWith("`r`n", [StringComparison]::Ordinal)) { $content = $content.Substring(2) }
        elseif ($content.StartsWith("`n", [StringComparison]::Ordinal) -or $content.StartsWith("`r", [StringComparison]::Ordinal)) { $content = $content.Substring(1) }
        return ($content -replace "`r`n|`r|`n", "`n")
    }
    $content = $Literal.Substring(1, $Literal.Length - 2)
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $bytes = [Collections.Generic.List[byte]]::new()
    for ($index = 0; $index -lt $content.Length; $index++) {
        if ($content[$index] -ne '\') {
            $characterLength = if ([char]::IsHighSurrogate($content[$index]) -and ($index + 1) -lt $content.Length -and
                [char]::IsLowSurrogate($content[$index + 1])) { 2 } else { 1 }
            $bytes.AddRange($encoding.GetBytes($content.Substring($index, $characterLength)))
            $index += $characterLength - 1
            continue
        }
        if (($index + 1) -ge $content.Length) { throw 'Lua key string ends with an incomplete escape.' }
        $index++
        $escaped = $content[$index]
        if ([char]::IsDigit($escaped)) {
            $digitStart = $index
            $digitEnd = $index
            while (($digitEnd + 1) -lt $content.Length -and ($digitEnd - $digitStart) -lt 2 -and [char]::IsDigit($content[$digitEnd + 1])) { $digitEnd++ }
            $value = [int]$content.Substring($digitStart, $digitEnd - $digitStart + 1)
            if ($value -gt 255) { throw 'Lua decimal key escape exceeds one byte.' }
            $bytes.Add([byte]$value)
            $index = $digitEnd
            continue
        }
        switch -CaseSensitive ($escaped) {
            'a' { $bytes.Add(7) }
            'b' { $bytes.Add(8) }
            'f' { $bytes.Add(12) }
            'n' { $bytes.Add(10) }
            'r' { $bytes.Add(13) }
            't' { $bytes.Add(9) }
            'v' { $bytes.Add(11) }
            '\' { $bytes.Add(92) }
            '"' { $bytes.Add(34) }
            "'" { $bytes.Add(39) }
            "`n" { $bytes.Add(10) }
            "`r" {
                if (($index + 1) -lt $content.Length -and $content[$index + 1] -eq "`n") { $index++ }
                $bytes.Add(10)
            }
            'z' {
                while (($index + 1) -lt $content.Length -and [char]::IsWhiteSpace($content[$index + 1])) { $index++ }
            }
            'x' {
                if (($index + 2) -ge $content.Length -or $content.Substring($index + 1, 2) -notmatch '^[0-9A-Fa-f]{2}$') {
                    throw 'Lua hexadecimal key escape must contain exactly two digits.'
                }
                $bytes.Add([Convert]::ToByte($content.Substring($index + 1, 2), 16))
                $index += 2
            }
            'u' {
                $unicode = [regex]::Match($content.Substring($index), '^u\{([0-9A-Fa-f]+)\}')
                if (-not $unicode.Success) { throw 'Lua Unicode key escape is malformed.' }
                $codePoint = [Convert]::ToInt32($unicode.Groups[1].Value, 16)
                if ($codePoint -gt 0x10FFFF -or ($codePoint -ge 0xD800 -and $codePoint -le 0xDFFF)) {
                    throw 'Lua Unicode key escape is outside the valid scalar range.'
                }
                $bytes.AddRange($encoding.GetBytes([char]::ConvertFromUtf32($codePoint)))
                $index += $unicode.Length - 1
            }
            default { throw "Unsupported Lua key string escape: \$escaped" }
        }
    }
    try { $encoding.GetString($bytes.ToArray()) }
    catch { '@bytes:' + [Convert]::ToHexString($bytes.ToArray()).ToLowerInvariant() }
}

function Get-CanonicalTokenText {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex)
    if ($EndIndex -lt $StartIndex) { return '' }
    (@($Tokens[$StartIndex..$EndIndex] | ForEach-Object { $_.text }) -join '')
}

function Get-MatchingTokenIndex {
    param([object[]] $Tokens, [int] $StartIndex, [string] $Open, [string] $Close)
    $depth = 0
    for ($index = $StartIndex; $index -lt $Tokens.Count; $index++) {
        if ($Tokens[$index].text -ceq $Open) { $depth++ }
        elseif ($Tokens[$index].text -ceq $Close) {
            $depth--
            if ($depth -eq 0) { return $index }
        }
    }
    throw "Unmatched Lua token $Open at token index $StartIndex."
}

function Get-LuaKey {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex)
    if ($StartIndex -eq $EndIndex -and $Tokens[$StartIndex].type -eq 'identifier') {
        return [string]$Tokens[$StartIndex].text
    }
    if ($Tokens[$StartIndex].text -ceq '[' -and $Tokens[$EndIndex].text -ceq ']') {
        if (($EndIndex - $StartIndex) -eq 2 -and $Tokens[$StartIndex + 1].type -eq 'string') {
            return ConvertFrom-LuaKeyString -Literal ([string]$Tokens[$StartIndex + 1].text)
        }
        return '[' + (Get-CanonicalTokenText -Tokens $Tokens -StartIndex ($StartIndex + 1) -EndIndex ($EndIndex - 1)) + ']'
    }
    $null
}

function ConvertTo-Utf8ByteOffset {
    param([string] $Text, [int] $CharacterIndex, [int] $BomLength)
    $BomLength + [Text.UTF8Encoding]::new($false, $true).GetByteCount($Text.Substring(0, $CharacterIndex))
}

function New-ExpressionRecord {
    param(
        [string] $Text,
        [object[]] $Tokens,
        [Collections.IDictionary] $Field,
        [int] $BomLength
    )
    $valueStart = [int]$Tokens[$Field.valueStartIndex].start
    $lastToken = $Tokens[$Field.valueEndIndex]
    $valueEnd = [int]$lastToken.start + [int]$lastToken.length
    $fieldStart = [int]$Tokens[$Field.fieldStartIndex].start
    $fieldEnd = $valueEnd
    $separatorStart = $null
    $separatorLength = 0
    if ($null -ne $Field.separatorIndex) {
        $separatorToken = $Tokens[[int]$Field.separatorIndex]
        $separatorStart = ConvertTo-Utf8ByteOffset -Text $Text -CharacterIndex ([int]$separatorToken.start) -BomLength $BomLength
        $separatorLength = [Text.UTF8Encoding]::new($false, $true).GetByteCount([string]$separatorToken.text)
        $fieldEnd = [int]$separatorToken.start + [int]$separatorToken.length
    }
    [ordered]@{
        raw = $Text.Substring($valueStart, $valueEnd - $valueStart)
        canonical = Get-CanonicalTokenText -Tokens $Tokens -StartIndex $Field.valueStartIndex -EndIndex $Field.valueEndIndex
        startByte = ConvertTo-Utf8ByteOffset -Text $Text -CharacterIndex $valueStart -BomLength $BomLength
        lengthByte = [Text.UTF8Encoding]::new($false, $true).GetByteCount($Text.Substring($valueStart, $valueEnd - $valueStart))
        fieldStartByte = ConvertTo-Utf8ByteOffset -Text $Text -CharacterIndex $fieldStart -BomLength $BomLength
        fieldLengthByte = [Text.UTF8Encoding]::new($false, $true).GetByteCount($Text.Substring($fieldStart, $fieldEnd - $fieldStart))
        separatorStartByte = $separatorStart
        separatorLengthByte = $separatorLength
    }
}

function Join-LuaContainerPath {
    param([string] $ContainerPath, [string] $Key)
    if ($Key.StartsWith('[', [StringComparison]::Ordinal)) { return $ContainerPath + $Key }
    $ContainerPath + '.' + $Key
}

function Read-LuaTable {
    param(
        [string] $Text,
        [object[]] $Tokens,
        [int] $OpenIndex,
        [string] $ContainerPath,
        [AllowNull()][string] $AssignedKey,
        [string] $SourceId,
        [Collections.Generic.List[object]] $Units,
        [int] $BomLength
    )
    $closeIndex = Get-MatchingTokenIndex -Tokens $Tokens -StartIndex $OpenIndex -Open '{' -Close '}'
    $fields = [Collections.Generic.List[object]]::new()
    $position = $OpenIndex + 1
    while ($position -lt $closeIndex) {
        while ($position -lt $closeIndex -and $Tokens[$position].text -in @(',', ';')) { $position++ }
        if ($position -ge $closeIndex) { break }
        $fieldStart = $position
        $keyEnd = $position
        $equalsIndex = $null
        if ($Tokens[$position].text -ceq '[') {
            $keyEnd = Get-MatchingTokenIndex -Tokens $Tokens -StartIndex $position -Open '[' -Close ']'
            if (($keyEnd + 1) -lt $closeIndex -and $Tokens[$keyEnd + 1].text -ceq '=') { $equalsIndex = $keyEnd + 1 }
        }
        elseif ($Tokens[$position].type -eq 'identifier' -and ($position + 1) -lt $closeIndex -and $Tokens[$position + 1].text -ceq '=') {
            $equalsIndex = $position + 1
        }

        if ($null -eq $equalsIndex) {
            $position++
            continue
        }
        $key = Get-LuaKey -Tokens $Tokens -StartIndex $fieldStart -EndIndex $keyEnd
        if ([string]::IsNullOrWhiteSpace($key)) { $position = [int]$equalsIndex + 1; continue }
        $valueStart = [int]$equalsIndex + 1
        if ($valueStart -ge $closeIndex) { throw "Lua field $key has no value expression." }
        $braceDepth = 0; $parenDepth = 0; $bracketDepth = 0; $blockDepth = 0
        $valueEnd = $valueStart - 1
        $separatorIndex = $null
        for ($cursor = $valueStart; $cursor -le $closeIndex; $cursor++) {
            $token = [string]$Tokens[$cursor].text
            if ($cursor -eq $closeIndex -and $braceDepth -eq 0 -and $parenDepth -eq 0 -and $bracketDepth -eq 0 -and $blockDepth -eq 0) { break }
            if ($token -in @(',', ';') -and $braceDepth -eq 0 -and $parenDepth -eq 0 -and $bracketDepth -eq 0 -and $blockDepth -eq 0) {
                $separatorIndex = $cursor
                break
            }
            switch -CaseSensitive ($token) {
                '{' { $braceDepth++ }
                '}' { if ($braceDepth -gt 0) { $braceDepth-- } }
                '(' { $parenDepth++ }
                ')' { if ($parenDepth -gt 0) { $parenDepth-- } }
                '[' { $bracketDepth++ }
                ']' { if ($bracketDepth -gt 0) { $bracketDepth-- } }
                'function' { $blockDepth++ }
                'if' { if ($blockDepth -gt 0) { $blockDepth++ } }
                'do' { if ($blockDepth -gt 0) { $blockDepth++ } }
                'repeat' { if ($blockDepth -gt 0) { $blockDepth++ } }
                'end' { if ($blockDepth -gt 0) { $blockDepth-- } }
                'until' { if ($blockDepth -gt 0) { $blockDepth-- } }
            }
            $valueEnd = $cursor
        }
        if ($valueEnd -lt $valueStart) { throw "Lua field $key has an empty value expression." }
        $field = [ordered]@{
            key = $key
            fieldStartIndex = $fieldStart
            valueStartIndex = $valueStart
            valueEndIndex = $valueEnd
            separatorIndex = $separatorIndex
        }
        $fields.Add($field)

        if ($Tokens[$valueStart].text -ceq '{') {
            $tablePath = if ([string]::IsNullOrWhiteSpace($AssignedKey)) { $ContainerPath } else { Join-LuaContainerPath -ContainerPath $ContainerPath -Key $AssignedKey }
            $null = Read-LuaTable -Text $Text -Tokens $Tokens -OpenIndex $valueStart -ContainerPath $tablePath -AssignedKey $key -SourceId $SourceId -Units $Units -BomLength $BomLength
        }
        $position = if ($null -ne $separatorIndex) { [int]$separatorIndex + 1 } else { $valueEnd + 1 }
    }

    if (-not [string]::IsNullOrWhiteSpace($AssignedKey)) {
        $sourceFields = @($fields | Where-Object { $_.key -ceq 'en' })
        $zhTwFields = @($fields | Where-Object { $_.key -ceq 'zh-tw' })
        if ($sourceFields.Count -gt 1 -or $zhTwFields.Count -gt 1) {
            $Units.Add([pscustomobject]@{
                sourceId = $SourceId; containerPath = $ContainerPath; key = $AssignedKey; blockedReason = 'duplicate_language_field'
                sourceExpression = $null; zhTwExpression = $null
            })
        }
        elseif ($sourceFields.Count -eq 1 -or $zhTwFields.Count -eq 1) {
            $closeToken = $Tokens[$closeIndex]
            $Units.Add([pscustomobject]@{
                sourceId = $SourceId
                containerPath = $ContainerPath
                key = $AssignedKey
                blockedReason = if ($sourceFields.Count -eq 0) { 'missing_en_source_expression' } else { $null }
                sourceExpression = if ($sourceFields.Count -eq 1) { New-ExpressionRecord -Text $Text -Tokens $Tokens -Field $sourceFields[0] -BomLength $BomLength } else { $null }
                zhTwExpression = if ($zhTwFields.Count -eq 1) { New-ExpressionRecord -Text $Text -Tokens $Tokens -Field $zhTwFields[0] -BomLength $BomLength } else { $null }
                tableOpenByte = ConvertTo-Utf8ByteOffset -Text $Text -CharacterIndex ([int]$Tokens[$OpenIndex].start) -BomLength $BomLength
                tableCloseByte = ConvertTo-Utf8ByteOffset -Text $Text -CharacterIndex ([int]$closeToken.start) -BomLength $BomLength
            })
        }
    }
    $closeIndex
}

function Get-LuaLocalizationDocument {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]] $Bytes,
        [Parameter(ParameterSetName = 'Bytes')][string] $DisplayPath = '<memory>',
        [Parameter(Mandatory)][string] $SourceId
    )
    $fullPath = if ($PSCmdlet.ParameterSetName -eq 'Path') { [IO.Path]::GetFullPath($Path) } else { $DisplayPath }
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'Lua localization source does not exist.' }
        $Bytes = [IO.File]::ReadAllBytes($fullPath)
    }
    $bytes = $Bytes
    $bomLength = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    try { $text = $encoding.GetString($bytes, $bomLength, $bytes.Length - $bomLength) }
    catch { throw 'Lua localization source must be valid UTF-8.' }
    $tokens = @(Get-LuaTokens -Text $text)
    $units = [Collections.Generic.List[object]]::new()
    $position = 0
    while ($position -lt $tokens.Count) {
        if ($tokens[$position].text -ceq '{') {
            $position = Read-LuaTable -Text $text -Tokens $tokens -OpenIndex $position -ContainerPath '$' -AssignedKey $null -SourceId $SourceId -Units $units -BomLength $bomLength
        }
        $position++
    }

    $occurrences = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $numbered = foreach ($unit in $units) {
        $identityBase = "$($unit.sourceId) :: $($unit.containerPath) :: $($unit.key)"
        if (-not $occurrences.ContainsKey($identityBase)) { $occurrences[$identityBase] = 0 }
        $occurrences[$identityBase]++
        [ordered]@{
            sourceId = $unit.sourceId
            containerPath = $unit.containerPath
            key = $unit.key
            occurrence = $occurrences[$identityBase]
            unitId = "$identityBase :: $($occurrences[$identityBase])"
            blockedReason = $unit.blockedReason
            sourceExpression = $unit.sourceExpression
            zhTwExpression = $unit.zhTwExpression
            tableOpenByte = $unit.tableOpenByte
            tableCloseByte = $unit.tableCloseByte
        }
    }
    $withoutCrlf = $text.Replace("`r`n", '')
    $hasCrlf = $withoutCrlf.Length -ne $text.Length
    $hasOtherLineBreak = $withoutCrlf.Contains("`n", [StringComparison]::Ordinal) -or $withoutCrlf.Contains("`r", [StringComparison]::Ordinal)
    $newline = if ($hasCrlf -and $hasOtherLineBreak) { 'mixed' } elseif ($hasCrlf) { 'crlf' } elseif ($hasOtherLineBreak -and $withoutCrlf.Contains("`r", [StringComparison]::Ordinal)) { 'mixed' } else { 'lf' }
    [ordered]@{
        schemaVersion = 1
        sourceId = $SourceId
        path = $fullPath
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        size = $bytes.LongLength
        bom = $bomLength -eq 3
        newline = $newline
        ioDofileLoaderCallCount = Get-IoDofileLoaderCallCount -Tokens $tokens
        isIoDofileOnlyLoader = Test-IoDofileOnlyLoaderTokens -Tokens $tokens
        units = @($numbered)
    }
}

Export-ModuleMember -Function Get-LuaLocalizationDocument
