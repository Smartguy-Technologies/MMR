@{
    RootModule        = 'ContactManagement.psm1'
    ModuleVersion     = '1.0.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID              = 'a3c7f812-6d4e-4b19-8e52-d9f2a1c03b7e'
    Author            = 'James Terry'
    CompanyName       = 'Smartguy Technologies'
    Copyright         = '(c) 2026 Smartguy Technologies. All rights reserved.'
    Description       = 'Provides VCF (vCard) file reading and writing, plus Outlook contact import and export via COM automation. All parsing is done natively with no external dependencies.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Read-VCF',
        'Write-VCF',
        'Read-OutlookContact',
        'Write-OutlookContact'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('VCF', 'vCard', 'Contacts', 'Outlook', 'CSV', 'Import', 'Export')
            LicenseUri   = ''
            ProjectUri   = ''
            IconUri      = ''
            ReleaseNotes = @'
Initial release.
- Read-VCF: Parse one or more vCards from a .vcf file into structured objects.
- Write-VCF: Serialize contact objects back to a standards-compliant .vcf file.
- Read-OutlookContact: Pull contacts from the Outlook default Contacts folder via COM.
- Write-OutlookContact: Create or update contacts in Outlook via COM.
'@
        }
    }
}
