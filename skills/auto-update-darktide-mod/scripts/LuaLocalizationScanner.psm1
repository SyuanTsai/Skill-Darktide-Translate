# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:luaScannerHeartbeatAction = $null
$script:luaScannerHeartbeatProgress = 0

function Invoke-LuaScannerHeartbeat {
    if ($script:luaScannerHeartbeatAction) { $null = & $script:luaScannerHeartbeatAction }
}

function Invoke-LuaScannerProgressHeartbeat {
    $script:luaScannerHeartbeatProgress++
    if (($script:luaScannerHeartbeatProgress -band 0x3FFF) -eq 0) { Invoke-LuaScannerHeartbeat }
}

function Find-LuaDelimiterIndex {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Delimiter,
        [Parameter(Mandatory)][int] $StartIndex
    )
    if ($Delimiter.Length -eq 0) { throw 'Lua delimiter must not be empty.' }
    $cursor = $StartIndex
    while ($cursor -le ($Text.Length - $Delimiter.Length)) {
        $count = [Math]::Min((1MB + $Delimiter.Length - 1), $Text.Length - $cursor)
        $found = $Text.IndexOf($Delimiter, $cursor, $count, [StringComparison]::Ordinal)
        if ($found -ge 0) { return $found }
        $cursor += 1MB
        Invoke-LuaScannerHeartbeat
    }
    -1
}

function Read-LuaScannerFileBytes {
    param([Parameter(Mandatory)][string] $Path)
    $source = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $readCount)
            Invoke-LuaScannerHeartbeat
        }
        $memory.ToArray()
    }
    finally { $memory.Dispose(); $source.Dispose() }
}

function Get-LuaScannerSha256 {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        for ($offset = 0; $offset -lt $Bytes.Length; $offset += 1MB) {
            $count = [Math]::Min(1MB, $Bytes.Length - $offset)
            $hasher.AppendData($Bytes, $offset, $count)
            Invoke-LuaScannerHeartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
}

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
    $longCommentPattern = [regex]::new('\G--\[(=*)\[')
    $longStringPattern = [regex]::new('\G\[(=*)\[')
    $index = 0
    while ($index -lt $Text.Length) {
        Invoke-LuaScannerProgressHeartbeat
        $character = $Text[$index]
        if ([char]::IsWhiteSpace($character)) { $index++; continue }

        if ($character -eq '-' -and ($index + 1) -lt $Text.Length -and $Text[$index + 1] -eq '-') {
            $longComment = $longCommentPattern.Match($Text, $index)
            if ($longComment.Success) {
                $closing = ']' + $longComment.Groups[1].Value + ']'
                $closingIndex = Find-LuaDelimiterIndex -Text $Text -Delimiter $closing -StartIndex ($index + $longComment.Length)
                $index = if ($closingIndex -lt 0) { $Text.Length } else { $closingIndex + $closing.Length }
            }
            else {
                $lineEnd = Find-LuaDelimiterIndex -Text $Text -Delimiter ([string][char]10) -StartIndex $index
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
                Invoke-LuaScannerProgressHeartbeat
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
            $longString = $longStringPattern.Match($Text, $index)
            if ($longString.Success) {
                $start = $index
                $closing = ']' + $longString.Groups[1].Value + ']'
                $closingIndex = Find-LuaDelimiterIndex -Text $Text -Delimiter $closing -StartIndex ($index + $longString.Length)
                if ($closingIndex -lt 0) { throw "Unterminated Lua long string at character $start." }
                $index = $closingIndex + $closing.Length
                Add-LuaToken -Tokens $tokens -Type 'string' -Text $Text.Substring($start, $index - $start) -Start $start
                continue
            }
        }

        if ([char]::IsLetter($character) -or $character -eq '_') {
            $start = $index
            $index++
            while ($index -lt $Text.Length -and ([char]::IsLetterOrDigit($Text[$index]) -or $Text[$index] -eq '_')) {
                Invoke-LuaScannerProgressHeartbeat
                $index++
            }
            Add-LuaToken -Tokens $tokens -Type 'identifier' -Text $Text.Substring($start, $index - $start) -Start $start
            continue
        }

        if ([char]::IsDigit($character)) {
            $start = $index
            $index++
            while ($index -lt $Text.Length -and ($Text[$index] -match '[A-Za-z0-9._]')) {
                Invoke-LuaScannerProgressHeartbeat
                $index++
            }
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
        Invoke-LuaScannerProgressHeartbeat
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
        Invoke-LuaScannerProgressHeartbeat
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
    param([string] $Literal, [switch] $RequireUtf8)
    if ($Literal.StartsWith('[', [StringComparison]::Ordinal)) {
        $longString = [regex]::Match($Literal, '^\[(=*)\[(.*)\]\1\]$', [Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $longString.Success) { throw 'Lua long-string key literal is malformed.' }
        $content = $longString.Groups[2].Value
        if ($content.StartsWith(([string][char]13 + [string][char]10), [StringComparison]::Ordinal)) { $content = $content.Substring(2) }
        elseif ($content.StartsWith([string][char]10, [StringComparison]::Ordinal) -or $content.StartsWith([string][char]13, [StringComparison]::Ordinal)) { $content = $content.Substring(1) }
        return ($content -replace ([string][char]13 + [string][char]10 + '|' + [string][char]13 + '|' + [string][char]10), [string][char]10)
    }
    $content = $Literal.Substring(1, $Literal.Length - 2)
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $bytes = [Collections.Generic.List[byte]]::new()
    for ($index = 0; $index -lt $content.Length; $index++) {
        Invoke-LuaScannerProgressHeartbeat
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
            ([string][char]10) { $bytes.Add(10) }
            ([string][char]13) {
                if (($index + 1) -lt $content.Length -and $content[$index + 1] -eq [string][char]10) { $index++ }
                $bytes.Add(10)
            }
            'z' {
                while (($index + 1) -lt $content.Length -and [char]::IsWhiteSpace($content[$index + 1])) {
                    $index++
                    Invoke-LuaScannerProgressHeartbeat
                }
            }
            'x' {
                if (($index + 2) -ge $content.Length -or $content.Substring($index + 1, 2) -notmatch '^[0-9A-Fa-f]{2}$') {
                    throw 'Lua hexadecimal key escape must contain exactly two digits.'
                }
                $bytes.Add([Convert]::ToByte($content.Substring($index + 1, 2), 16))
                $index += 2
            }
            'u' {
                if (($index + 2) -ge $content.Length -or $content[$index + 1] -cne '{') {
                    throw 'Lua Unicode key escape is malformed.'
                }
                $unicodeStart = $index + 2
                $unicodeEnd = $unicodeStart
                while ($unicodeEnd -lt $content.Length -and $content[$unicodeEnd] -match '[0-9A-Fa-f]') {
                    Invoke-LuaScannerProgressHeartbeat
                    $unicodeEnd++
                }
                if ($unicodeEnd -eq $unicodeStart -or $unicodeEnd -ge $content.Length -or $content[$unicodeEnd] -cne '}') {
                    throw 'Lua Unicode key escape is malformed.'
                }
                try { $codePoint = [Convert]::ToInt32($content.Substring($unicodeStart, $unicodeEnd - $unicodeStart), 16) }
                catch { throw 'Lua Unicode key escape is outside the valid scalar range.' }
                if ($codePoint -gt 0x10FFFF -or ($codePoint -ge 0xD800 -and $codePoint -le 0xDFFF)) {
                    throw 'Lua Unicode key escape is outside the valid scalar range.'
                }
                $bytes.AddRange($encoding.GetBytes([char]::ConvertFromUtf32($codePoint)))
                $index = $unicodeEnd
            }
            default { throw "Unsupported Lua key string escape: \$escaped" }
        }
    }
    try { $encoding.GetString($bytes.ToArray()) }
    catch {
        if ($RequireUtf8) { throw }
        '@bytes:' + [Convert]::ToHexString($bytes.ToArray()).ToLowerInvariant()
    }
}

function Get-CanonicalTokenText {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex)
    if ($EndIndex -lt $StartIndex) { return '' }
    $builder = [Text.StringBuilder]::new()
    for ($index = $StartIndex; $index -le $EndIndex; $index++) {
        $null = $builder.Append([string]$Tokens[$index].text)
        Invoke-LuaScannerProgressHeartbeat
    }
    $builder.ToString()
}

function Get-MatchingTokenIndex {
    param([object[]] $Tokens, [int] $StartIndex, [string] $Open, [string] $Close)
    $depth = 0
    for ($index = $StartIndex; $index -lt $Tokens.Count; $index++) {
        Invoke-LuaScannerProgressHeartbeat
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

function Get-LuaUtf8ByteCount {
    param([string] $Text, [int] $StartIndex, [int] $CharacterCount)
    if ($StartIndex -lt 0 -or $CharacterCount -lt 0 -or ($StartIndex + $CharacterCount) -gt $Text.Length) {
        throw 'Lua UTF-8 byte-count range escapes the source text.'
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $total = [int64]0
    $offset = $StartIndex
    $remaining = $CharacterCount
    while ($remaining -gt 0) {
        $count = [Math]::Min(1MB, $remaining)
        if ($count -lt $remaining -and [char]::IsHighSurrogate($Text[$offset + $count - 1]) -and
            [char]::IsLowSurrogate($Text[$offset + $count])) {
            $count--
        }
        $total += $encoding.GetByteCount($Text, $offset, $count)
        $offset += $count
        $remaining -= $count
        Invoke-LuaScannerHeartbeat
    }
    $total
}

function ConvertTo-Utf8ByteOffset {
    param([string] $Text, [int] $CharacterIndex, [int] $BomLength)
    $BomLength + (Get-LuaUtf8ByteCount -Text $Text -StartIndex 0 -CharacterCount $CharacterIndex)
}

function Test-LuaIdentifierIsOnlyCalled {
    param([object[]] $Tokens, [string] $Name)
    $seen = $false
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        Invoke-LuaScannerProgressHeartbeat
        if ($Tokens[$index].type -cne 'identifier' -or $Tokens[$index].text -cne $Name) { continue }
        $previous = if ($index -gt 0) { [string]$Tokens[$index - 1].text } else { $null }
        $next = if (($index + 1) -lt $Tokens.Count) { [string]$Tokens[$index + 1].text } else { $null }
        if (-not $seen -and $previous -ceq 'local' -and $next -ceq '=' -and
            ($index + 2) -lt $Tokens.Count -and $Tokens[$index + 2].type -ceq 'identifier' -and
            $Tokens[$index + 2].text -ceq $Name) {
            # A call, member, or operator following the RHS would change the alias value.
            if (($index + 3) -lt $Tokens.Count) {
                $afterAlias = $Tokens[$index + 3]
                if ($afterAlias.text -cne ';' -and
                    ($afterAlias.type -cne 'identifier' -or $afterAlias.text -cin @('and', 'or'))) {
                    return $false
                }
            }
            $seen = $true
            $index += 2
            continue
        }
        if ($next -cne '(' -or $previous -in @('function', '.', ':')) { return $false }
        $seen = $true
    }
    $true
}

function Test-DirectLocalizeCallRange {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex)
    if (($EndIndex - $StartIndex) -lt 2 -or
        $Tokens[$StartIndex].type -cne 'identifier' -or $Tokens[$StartIndex].text -cne 'Localize' -or
        $Tokens[$StartIndex + 1].text -cne '(' -or $Tokens[$EndIndex].text -cne ')') {
        return $false
    }
    (Get-MatchingTokenIndex -Tokens $Tokens -StartIndex ($StartIndex + 1) -Open '(' -Close ')') -eq $EndIndex
}

function Test-DirectLocalizeCall {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex)
    if (-not (Test-LuaIdentifierIsOnlyCalled -Tokens $Tokens -Name 'Localize')) { return $false }
    Test-DirectLocalizeCallRange -Tokens $Tokens -StartIndex $StartIndex -EndIndex $EndIndex
}

function Test-NeutralLuaStringLiteral {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex)
    if ($StartIndex -ne $EndIndex -or $Tokens[$StartIndex].type -cne 'string') { return $false }
    try { $content = ConvertFrom-LuaKeyString -Literal ([string]$Tokens[$StartIndex].text) }
    catch { return $false }
    [regex]::Replace($content, $script:luaFormatSpecifier, '') -notmatch '[\p{L}\p{N}]'
}

function Get-FullyLocaleResolvedExpressionPart {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex, [int] $Depth)
    if ($StartIndex -gt $EndIndex -or $Depth -gt 256) {
        return [pscustomobject]@{ valid = $false; hasLocalize = $false }
    }

    while ($StartIndex -lt $EndIndex -and $Tokens[$StartIndex].text -ceq '(') {
        $matchingIndex = Get-MatchingTokenIndex -Tokens $Tokens -StartIndex $StartIndex -Open '(' -Close ')'
        if ($matchingIndex -ne $EndIndex) { break }
        $StartIndex++
        $EndIndex--
    }

    if (($EndIndex - $StartIndex) -eq 3 -and $Tokens[$StartIndex + 2].type -ceq 'string' -and
        (Test-DirectLocalizeCallRange -Tokens $Tokens -StartIndex $StartIndex -EndIndex $EndIndex)) {
        $key = ConvertFrom-LuaKeyString -Literal ([string]$Tokens[$StartIndex + 2].text)
        if ($key -cmatch '^loc_[A-Za-z0-9_]+$') {
            return [pscustomobject]@{ valid = $true; hasLocalize = $true }
        }
    }
    if (Test-NeutralLuaStringLiteral -Tokens $Tokens -StartIndex $StartIndex -EndIndex $EndIndex) {
        return [pscustomobject]@{ valid = $true; hasLocalize = $false }
    }

    $segments = [Collections.Generic.List[object]]::new()
    $segmentStart = $StartIndex
    $parenthesisDepth = 0
    $bracketDepth = 0
    $braceDepth = 0
    for ($index = $StartIndex; $index -le $EndIndex; $index++) {
        Invoke-LuaScannerProgressHeartbeat
        $token = [string]$Tokens[$index].text
        switch -CaseSensitive ($token) {
            '(' { $parenthesisDepth++ }
            ')' { $parenthesisDepth-- }
            '[' { $bracketDepth++ }
            ']' { $bracketDepth-- }
            '{' { $braceDepth++ }
            '}' { $braceDepth-- }
        }
        if ($parenthesisDepth -lt 0 -or $bracketDepth -lt 0 -or $braceDepth -lt 0) {
            return [pscustomobject]@{ valid = $false; hasLocalize = $false }
        }
        if ($token -ceq '..' -and $parenthesisDepth -eq 0 -and $bracketDepth -eq 0 -and $braceDepth -eq 0) {
            if ($index -eq $segmentStart) { return [pscustomobject]@{ valid = $false; hasLocalize = $false } }
            $segments.Add([pscustomobject]@{ start = $segmentStart; end = $index - 1 })
            $segmentStart = $index + 1
        }
    }
    if ($parenthesisDepth -ne 0 -or $bracketDepth -ne 0 -or $braceDepth -ne 0 -or
        $segments.Count -eq 0 -or $segmentStart -gt $EndIndex) {
        return [pscustomobject]@{ valid = $false; hasLocalize = $false }
    }
    $segments.Add([pscustomobject]@{ start = $segmentStart; end = $EndIndex })

    $hasLocalize = $false
    foreach ($segment in $segments) {
        $result = Get-FullyLocaleResolvedExpressionPart -Tokens $Tokens -StartIndex $segment.start -EndIndex $segment.end -Depth ($Depth + 1)
        if (-not $result.valid) { return [pscustomobject]@{ valid = $false; hasLocalize = $false } }
        $hasLocalize = $hasLocalize -or $result.hasLocalize
    }
    [pscustomobject]@{ valid = $true; hasLocalize = $hasLocalize }
}

function Test-FullyLocaleResolvedExpression {
    param([object[]] $Tokens, [int] $StartIndex, [int] $EndIndex)
    if (-not (Test-LuaIdentifierIsOnlyCalled -Tokens $Tokens -Name 'Localize')) { return $false }
    $result = Get-FullyLocaleResolvedExpressionPart -Tokens $Tokens -StartIndex $StartIndex -EndIndex $EndIndex -Depth 0
    [bool]($result.valid -and $result.hasLocalize)
}

function Test-LuaTableFieldAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Key,
        [scriptblock] $HeartbeatAction
    )
    if ([string]::IsNullOrWhiteSpace($Key)) { throw 'Lua table field key cannot be empty.' }
    $previousHeartbeatAction = $script:luaScannerHeartbeatAction
    $previousHeartbeatProgress = $script:luaScannerHeartbeatProgress
    $script:luaScannerHeartbeatAction = $HeartbeatAction
    $script:luaScannerHeartbeatProgress = [int64]0
    try {
        $tokens = @(Get-LuaTokens -Text $Text)
        $braceDepth = 0
        for ($index = 0; $index -lt $tokens.Count; $index++) {
            Invoke-LuaScannerProgressHeartbeat
            $token = [string]$tokens[$index].text
            if ($token -ceq '{') { $braceDepth++; continue }
            if ($token -ceq '}') { if ($braceDepth -gt 0) { $braceDepth-- }; continue }
            if ($braceDepth -eq 0) { continue }
            $previous = if ($index -gt 0) { [string]$tokens[$index - 1].text } else { $null }
            if ($previous -notin @('{', ',', ';')) { continue }
            if ($tokens[$index].type -ceq 'identifier' -and $token -ceq $Key -and
                ($index + 1) -lt $tokens.Count -and $tokens[$index + 1].text -ceq '=') {
                return $true
            }
            if ($token -ceq '[' -and ($index + 3) -lt $tokens.Count -and
                $tokens[$index + 1].type -ceq 'string' -and $tokens[$index + 2].text -ceq ']' -and
                $tokens[$index + 3].text -ceq '=' -and
                (ConvertFrom-LuaKeyString -Literal ([string]$tokens[$index + 1].text)) -ceq $Key) {
                return $true
            }
        }
        $false
    }
    finally {
        $script:luaScannerHeartbeatAction = $previousHeartbeatAction
        $script:luaScannerHeartbeatProgress = $previousHeartbeatProgress
    }
}

function New-ExpressionRecord {
    param(
        [string] $Text,
        [object[]] $Tokens,
        [Collections.IDictionary] $Field,
        [int] $BomLength,
        [switch] $KnownStringLiteral
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
        $separatorLength = Get-LuaUtf8ByteCount -Text ([string]$separatorToken.text) -StartIndex 0 -CharacterCount ([int]$separatorToken.length)
        $fieldEnd = [int]$separatorToken.start + [int]$separatorToken.length
    }
    [ordered]@{
        raw = $Text.Substring($valueStart, $valueEnd - $valueStart)
        canonical = Get-CanonicalTokenText -Tokens $Tokens -StartIndex $Field.valueStartIndex -EndIndex $Field.valueEndIndex
        isDirectLocalizeCall = -not $KnownStringLiteral -and (Test-DirectLocalizeCall -Tokens $Tokens -StartIndex $Field.valueStartIndex -EndIndex $Field.valueEndIndex)
        isFullyLocaleResolvedExpression = -not $KnownStringLiteral -and (Test-FullyLocaleResolvedExpression -Tokens $Tokens -StartIndex $Field.valueStartIndex -EndIndex $Field.valueEndIndex)
        startByte = ConvertTo-Utf8ByteOffset -Text $Text -CharacterIndex $valueStart -BomLength $BomLength
        lengthByte = Get-LuaUtf8ByteCount -Text $Text -StartIndex $valueStart -CharacterCount ($valueEnd - $valueStart)
        fieldStartByte = ConvertTo-Utf8ByteOffset -Text $Text -CharacterIndex $fieldStart -BomLength $BomLength
        fieldLengthByte = Get-LuaUtf8ByteCount -Text $Text -StartIndex $fieldStart -CharacterCount ($fieldEnd - $fieldStart)
        separatorStartByte = $separatorStart
        separatorLengthByte = $separatorLength
    }
}

function Join-LuaContainerPath {
    param([string] $ContainerPath, [string] $Key)
    if ($Key.StartsWith('[', [StringComparison]::Ordinal)) { return $ContainerPath + $Key }
    $ContainerPath + '.' + $Key
}

function Test-LuaTableFieldStart {
    param([object[]] $Tokens, [int] $Index, [int] $CloseIndex)
    if ($Tokens[$Index].type -ceq 'identifier' -and ($Index + 1) -lt $CloseIndex -and
        $Tokens[$Index + 1].text -ceq '=') {
        return $true
    }
    if ($Tokens[$Index].text -cne '[') { return $false }
    $keyEnd = Get-MatchingTokenIndex -Tokens $Tokens -StartIndex $Index -Open '[' -Close ']'
    ($keyEnd + 1) -lt $CloseIndex -and $Tokens[$keyEnd + 1].text -ceq '='
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
        [int] $BomLength,
        [string] $RootKey
    )
    $closeIndex = Get-MatchingTokenIndex -Tokens $Tokens -StartIndex $OpenIndex -Open '{' -Close '}'
    $fields = [Collections.Generic.List[object]]::new()
    $position = $OpenIndex + 1
    while ($position -lt $closeIndex) {
        Invoke-LuaScannerProgressHeartbeat
        while ($position -lt $closeIndex -and $Tokens[$position].text -in @(',', ';')) {
            $position++
            Invoke-LuaScannerProgressHeartbeat
        }
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
            Invoke-LuaScannerProgressHeartbeat
            $token = [string]$Tokens[$cursor].text
            if ($cursor -eq $closeIndex -and $braceDepth -eq 0 -and $parenDepth -eq 0 -and $bracketDepth -eq 0 -and $blockDepth -eq 0) { break }
            if ($token -in @(',', ';') -and $braceDepth -eq 0 -and $parenDepth -eq 0 -and $bracketDepth -eq 0 -and $blockDepth -eq 0) {
                $separatorIndex = $cursor
                break
            }
            if ($cursor -gt $valueStart -and $braceDepth -eq 0 -and $parenDepth -eq 0 -and
                $bracketDepth -eq 0 -and $blockDepth -eq 0 -and
                (Test-LuaTableFieldStart -Tokens $Tokens -Index $cursor -CloseIndex $closeIndex)) {
                throw "Lua table field $key is missing a separator before the next field."
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
            $childRootKey = if ($AssignedKey) { $RootKey } else { $key }
            $null = Read-LuaTable -Text $Text -Tokens $Tokens -OpenIndex $valueStart -ContainerPath $tablePath -AssignedKey $key -SourceId $SourceId -Units $Units -BomLength $BomLength -RootKey $childRootKey
        }
        $position = if ($null -ne $separatorIndex) { [int]$separatorIndex + 1 } else { $valueEnd + 1 }
    }

    if (-not [string]::IsNullOrWhiteSpace($AssignedKey)) {
        $sourceFields = @($fields | Where-Object { $_.key -ceq 'en' })
        $zhTwFields = @($fields | Where-Object { $_.key -ceq 'zh-tw' })
        if ($sourceFields.Count -gt 1 -or $zhTwFields.Count -gt 1) {
            $Units.Add([pscustomobject]@{
                sourceId = $SourceId; containerPath = $ContainerPath; key = $AssignedKey; blockedReason = 'duplicate_language_field'
                sourceExpression = $null; zhTwExpression = $null; tableOpenByte = $null; tableCloseByte = $null; rootKey = $RootKey
            })
        }
        elseif ($sourceFields.Count -eq 1 -or $zhTwFields.Count -eq 1) {
            $closeToken = $Tokens[$closeIndex]
            $Units.Add([pscustomobject]@{
                sourceId = $SourceId
                containerPath = $ContainerPath
                key = $AssignedKey
                rootKey = $RootKey
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

# Track statement blocks outside table constructors, indices, and argument lists.
# The supported generators each have an explicit token shape checked against these boundaries.
function Get-LuaStatementLayout {
    param([object[]] $Tokens)
    $depths = [Collections.Generic.Dictionary[int, int]]::new()
    $closes = [Collections.Generic.Dictionary[int, int]]::new()
    $blocks = [Collections.Generic.Stack[int]]::new()
    $outerReturns = [Collections.Generic.List[int]]::new()
    $functionDepth = 0
    $outerGotoOrLabel = $false
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        Invoke-LuaScannerProgressHeartbeat
        $depths[$index] = $blocks.Count
        switch -CaseSensitive ($Tokens[$index].text) {
            '(' { $index = Get-MatchingTokenIndex $Tokens $index '(' ')' }
            '[' { $index = Get-MatchingTokenIndex $Tokens $index '[' ']' }
            '{' { $index = Get-MatchingTokenIndex $Tokens $index '{' '}' }
            'function' { $blocks.Push($index); $functionDepth++ }
            { $_ -cin @('if', 'do', 'repeat') } { $blocks.Push($index) }
            'return' { if ($functionDepth -eq 0) { $outerReturns.Add($index) } }
            { $_ -cin @('goto', '::') } { if ($functionDepth -eq 0) { $outerGotoOrLabel = $true } }
            { $_ -cin @('end', 'until') } {
                if ($blocks.Count -gt 0) {
                    $start = $blocks.Pop()
                    $closes[$start] = $index
                    if ($Tokens[$start].text -ceq 'function') { $functionDepth-- }
                }
            }
        }
    }
    [pscustomobject]@{ depths = $depths; closes = $closes; outerReturns = $outerReturns; outerGotoOrLabel = $outerGotoOrLabel }
}

function Add-LuaGeneratedBlock {
    param($Context, [string] $Key, [string] $Reason, [string] $ContainerPath = '$generated', [switch] $ConditionalZhTwSidecar)
    $Context.units.Add([pscustomobject]@{
        sourceId = $Context.sourceId; containerPath = $ContainerPath; key = $Key; blockedReason = $Reason
        sourceExpression = $null; zhTwExpression = $null; tableOpenByte = $null; tableCloseByte = $null
        generated = $true; positionalLocale = $false; conditionalZhTwSidecar = [bool]$ConditionalZhTwSidecar
    })
}

function Set-LuaOverwrittenDescendants {
    param($Context, [string] $Key)
    # Keep prior identities as blocked evidence for the workset comparison.
    $descendants = $null
    if (-not $Context.descendantsByRoot.Remove($Key, [ref]$descendants)) { return }
    foreach ($unit in $descendants) {
        Invoke-LuaScannerProgressHeartbeat
        if (-not $unit.blockedReason) { $unit.blockedReason = 'generated_root_assignment_overwrites_descendant' }
    }
}

function Add-LuaGeneratedTable {
    param($Context, [int] $TableIndex, [string] $Key, $Binding)
    $templateKey = '__template__'
    $templatePath = '$.' + $templateKey
    if (-not $Context.tableCache.ContainsKey($TableIndex)) {
        $tableUnits = [Collections.Generic.List[object]]::new()
        $null = Read-LuaTable -Text $Context.text -Tokens $Context.tokens -OpenIndex $TableIndex -ContainerPath '$' -AssignedKey $templateKey -SourceId $Context.sourceId -Units $tableUnits -BomLength $Context.bomLength
        $Context.tableCache.Add($TableIndex, $tableUnits)
    }
    Set-LuaOverwrittenDescendants $Context $Key
    $descendants = [Collections.Generic.List[object]]::new()
    $destination = Join-LuaContainerPath '$' $Key
    $hasRoot = $false
    foreach ($unit in $Context.tableCache[$TableIndex]) {
        $root = $unit.containerPath -ceq '$'
        $hasRoot = $hasRoot -or $root
        $projected = [pscustomobject]@{
            sourceId = $unit.sourceId
            containerPath = if ($root) { '$' } else { $destination + $unit.containerPath.Substring($templatePath.Length) }
            key = if ($root) { $Key } else { $unit.key }
            blockedReason = $unit.blockedReason
            sourceExpression = $unit.sourceExpression
            zhTwExpression = $unit.zhTwExpression
            tableOpenByte = $unit.tableOpenByte
            tableCloseByte = $unit.tableCloseByte
            generated = $true
            generatedBinding = $Binding
        }
        $Context.units.Add($projected)
        if (-not $root) { $descendants.Add($projected) }
    }
    if ($descendants.Count) { $Context.descendantsByRoot.Add($Key, $descendants) }
    if (-not $hasRoot) { Add-LuaGeneratedBlock $Context $Key 'generated_output_language_fields_unproven' '$' }
}

function Get-LuaAccumulatorAssignment {
    param([object[]] $Tokens, [int] $Index)
    if (($Index + 3) -ge $Tokens.Count) { return }
    $keyStart = $Index + 2
    if ($Tokens[$Index + 1].text -ceq '.' -and $Tokens[$keyStart].type -ceq 'identifier') {
        $keyEnd = $keyStart
        $equalsIndex = $keyEnd + 1
    }
    elseif ($Tokens[$Index + 1].text -ceq '[') {
        $equalsIndex = (Get-MatchingTokenIndex $Tokens ($Index + 1) '[' ']') + 1
        $keyEnd = $equalsIndex - 2
    }
    else { return }
    if (($equalsIndex + 1) -ge $Tokens.Count -or $Tokens[$equalsIndex].text -cne '=') { return }
    $valueIndex = $equalsIndex + 1
    $tableEnd = if ($Tokens[$valueIndex].text -ceq '{') { Get-MatchingTokenIndex $Tokens $valueIndex '{' '}' } else { -1 }
    [pscustomobject]@{ keyStart = $keyStart; keyEnd = $keyEnd; valueIndex = $valueIndex; tableEnd = $tableEnd }
}

function Test-LuaTableStatementBoundary {
    param([object[]] $Tokens, [int] $End)
    if ($End -lt 0) { return $false }
    if (($End + 1) -eq $Tokens.Count) { return $true }
    $next = $Tokens[$End + 1]
    $next.text -ceq ';' -or ($next.type -ceq 'identifier' -and $next.text -cnotin @('and', 'or'))
}

function Get-LuaLiteralAccumulatorKey {
    param([object[]] $Tokens, [int] $AssignmentIndex, $Assignment)
    if ($Assignment.keyStart -ne $Assignment.keyEnd) { return }
    $key = $Tokens[$Assignment.keyStart]
    if ($Tokens[$AssignmentIndex + 1].text -ceq '.') { return [string]$key.text }
    if ($key.type -ceq 'string') { ConvertFrom-LuaKeyString -Literal $key.text }
}

function Test-LuaUnshadowedPrimitive {
    param($Context, [string] $Name, [switch] $MemberCalls)
    $tokens = $Context.tokens
    foreach ($environment in @('_G', '_ENV', 'setfenv', 'getfenv')) {
        if ($Context.references.ContainsKey($environment)) { return $false }
    }
    foreach ($index in $Context.references[$Name]) {
        if ($index -gt 0 -and $tokens[$index - 1].text -cin @('.', ':')) { continue }
        if ($index -gt 0 -and -not $Context.layout.depths.ContainsKey($index) -and
            $tokens[$index - 1].text -cin @('{', ',', ';') -and $tokens[$index + 1].text -ceq '=') { continue }
        if ($index -gt 0 -and $tokens[$index - 1].text -cin @('local', 'function')) { return $false }
        if ($MemberCalls) {
            if (($index + 3) -ge $tokens.Count -or $tokens[$index + 1].text -cne '.' -or
                $tokens[$index + 2].type -cne 'identifier' -or $tokens[$index + 3].text -cne '(') { return $false }
        }
        elseif (($index + 1) -ge $tokens.Count -or $tokens[$index + 1].text -cne '(') { return $false }
    }
    $true
}

function Get-LuaLimitedFormatOutputs {
    param($Context, [int] $AssignmentIndex, $Assignment)
    # The complete loop body must consist of this one assignment.
    $tokens = $Context.tokens
    $loop = $AssignmentIndex - 7
    $keyStart = $Assignment.keyStart
    if ($loop -lt 0 -or $Assignment.tableEnd -lt 0 -or $Context.layout.depths[$loop] -ne 0 -or
        $tokens[$loop].text -cne 'for' -or $tokens[$loop + 1].type -cne 'identifier' -or
        $tokens[$loop + 2].text -cne '=' -or $tokens[$loop + 4].text -cne ',' -or
        $tokens[$loop + 6].text -cne 'do' -or $Context.layout.closes[$loop + 6] -ne ($Assignment.tableEnd + 1) -or
        $Assignment.keyEnd -ne ($keyStart + 7)) { return }
    $variable = $tokens[$loop + 1].text
    if ($tokens[$keyStart].text -cne 'string' -or $tokens[$keyStart + 1].text -cne '.' -or
        $tokens[$keyStart + 2].text -cne 'format' -or $tokens[$keyStart + 3].text -cne '(' -or
        $tokens[$keyStart + 4].type -cne 'string' -or $tokens[$keyStart + 5].text -cne ',' -or
        $tokens[$keyStart + 6].text -cne $variable -or $tokens[$keyStart + 7].text -cne ')') { return }
    if (-not (Test-LuaUnshadowedPrimitive $Context 'string' -MemberCalls)) { return }
    $usesToString = @($Context.references['tostring'] | Where-Object { $_ -ge $Assignment.valueIndex -and $_ -lt $Assignment.tableEnd }).Count -gt 0
    $tostringBindingProven = Test-LuaUnshadowedPrimitive $Context 'tostring'
    if ($usesToString -and -not $tostringBindingProven) { return }
    $first = 0; $last = 0
    if ($tokens[$loop + 3].text -cnotmatch '^[0-9]+$' -or $tokens[$loop + 5].text -cnotmatch '^[0-9]+$' -or
        -not [int]::TryParse($tokens[$loop + 3].text, [ref]$first) -or
        -not [int]::TryParse($tokens[$loop + 5].text, [ref]$last) -or
        $last -lt $first -or ($last - [long]$first) -ge 128) { return }
    $format = ConvertFrom-LuaKeyString -Literal $tokens[$keyStart + 4].text
    if ($format -cnotmatch '^[^%]*%s[^%]*$') { return }
    for ($value = [long]$first; $value -le $last; $value++) {
        $literal = $value.ToString([Globalization.CultureInfo]::InvariantCulture)
        [pscustomobject]@{
            key = $format.Replace('%s', $literal)
            binding = [ordered]@{
                kind = 'numeric-loop'; parameter = $variable; value = $literal; format = $format
                tostringBindingProven = $tostringBindingProven
            }
        }
    }
}

function Test-LuaExactTokens {
    param([object[]] $Tokens, [int] $Start, [int] $End, [string] $Expected)
    $pattern = @(Get-LuaTokens -Text $Expected)
    if ($End - $Start + 1 -ne $pattern.Count) { return $false }
    for ($offset = 0; $offset -lt $pattern.Count; $offset++) {
        if ($Tokens[$Start + $offset].text -cne $pattern[$offset].text) { return $false }
    }
    $true
}

function Get-LuaLiteralList {
    param([object[]] $Tokens, [int] $Open, [int] $Close)
    $fields = [Collections.Generic.List[object]]::new()
    for ($index = $Open + 1; $index -lt $Close; $index += 2) {
        if ($Tokens[$index].type -cne 'string' -or
            (($index + 1) -lt $Close -and $Tokens[$index + 1].text -cnotin @(',', ';'))) { return }
        $fields.Add([ordered]@{
            fieldStartIndex = $index; valueStartIndex = $index; valueEndIndex = $index
            separatorIndex = if (($index + 1) -lt $Close) { $index + 1 } else { $null }
        })
    }
    [pscustomobject]@{ fields = @($fields) }
}

function Get-LuaCallArguments {
    param([object[]] $Tokens, [int] $Open, [int] $Close)
    # Each supported call takes single-token arguments.
    $indices = [Collections.Generic.List[int]]::new()
    for ($index = $Open + 1; $index -lt $Close; $index += 2) {
        if (($index + 1) -lt $Close -and $Tokens[$index + 1].text -cne ',') { return }
        $indices.Add($index)
    }
    if (($Close - $Open) % 2 -ne 0 -and $Close -ne ($Open + 1)) { return }
    [pscustomobject]@{ indices = @($indices) }
}

function Get-LuaLiteralLocalTable {
    param($Context, [int] $ArgumentIndex, [Collections.Generic.HashSet[int]] $AllowedReferences)
    $tokens = $Context.tokens
    $token = $tokens[$ArgumentIndex]
    if ($token.type -cne 'identifier' -or -not $Context.references.ContainsKey($token.text)) { return }
    $references = $Context.references[$token.text]
    $declaration = -1
    foreach ($index in $references) {
        if ($AllowedReferences.Contains($index) -and $index -ne $ArgumentIndex) { continue }
        if ($index -eq $ArgumentIndex) { continue }
        # A member selector with the same spelling does not reference the local.
        if ($index -gt 0 -and $tokens[$index - 1].text -cin @('.', ':')) { continue }
        if ($index -gt 0 -and -not $Context.layout.depths.ContainsKey($index) -and
            $tokens[$index - 1].text -cin @('{', ',', ';') -and $tokens[$index + 1].text -ceq '=') { continue }
        if ($index -le 0 -or $index -ge $ArgumentIndex -or $declaration -ge 0 -or
            $Context.layout.depths[$index] -ne 0 -or $tokens[$index - 1].text -cne 'local' -or
            $tokens[$index + 1].text -cne '=' -or $tokens[$index + 2].text -cne '{') { return }
        $declaration = $index
    }
    if ($declaration -lt 0) { return }
    $open = $declaration + 2
    $close = Get-MatchingTokenIndex $tokens $open '{' '}'
    if (Test-LuaTableStatementBoundary $tokens $close) { [pscustomobject]@{ open = $open; close = $close } }
}

function Get-LuaLiteralListInsertByte {
    param($Context, [object[]] $Fields)
    $last = $Context.tokens[$Fields[-1].valueEndIndex]
    ConvertTo-Utf8ByteOffset $Context.text ($last.start + $last.length) $Context.bomLength
}

function Add-LuaPositionalRows {
    param(
        $Context,
        [int[]] $Arguments,
        [Collections.Generic.HashSet[int]] $AllowedReferences,
        [Collections.Generic.HashSet[string]] $AmbiguousTables
    )
    $tokens = $Context.tokens
    $sourceTable = Get-LuaLiteralLocalTable $Context $Arguments[0] $AllowedReferences
    $localeOrder = Get-LuaLiteralLocalTable $Context $Arguments[3] $AllowedReferences
    if ($null -eq $sourceTable -or $null -eq $localeOrder) {
        Add-LuaGeneratedBlock $Context $tokens[$Arguments[0]].text 'generated_local_table_unproven'
        return
    }
    $affixes = @(
        for ($index = 1; $index -le 2; $index++) {
            $token = $tokens[$Arguments[$index]]
            if ($token.type -ceq 'string') { ConvertFrom-LuaKeyString -Literal $token.text }
            elseif ($token.text -ceq 'nil') { '' }
        }
    )
    if ($affixes.Count -ne 2) {
        Add-LuaGeneratedBlock $Context $tokens[$Arguments[0]].text 'generated_key_affix_not_literal'
        return
    }
    $localeFields = Get-LuaLiteralList $tokens $localeOrder.open $localeOrder.close
    $localeIndices = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $localeReason = 'generated_locale_order_unproven'
    if ($null -ne $localeFields) {
        $localeReason = $null
        foreach ($field in $localeFields.fields) {
            $name = ConvertFrom-LuaKeyString -Literal $tokens[$field.valueStartIndex].text
            if (-not $localeIndices.TryAdd($name, $localeIndices.Count)) { $localeReason = 'duplicate_generated_locale' }
        }
        if (-not $localeIndices.ContainsKey('en') -and -not $localeReason) { $localeReason = 'missing_en_source_expression' }
    }

    $languageCount = $localeIndices.Count
    $localeInsertByte = if (-not $localeReason -and
        -not $AmbiguousTables.Contains($tokens[$Arguments[0]].text) -and
        -not $AmbiguousTables.Contains($tokens[$Arguments[3]].text) -and
        $localeIndices['en'] -eq 0 -and $localeIndices['zh-cn'] -eq 1 -and
        ($languageCount -eq 2 -or ($languageCount -eq 3 -and $localeIndices['zh-tw'] -eq 2))) {
        Get-LuaLiteralListInsertByte $Context $localeFields.fields
    } else { $null }

    $rowIndex = $sourceTable.open + 1
    while ($rowIndex -lt $sourceTable.close) {
        Invoke-LuaScannerProgressHeartbeat
        $keyEnd = if ($tokens[$rowIndex].text -ceq '[') { Get-MatchingTokenIndex $tokens $rowIndex '[' ']' } else { $rowIndex }
        $key = if ($keyEnd -eq $rowIndex -or ($keyEnd -eq ($rowIndex + 2) -and $tokens[$rowIndex + 1].type -ceq 'string')) {
            Get-LuaKey -Tokens $tokens -StartIndex $rowIndex -EndIndex $keyEnd
        }
        if ([string]::IsNullOrEmpty($key) -or $tokens[$keyEnd + 1].text -cne '=') {
            Add-LuaGeneratedBlock $Context $tokens[$Arguments[0]].text 'generated_input_row_key_unproven'
            return
        }
        $key = $affixes[0] + $key + $affixes[1]
        $rowOpen = $keyEnd + 2
        if ($tokens[$rowOpen].text -cne '{') {
            Add-LuaGeneratedBlock $Context $key 'generated_row_not_literal' '$'
            Add-LuaGeneratedBlock $Context $tokens[$Arguments[0]].text 'generated_input_rows_unproven'
            return
        }
        $rowClose = Get-MatchingTokenIndex $tokens $rowOpen '{' '}'
        $rowFields = Get-LuaLiteralList $tokens $rowOpen $rowClose
        $reason = if ($localeReason) { $localeReason }
            elseif ($null -eq $rowFields) { 'generated_row_not_literal' }
            elseif ($rowFields.fields.Count -ne $localeFields.fields.Count) { 'generated_locale_length_mismatch' }
            else { $null }
        $zhTwValue = $null
        if (-not $reason -and $localeIndices.ContainsKey('zh-tw')) {
            $literal = $tokens[$rowFields.fields[$localeIndices['zh-tw']].valueStartIndex].text
            try { $zhTwValue = ConvertFrom-LuaKeyString -Literal $literal -RequireUtf8 }
            catch { $reason = 'generated_positional_literal_value_unproven' }
        }
        if ($reason) { Add-LuaGeneratedBlock $Context $key $reason '$' }
        else {
            $zhCnValue = $null
            if ($localeIndices.ContainsKey('zh-cn')) {
                $literal = $tokens[$rowFields.fields[$localeIndices['zh-cn']].valueStartIndex].text
                $zhCnValue = try { ConvertFrom-LuaKeyString -Literal $literal -RequireUtf8 } catch { $null }
            }
            $Context.units.Add([pscustomobject]@{
                sourceId = $Context.sourceId; containerPath = '$'; key = $key; blockedReason = $null
                sourceExpression = New-ExpressionRecord -Text $Context.text -Tokens $tokens -Field $rowFields.fields[$localeIndices['en']] -BomLength $Context.bomLength -KnownStringLiteral
                zhTwExpression = if ($localeIndices.ContainsKey('zh-tw')) {
                    New-ExpressionRecord -Text $Context.text -Tokens $tokens -Field $rowFields.fields[$localeIndices['zh-tw']] -BomLength $Context.bomLength -KnownStringLiteral
                } else { $null }
                tableOpenByte = ConvertTo-Utf8ByteOffset $Context.text $tokens[$rowOpen].start $Context.bomLength
                tableCloseByte = ConvertTo-Utf8ByteOffset $Context.text $tokens[$rowClose].start $Context.bomLength
                generated = $true; positionalLocale = $true; positionalZhTwValue = $zhTwValue
                positionalZhCnValue = $zhCnValue
                positionalWrite = if ($null -ne $localeInsertByte -and $null -ne $zhCnValue) {
                    [ordered]@{
                        localeInsertByte = $localeInsertByte
                        rowInsertByte = Get-LuaLiteralListInsertByte $Context $rowFields.fields
                        languageCount = $languageCount
                        zhCnValue = $zhCnValue
                    }
                } else { $null }
            })
        }
        $rowIndex = $rowClose + 1
        if ($rowIndex -lt $sourceTable.close) {
            if ($tokens[$rowIndex].text -cnotin @(',', ';')) {
                Add-LuaGeneratedBlock $Context $tokens[$Arguments[0]].text 'generated_input_rows_unproven'
                return
            }
            $rowIndex++
        }
    }
}

function Get-LuaPositionalGeneratorCall {
    param($Context, [int] $Index, [int] $Definition)
    $tokens = $Context.tokens
    if ($Index -le $Definition -or $Context.layout.depths[$Index] -ne 0 -or
        $tokens[$Index + 1].text -cne '(' -or $tokens[$Index - 1].text -cin @('.', ':', '=', 'return', ',')) { return }
    $close = Get-MatchingTokenIndex $tokens ($Index + 1) '(' ')'
    $arguments = Get-LuaCallArguments $tokens ($Index + 1) $close
    if ($null -ne $arguments -and $arguments.indices.Count -eq 4 -and (Test-LuaTableStatementBoundary $tokens $close)) {
        $arguments
    }
}

function Get-LuaPositionalGenerator {
    param($Context, [string] $Accumulator)
    $tokens = $Context.tokens
    $name = 'generate_translation'
    if (-not $Context.references.ContainsKey($name)) { return }
    $references = $Context.references[$name]
    $definitions = @($references | Where-Object {
        $_ -ge 2 -and $Context.layout.depths[$_ - 1] -eq 0 -and $tokens[$_ - 2].text -ceq 'local' -and $tokens[$_ - 1].text -ceq 'function'
    })
    if ($definitions.Count -ne 1) { return }
    $definition = $definitions[0]
    $end = $Context.layout.closes[$definition - 1]
    $body = @'
generate_translation(t,prefix,suffix,lids)
    if type(t) ~= "table" then return end
    local prefix = prefix or ""
    local suffix = suffix or ""
    local full_id = ""
    for id,text in pairs(t) do
        full_id = prefix..id..suffix
        ACCUMULATOR[full_id] = ACCUMULATOR[full_id] or {}
        if type(text) == "table" and type(lids) == "table" and #lids == #text then
            for i = 1,#lids do
                ACCUMULATOR[full_id][lids[i]] = text[i]
            end
        elseif type(text) == "string" and type(lids) == "string" then
            ACCUMULATOR[full_id][lids] = text
        end
    end
end
'@
    if (-not $end -or -not (Test-LuaExactTokens $tokens $definition $end ($body.Replace('ACCUMULATOR', $Accumulator)))) { return }
    # Calls at conditional depth are retained as unresolved evidence, but any other
    # use of the helper name can rebind or escape it and invalidates static calls.
    $calls = [Collections.Generic.Dictionary[int, object]]::new()
    $allowedReferences = [Collections.Generic.HashSet[int]]::new()
    $inputTables = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $localeTables = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ambiguousTables = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $unresolved = [Collections.Generic.List[int]]::new()
    $reason = if ($Accumulator -cin @('t', 'prefix', 'suffix', 'lids', 'full_id', 'id', 'text', 'i') -or
        -not (Test-LuaUnshadowedPrimitive $Context 'pairs') -or -not (Test-LuaUnshadowedPrimitive $Context 'type')) {
        'generated_helper_binding_unproven'
    } else { $null }
    foreach ($index in $references) {
        if ($index -eq $definition) { continue }
        $call = Get-LuaPositionalGeneratorCall $Context $index $definition
        if ($null -ne $call) {
            $calls.Add($index, $call.indices)
            $null = $allowedReferences.Add($call.indices[0])
            $null = $allowedReferences.Add($call.indices[3])
            $inputName = $tokens[$call.indices[0]].text
            if (-not $inputTables.Add($inputName)) { $null = $ambiguousTables.Add($inputName) }
            $null = $localeTables.Add($tokens[$call.indices[3]].text)
        }
        else {
            $unresolved.Add($index)
            if ($index -lt $definition -or $tokens[$index + 1].text -cne '(' -or
                $tokens[$index - 1].text -cin @('local', 'function', '.', ':', '=', 'return', ',')) {
                $reason = 'generated_helper_binding_unproven'
            }
        }
    }
    $localeTables.IntersectWith($inputTables)
    $ambiguousTables.UnionWith($localeTables)
    [pscustomobject]@{
        start = $definition; end = $end; calls = $calls; allowedReferences = $allowedReferences
        unresolved = $unresolved; reason = $reason; ambiguousTables = $ambiguousTables
    }
}

function Get-LuaTemplateGenerator {
    param($Context, [string] $Name, [int] $CallIndex)
    $tokens = $Context.tokens
    $definitions = @($Context.references[$Name] | Where-Object {
        $_ -ge 2 -and $_ -lt $CallIndex -and $Context.layout.depths[$_ - 1] -eq 0 -and
        $tokens[$_ - 2].text -ceq 'local' -and $tokens[$_ - 1].text -ceq 'function'
    })
    if ($definitions.Count -ne 1) { return }
    $definition = $definitions[0]
    $end = $Context.layout.closes[$definition - 1]
    if (($definition + 5) -ge $end -or $tokens[$definition + 1].text -cne '(' -or
        $tokens[$definition + 2].type -cne 'identifier' -or $tokens[$definition + 3].text -cne ',' -or
        $tokens[$definition + 4].type -cne 'identifier' -or $tokens[$definition + 5].text -cne ')') { return }
    foreach ($reference in $Context.references[$Name]) {
        if ($reference -eq $definition) { continue }
        if ($reference -lt $definition -or $tokens[$reference + 1].text -cne '(' -or
            $tokens[$reference - 1].text -cin @('local', 'function', '.', ':', '=', 'return', ',')) { return }
    }
    $target = $tokens[$definition + 2].text
    $value = $tokens[$definition + 4].text
    if ($target -ceq $value) { return }
    $position = $definition + 6
    # Spidey Sense registers a separate options entry before assigning localization tables.
    if ($tokens[$position].text -ceq 'if') {
        $guardEnd = $Context.layout.closes[$position]
        $registration = 'if TEMPLATE ~= "melee_backstab" and TEMPLATE ~= "ranged_backstab" then table.insert(mod.typeList, {text = TEMPLATE .. "_name", value = TEMPLATE}) end'
        if (-not $guardEnd -or -not (Test-LuaUnshadowedPrimitive $Context 'table' -MemberCalls) -or
            -not (Test-LuaExactTokens $tokens $position $guardEnd ($registration.Replace('TEMPLATE', $value)))) { return }
        $position = $guardEnd + 1
    }
    $templates = [Collections.Generic.List[object]]::new()
    while ($position -lt $end) {
        Invoke-LuaScannerProgressHeartbeat
        if ($tokens[$position].text -cne $target -or $tokens[$position + 1].text -cne '[') { return }
        $assignment = Get-LuaAccumulatorAssignment $tokens $position
        if ($null -eq $assignment -or $assignment.keyEnd -ne ($assignment.keyStart + 2) -or
            $assignment.tableEnd -lt 0 -or $tokens[$assignment.keyStart + 1].text -cne '..' -or
            -not (Test-LuaTableStatementBoundary $tokens $assignment.tableEnd)) { return }
        $left = $tokens[$assignment.keyStart]
        $right = $tokens[$assignment.keyEnd]
        $prefix = ''; $suffix = ''
        if ($left.type -ceq 'string' -and $right.text -ceq $value) { $prefix = ConvertFrom-LuaKeyString -Literal $left.text }
        elseif ($left.text -ceq $value -and $right.type -ceq 'string') { $suffix = ConvertFrom-LuaKeyString -Literal $right.text }
        else { return }
        $templates.Add([pscustomobject]@{ prefix = $prefix; suffix = $suffix; tableIndex = $assignment.valueIndex })
        $position = $assignment.tableEnd + 1
        if ($tokens[$position].text -ceq ';') { $position++ }
    }
    if ($templates.Count -gt 0) { [pscustomobject]@{ templates = @($templates); parameter = $value; targetParameter = $target } }
}

function Test-LuaReferenceIsField {
    param($Context, [int] $Index)
    if ($Index -eq 0) { return $false }
    $tokens = $Context.tokens
    if ($tokens[$Index - 1].text -cin @('.', ':')) { return $true }
    -not $Context.layout.depths.ContainsKey($Index) -and ($Index + 1) -lt $tokens.Count -and
        $tokens[$Index - 1].text -cin @('{', ',', ';') -and $tokens[$Index + 1].text -ceq '='
}

function Add-LuaAccumulatorRootTable {
    param($Context, [int] $Open)
    $firstUnit = $Context.units.Count
    $null = Read-LuaTable -Text $Context.text -Tokens $Context.tokens -OpenIndex $Open -ContainerPath '$' -AssignedKey $null -SourceId $Context.sourceId -Units $Context.units -BomLength $Context.bomLength
    for ($index = $firstUnit; $index -lt $Context.units.Count; $index++) {
        Invoke-LuaScannerProgressHeartbeat
        $unit = $Context.units[$index]
        if ($unit.containerPath -ceq '$') { continue }
        if (-not $Context.descendantsByRoot.ContainsKey($unit.rootKey)) {
            $Context.descendantsByRoot.Add($unit.rootKey, [Collections.Generic.List[object]]::new())
        }
        $Context.descendantsByRoot[$unit.rootKey].Add($unit)
    }
}

function Test-LuaLiteralLanguageTable {
    param([object[]] $Tokens, [int] $Open, [int] $Close)
    $languages = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $position = $Open + 1
    while ($position -lt $Close) {
        $keyEnd = if ($Tokens[$position].text -ceq '[') { $position + 2 } else { $position }
        $value = $keyEnd + 2
        if ($value -ge $Close -or $Tokens[$keyEnd + 1].text -cne '=' -or $Tokens[$value].type -cne 'string') { return $false }
        $key = Get-LuaKey $Tokens $position $keyEnd
        if ($key -cnotin @('en', 'zh-cn', 'zh-tw') -or -not $languages.Add($key)) { return $false }
        try { $null = ConvertFrom-LuaKeyString $Tokens[$value].text -RequireUtf8 }
        catch { return $false }
        $position = $value + 1
        if ($position -lt $Close) {
            if ($Tokens[$position].text -cnotin @(',', ';')) { return $false }
            $position++
        }
    }
    $languages.Contains('en')
}

function Get-LuaLiteralListLoop {
    param($Context, [string] $Accumulator, [int] $Iterator, [int] $After)
    $tokens = $Context.tokens
    $start = $Iterator - 5
    if ($start -le $After -or ($Iterator + 7) -ge $tokens.Count -or $Context.layout.depths[$start] -ne 0 -or
        $tokens[$start].text -cne 'for' -or $tokens[$start + 1].text -cne '_' -or $tokens[$start + 2].text -cne ',' -or
        $tokens[$start + 3].type -cne 'identifier' -or $tokens[$start + 4].text -cne 'in' -or
        $tokens[$Iterator + 1].text -cne '(') { return }
    $parameter = $tokens[$start + 3].text
    if ($parameter -cin @('_', $Accumulator) -or $Accumulator -ceq '_') { return }

    $argument = $Iterator + 2
    $close = Get-MatchingTokenIndex $tokens ($Iterator + 1) '(' ')'
    $doIndex = $close + 1
    if ($tokens[$doIndex].text -cne 'do' -or -not $Context.layout.closes.ContainsKey($doIndex)) { return }
    $end = $Context.layout.closes[$doIndex]
    if ($tokens[$end].text -cne 'end') { return }
    $list = if ($tokens[$argument].text -ceq '{' -and $tokens[$close - 1].text -ceq '}') {
        if ((Get-MatchingTokenIndex $tokens $argument '{' '}') -eq ($close - 1)) { [pscustomobject]@{ open = $argument; close = $close - 1 } }
    }
    elseif ($close -eq ($argument + 1)) {
        Get-LuaLiteralLocalTable $Context $argument ([Collections.Generic.HashSet[int]]::new())
    }
    if ($null -eq $list) { return }
    $fields = Get-LuaLiteralList $tokens $list.open $list.close
    if ($null -eq $fields -or $fields.fields.Count -lt 1 -or $fields.fields.Count -gt 128) { return }
    $prefixes = [Collections.Generic.List[string]]::new()
    $seenPrefixes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($field in $fields.fields) {
        try { $prefix = ConvertFrom-LuaKeyString $tokens[$field.valueStartIndex].text -RequireUtf8 }
        catch { return }
        if ($prefix -cnotmatch '^[A-Za-z0-9_]+$' -or -not $seenPrefixes.Add($prefix)) { return }
        $prefixes.Add($prefix)
    }

    $items = [Collections.Generic.List[object]]::new()
    $seenSuffixes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $position = $doIndex + 1
    $overlay = $null
    while ($position -lt $end) {
        Invoke-LuaScannerProgressHeartbeat
        if ($items.Count -ge 128 -or ($position + 6) -ge $end -or $tokens[$position].text -cne $Accumulator -or
            $tokens[$position + 1].text -cne '[' -or $tokens[$position + 2].text -cne $parameter -or
            $tokens[$position + 3].text -cne '..' -or $tokens[$position + 4].type -cne 'string' -or
            $tokens[$position + 5].text -cne ']') { return }
        try { $suffix = ConvertFrom-LuaKeyString $tokens[$position + 4].text -RequireUtf8 }
        catch { return }
        if ($suffix -cnotmatch '^_[A-Za-z0-9_]+$' -or -not $seenSuffixes.Add($suffix)) { return }

        $fieldIndex = $position + 6
        $isOverlay = $tokens[$fieldIndex].text -ceq '['
        if ($null -eq $overlay) { $overlay = $isOverlay }
        elseif ($overlay -ne $isOverlay) { return }
        if ($isOverlay) {
            $value = $fieldIndex + 4
            if ($value -ge $end -or $tokens[$fieldIndex + 1].text -cne '"zh-tw"' -or
                $tokens[$fieldIndex + 2].text -cne ']' -or $tokens[$fieldIndex + 3].text -cne '=' -or
                $tokens[$value].type -cne 'string' -or -not (Test-LuaTableStatementBoundary $tokens $value)) { return }
            try { $null = ConvertFrom-LuaKeyString $tokens[$value].text -RequireUtf8 }
            catch { return }
            $items.Add([pscustomobject]@{ suffix = $suffix; field = [ordered]@{
                fieldStartIndex = $fieldIndex; valueStartIndex = $value; valueEndIndex = $value; separatorIndex = $null
            } })
            $position = $value + 1
        }
        else {
            $assignment = Get-LuaAccumulatorAssignment $tokens $position
            if ($null -eq $assignment -or $assignment.tableEnd -lt 0 -or $assignment.tableEnd -ge $end -or
                -not (Test-LuaLiteralLanguageTable $tokens $assignment.valueIndex $assignment.tableEnd)) { return }
            $items.Add([pscustomobject]@{ suffix = $suffix; tableIndex = $assignment.valueIndex })
            $position = $assignment.tableEnd + 1
        }
        if ($tokens[$position].text -ceq ';') { $position++ }
    }
    if ($items.Count -eq 0 -or ($items.Count * $prefixes.Count) -gt 512) { return }

    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $items) {
        foreach ($prefix in $prefixes) {
            if (-not $keys.Add($prefix + $item.suffix)) { return }
        }
    }
    [pscustomobject]@{ start = $start; end = $end; parameter = $parameter; prefixes = $prefixes; items = $items; overlay = $overlay }
}

function Add-LuaLiteralListLoop {
    param($Context, $Loop, [Collections.Generic.Dictionary[string, object]] $PriorOutputs)
    foreach ($item in $Loop.items) {
        $overlayTable = $null
        foreach ($prefix in $Loop.prefixes) {
            Invoke-LuaScannerProgressHeartbeat
            $key = $prefix + $item.suffix
            if ($Loop.overlay) {
                $target = if ($PriorOutputs.ContainsKey($key)) { $PriorOutputs[$key] }
                if ($null -eq $target -or $null -ne $target.zhTwExpression -or $null -eq $target.tableOpenByte -or
                    $target.generatedBinding.prefix -cne $prefix -or $target.generatedBinding.suffix -cne $item.suffix -or
                    ($null -ne $overlayTable -and $target.tableOpenByte -ne $overlayTable)) {
                    Add-LuaGeneratedBlock $Context $key 'generated_literal_overlay_target_unproven'
                    return
                }
                # All users of this physical overlay value must be in one shared-table group.
                $overlayTable = $target.tableOpenByte
            }
            else {
                $binding = [ordered]@{ kind = 'literal-list-loop'; parameter = $Loop.parameter; prefix = $prefix; suffix = $item.suffix }
                Add-LuaGeneratedTable $Context $item.tableIndex $key $binding
                $unit = $Context.units[$Context.units.Count - 1]
                if (-not $PriorOutputs.TryAdd($key, $unit)) { $PriorOutputs[$key] = $null }
            }
        }
    }
    if ($Loop.overlay) {
        foreach ($item in $Loop.items) {
            $translation = New-ExpressionRecord -Text $Context.text -Tokens $Context.tokens -Field $item.field -BomLength $Context.bomLength -KnownStringLiteral
            foreach ($prefix in $Loop.prefixes) {
                $PriorOutputs[$prefix + $item.suffix].zhTwExpression = $translation
            }
        }
    }
}

function Test-LuaLocalizationUnitInRootNamespace {
    param($Unit, [string] $Prefix)
    if ($null -eq $Unit -or [string]::IsNullOrEmpty($Prefix)) { return $false }
    $container = [string]$Unit.containerPath
    # A computed root key has no proven literal namespace.
    if ($container -ceq '$') {
        $key = [string]$Unit.key
        return $key.StartsWith($Prefix, [StringComparison]::Ordinal) -or $key.StartsWith('[', [StringComparison]::Ordinal)
    }
    $container.StartsWith('$.' + $Prefix, [StringComparison]::Ordinal) -or $container.StartsWith('$[', [StringComparison]::Ordinal)
}

function Get-LuaGameLocalizedPassthrough {
    param($Context, [string] $Accumulator, [int] $After)
    $prefix = 'game_class_name_'
    if ($Accumulator -cin @('_', 'class', 'datalookup', 'lid', 'pairs', 'Localize')) { return }
    $tokens = $Context.tokens
    $lookupReferences = @($Context.references['datalookup'] | Where-Object { $null -ne $_ -and -not (Test-LuaReferenceIsField $Context $_) })
    if ($lookupReferences.Count -ne 2) { return }
    $lookupDeclaration = $lookupReferences[0]
    if ($lookupDeclaration -lt 1 -or $Context.layout.depths[$lookupDeclaration] -ne 0 -or
        ($lookupDeclaration + 4) -ge $tokens.Count -or
        -not (Test-LuaExactTokens $tokens ($lookupDeclaration - 1) ($lookupDeclaration + 4) 'local datalookup = mod.datalookup') -or
        -not (Test-LuaTableStatementBoundary $tokens ($lookupDeclaration + 4))) { return }

    # The only permitted runtime result is an active-locale game string under this prefix.
    $loop = @'
for _,class in pairs(datalookup.class_index) do
    ACCUMULATOR["game_class_name_"..class] = ACCUMULATOR["game_class_name_"..class] or {}
    ACCUMULATOR["game_class_name_"..class][lid] = Localize("loc_class_"..class.."_name")
end
'@
    $start = $lookupReferences[1] - 7
    $doIndex = $start + 11
    if ($start -le $After -or $start -le $lookupDeclaration -or $Context.layout.depths[$start] -ne 0 -or
        -not $Context.layout.closes.ContainsKey($doIndex)) { return }
    $end = $Context.layout.closes[$doIndex]
    if (-not (Test-LuaExactTokens $tokens $start $end ($loop.Replace('ACCUMULATOR', $Accumulator))) -or
        -not (Test-LuaUnshadowedPrimitive $Context 'pairs') -or
        -not (Test-LuaUnshadowedPrimitive $Context 'Localize') -or
        -not (Test-LuaActiveLocaleBinding $Context $start)) { return }

    [pscustomobject]@{ start = $start; end = $end; prefix = $prefix }
}

function Get-LuaMoodLocalizedPassthrough {
    param($Context, [string] $Accumulator, [int] $After)
    if ($Accumulator -cin @('_', 'mood_type', 'label', 'MoodSettings', 'require', 'pairs', 'string')) { return }
    $tokens = $Context.tokens
    $references = @($Context.references['MoodSettings'] | Where-Object { $null -ne $_ -and -not (Test-LuaReferenceIsField $Context $_) })
    if ($references.Count -ne 2) { return }
    $declaration = $references[0]
    $start = $references[1] - 7
    $doIndex = $start + 11
    if ($declaration -lt 1 -or $Context.layout.depths[$declaration] -ne 0 -or ($declaration + 5) -ge $start -or
        $start -le $After -or $Context.layout.depths[$start] -ne 0 -or -not $Context.layout.closes.ContainsKey($doIndex) -or
        -not (Test-LuaExactTokens $tokens ($declaration - 1) ($declaration + 5) 'local MoodSettings = require("scripts/settings/camera/mood/mood_settings")') -or
        -not (Test-LuaTableStatementBoundary $tokens ($declaration + 5))) { return }

    $loop = @'
for mood_type, _ in pairs(MoodSettings.mood_types) do
    local label = string.gsub(mood_type, "_", " ")
    ACCUMULATOR["hide_mood_vfx_" .. mood_type] = {
        en = "Disable " .. label,
    }
end
'@
    $end = $Context.layout.closes[$doIndex]
    if (-not (Test-LuaExactTokens $tokens $start $end ($loop.Replace('ACCUMULATOR', $Accumulator))) -or
        -not (Test-LuaUnshadowedPrimitive $Context 'require') -or
        -not (Test-LuaUnshadowedPrimitive $Context 'pairs') -or
        -not (Test-LuaUnshadowedPrimitive $Context 'string' -MemberCalls)) { return }

    [pscustomobject]@{ start = $start; end = $end; prefix = 'hide_mood_vfx_' }
}

function Add-LuaAccumulatorUnits {
    param($Context)
    $tokens = $Context.tokens
    $last = $tokens.Count - 1
    while ($last -ge 0 -and $tokens[$last].text -ceq ';') { $last-- }
    if ($last -lt 2 -or $tokens[$last].type -cne 'identifier' -or $tokens[$last - 1].text -cne 'return') { return }
    $accumulator = $tokens[$last].text
    if ($accumulator -cin @('nil', 'true', 'false')) { return }
    $Context.layout = Get-LuaStatementLayout $tokens
    if ($Context.layout.depths[$last - 1] -ne 0) { return }
    $references = [Collections.Generic.Dictionary[string, Collections.Generic.List[int]]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        Invoke-LuaScannerProgressHeartbeat
        if ($tokens[$index].type -cne 'identifier') { continue }
        $name = $tokens[$index].text
        if (-not $references.ContainsKey($name)) { $references.Add($name, [Collections.Generic.List[int]]::new()) }
        $references[$name].Add($index)
    }
    $Context.references = $references
    $accumulatorReferences = @($references[$accumulator] | Where-Object { -not (Test-LuaReferenceIsField $Context $_) })
    $declarations = @($accumulatorReferences | Where-Object {
        $_ -gt 0 -and $_ -lt ($last - 1) -and $Context.layout.depths.ContainsKey($_) -and
        $Context.layout.depths[$_] -eq 0 -and $tokens[$_ - 1].text -ceq 'local'
    })
    if ($declarations.Count -eq 0) { return }
    $declaration = $declarations[0]
    $initial = $declaration
    if ($tokens[$declaration + 1].text -ceq ';' -or $tokens[$declaration + 1].type -ceq 'identifier') {
        $deferred = @($accumulatorReferences | Where-Object { $_ -gt $declaration })
        if ($deferred.Count -gt 0) { $initial = $deferred[0] }
    }
    if (($initial + 2) -ge $tokens.Count -or $tokens[$initial + 1].text -cne '=' -or $tokens[$initial + 2].text -cne '{') {
        $writes = @($accumulatorReferences | Where-Object { $null -ne (Get-LuaAccumulatorAssignment $tokens $_) })
        if ($writes.Count -gt 0) { Add-LuaGeneratedBlock $Context $accumulator 'localization_accumulator_unproven' }
        return
    }
    $Context.namedAccumulator = $true
    if ($declarations.Count -gt 1) {
        Add-LuaGeneratedBlock $Context $accumulator 'localization_accumulator_reassigned'
        return
    }
    if ($Context.layout.outerReturns.Count -ne 1 -or $Context.layout.outerGotoOrLabel) {
        Add-LuaGeneratedBlock $Context $accumulator 'generated_control_flow_unproven'
        return
    }
    $initialClose = Get-MatchingTokenIndex $tokens ($initial + 2) '{' '}'
    if (-not $Context.layout.depths.ContainsKey($initial) -or $Context.layout.depths[$initial] -ne 0 -or
        -not (Test-LuaTableStatementBoundary $tokens $initialClose)) {
        Add-LuaGeneratedBlock $Context $accumulator 'localization_accumulator_unproven'
        return
    }
    Add-LuaAccumulatorRootTable $Context ($initial + 2)

    $generator = Get-LuaPositionalGenerator $Context $accumulator
    $Context.sidecarPath = Get-LuaGeneratedSidecarPath $Context $generator
    $gameLocalized = @(
        Get-LuaGameLocalizedPassthrough $Context $accumulator $initialClose
        Get-LuaMoodLocalizedPassthrough $Context $accumulator $initialClose
    )
    $literalLoops = @(
        if ($Context.references.ContainsKey('ipairs') -and (Test-LuaUnshadowedPrimitive $Context 'ipairs')) {
            foreach ($iterator in $Context.references['ipairs']) { Get-LuaLiteralListLoop $Context $accumulator $iterator $initialClose }
        }
    )
    $events = [Collections.Generic.SortedDictionary[int, object]]::new()
    $coveredReferences = [Collections.Generic.HashSet[int]]::new()
    foreach ($loop in $gameLocalized) {
        $events.Add($loop.start, [pscustomobject]@{ type = 'gameLocalizedPassthrough' })
        for ($index = $loop.start + 1; $index -lt $loop.end; $index++) { $null = $coveredReferences.Add($index) }
    }
    foreach ($loop in $literalLoops) {
        $events.Add($loop.start, [pscustomobject]@{ type = 'literalListLoop'; loop = $loop })
        for ($index = $loop.start + 1; $index -lt $loop.end; $index++) { $null = $coveredReferences.Add($index) }
    }
    if ($null -ne $generator) {
        foreach ($entry in $generator.calls.GetEnumerator()) {
            $events.Add($entry.Key, [pscustomobject]@{ type = 'positional'; arguments = $entry.Value })
        }
        foreach ($index in $generator.unresolved) {
            $events.Add($index, [pscustomobject]@{ type = 'unresolvedPositional' })
        }
    }

    foreach ($index in $accumulatorReferences) {
        if ($index -in @($declaration, $initial, $last)) { continue }
        if ($coveredReferences.Contains($index)) { continue }
        if ($null -ne $generator -and $index -gt $generator.start -and $index -lt $generator.end -and $initial -lt $generator.start) { continue }
        $assignment = Get-LuaAccumulatorAssignment $tokens $index
        if ($null -ne $assignment) {
            $events.Add($index, [pscustomobject]@{ type = 'assignment'; assignment = $assignment })
            continue
        }
        if ($tokens[$index + 1].text -ceq '=') {
            $events.Add($index, [pscustomobject]@{ type = 'reassignment' })
            continue
        }
        $events.Add($index, [pscustomobject]@{ type = 'reference' })
    }

    $hasWritten = $false
    $templateGenerators = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $literalLoopOutputs = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $events.GetEnumerator()) {
        Invoke-LuaScannerProgressHeartbeat
        $index = $entry.Key
        switch ($entry.Value.type) {
            'literalListLoop' { Add-LuaLiteralListLoop $Context $entry.Value.loop $literalLoopOutputs }
            'reassignment' {
                if (-not $hasWritten -and $index -gt $initialClose -and $initialClose -eq ($initial + 3) -and
                    $Context.layout.depths[$index] -eq 0 -and $tokens[$index - 1].text -cnotin @('local', '.', ':', ',') -and
                    $tokens[$index + 2].text -ceq '{') {
                    $close = Get-MatchingTokenIndex $tokens ($index + 2) '{' '}'
                    if (Test-LuaTableStatementBoundary $tokens $close) {
                        Add-LuaAccumulatorRootTable $Context ($index + 2)
                        $hasWritten = $true
                        continue
                    }
                }
                Add-LuaGeneratedBlock $Context $accumulator 'localization_accumulator_reassigned'
            }
            'positional' {
                if ($generator.reason) { Add-LuaGeneratedBlock $Context $accumulator $generator.reason }
                elseif ($initial -gt $generator.start) { Add-LuaGeneratedBlock $Context $accumulator 'localization_accumulator_unproven' }
                else { Add-LuaPositionalRows $Context $entry.Value.arguments $generator.allowedReferences $generator.ambiguousTables }
            }
            'unresolvedPositional' {
                $key = if ($tokens[$index + 1].text -ceq '(') {
                    $close = Get-MatchingTokenIndex $tokens ($index + 1) '(' ')'
                    Get-CanonicalTokenText $tokens $index $close
                } else { $tokens[$index].text }
                $conditionalSidecar = $null -ne $Context.sidecarPath -and $index -in $Context.sidecarPath.conditionalCallIndices
                Add-LuaGeneratedBlock $Context $key 'unsupported_generated_localization_call' -ConditionalZhTwSidecar:$conditionalSidecar
            }
            'assignment' {
                $assignment = $entry.Value.assignment
                $outputs = @(
                    if ($Context.layout.depths[$index] -eq 0 -and $tokens[$index - 1].text -cnotin @('local', '.', ':', ',', '=') -and
                        (Test-LuaTableStatementBoundary $tokens $assignment.tableEnd)) {
                        $key = Get-LuaLiteralAccumulatorKey $tokens $index $assignment
                        if ($key) { [pscustomobject]@{ key = $key; binding = $null } }
                    }
                    elseif ($assignment.tableEnd -ge 0) { Get-LuaLimitedFormatOutputs $Context $index $assignment }
                )
                if ($index -gt $initialClose -and $outputs.Count -gt 0) {
                    foreach ($item in $outputs) { Add-LuaGeneratedTable $Context $assignment.valueIndex $item.key $item.binding }
                }
                else {
                    $key = Get-LuaLiteralAccumulatorKey $tokens $index $assignment
                    if ($key) {
                        if ($index -gt $initialClose) { Set-LuaOverwrittenDescendants $Context $key }
                        Add-LuaGeneratedBlock $Context $key 'unsupported_generated_localization_assignment' '$'
                    }
                    else {
                        $shape = Get-CanonicalTokenText $tokens $assignment.keyStart $assignment.keyEnd
                        Add-LuaGeneratedBlock $Context $shape 'unsupported_generated_localization_key'
                    }
                }
            }
            'reference' {
                if ($index -gt ($initialClose + 1) -and $index -lt ($last - 3) -and
                    $tokens[$index - 1].text -ceq '(' -and $tokens[$index - 2].type -ceq 'identifier' -and
                    $Context.layout.depths[$index - 2] -eq 0 -and $tokens[$index - 3].text -cnotin @('.', ':', '=', 'return', ',') -and
                    $tokens[$index + 1].text -ceq ',' -and $tokens[$index + 2].type -ceq 'string' -and
                    $tokens[$index + 3].text -ceq ')' -and (Test-LuaTableStatementBoundary $tokens ($index + 3))) {
                    $helperName = $tokens[$index - 2].text
                    if (-not $templateGenerators.ContainsKey($helperName)) {
                        $templateGenerators[$helperName] = Get-LuaTemplateGenerator $Context $helperName ($index - 2)
                    }
                    $helper = $templateGenerators[$helperName]
                    if ($null -ne $helper) {
                        $value = ConvertFrom-LuaKeyString -Literal $tokens[$index + 2].text
                        foreach ($template in $helper.templates) {
                            $binding = [ordered]@{
                                kind = 'literal-helper'; parameter = $helper.parameter; targetParameter = $helper.targetParameter
                                value = $value; prefix = $template.prefix; suffix = $template.suffix
                            }
                            Add-LuaGeneratedTable $Context $template.tableIndex ($template.prefix + $value + $template.suffix) $binding
                        }
                        $hasWritten = $true
                        continue
                    }
                }
                $shape = Get-CanonicalTokenText $tokens ([Math]::Max(0, $index - 2)) ([Math]::Min($last, $index + 3))
                Add-LuaGeneratedBlock $Context $shape 'localization_accumulator_reference_unproven'
            }
        }
        $hasWritten = $true
    }

    foreach ($loop in $gameLocalized) {
        $collides = $false
        foreach ($unit in $Context.units) {
            Invoke-LuaScannerProgressHeartbeat
            if (Test-LuaLocalizationUnitInRootNamespace $unit $loop.prefix) {
                $collides = $true
                break
            }
        }
        if ($collides) { Add-LuaGeneratedBlock $Context $loop.prefix 'game_localize_passthrough_prefix_collision' }
        else { $Context.gameLocalizedPassthroughPrefixes.Add($loop.prefix) }
    }
}

function Test-LuaActiveLocaleBinding {
    param($Context, [int] $LoaderStart)
    $tokens = $Context.tokens
    $declarations = [Collections.Generic.List[int]]::new()
    $memberWrites = [Collections.Generic.List[int]]::new()
    foreach ($index in $Context.references['lid']) {
        if (($index + 1) -ge $tokens.Count) { return $false }
        if ($index -ge 2 -and $tokens[$index - 1].text -ceq '.' -and $tokens[$index - 2].text -ceq 'mod') {
            if ($tokens[$index + 1].text -ceq '=') { $memberWrites.Add($index) }
            elseif ($tokens[$index + 1].text -ceq ',') { return $false }
            continue
        }
        if (Test-LuaReferenceIsField $Context $index) { continue }
        if ($index -gt 0 -and $tokens[$index - 1].text -ceq 'local') { $declarations.Add($index); continue }
        if ($tokens[$index + 1].text -cin @('=', ',')) { return $false }
    }
    if ($declarations.Count -ne 1) { return $false }
    $declaration = $declarations[0]
    if ($declaration -ge $LoaderStart -or $Context.layout.depths[$declaration] -ne 0) { return $false }

    $oldBinding = 'local lid = Managers and Managers.localization and Managers.localization:language() or mod:get("user_lid") or "en"'
    $oldEnd = $declaration + @(Get-LuaTokens -Text $oldBinding).Count - 2
    if ($oldEnd -lt $tokens.Count -and $memberWrites.Count -eq 0 -and
        (Test-LuaExactTokens $tokens ($declaration - 1) $oldEnd $oldBinding) -and
        (Test-LuaTableStatementBoundary $tokens $oldEnd)) { return $true }

    if ($memberWrites.Count -ne 1 -or $memberWrites[0] -ge $declaration -or
        $Context.layout.depths[$memberWrites[0]] -ne 0 -or
        -not (Test-LuaExactTokens $tokens ($declaration - 1) ($declaration + 4) 'local lid = mod.lid') -or
        -not (Test-LuaTableStatementBoundary $tokens ($declaration + 4))) { return $false }
    $start = $memberWrites[0] - 2
    $newBinding = 'mod.lid = Managers and Managers.localization and Managers.localization:language() or Application.user_setting("language_id") or "en"'
    $newEnd = $start + @(Get-LuaTokens -Text $newBinding).Count - 1
    $newEnd -lt $declaration -and (Test-LuaExactTokens $tokens $start $newEnd $newBinding) -and
        (Test-LuaTableStatementBoundary $tokens $newEnd)
}

function Test-LuaNativeSidecarLoaderBinding {
    param($Context, [string] $LoaderPath, [int] $Start, [int] $End)
    $tokens = $Context.tokens
    $getModReferences = @($Context.references['get_mod'] | Where-Object { $null -ne $_ -and -not (Test-LuaReferenceIsField $Context $_) })
    if ($getModReferences.Count -ne 1 -or -not (Test-LuaUnshadowedPrimitive $Context 'get_mod')) { return $false }
    $getModIndex = $getModReferences[0]
    $modDeclaration = $getModIndex - 2
    if ($getModIndex -lt 3 -or ($getModIndex + 3) -ge $Start -or $Context.layout.depths[$modDeclaration] -ne 0) { return $false }
    $nameToken = $tokens[$getModIndex + 2]
    if ($nameToken.type -cne 'string' -or
        -not (Test-LuaExactTokens $tokens ($getModIndex - 3) ($getModIndex + 3) ('local mod = get_mod(' + $nameToken.text + ')')) -or
        -not (Test-LuaTableStatementBoundary $tokens ($getModIndex + 3))) { return $false }
    try { $modName = ConvertFrom-LuaKeyString -Literal $nameToken.text -RequireUtf8 }
    catch { return $false }
    $pathParts = $LoaderPath.Split('/')
    if ($modName -cne $pathParts[0] -or $modName -cne $pathParts[3]) { return $false }

    # The receiver may use unrelated named members. Reject replacement or escape of
    # the receiver itself and allow references to io_dofile only as direct calls.
    $loaderCallFound = $false
    foreach ($index in $Context.references['mod']) {
        if ($index -eq $modDeclaration -or (Test-LuaReferenceIsField $Context $index)) { continue }
        if ($index -lt $modDeclaration -or ($index + 2) -ge $tokens.Count -or
            $tokens[$index + 1].text -cnotin @('.', ':') -or $tokens[$index + 2].type -cne 'identifier') { return $false }
        if ($tokens[$index + 2].text -ceq 'io_dofile') {
            if ($tokens[$index - 1].text -ceq 'function' -or
                ($index + 3) -ge $tokens.Count -or $tokens[$index + 3].text -cne '(') { return $false }
            if ($index -gt $Start -and $index -lt $End) { $loaderCallFound = $true }
        }
    }
    if (-not $loaderCallFound) { return $false }

    # Both the native I/O chain and its local alias must be confined to the exact
    # initializer and the loader's single open call.
    $ioReferences = @($Context.references['_io'] | Where-Object { $null -ne $_ -and -not (Test-LuaReferenceIsField $Context $_) })
    $modsReferences = @($Context.references['Mods'] | Where-Object { $null -ne $_ -and -not (Test-LuaReferenceIsField $Context $_) })
    if ($ioReferences.Count -ne 2 -or $modsReferences.Count -ne 1) { return $false }
    $ioDeclaration = $ioReferences[0]
    $ioCall = $ioReferences[1]
    $ioDeclaration -gt 0 -and ($ioDeclaration + 6) -lt $Start -and
        $Context.layout.depths[$ioDeclaration] -eq 0 -and $modsReferences[0] -eq ($ioDeclaration + 2) -and
        $ioCall -gt $Start -and ($ioCall + 3) -lt $End -and
        (Test-LuaExactTokens $tokens ($ioDeclaration - 1) ($ioDeclaration + 6) 'local _io = Mods.lua.io') -and
        (Test-LuaTableStatementBoundary $tokens ($ioDeclaration + 6)) -and
        $tokens[$ioCall + 1].text -ceq '.' -and $tokens[$ioCall + 2].text -ceq 'open' -and $tokens[$ioCall + 3].text -ceq '('
}

function Get-LuaGeneratedSidecarPath {
    param($Context, $Generator)
    $tokens = $Context.tokens
    if ($null -eq $Generator -or $Generator.reason -or $Generator.unresolved.Count -ne 3) { return }
    $beforeOpen = @'
if lid and type(lid) == "string" then
    local _mod_directory = "./../mods/"
    local my_lid = SIDECAR_PATH .. lid
'@
    # Verify the path operand and literal read-only mode directly in the Lua tokens.
    $readOnlyOpen = @(
        'local', 'file', '=', '_io', '.', 'open', '('
        '_mod_directory', '..', 'my_lid', '..', '".lua"'
        ',', '"r"', ')'
    )
    $afterOpen = @'
    if file ~= nil then
        file:close()
        my_lid = mod:io_dofile(my_lid)
        if my_lid.common then
            local myl_nt = my_lid.common.player_notable_talents or my_lid.common.setting_player_notable_talents
            if my_nt then
                my_lid.common.mod_description = generate_notable_talents_description(myl_nt)
            end
            generate_translation(my_lid.common,nil,nil,lid)
        end
        if my_lid.talents then generate_translation(my_lid.talents,"def_",nil,lid) end
        if my_lid.notable then generate_translation(my_lid.notable,"highlight_",nil,lid) end
    end
end
'@
    foreach ($index in $Context.references['my_lid']) {
        if ($index -lt 2 -or $tokens[$index - 1].text -cne 'local' -or
            $tokens[$index + 1].text -cne '=' -or $tokens[$index + 2].type -cne 'string') { continue }
        $pathToken = $tokens[$index + 2].text
        $path = ConvertFrom-LuaKeyString -Literal $pathToken
        if ($path -cnotmatch '^[A-Za-z0-9_-]+/scripts/mods/[A-Za-z0-9_-]+/(?<stem>[A-Za-z0-9_-]+)_localization_$') { continue }
        $start = $index - 15
        if ($start -lt 0 -or $tokens[$start].text -cne 'if' -or $Context.layout.depths[$start] -ne 0) { continue }
        $end = $Context.layout.closes[$start]
        $openStart = $index + 5
        $afterOpenStart = $openStart + $readOnlyOpen.Count
        if (-not $end -or $afterOpenStart -gt $end -or
            -not (Test-LuaExactTokens $tokens $start ($openStart - 1) ($beforeOpen.Replace('SIDECAR_PATH', $pathToken))) -or
            -not (Test-LuaExactTokens $tokens $afterOpenStart $end $afterOpen)) { continue }

        $matchesReadOnlyOpen = $true
        for ($offset = 0; $offset -lt $readOnlyOpen.Count; $offset++) {
            if ($tokens[$openStart + $offset].text -cne $readOnlyOpen[$offset]) {
                $matchesReadOnlyOpen = $false
                break
            }
        }
        if ($matchesReadOnlyOpen) {
            $localeBindingProven = Test-LuaActiveLocaleBinding $Context $start
            $outsideCalls = @($Generator.unresolved | Where-Object { $_ -le $start -or $_ -ge $end })
            return [pscustomobject]@{
                path = $path + 'zh-tw.lua'
                localeBindingProven = $localeBindingProven
                conditionalCallIndices = if ($localeBindingProven -and $outsideCalls.Count -eq 0 -and
                    (Test-LuaNativeSidecarLoaderBinding $Context $path $start $end)) {
                    @($Generator.unresolved)
                } else { @() }
            }
        }
    }
}

function Read-LuaGeneratedSidecarValues {
    param([object[]] $Tokens)
    $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $groups = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $prefixes = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $prefixes.Add('common', '')
    $prefixes.Add('talents', 'def_')
    $prefixes.Add('notable', 'highlight_')
    if ($Tokens.Count -lt 3 -or $Tokens[0].text -cne 'return' -or $Tokens[1].text -cne '{') { return }
    $last = Get-MatchingTokenIndex $Tokens 1 '{' '}'
    if ($last -ne ($Tokens.Count - 1)) { return }
    $groupStart = 2
    while ($groupStart -lt $last) {
        Invoke-LuaScannerProgressHeartbeat
        $group = $Tokens[$groupStart].text
        if (-not $prefixes.ContainsKey($group) -or -not $groups.Add($group) -or
            $Tokens[$groupStart + 1].text -cne '=' -or $Tokens[$groupStart + 2].text -cne '{') { return }
        $groupEnd = Get-MatchingTokenIndex $Tokens ($groupStart + 2) '{' '}'
        $position = $groupStart + 3
        while ($position -lt $groupEnd) {
            Invoke-LuaScannerProgressHeartbeat
            $keyEnd = if ($Tokens[$position].text -ceq '[') { Get-MatchingTokenIndex $Tokens $position '[' ']' } else { $position }
            $key = if ($keyEnd -eq $position -or ($keyEnd -eq ($position + 2) -and $Tokens[$position + 1].type -ceq 'string')) {
                Get-LuaKey $Tokens $position $keyEnd
            }
            if (-not $key -or $Tokens[$keyEnd + 1].text -cne '=' -or $Tokens[$keyEnd + 2].type -cne 'string') { return }
            try { $value = ConvertFrom-LuaKeyString -Literal $Tokens[$keyEnd + 2].text -RequireUtf8 }
            catch {
                return [pscustomobject]@{ values = $null; blockedReason = 'generated_sidecar_literal_value_unproven' }
            }
            if (-not $values.TryAdd($prefixes[$group] + $key, $value)) { return }
            $position = $keyEnd + 3
            if ($position -lt $groupEnd) {
                if ($Tokens[$position].text -cnotin @(',', ';')) { return }
                $position++
            }
        }
        $groupStart = $groupEnd + 1
        if ($groupStart -lt $last) {
            if ($Tokens[$groupStart].text -cnotin @(',', ';')) { return }
            $groupStart++
        }
    }
    [pscustomobject]@{ values = $values; blockedReason = $null }
}

function Set-LuaGeneratedDuplicateReasons {
    param([Collections.Generic.List[object]] $Units)
    $identities = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($unit in $Units) {
        Invoke-LuaScannerProgressHeartbeat
        if ($unit.containerPath -cne '$') { continue }
        if (-not $identities.ContainsKey($unit.key)) { $identities[$unit.key] = [Collections.Generic.List[object]]::new() }
        $identities[$unit.key].Add($unit)
    }
    foreach ($group in $identities.Values) {
        if ($group.Count -le 1 -or @($group | Where-Object { $_.PSObject.Properties['generated'] }).Count -eq 0) { continue }
        foreach ($unit in $group) {
            if (-not $unit.blockedReason) { $unit.blockedReason = 'duplicate_generated_localization_key' }
        }
    }
}

function Get-LuaLocalizationDocument {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Bytes')][byte[]] $Bytes,
        [Parameter(ParameterSetName = 'Bytes')][string] $DisplayPath = '<memory>',
        [Parameter(Mandatory)][string] $SourceId,
        [switch] $ZhTwSidecar,
        [scriptblock] $HeartbeatAction
    )
    $previousHeartbeatAction = $script:luaScannerHeartbeatAction
    $previousHeartbeatProgress = $script:luaScannerHeartbeatProgress
    $script:luaScannerHeartbeatAction = $HeartbeatAction
    $script:luaScannerHeartbeatProgress = 0
    try {
        Invoke-LuaScannerHeartbeat
        $fullPath = if ($PSCmdlet.ParameterSetName -eq 'Path') { [IO.Path]::GetFullPath($Path) } else { $DisplayPath }
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'Lua localization source does not exist.' }
            $Bytes = Read-LuaScannerFileBytes -Path $fullPath
        }
        $bytes = $Bytes
        $bomLength = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        try { $text = $encoding.GetString($bytes, $bomLength, $bytes.Length - $bomLength) }
        catch { throw 'Lua localization source must be valid UTF-8.' }
        Invoke-LuaScannerHeartbeat
        $tokens = @(Get-LuaTokens -Text $text)
        if ($ZhTwSidecar) {
            $sidecar = Read-LuaGeneratedSidecarValues $tokens
            return [ordered]@{
                sourceId = $SourceId; path = $fullPath; size = $bytes.LongLength
                sha256 = Get-LuaScannerSha256 -Bytes $bytes
                values = if ($null -ne $sidecar) { $sidecar.values } else { $null }
                blockedReason = if ($null -eq $sidecar) { 'generated_sidecar_structure_unproven' } else { $sidecar.blockedReason }
            }
        }
        $units = [Collections.Generic.List[object]]::new()
        $context = [pscustomobject]@{
            tokens = $tokens; text = $text; units = $units; sourceId = $SourceId; bomLength = $bomLength
            layout = $null; references = $null; sidecarPath = $null; namedAccumulator = $false
            tableCache = [Collections.Generic.Dictionary[int, object]]::new()
            descendantsByRoot = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            gameLocalizedPassthroughPrefixes = [Collections.Generic.List[string]]::new()
        }
        Add-LuaAccumulatorUnits $context
        if (-not $context.namedAccumulator) {
            $position = 0
            while ($position -lt $tokens.Count) {
                Invoke-LuaScannerProgressHeartbeat
                if ($tokens[$position].text -ceq '{') {
                    $position = Read-LuaTable -Text $text -Tokens $tokens -OpenIndex $position -ContainerPath '$' -AssignedKey $null -SourceId $SourceId -Units $units -BomLength $bomLength
                }
                $position++
            }
        }
        Set-LuaGeneratedDuplicateReasons $units

        $occurrences = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        $unitIndex = 0
        $numbered = foreach ($unit in $units) {
            Invoke-LuaScannerProgressHeartbeat
            $unitIndex++
            $identityBase = ('{0} :: {1} :: {2}' -f $unit.sourceId, $unit.containerPath, $unit.key)
            if (-not $occurrences.ContainsKey($identityBase)) { $occurrences[$identityBase] = 0 }
            $occurrences[$identityBase]++
            $numberedUnit = [ordered]@{
                sourceId = $unit.sourceId
                containerPath = $unit.containerPath
                key = $unit.key
                occurrence = $occurrences[$identityBase]
                unitId = ('{0} :: {1}' -f $identityBase, $occurrences[$identityBase])
                blockedReason = $unit.blockedReason
                sourceExpression = $unit.sourceExpression
                zhTwExpression = $unit.zhTwExpression
                tableOpenByte = $unit.tableOpenByte
                tableCloseByte = $unit.tableCloseByte
            }
            if ($unit.PSObject.Properties['positionalLocale'] -and $unit.positionalLocale) {
                $numberedUnit.positionalLocale = $true
                if ($null -ne $unit.positionalZhCnValue) { $numberedUnit.positionalZhCnValue = $unit.positionalZhCnValue }
                if (-not $unit.blockedReason -and $null -ne $unit.positionalWrite) {
                    $numberedUnit.positionalWrite = $unit.positionalWrite
                }
                if ($null -ne $unit.zhTwExpression) {
                    $numberedUnit.positionalZhTwValue = $unit.positionalZhTwValue
                }
            }
            if ($unit.PSObject.Properties['conditionalZhTwSidecar'] -and $unit.conditionalZhTwSidecar) {
                $numberedUnit.conditionalZhTwSidecar = $true
            }
            if ($unit.PSObject.Properties['generatedBinding'] -and $null -ne $unit.generatedBinding) { $numberedUnit.generatedBinding = $unit.generatedBinding }
            $numberedUnit
        }
        $hasCrlf = $false
        $hasLf = $false
        $hasBareCr = $false
        for ($newlineIndex = 0; $newlineIndex -lt $text.Length; $newlineIndex++) {
            Invoke-LuaScannerProgressHeartbeat
            if ($text[$newlineIndex] -eq [string][char]13) {
                if (($newlineIndex + 1) -lt $text.Length -and $text[$newlineIndex + 1] -eq [string][char]10) {
                    $hasCrlf = $true
                    $newlineIndex++
                }
                else { $hasBareCr = $true }
            }
            elseif ($text[$newlineIndex] -eq [string][char]10) { $hasLf = $true }
        }
        $newline = if ($hasCrlf -and ($hasLf -or $hasBareCr)) { 'mixed' }
            elseif ($hasCrlf) { 'crlf' }
            elseif ($hasBareCr) { 'mixed' }
            else { 'lf' }
        Invoke-LuaScannerHeartbeat
        $document = [ordered]@{
            schemaVersion = 1
            sourceId = $SourceId
            path = $fullPath
            sha256 = Get-LuaScannerSha256 -Bytes $bytes
            size = $bytes.LongLength
            bom = $bomLength -eq 3
            newline = $newline
            ioDofileLoaderCallCount = Get-IoDofileLoaderCallCount -Tokens $tokens
            isIoDofileOnlyLoader = Test-IoDofileOnlyLoaderTokens -Tokens $tokens
            units = @($numbered)
        }
        if ($context.sidecarPath) {
            $document.zhTwSidecarPath = $context.sidecarPath.path
            $document.zhTwSidecarLocaleBindingProven = $context.sidecarPath.localeBindingProven
        }
        if ($context.gameLocalizedPassthroughPrefixes.Count -gt 0) {
            $document.gameLocalizedPassthroughPrefixes = @($context.gameLocalizedPassthroughPrefixes)
        }
        $document
    }
    finally {
        $script:luaScannerHeartbeatAction = $previousHeartbeatAction
        $script:luaScannerHeartbeatProgress = $previousHeartbeatProgress
    }
}

$script:luaFormatSpecifier = '%(?:%|[-+ #0]*[0-9]*(?:\.[0-9]+)?[cdiouxXeEfgGqs])'

function Test-LuaFormatFunctionToken {
    param([object[]] $Tokens, [int] $Index)
    if ($Index -lt 0 -or $Tokens[$Index].type -cne 'identifier' -or $Tokens[$Index].text -cne 'format') {
        return $false
    }
    if ($Index -gt 0 -and $Tokens[$Index - 1].text -ceq '.') {
        if ($Index -lt 2 -or $Tokens[$Index - 2].text -cne 'string') { return $false }
        $Index -= 2
    }
    $Index -eq 0 -or $Tokens[$Index - 1].text -cnotin @('.', ':', 'function')
}

function Get-LuaFormatSpans {
    param([object[]] $Tokens)
    $delimiters = [Collections.Generic.Stack[object]]::new()
    $openingByClosing = @{ ')' = '('; ']' = '['; '}' = '{' }
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        Invoke-LuaScannerProgressHeartbeat
        $token = $Tokens[$index]
        if ($token.type -ceq 'string') {
            if (Test-LuaFormatFunctionToken -Tokens $Tokens -Index ($index - 1)) {
                @{ start = $index; end = $index }
            }
        }
        elseif ($token.text -cin @('(', '[', '{')) {
            $delimiters.Push(@{ start = $index; firstComma = -1 })
        }
        elseif ($token.text -ceq ',' -and $delimiters.Count -gt 0) {
            $frame = $delimiters.Peek()
            if ($frame.firstComma -lt 0) { $frame.firstComma = $index }
        }
        elseif ($openingByClosing.ContainsKey($token.text) -and $delimiters.Count -gt 0) {
            $frame = $delimiters.Pop()
            $open = $frame.start
            if ($Tokens[$open].text -cne $openingByClosing[$token.text] -or $token.text -ceq ']') { continue }

            if (Test-LuaFormatFunctionToken -Tokens $Tokens -Index ($open - 1)) {
                if ($token.text -ceq '}') {
                    @{ start = $open; end = $index }
                }
                else {
                    # Only a comma at this call's nesting level ends the first argument.
                    $end = if ($frame.firstComma -ge 0) { $frame.firstComma - 1 } else { $index - 1 }
                    @{ start = $open + 1; end = $end }
                }
            }
            if ($token.text -cne ')' -or ($index + 3) -ge $Tokens.Count -or
                $Tokens[$index + 1].text -cne ':' -or $Tokens[$index + 2].text -cne 'format' -or
                ($Tokens[$index + 3].type -cne 'string' -and $Tokens[$index + 3].text -cnotin @('(', '{'))) { continue }

            # Match a parenthesized receiver, excluding the argument list of a preceding call.
            if ($open -gt 0) {
                $previous = $Tokens[$open - 1]
                if ($previous.type -ceq 'string' -or $previous.text -cin @(')', ']', '}') -or
                    ($previous.type -ceq 'identifier' -and $previous.text -cnotin @('and', 'or', 'not'))) { continue }
            }
            @{ start = $open + 1; end = $index - 1 }
        }
    }
}

function Get-LuaFormatSignature {
    param([object[]] $Tokens, [object[]] $FormatSpans)
    $literals = [Collections.Generic.SortedDictionary[int,string]]::new()
    for ($index = 0; $index -lt $Tokens.Count; $index++) {
        Invoke-LuaScannerProgressHeartbeat
        if ($Tokens[$index].type -ceq 'string') {
            $literals.Add($index, (ConvertFrom-LuaKeyString -Literal ([string]$Tokens[$index].text)))
        }
    }

    $grouped = [Collections.Generic.HashSet[int]]::new()
    $values = [Collections.Generic.List[string]]::new()
    foreach ($span in $FormatSpans) {
        $text = [Text.StringBuilder]::new()
        for ($index = $span.start; $index -le $span.end; $index++) {
            Invoke-LuaScannerProgressHeartbeat
            if ($literals.ContainsKey($index)) {
                $null = $text.Append($literals[$index])
                $null = $grouped.Add($index)
            }
        }
        $values.Add($text.ToString())
    }
    foreach ($literal in $literals.GetEnumerator()) {
        if (-not $grouped.Contains($literal.Key)) { $values.Add($literal.Value) }
    }

    $signature = [Text.StringBuilder]::new()
    foreach ($text in $values) {
        Invoke-LuaScannerProgressHeartbeat
        $formats = @([regex]::Matches($text, $script:luaFormatSpecifier) | ForEach-Object Value)
        $null = $signature.Append('|').Append(($formats -join ','))
    }
    $signature.ToString()
}

function Test-LuaNonStringTokenSequence {
    param([string] $Source, [string] $Translation)

    # Compare the full structure while allowing ordinary string literal text to change.
    $sourceTokens = @(Get-LuaTokens -Text $Source)
    $translationTokens = @(Get-LuaTokens -Text $Translation)
    if ($sourceTokens.Count -ne $translationTokens.Count) { return $false }
    $localizeEnd = -1
    $changedLiteral = $false
    for ($index = 0; $index -lt $sourceTokens.Count; $index++) {
        $sourceToken = $sourceTokens[$index]
        $translationToken = $translationTokens[$index]
        if ($sourceToken.type -cne $translationToken.type) { return $false }
        if ($sourceToken.type -cne 'string') {
            if ($sourceToken.text -cne $translationToken.text) { return $false }
            if ($index -gt $localizeEnd -and $sourceToken.type -ceq 'identifier' -and
                $sourceToken.text -ceq 'Localize' -and ($index + 1) -lt $sourceTokens.Count) {
                $nextToken = $sourceTokens[$index + 1]
                if ($nextToken.text -ceq '(') {
                    $localizeEnd = Get-MatchingTokenIndex -Tokens $sourceTokens -StartIndex ($index + 1) -Open '(' -Close ')'
                }
                elseif ($nextToken.type -ceq 'string') { $localizeEnd = $index + 1 }
            }
            continue
        }
        if ($sourceToken.text -ceq $translationToken.text) { continue }
        $changedLiteral = $true
        $sourceText = ConvertFrom-LuaKeyString -Literal ([string]$sourceToken.text)
        $translationText = ConvertFrom-LuaKeyString -Literal ([string]$translationToken.text)
        if (($index -le $localizeEnd -or $sourceText -cmatch '^loc_[A-Za-z0-9_]+$') -and
            $sourceText -cne $translationText) { return $false }
    }
    if (-not $changedLiteral) { return $true }
    $formatSpans = @(Get-LuaFormatSpans -Tokens $sourceTokens)
    (Get-LuaFormatSignature -Tokens $sourceTokens -FormatSpans $formatSpans) -ceq
        (Get-LuaFormatSignature -Tokens $translationTokens -FormatSpans $formatSpans)
}

Export-ModuleMember -Function Get-LuaLocalizationDocument, Test-LuaTableFieldAssignment, Test-LuaNonStringTokenSequence, Test-LuaLocalizationUnitInRootNamespace
