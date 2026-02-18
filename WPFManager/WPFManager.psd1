@{
    RootModule        = 'WPFManager.psm1'
    ModuleVersion     = '1.0.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID              = 'c2f4e819-3b7d-4a5c-9e01-d6f3a8b27c4e'
    Author            = 'James Terry'
    CompanyName       = 'Smartguy Technologies'
    Copyright         = '(c) 2026 Smartguy Technologies. All rights reserved.'
    Description       = @'
WPF GUI framework for PowerShell tooling. Provides a complete infrastructure
for building multi-threaded WPF applications without external dependencies:

  - Show-WPFWindow    : Hosts a WPF window on a dedicated STA thread and
                        returns a live session object immediately.
  - Invoke-UIAction   : Safely dispatch any scriptblock onto the WPF UI
                        thread from any calling context.
  - Start-WPFJob      : Run background work in an MTA runspace with the
                        shared SyncHash already wired in.
  - Stop/Wait/Result  : Manage background jobs cleanly.
  - Register-WPFEvent : Attach event handlers from any thread.
  - Start-WPFTimer    : Fire repeating UI-thread callbacks via DispatcherTimer.
  - Get-WPFTemplate   : Return ready-to-customise XAML window templates.

Every session exposes a synchronized SyncHash that all threads share.
The SyncHash also carries Dispatch{} and RunJob{} helper closures so that
event handlers and OnInit scripts can start jobs and update the UI without
needing the session object.
'@
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Show-WPFWindow',
        'Invoke-UIAction',
        'Start-WPFJob',
        'Stop-WPFJob',
        'Wait-WPFJob',
        'Get-WPFJobResult',
        'Wait-WPFWindow',
        'Close-WPFWindow',
        'Get-WPFControl',
        'Register-WPFEvent',
        'Start-WPFTimer',
        'Stop-WPFTimer',
        'Get-WPFTemplate'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('WPF', 'GUI', 'XAML', 'Runspace', 'SyncHash', 'Multithreading', 'UI')
            LicenseUri   = ''
            ProjectUri   = ''
            IconUri      = ''
            ReleaseNotes = @'
Initial release.
- Show-WPFWindow: STA-thread window hosting with automatic control registration.
- Invoke-UIAction: Dispatcher.Invoke / BeginInvoke abstraction.
- Start-WPFJob: MTA background runspace with automatic SyncHash injection.
- DispatcherTimer support via Start-WPFTimer / Stop-WPFTimer.
- Four built-in XAML window templates (Basic, Console, Form, Split).
- SyncHash.Dispatch and SyncHash.RunJob helpers for use inside event handlers.
'@
        }
    }
}
