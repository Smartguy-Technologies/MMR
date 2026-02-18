@{
    RootModule = 'BootOrderGuard.psm1'
    ModuleVersion = '1.0.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID = 'f8b592c2-b617-4ef1-873b-b3a9e185e78b'
    Author = 'James Terry'
    CompanyName = 'Smartguy Technologies'
    Copyright = '(c) 2026 Smartguy Technologies. All rights reserved.'
    Description = 'Provides firmware boot-order inspection and a rebuild tollgate that enforces network-first boot.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-BootOrderInfo',
        'Test-NetworkBootFirst',
        'Assert-NetworkBootFirstForRebuild'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @(
                'BootOrder',
                'Firmware',
                'PXE',
                'NetworkBoot',
                'Rebuild'
            )
            LicenseUri = ''
            ProjectUri = ''
            IconUri = ''
            ReleaseNotes = @'
Initial release.
- Firmware boot order retrieval via bcdedit
- Network-first validation helper
- Rebuild tollgate assertion function
'@
        }
    }
}
