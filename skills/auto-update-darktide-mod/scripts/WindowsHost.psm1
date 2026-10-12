# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DarktideHostPlatform {
    [Environment]::OSVersion.Platform
}

function Assert-DarktideWindowsHost {
    if ((Get-DarktideHostPlatform) -ne [PlatformID]::Win32NT) {
        throw 'DARKTIDE MOD automation requires a Windows host. Linux, macOS, and WSL are unsupported.'
    }
}

Export-ModuleMember -Function Assert-DarktideWindowsHost