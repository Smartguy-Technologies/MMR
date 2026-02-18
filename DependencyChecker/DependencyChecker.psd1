@{
    RootModule           = 'DependencyChecker.psm1'
    ModuleVersion        = '1.0.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID                 = 'cf2785b2-bdcb-4f38-83b7-3f1112e30b9f'
    Author               = 'James Terry'
    CompanyName          = 'Smartguy Technologies'
    Copyright            = '(c) 2026 Smartguy Technologies. All rights reserved.'
    Description          = @'
Static analysis module for PowerShell scripts. Discovers and reports module
dependencies without executing the target scripts:

  - Get-ScriptDependency  : Analyze a .ps1 file or folder of scripts and return
                            structured dependency result objects.
  - Show-DependencyReport : Print a color-coded dependency tree and summary to
                            the console.

Detects #Requires -Modules, Import-Module, and using module declarations.
Follows transitive dependencies through .psd1 RequiredModules chains (depth limit 10).
Resolves bare module names against PSModulePath and the script directory tree.
No external dependencies required.
'@
    PowerShellVersion    = '5.1'

    FunctionsToExport    = @(
        'Get-ScriptDependency',
        'Show-DependencyReport'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Dependency', 'Analysis', 'Modules', 'Import', 'Requires', 'StaticAnalysis', 'Audit')
            LicenseUri   = ''
            ProjectUri   = ''
            IconUri      = ''
            ReleaseNotes = @'
Initial release.
- Get-ScriptDependency : Analyze one .ps1 file or a folder of scripts for module dependencies.
- Show-DependencyReport: Print a color-coded dependency tree and summary to the console.
- Transitive resolution through RequiredModules in .psd1 manifests (depth limit 10).
- Detects: #Requires -Modules, Import-Module (bare name, absolute path, relative path),
  using module (bare name and path).
- Cycle prevention via visited-path tracking.
'@
        }
    }
}
