# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

@{
    RootModule = 'platform-runtime.psm1'
    ModuleVersion = '1.0.0'
    GUID = '896eea26-3fc0-4de1-bb21-6c2fb6a6c3ef'
    Author = 'SyuanTsai-AI-Instructions contributors'
    Copyright = 'Copyright 2026 SyuanTsai. Licensed under Apache-2.0.'
    Description = 'Fail-closed cross-platform capability and runtime adapter API.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Assert-PlatformRuntimeInventory',
        'Get-PlatformCapabilities',
        'Open-PlatformDirectory',
        'Open-PlatformFile',
        'Assert-PlatformFileIdentity',
        'Enter-PlatformLock',
        'Publish-PlatformFile',
        'Remove-PlatformOwnedFile',
        'Get-PlatformDirectoryState',
        'Move-PlatformOwnedDirectory',
        'Remove-PlatformOwnedDirectoryTree',
        'Get-PlatformPermissions',
        'Set-PlatformPermissions',
        'Start-PlatformOwnedProcess',
        'Stop-PlatformOwnedProcess',
        'Resolve-PlatformPowerShell',
        'Resolve-PlatformPhysicalPath',
        'Initialize-PlatformAuthorityPester',
        'Assert-PlatformAuthorityPester',
        'New-PlatformPrivateRoot',
        'Invoke-PlatformPreparationCommand',
        'Initialize-PlatformPester',
        'Set-PlatformProcessEnvironment'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    FileList = @(
        'platform-runtime.psd1',
        'platform-runtime.psm1',
        'installer-safe-mutation.psm1',
        'WindowsDacl.psm1',
        'platform/PlatformNative.cs',
        'platform/UnixNative.cs',
        'platform/WindowsNative.cs',
        'platform/WindowsInstallerMutation.cs',
        'platform/OwnedProcess.cs',
        'platform/UnixProcess.cs',
        'platform/WindowsProcess.cs',
        'platform/Unix.psm1',
        'platform/RuntimePreparation.psm1',
        'platform/Windows.psm1',
        'platform/Linux.psm1',
        'platform/MacOS.psm1',
        'Resolve-StandardValidationTool.ps1'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('platform','runtime','capability')
            LicenseUri = 'https://www.apache.org/licenses/LICENSE-2.0'
        }
        PlatformRuntime = @{
            ApiVersion = '1.0'
            HashMode = 'sha256-utf8-lf'
            Inventory = @(
                @{ Path = 'platform/UnixNative.cs'; Sha256 = '171da4acded889da89ab4e7af2729e9bbf4f3639cf1e63fe08a4c046f7545c74' },
                @{ Path = 'platform/WindowsNative.cs'; Sha256 = '6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433' },
                @{ Path = 'platform/WindowsInstallerMutation.cs'; Sha256 = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218' },
                @{ Path = 'platform/Unix.psm1'; Sha256 = 'ec3b3bb0b39e1ce84d4c8f60a78c44fb40cb9d58c13ed88a6b9d9db978fcc147' },
                @{ Path = 'platform/RuntimePreparation.psm1'; Sha256 = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077' },
                @{ Path = 'platform-runtime.psm1'; Sha256 = 'ad051b2794ce4dc10108404201735d02f7b032ed0e633c5f22f73c884fb10370' },
                @{ Path = 'installer-safe-mutation.psm1'; Sha256 = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293' },
                @{ Path = 'WindowsDacl.psm1'; Sha256 = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6' },
                @{ Path = 'platform/PlatformNative.cs'; Sha256 = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514' },
                @{ Path = 'platform/Windows.psm1'; Sha256 = '9b7442178083a9b165ed3bf53367d5c3ce1b1f09d56f0f6efe964b524e17be0b' },
                @{ Path = 'platform/Linux.psm1'; Sha256 = '52c261d577ee7b3946771d1112030996896fdd119e06ac3849e430a3d56fb38c' },
                @{ Path = 'platform/MacOS.psm1'; Sha256 = '8f25edfbee5ab36b5e1c42eb55c6dbab44db0bc29896c180612b1248920c7c47' },
                @{ Path = 'Resolve-StandardValidationTool.ps1'; Sha256 = 'c0d68b227fc04e19d710a89c4559fe45e0cc979eead846006261dc2dc5bfa14f' },
                @{ Path = 'platform/OwnedProcess.cs'; Sha256 = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58' },
                @{ Path = 'platform/UnixProcess.cs'; Sha256 = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1' },
                @{ Path = 'platform/WindowsProcess.cs'; Sha256 = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6' }
            )
        }
    }
}
