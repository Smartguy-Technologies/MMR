@{
    # Script module or binary module file associated with this manifest
    RootModule = 'SystemLoadGuard.psm1'

    # Version number of this module
    ModuleVersion = '1.0.0'

    # Supported PowerShell editions
    CompatiblePSEditions = @('Desktop', 'Core')

    # ID used to uniquely identify this module
    GUID = 'd7e1d5f3-4f8e-4d8a-9b61-9d1c7a6e4c3a'

    # Author of this module
    Author = 'James Terry'

    # Company or organization
    CompanyName = 'Smartguy Technologies'

    # Copyright
    Copyright = '(c) 2026 Smartguy Technologies. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'Provides a system load guard that delays task execution until CPU conditions are stable. Includes VMware-aware CPU contention detection.'

    # Minimum version of PowerShell required
    PowerShellVersion = '5.1'

    # Functions to export from this module
    FunctionsToExport = @(
        'Test-IsVMwareVM',
        'Get-SystemLoadSnapshot',
        'Wait-ForSystemReadyToRun'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule
    PrivateData = @{
        PSData = @{
            # Tags applied to this module for discovery
            Tags = @(
                'CPU',
                'Performance',
                'Scheduling',
                'VMware',
                'Automation'
            )

            # A URL to the license for this module
            LicenseUri = ''

            # A URL to the main website for this project
            ProjectUri = ''

            # A URL to an icon representing this module
            IconUri = ''

            # Release notes for this version
            ReleaseNotes = @'
Initial release.
- CPU-based execution gating
- VMware-aware processor queue detection
- Stable-time enforcement before task execution
'@
        }
    }
}
