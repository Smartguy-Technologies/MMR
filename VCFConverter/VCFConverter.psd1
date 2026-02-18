@{
    RootModule        = 'VCFConverter.psm1'
    ModuleVersion     = '1.0.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID              = 'b9e4d231-7a3f-4c88-a56d-e8210fb94c5a'
    Author            = 'James Terry'
    CompanyName       = 'Smartguy Technologies'
    Copyright         = '(c) 2026 Smartguy Technologies. All rights reserved.'
    Description       = 'Converts VCF (vCard) files to Outlook-importable CSV format. Custom and overflow fields are appended to the Notes column so nothing is lost. No external dependencies required.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Convert-VCFToCSV')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('VCF', 'vCard', 'CSV', 'Outlook', 'Contacts', 'Import', 'Convert')
            LicenseUri   = ''
            ProjectUri   = ''
            IconUri      = ''
            ReleaseNotes = @'
Initial release.
- Convert-VCFToCSV: Converts one or more vCard contacts to an Outlook-importable
  CSV with exact column names. Standard fields map directly; custom X- fields and
  overflow values (e.g. a 4th email, a 2nd mobile) are appended to Notes so the
  original Notes content is preserved.
'@
        }
    }
}
