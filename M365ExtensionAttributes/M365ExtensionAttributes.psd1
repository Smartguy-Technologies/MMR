@{
    RootModule        = 'M365ExtensionAttributes.psm1'
    ModuleVersion     = '1.2.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID              = 'E1FAD010-FF69-42FB-90AF-5B4C04F832B0'
    Author            = 'James Terry'
    CompanyName       = 'Smartguy Technologies'
    Copyright         = '(c) 2026 Smartguy Technologies. All rights reserved.'
    Description       = 'Manage M365 extensionAttribute1-15 for users via Microsoft Graph, with duplicate protection and left-shift delete behavior.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-M365ExtensionAttributes',
        'Add-M365ExtensionAttribute',
        'Set-M365ExtensionAttribute',
        'Remove-M365ExtensionAttribute',
        'Find-M365UsersWithExtensionAttribute',
        'Optimize-M365ExtensionAttributes',
        'Add-M365ExtensionAttributeBulk',
        'Remove-M365ExtensionAttributeBulk'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('M365', 'Graph', 'AzureAD', 'ExtensionAttributes', 'Users')
            LicenseUri   = ''
            ProjectUri   = ''
            IconUri      = ''
            ReleaseNotes = @'
1.2.0
- Add Optimize-M365ExtensionAttributes: deduplicates, natural-sorts, and compacts extension attributes for a single user or all users in the tenant.

1.1.0
- Add Get-M365ExtensionAttributes to retrieve all 15 attributes for a single user.
- Add wildcard support (* and ?) to Find-M365UsersWithExtensionAttribute; exact matches continue to use server-side OData filtering, wildcard matches filter client-side.

1.0.0
- Add, update, delete, find, and bulk-manage extensionAttribute1-15.
- Duplicate-value protection and explicit overwrite controls.
- Delete operation shifts attributes left to avoid gaps.
'@
        }
    }
}
