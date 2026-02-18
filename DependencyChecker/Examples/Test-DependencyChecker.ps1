#Requires -Version 5.1
#Requires -Modules WPFManager
#Requires -Modules @{ModuleName='SystemLoadGuard'; ModuleVersion='1.0.0'}

Import-Module VCFConverter
Import-Module ContactManagement
Import-Module 'C:\Users\James\MMR\BootOrderGuard\BootOrderGuard.psd1'
Import-Module .\NonExistentModule

using module WPFManager

Write-Host 'This is a test script for DependencyChecker'
