#Requires -Version 5.1

#region ======== Module Initialisation ========

$script:WPFAssembliesLoaded = $false

function Initialize-WPFAssemblies {
    if (-not $script:WPFAssembliesLoaded) {
        Add-Type -AssemblyName PresentationFramework,
                               PresentationCore,
                               WindowsBase,
                               System.Xaml
        $script:WPFAssembliesLoaded = $true
    }
}

#endregion


#region ======== Private Helpers ========

<#
.SYNOPSIS
Recursively walks the WPF logical tree and registers every named FrameworkElement
into the provided dictionary. Safe to call before ShowDialog().
#>
function Register-NamedControls {
    param(
        [System.Windows.DependencyObject]$Element,
        [System.Collections.Generic.Dictionary[string, object]]$Registry
    )
    if (-not $Element) { return }

    if ($Element -is [System.Windows.FrameworkElement] -and $Element.Name) {
        $Registry[$Element.Name] = $Element
    }

    try {
        $children = [System.Windows.LogicalTreeHelper]::GetChildren($Element)
        foreach ($child in $children) {
            if ($child -is [System.Windows.DependencyObject]) {
                Register-NamedControls -Element $child -Registry $Registry
            }
        }
    }
    catch { }  # Some custom controls throw on GetChildren before layout
}

<#
.SYNOPSIS
Strips XAML attributes that cause XamlReader.Load to fail at runtime because
they require a compiled code-behind assembly.

.DESCRIPTION
x:Class   - Tells the XAML compiler to generate a code-behind partial class.
             At runtime, XamlReader.Load throws XamlParseException if present.
x:ClassModifier - Accompanies x:Class; harmless alone but stripped for safety.

Uses XML DOM manipulation for correctness — regex alternatives can fail if
attribute values contain unusual characters.
#>
function Clear-XamlCodeBehind {
    param([string]$Xaml)

    try {
        # Parse to DOM so attribute removal is reliable
        $xmlDoc = [xml]$Xaml
        $root   = $xmlDoc.DocumentElement

        # Resolve the x: namespace prefix used in this document
        $xNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
        foreach ($attr in @('x:Class', 'x:ClassModifier')) {
            $local = $attr.Split(':')[1]
            if ($root.HasAttributeNS($xNs, $local)) {
                $root.RemoveAttributeNS($xNs, $local) | Out-Null
            }
            # Also try the un-prefixed form
            if ($root.HasAttribute($attr)) {
                $root.RemoveAttribute($attr) | Out-Null
            }
        }
        return $xmlDoc.OuterXml
    }
    catch {
        # Fall back to regex if XML parse fails (e.g. XAML with BOM or invalid encoding)
        $Xaml = $Xaml -replace '\s+x:Class(?:Modifier)?="[^"]*"', ''
        return $Xaml
    }
}

<#
.SYNOPSIS
The PowerShell script that runs on the STA thread inside Show-WPFWindow.
Defined as a module-level variable so it can be kept out of the function body.
All variables it needs ($xamlContent, $onInitScript, $syncHash, $session,
$extraVars) are injected via SessionStateProxy before BeginInvoke is called.
#>
$script:STAThreadScript = {
    # Load WPF assemblies on the STA thread
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    # ---- Local helpers (defined here so they exist in STA scope) ----

    function Register-NamedControls-STA {
        param($Element, $Registry)
        if (-not $Element) { return }
        if ($Element -is [System.Windows.FrameworkElement] -and $Element.Name) {
            $Registry[$Element.Name] = $Element
        }
        try {
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Element)) {
                if ($child -is [System.Windows.DependencyObject]) {
                    Register-NamedControls-STA -Element $child -Registry $Registry
                }
            }
        } catch { }
    }

    # ---- Main window startup ----
    try {
        # Parse XAML on the STA thread (XamlReader.Load requires STA)
        $xmlDoc = [xml]$xamlContent
        $xmlReader = [System.Xml.XmlNodeReader]::new($xmlDoc)
        $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)

        $syncHash.Window = $window

        # Register all named controls
        Register-NamedControls-STA -Element $window -Registry $syncHash.Controls

        # ---- Attach helper closures to syncHash ----
        # These are defined here (STA scope) so $syncHash references this runspace's variable.

        # Dispatch: invoke a scriptblock on the WPF UI thread.
        # Usage (from any thread): & $syncHash.Dispatch { $syncHash.Controls['lbl'].Content = 'hi' }
        $syncHash.Dispatch = {
            param(
                [scriptblock]$Block,
                [switch]$Async,
                [System.Windows.Threading.DispatcherPriority]$Priority = 'Normal'
            )
            if ($Async) {
                [void]$syncHash.Window.Dispatcher.BeginInvoke($Priority, [action]$Block)
            }
            else {
                $syncHash.Window.Dispatcher.Invoke($Priority, [action]$Block)
            }
        }.GetNewClosure()

        # RunJob: start a background MTA runspace job with $syncHash already injected.
        # Usage (from OnInit or event handlers): $job = & $syncHash.RunJob { ... }
        $syncHash.RunJob = {
            param(
                [scriptblock]$Script,
                [hashtable]$Variables = @{},
                [string]$Name = 'WPFJob'
            )
            $rs = [runspacefactory]::CreateRunspace()
            $rs.ApartmentState = 'MTA'
            $rs.ThreadOptions  = 'ReuseThread'
            $rs.Open()
            $rs.SessionStateProxy.SetVariable('syncHash', $syncHash)
            foreach ($k in $Variables.Keys) {
                $rs.SessionStateProxy.SetVariable($k, $Variables[$k])
            }
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript($Script)
            $handle = $ps.BeginInvoke()
            [PSCustomObject]@{
                Name       = $Name
                PowerShell = $ps
                Runspace   = $rs
                Handle     = $handle
                StartTime  = [datetime]::Now
            }
        }.GetNewClosure()

        # Inject any extra variables the caller passed via -Variables
        if ($extraVars) {
            foreach ($k in $extraVars.Keys) {
                Set-Variable -Name $k -Value $extraVars[$k] -Scope Local
            }
        }

        # Run the caller's OnInit scriptblock (runs on STA thread, has full access to $syncHash)
        if ($onInitScript) {
            try { & $onInitScript }
            catch { $syncHash.LastError = "OnInit error: $_" }
        }

        # Signal that the window is ready to use
        $syncHash.IsReady = $true
        $syncHash.IsAlive = $true

        # This blocks the STA thread until the window is closed
        [void]$window.ShowDialog()
    }
    catch {
        $syncHash.LastError = $_
        $syncHash.IsReady   = $true   # Unblock the caller even on failure
    }
    finally {
        $syncHash.IsAlive = $false
    }
}

#endregion


#region ======== Show-WPFWindow ========
<#
.SYNOPSIS
Hosts a WPF window on a dedicated STA thread and returns a session object.

.DESCRIPTION
Show-WPFWindow is the entry point for all WPF tool windows. It:

  1. Creates a synchronized SyncHash that every thread in the session shares.
  2. Starts a dedicated STA runspace whose entire job is to run the WPF
     message pump (ShowDialog). The window lives on that thread.
  3. Auto-registers every named FrameworkElement in the XAML into
     SyncHash.Controls so controls are accessible by name from any thread.
  4. Attaches two helper closures to the SyncHash:
       $syncHash.Dispatch { scriptblock } [-Async] [-Priority <value>]
       $syncHash.RunJob   { scriptblock } [-Variables @{}] [-Name 'label']
  5. Waits until the window is fully initialised, then returns the $session.

The calling thread is NOT blocked. Call Wait-WPFWindow to block until the
window closes. Call Close-WPFWindow to close it programmatically.

.PARAMETER Xaml
A XAML string (begins with '<') or a full path to a .xaml file.
The x:Class attribute is stripped automatically.

.PARAMETER Title
Override the Title attribute in the XAML.

.PARAMETER OnInit
A scriptblock that runs on the STA (UI) thread after controls are registered
but before ShowDialog. Use this to wire up event handlers.

Inside -OnInit the following are available:
  $syncHash          - the shared SyncHash
  $syncHash.Controls - dictionary of named controls
  $syncHash.Dispatch - closure for thread-safe UI dispatch
  $syncHash.RunJob   - closure to start MTA background jobs
  $session           - the session object (UIThread may still be $null;
                       use $syncHash.RunJob instead of Start-WPFJob here)

.PARAMETER Variables
Hashtable of extra key/value pairs to inject into the STA runspace as variables.
Useful for passing configuration data to -OnInit.

.PARAMETER InitTimeoutSeconds
Maximum seconds to wait for the window to signal IsReady. Default: 20.

.OUTPUTS
PSCustomObject with:
  .SyncHash   - The shared synchronized hashtable
  .UIThread   - [Runspace, PowerShell, Handle] of the STA thread
  .Jobs       - ConcurrentBag of jobs started via Start-WPFJob

.EXAMPLE
$xaml = Get-WPFTemplate -Name Basic
$session = Show-WPFWindow -Xaml $xaml -Title 'My Tool' -OnInit {
    $syncHash.Controls['btnRun'].Add_Click({
        & $syncHash.RunJob {
            Start-Sleep -Seconds 2
            $syncHash.Window.Dispatcher.Invoke([action]{
                $syncHash.Controls['lblStatus'].Content = 'Done'
            }, 'Normal')
        }
    })
}
Wait-WPFWindow -Session $session

.EXAMPLE
# Load XAML from a file
$session = Show-WPFWindow -Xaml 'C:\Tools\MyWindow.xaml'
#>
function Show-WPFWindow {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Xaml,

        [string]$Title,

        [scriptblock]$OnInit,

        [hashtable]$Variables = @{},

        [int]$InitTimeoutSeconds = 20
    )

    Initialize-WPFAssemblies

    # Resolve XAML content
    $xamlContent = if ($Xaml.TrimStart() -like '<*') {
        $Xaml
    }
    elseif (Test-Path -LiteralPath $Xaml -PathType Leaf) {
        [System.IO.File]::ReadAllText($Xaml, [System.Text.Encoding]::UTF8)
    }
    else {
        throw "The -Xaml parameter must be a XAML string (starting with '<') or a path to an existing .xaml file."
    }

    $xamlContent = Clear-XamlCodeBehind -Xaml $xamlContent

    # Override title in XAML if requested
    if ($Title) {
        $xamlContent = [System.Text.RegularExpressions.Regex]::Replace(
            $xamlContent,
            '(?<=<Window[^>]{0,2000}\sTitle=")[^"]*(?=")',
            [System.Text.RegularExpressions.Regex]::Escape($Title)
        )
    }

    # Build the shared synchronized state
    $syncHash = [hashtable]::Synchronized(@{
        Window    = $null
        Controls  = [System.Collections.Generic.Dictionary[string, object]]::new()
        Data      = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        IsReady   = $false
        IsAlive   = $false
        LastError = $null
        Dispatch  = $null   # Populated by STA thread after window loads
        RunJob    = $null   # Populated by STA thread after window loads
    })

    # Pre-build the session object so $session can be passed into the STA runspace.
    # UIThread is filled in after BeginInvoke (before IsReady is set, so no race).
    $session = [PSCustomObject]@{
        SyncHash = $syncHash
        UIThread = $null
        Jobs     = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    }

    # Create the dedicated STA runspace
    $uiRunspace = [runspacefactory]::CreateRunspace()
    $uiRunspace.ApartmentState = 'STA'
    $uiRunspace.ThreadOptions  = 'ReuseThread'
    $uiRunspace.Open()

    $uiRunspace.SessionStateProxy.SetVariable('syncHash',     $syncHash)
    $uiRunspace.SessionStateProxy.SetVariable('session',      $session)
    $uiRunspace.SessionStateProxy.SetVariable('xamlContent',  $xamlContent)
    $uiRunspace.SessionStateProxy.SetVariable('onInitScript', $OnInit)
    $uiRunspace.SessionStateProxy.SetVariable('extraVars',    $Variables)

    $uiPS = [powershell]::Create()
    $uiPS.Runspace = $uiRunspace
    [void]$uiPS.AddScript($script:STAThreadScript)
    $uiHandle = $uiPS.BeginInvoke()

    # Now safe to populate UIThread (OnInit runs after XAML loads, not immediately)
    $session.UIThread = [PSCustomObject]@{
        Runspace   = $uiRunspace
        PowerShell = $uiPS
        Handle     = $uiHandle
    }

    # Wait for the STA thread to finish loading and signal IsReady
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $syncHash.IsReady -and $sw.ElapsedMilliseconds -lt ($InitTimeoutSeconds * 1000)) {
        Start-Sleep -Milliseconds 50
    }

    if ($syncHash.LastError) {
        throw "WPF window failed to initialise: $($syncHash.LastError)"
    }
    if (-not $syncHash.IsReady) {
        throw "WPF window did not become ready within $InitTimeoutSeconds second(s). Check the XAML for errors."
    }

    return $session
}
#endregion


#region ======== Invoke-UIAction ========
<#
.SYNOPSIS
Executes a scriptblock on the WPF UI (STA) thread from any calling context.

.DESCRIPTION
All WPF controls must be read or modified on the STA thread that owns them.
Invoke-UIAction wraps Dispatcher.Invoke (synchronous) and Dispatcher.BeginInvoke
(fire-and-forget) so you never need to reference the Dispatcher directly.

THREAD SAFETY NOTE — [action] delegates and runspace affinity:
When PowerShell converts a scriptblock to [action] it binds the delegate to the
runspace that is active at cast time. Invoke-UIAction is designed to be called
from the MAIN (calling) thread only, not from inside background Start-WPFJob
scriptblocks. Calling it from a background runspace would bind the delegate to
that runspace, causing a reentrancy error if the runspace is still executing.

FROM BACKGROUND JOBS — use the SyncHash helpers instead:
  & $syncHash.Dispatch { $syncHash.Controls['lbl'].Content = 'Done' }
  $syncHash.Window.Dispatcher.BeginInvoke('Normal', [action]{ ... })

These closures are created inside the STA runspace, so no cross-runspace
delegate is involved.

FROM THE MAIN THREAD — Invoke-UIAction is safe. The main thread blocks inside
Dispatcher.Invoke, leaving the main runspace available for the STA thread to
execute the delegate. Variables from the calling scope are accessible via closure.
To access controls use: $Session.SyncHash.Controls['controlName']

.PARAMETER Session
The session object returned by Show-WPFWindow.

.PARAMETER Action
The scriptblock to run on the UI thread.

.PARAMETER Priority
WPF DispatcherPriority. Defaults to Normal.
Common values: Normal, Background, Render, ApplicationIdle.

.PARAMETER Async
When specified, uses BeginInvoke (returns immediately without waiting for the
action to complete). Useful for fire-and-forget UI updates.

.EXAMPLE
Invoke-UIAction -Session $session -Action {
    $session.SyncHash.Controls['lblStatus'].Content = 'Processing...'
    $session.SyncHash.Controls['progressBar'].Value = 50
}

.EXAMPLE
# Fire-and-forget
Invoke-UIAction -Session $session -Async -Action {
    $session.SyncHash.Controls['lblTitle'].Text = 'Updated'
}
#>
function Invoke-UIAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [System.Windows.Threading.DispatcherPriority]$Priority = 'Normal',

        [switch]$Async
    )

    $dispatcher = $Session.SyncHash.Window.Dispatcher
    if ($Async) {
        [void]$dispatcher.BeginInvoke($Priority, [action]$Action)
    }
    else {
        $dispatcher.Invoke($Priority, [action]$Action)
    }
}
#endregion


#region ======== Start-WPFJob ========
<#
.SYNOPSIS
Runs a scriptblock in a background MTA runspace with the SyncHash already wired in.

.DESCRIPTION
Start-WPFJob creates a new MTA runspace, injects $syncHash as a runspace-level
variable, optionally injects extra variables, and starts the scriptblock
asynchronously. The job object can be passed to Wait-WPFJob, Stop-WPFJob, or
Get-WPFJobResult.

Inside the scriptblock, update the UI using the Dispatcher directly:
    $syncHash.Window.Dispatcher.Invoke([action]{
        $syncHash.Controls['label'].Content = 'Done'
    }, 'Normal')

Or using the convenience closure:
    & $syncHash.Dispatch { $syncHash.Controls['label'].Content = 'Done' }

To signal cancellation, set $syncHash.Data['CancelRequested'] = $true and
check it periodically inside the scriptblock.

.PARAMETER Session
The session object returned by Show-WPFWindow.

.PARAMETER ScriptBlock
The scriptblock to execute on the background thread.

.PARAMETER Variables
Extra variables to inject into the background runspace.

.PARAMETER Name
An optional label for the job (stored in the returned object).

.OUTPUTS
PSCustomObject with: Name, PowerShell, Runspace, Handle, StartTime.

.EXAMPLE
$job = Start-WPFJob -Session $session -Name 'DataLoad' -ScriptBlock {
    $syncHash.Window.Dispatcher.Invoke([action]{
        $syncHash.Controls['progressBar'].Value = 0
        $syncHash.Controls['btnStart'].IsEnabled = $false
    }, 'Normal')

    for ($i = 1; $i -le 100; $i++) {
        if ($syncHash.Data['CancelRequested']) { break }
        Start-Sleep -Milliseconds 50
        $pct = $i
        $syncHash.Window.Dispatcher.BeginInvoke('Background', [action]{
            $syncHash.Controls['progressBar'].Value = $pct
        })
    }

    $syncHash.Window.Dispatcher.Invoke([action]{
        $syncHash.Controls['progressBar'].Value = 100
        $syncHash.Controls['btnStart'].IsEnabled = $true
        $syncHash.Controls['lblStatus'].Content  = 'Done'
    }, 'Normal')
}
#>
function Start-WPFJob {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [hashtable]$Variables = @{},

        [string]$Name = 'WPFJob'
    )

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('syncHash', $Session.SyncHash)
    foreach ($key in $Variables.Keys) {
        $rs.SessionStateProxy.SetVariable($key, $Variables[$key])
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($ScriptBlock)

    $handle = $ps.BeginInvoke()

    $job = [PSCustomObject]@{
        Name       = $Name
        PowerShell = $ps
        Runspace   = $rs
        Handle     = $handle
        StartTime  = [datetime]::Now
    }

    $Session.Jobs.Add($job)
    return $job
}
#endregion


#region ======== Stop-WPFJob ========
<#
.SYNOPSIS
Stops a WPF background job and disposes its resources.

.DESCRIPTION
By default signals cancellation via SyncHash and waits up to TimeoutMs for
the scriptblock to exit naturally. Use -Force to immediately stop the runspace.

Cooperative cancellation pattern (recommended):
  Inside the job scriptblock, check:  if ($syncHash.Data['CancelRequested']) { return }
  Set from outside:                   $session.SyncHash.Data['CancelRequested'] = $true
  Then call:                          Stop-WPFJob -Job $job

.PARAMETER Job
The job object returned by Start-WPFJob.

.PARAMETER TimeoutMs
Milliseconds to wait for cooperative shutdown before giving up. Default: 5000.

.PARAMETER Force
Immediately call PowerShell.Stop() without waiting. May leave resources dirty.
#>
function Stop-WPFJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Job,

        [int]$TimeoutMs = 5000,

        [switch]$Force
    )

    process {
        if ($Force) {
            try { $Job.PowerShell.Stop() } catch { }
        }
        else {
            $completed = $Job.Handle.AsyncWaitHandle.WaitOne($TimeoutMs)
            if (-not $completed) {
                Write-Warning "Job '$($Job.Name)' did not stop within ${TimeoutMs}ms. Use -Force to terminate."
            }
        }
        try { $Job.PowerShell.Dispose() } catch { }
        try { $Job.Runspace.Dispose()   } catch { }
    }
}
#endregion


#region ======== Wait-WPFJob ========
<#
.SYNOPSIS
Blocks the calling thread until one or more background jobs complete.

.PARAMETER Job
One or more job objects (pipeline supported).

.PARAMETER TimeoutMs
Maximum milliseconds to wait per job. -1 waits indefinitely. Default: -1.

.OUTPUTS
Boolean: $true if the job completed, $false if it timed out.

.EXAMPLE
$job | Wait-WPFJob
$job | Wait-WPFJob -TimeoutMs 10000
#>
function Wait-WPFJob {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Job,

        [int]$TimeoutMs = -1
    )

    process {
        foreach ($j in $Job) {
            if ($TimeoutMs -eq -1) {
                [void]$j.Handle.AsyncWaitHandle.WaitOne()
                $true
            }
            else {
                $j.Handle.AsyncWaitHandle.WaitOne($TimeoutMs)
            }
        }
    }
}
#endregion


#region ======== Get-WPFJobResult ========
<#
.SYNOPSIS
Retrieves the output and error streams from a completed background job.

.DESCRIPTION
Calls PowerShell.EndInvoke to collect results. Warns if the job has not
yet completed. Disposes the job's resources after collecting results.

.PARAMETER Job
The job object returned by Start-WPFJob.

.OUTPUTS
PSCustomObject with: Output, Errors, HadErrors.
#>
function Get-WPFJobResult {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Job
    )

    process {
        if (-not $Job.Handle.IsCompleted) {
            Write-Warning "Job '$($Job.Name)' is still running. Results may be incomplete."
        }

        $result = [PSCustomObject]@{
            Name      = $Job.Name
            Output    = @($Job.PowerShell.EndInvoke($Job.Handle))
            Errors    = @($Job.PowerShell.Streams.Error)
            Warnings  = @($Job.PowerShell.Streams.Warning)
            HadErrors = $Job.PowerShell.HadErrors
            RunTime   = ([datetime]::Now - $Job.StartTime)
        }

        try { $Job.PowerShell.Dispose() } catch { }
        try { $Job.Runspace.Dispose()   } catch { }

        return $result
    }
}
#endregion


#region ======== Wait-WPFWindow ========
<#
.SYNOPSIS
Blocks the calling thread until the WPF window is closed, then cleans up.

.DESCRIPTION
Polls SyncHash.IsAlive at 200 ms intervals. After the window closes,
disposes the STA runspace and collects the UI thread's error stream.

Use this at the end of a script to prevent the script from exiting before
the user closes the window.

.EXAMPLE
$session = Show-WPFWindow -Xaml $xaml -OnInit { ... }
# ... set up other things ...
Wait-WPFWindow -Session $session
#>
function Wait-WPFWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Session
    )

    while ($Session.SyncHash.IsAlive) {
        Start-Sleep -Milliseconds 200
    }

    # Collect any errors from the STA thread
    try {
        $uiErrors = @($Session.UIThread.PowerShell.Streams.Error)
        if ($uiErrors.Count -gt 0) {
            foreach ($err in $uiErrors) {
                Write-Warning "WPF UI thread error: $err"
            }
        }
        [void]$Session.UIThread.PowerShell.EndInvoke($Session.UIThread.Handle)
    }
    catch { }

    try { $Session.UIThread.PowerShell.Dispose() } catch { }
    try { $Session.UIThread.Runspace.Dispose()   } catch { }
}
#endregion


#region ======== Close-WPFWindow ========
<#
.SYNOPSIS
Closes the WPF window programmatically from any thread.

.DESCRIPTION
Uses Dispatcher.Invoke to call Window.Close() on the STA thread.
Has no effect if the window is already closed.

.EXAMPLE
Close-WPFWindow -Session $session
#>
function Close-WPFWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Session
    )

    if (-not $Session.SyncHash.IsAlive -or -not $Session.SyncHash.Window) { return }

    $win = $Session.SyncHash.Window
    try {
        $win.Dispatcher.Invoke([action]{ $win.Close() }, 'Normal')
    }
    catch { }
}
#endregion


#region ======== Get-WPFControl ========
<#
.SYNOPSIS
Returns a named control from the window's control registry.

.DESCRIPTION
All FrameworkElements with a Name attribute in the XAML are registered
automatically. Returns $null if the name is not found.

.PARAMETER Session
The session object returned by Show-WPFWindow.

.PARAMETER Name
The x:Name value of the control.

.EXAMPLE
$btn = Get-WPFControl -Session $session -Name 'btnSave'
Invoke-UIAction -Session $session -Action { $btn.IsEnabled = $false }
#>
function Get-WPFControl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $ctrl = $Session.SyncHash.Controls[$Name]
    if (-not $ctrl) {
        Write-Warning "Control '$Name' was not found. Check the x:Name attribute in XAML."
    }
    return $ctrl
}
#endregion


#region ======== Register-WPFEvent ========
<#
.SYNOPSIS
Attaches an event handler to a named control from any thread.

.DESCRIPTION
Uses Dispatcher.Invoke to safely add the event handler on the STA thread.
The -Action scriptblock runs on the STA thread when the event fires.
Inside -Action, $syncHash is available directly as a runspace variable.

NOTE: If you are already inside -OnInit (already on the STA thread), attach
events directly: $syncHash.Controls['btn'].Add_Click({ ... })
Use Register-WPFEvent only when calling from the main thread after Show-WPFWindow.

.PARAMETER Session
The session object returned by Show-WPFWindow.

.PARAMETER ControlName
The x:Name of the target control.

.PARAMETER EventName
The CLR event name without the 'Add_' prefix (e.g. 'Click', 'TextChanged').

.PARAMETER Action
The event handler scriptblock. Receives standard sender/$EventArgs parameters.

.EXAMPLE
Register-WPFEvent -Session $session -ControlName 'btnSave' -EventName 'Click' -Action {
    param($sender, $e)
    $syncHash.Controls['lblStatus'].Content = 'Saved'
}
#>
function Register-WPFEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [string]$ControlName,

        [Parameter(Mandatory)]
        [string]$EventName,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $sh         = $Session.SyncHash
    $ctrlName   = $ControlName
    $addMethod  = "Add_$EventName"
    $handler    = $Action

    $sh.Window.Dispatcher.Invoke([action]{
        $ctrl = $sh.Controls[$ctrlName]
        if (-not $ctrl) {
            Write-Warning "Register-WPFEvent: control '$ctrlName' not found."
            return
        }
        $ctrl.$addMethod($handler)
    }, 'Normal')
}
#endregion


#region ======== Start-WPFTimer ========
<#
.SYNOPSIS
Creates and starts a DispatcherTimer that fires a scriptblock on the UI thread.

.DESCRIPTION
DispatcherTimer callbacks run on the STA (UI) thread so they can safely touch
controls. Use timers to poll SyncHash for status changes and update the UI,
or to drive simple animations.

.PARAMETER Session
The session object returned by Show-WPFWindow.

.PARAMETER IntervalMs
Tick interval in milliseconds.

.PARAMETER TickAction
The scriptblock to run on each tick. Runs on the STA thread.
$syncHash is available directly (STA runspace variable).

.OUTPUTS
System.Windows.Threading.DispatcherTimer — pass to Stop-WPFTimer to stop it.

.EXAMPLE
$timer = Start-WPFTimer -Session $session -IntervalMs 500 -TickAction {
    $syncHash.Controls['lblClock'].Content = (Get-Date).ToString('HH:mm:ss')
}
# Later:
Stop-WPFTimer -Session $session -Timer $timer
#>
function Start-WPFTimer {
    [CmdletBinding()]
    [OutputType([System.Windows.Threading.DispatcherTimer])]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [int]$IntervalMs,

        [Parameter(Mandatory)]
        [scriptblock]$TickAction
    )

    # Use a unique key to retrieve the timer object after the Dispatcher call returns.
    $key = "_Timer_$(([guid]::NewGuid()).ToString('N').Substring(0,8))"
    $sh  = $Session.SyncHash
    $ms  = $IntervalMs
    $cb  = $TickAction

    # Dispatcher.Invoke is synchronous, so $sh.Data[$key] is set before we return.
    Invoke-UIAction -Session $Session -Action {
        $t = [System.Windows.Threading.DispatcherTimer]::new()
        $t.Interval = [timespan]::FromMilliseconds($ms)
        $t.Add_Tick($cb)
        $t.Start()
        $sh.Data[$key] = $t
    }

    return $sh.Data[$key]
}
#endregion


#region ======== Stop-WPFTimer ========
<#
.SYNOPSIS
Stops a DispatcherTimer returned by Start-WPFTimer.

.PARAMETER Session
The session object returned by Show-WPFWindow.

.PARAMETER Timer
The DispatcherTimer to stop.

.EXAMPLE
$timer = Start-WPFTimer -Session $session -IntervalMs 1000 -TickAction {
    $syncHash.Controls['lblClock'].Content = (Get-Date).ToString('HH:mm:ss')
}
# ... later ...
Stop-WPFTimer -Session $session -Timer $timer
#>
function Stop-WPFTimer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Session,

        [Parameter(Mandatory)]
        [System.Windows.Threading.DispatcherTimer]$Timer
    )

    Invoke-UIAction -Session $Session -Action {
        $Timer.Stop()
    }
}
#endregion


#region ======== Get-WPFTemplate ========
<#
.SYNOPSIS
Returns a ready-to-use XAML window template string.

.DESCRIPTION
Four templates are provided as starting points. Each uses only standard WPF
controls and works with XamlReader.Load out of the box. Customise them in
your tool's script or save them to .xaml files.

Template names:
  Basic    - Title bar, scrollable content area, and a status bar.
  Console  - Scrollable console output, progress bar, and Start/Stop buttons.
  Form     - Scrollable labelled form with text inputs and action buttons.
  Split    - Side navigation panel with a content area on the right.

All templates register named controls for direct use with Get-WPFControl /
SyncHash.Controls. See inline XAML comments for control names.

.PARAMETER Name
One of: Basic, Console, Form, Split.

.EXAMPLE
$xaml    = Get-WPFTemplate -Name Console
$session = Show-WPFWindow -Xaml $xaml -Title 'Build Runner' -OnInit {
    $syncHash.Controls['btnStart'].Add_Click({
        & $syncHash.RunJob {
            # long-running work here
        }
    })
}
Wait-WPFWindow -Session $session
#>
function Get-WPFTemplate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Basic', 'Console', 'Form', 'Split')]
        [string]$Name
    )

    $templates = @{

        # ──────────────────────────────────────────────────────────────────────
        # Basic: dark header, scrollable content, status bar.
        # Named controls: lblTitle, scrollContent, lblStatus
        # ──────────────────────────────────────────────────────────────────────
        Basic = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Tool Window"
    Height="520" Width="780"
    MinHeight="300" MinWidth="480"
    WindowStartupLocation="CenterScreen"
    Background="#F5F5F5">

    <Window.Resources>
        <Style x:Key="HeaderText" TargetType="TextBlock">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize"   Value="16"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="44"/>   <!-- Header  -->
            <RowDefinition Height="*"/>    <!-- Content -->
            <RowDefinition Height="26"/>   <!-- Status  -->
        </Grid.RowDefinitions>

        <!-- Header bar -->
        <Border Grid.Row="0" Background="#1E1E2E">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="lblTitle" Grid.Column="0"
                           Text="Tool Window" Style="{StaticResource HeaderText}"/>
                <TextBlock x:Name="lblSubtitle" Grid.Column="1"
                           Text="" Foreground="#AAA" FontSize="11"
                           VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Scrollable content area -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled" Margin="0">
            <StackPanel x:Name="scrollContent" Margin="16" />
        </ScrollViewer>

        <!-- Status bar -->
        <Border Grid.Row="2" Background="#E0E0E0" BorderBrush="#CCCCCC"
                BorderThickness="0,1,0,0">
            <Grid Margin="8,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="lblStatus" Grid.Column="0"
                           Text="Ready" VerticalAlignment="Center"
                           FontSize="11" Foreground="#555"/>
                <TextBlock x:Name="lblStatusRight" Grid.Column="1"
                           Text="" VerticalAlignment="Center"
                           FontSize="11" Foreground="#888"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

        # ──────────────────────────────────────────────────────────────────────
        # Console: toolbar with Start/Stop/Clear, scrolling dark output pane,
        # progress bar, and status bar.
        # Named controls: btnStart, btnStop, btnClear, txtOutput,
        #                 progressMain, lblStatus, lblElapsed
        # ──────────────────────────────────────────────────────────────────────
        Console = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Console Tool"
    Height="560" Width="900"
    MinHeight="320" MinWidth="540"
    WindowStartupLocation="CenterScreen"
    Background="#1E1E1E">

    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding"          Value="10,4"/>
            <Setter Property="Margin"           Value="2,0"/>
            <Setter Property="FontSize"         Value="12"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Cursor"           Value="Hand"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="44"/>    <!-- Toolbar     -->
            <RowDefinition Height="*"/>     <!-- Output pane -->
            <RowDefinition Height="6"/>     <!-- Progress    -->
            <RowDefinition Height="26"/>    <!-- Status bar  -->
        </Grid.RowDefinitions>

        <!-- Toolbar -->
        <Border Grid.Row="0" Background="#2D2D30" BorderBrush="#3F3F46"
                BorderThickness="0,0,0,1">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center"
                        Margin="8,0">
                <Button x:Name="btnStart" Content="▶  Start"
                        Background="#0E639C" Foreground="White"
                        BorderBrush="#1177BB"/>
                <Button x:Name="btnStop"  Content="■  Stop"
                        Background="#C72E2E" Foreground="White"
                        BorderBrush="#D44040" IsEnabled="False"/>
                <Separator Background="#555" Width="1" Margin="6,4"/>
                <Button x:Name="btnClear" Content="Clear"
                        Background="#3E3E42" Foreground="#CCC"
                        BorderBrush="#555"/>
                <Separator Background="#555" Width="1" Margin="6,4"/>
                <TextBlock x:Name="lblTitle" Text="Output"
                           Foreground="#AAA" FontSize="13"
                           VerticalAlignment="Center" Margin="4,0"/>
            </StackPanel>
        </Border>

        <!-- Scrolling output -->
        <ScrollViewer x:Name="scrollOutput" Grid.Row="1"
                      VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Auto"
                      Background="#1E1E1E">
            <TextBox x:Name="txtOutput"
                     IsReadOnly="True" TextWrapping="NoWrap"
                     Background="Transparent" Foreground="#D4D4D4"
                     FontFamily="Consolas" FontSize="12"
                     BorderThickness="0" Padding="8"
                     VerticalScrollBarVisibility="Disabled"
                     HorizontalScrollBarVisibility="Disabled"
                     AcceptsReturn="True"/>
        </ScrollViewer>

        <!-- Progress bar -->
        <ProgressBar x:Name="progressMain" Grid.Row="2"
                     Minimum="0" Maximum="100" Value="0"
                     Background="#333" Foreground="#0E639C"
                     BorderThickness="0"/>

        <!-- Status bar -->
        <Border Grid.Row="3" Background="#2D2D30">
            <Grid Margin="8,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="lblStatus" Grid.Column="0"
                           Text="Ready" Foreground="#9DA5B4"
                           VerticalAlignment="Center" FontSize="11"/>
                <TextBlock x:Name="lblElapsed" Grid.Column="1"
                           Text="" Foreground="#6B717D"
                           VerticalAlignment="Center" FontSize="11"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

        # ──────────────────────────────────────────────────────────────────────
        # Form: scrollable grid form with header, labelled fields, and
        # a button row. Extend the StackPanel with additional rows.
        # Named controls: lblFormTitle, formPanel, btnSubmit, btnCancel,
        #                 lblStatus
        # ──────────────────────────────────────────────────────────────────────
        Form = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Form"
    Height="520" Width="620"
    MinHeight="300" MinWidth="400"
    ResizeMode="CanResizeWithGrip"
    WindowStartupLocation="CenterScreen"
    Background="#F9F9F9">

    <Window.Resources>
        <Style x:Key="FieldLabel" TargetType="TextBlock">
            <Setter Property="FontSize"         Value="12"/>
            <Setter Property="FontWeight"       Value="SemiBold"/>
            <Setter Property="Foreground"       Value="#333"/>
            <Setter Property="Margin"           Value="0,10,0,3"/>
        </Style>
        <Style x:Key="FieldInput" TargetType="TextBox">
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="Padding"          Value="6,4"/>
            <Setter Property="BorderBrush"      Value="#CCC"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Background"       Value="White"/>
        </Style>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Padding"          Value="18,6"/>
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="Margin"           Value="4,0,0,0"/>
            <Setter Property="Cursor"           Value="Hand"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="50"/>   <!-- Header     -->
            <RowDefinition Height="*"/>    <!-- Form body  -->
            <RowDefinition Height="Auto"/> <!-- Buttons    -->
            <RowDefinition Height="26"/>   <!-- Status     -->
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#1565C0">
            <TextBlock x:Name="lblFormTitle" Text="Form Title"
                       Foreground="White" FontSize="17" FontWeight="Bold"
                       VerticalAlignment="Center" Margin="16,0"/>
        </Border>

        <!-- Scrollable form area -->
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"
                      Padding="0,0,4,0">
            <StackPanel x:Name="formPanel" Margin="20,8">

                <!-- ── Example fields (add / remove as needed) ── -->

                <TextBlock Text="Full Name" Style="{StaticResource FieldLabel}"/>
                <TextBox x:Name="txtFullName" Style="{StaticResource FieldInput}"/>

                <TextBlock Text="Email Address" Style="{StaticResource FieldLabel}"/>
                <TextBox x:Name="txtEmail" Style="{StaticResource FieldInput}"/>

                <TextBlock Text="Department" Style="{StaticResource FieldLabel}"/>
                <ComboBox x:Name="cboDepart" FontSize="13" Padding="6,4"
                          BorderBrush="#CCC" Background="White">
                    <ComboBoxItem Content="Engineering"/>
                    <ComboBoxItem Content="Operations"/>
                    <ComboBoxItem Content="Finance"/>
                    <ComboBoxItem Content="HR"/>
                </ComboBox>

                <TextBlock Text="Notes" Style="{StaticResource FieldLabel}"/>
                <TextBox x:Name="txtNotes" Style="{StaticResource FieldInput}"
                         Height="80" TextWrapping="Wrap"
                         AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>

                <!-- Add more rows here -->

            </StackPanel>
        </ScrollViewer>

        <!-- Button row -->
        <Border Grid.Row="2" Background="#ECECEC" BorderBrush="#DDD"
                BorderThickness="0,1,0,0" Padding="16,8">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="btnCancel" Content="Cancel"
                        Style="{StaticResource ActionButton}"
                        Background="#E0E0E0" BorderBrush="#BBB" Foreground="#333"/>
                <Button x:Name="btnSubmit" Content="Submit"
                        Style="{StaticResource ActionButton}"
                        Background="#1565C0" Foreground="White" BorderBrush="#1255A0"/>
            </StackPanel>
        </Border>

        <!-- Status bar -->
        <Border Grid.Row="3" Background="#E8E8E8" BorderBrush="#DDD"
                BorderThickness="0,1,0,0">
            <TextBlock x:Name="lblStatus" Text="Ready"
                       Margin="12,0" VerticalAlignment="Center"
                       FontSize="11" Foreground="#555"/>
        </Border>
    </Grid>
</Window>
'@

        # ──────────────────────────────────────────────────────────────────────
        # Split: collapsible left navigation panel + right content area.
        # Named controls: navPanel, btnNavToggle, contentArea,
        #                 lblTitle, lblStatus
        # Add ListBoxItems to navPanel and swap contentArea children per selection.
        # ──────────────────────────────────────────────────────────────────────
        Split = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Split Tool"
    Height="600" Width="900"
    MinHeight="350" MinWidth="560"
    WindowStartupLocation="CenterScreen"
    Background="#F0F0F0">

    <Window.Resources>
        <Style x:Key="NavItem" TargetType="ListBoxItem">
            <Setter Property="Padding"          Value="12,10"/>
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="Foreground"       Value="#DDD"/>
            <Setter Property="BorderThickness"  Value="0"/>
            <Setter Property="Cursor"           Value="Hand"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#3E3E42"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#2A2A30"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="44"/>   <!-- Header  -->
            <RowDefinition Height="*"/>    <!-- Body    -->
            <RowDefinition Height="26"/>   <!-- Status  -->
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#1E1E2E">
            <Grid Margin="8,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnNavToggle" Grid.Column="0"
                        Content="☰" Width="36" Background="Transparent"
                        Foreground="White" BorderThickness="0"
                        FontSize="18" Cursor="Hand" Margin="2,0,8,0"/>
                <TextBlock x:Name="lblTitle" Grid.Column="1"
                           Text="Split Tool" Foreground="White"
                           FontSize="15" FontWeight="SemiBold"
                           VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Body: nav + content -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition x:Name="navColumn" Width="180" MinWidth="0"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Navigation panel -->
            <Border Grid.Column="0" Background="#252526">
                <ListBox x:Name="navPanel"
                         Background="Transparent" BorderThickness="0"
                         ItemContainerStyle="{StaticResource NavItem}">
                    <ListBoxItem Content="Overview"/>
                    <ListBoxItem Content="Settings"/>
                    <ListBoxItem Content="Logs"/>
                    <!-- Add more nav items as needed -->
                </ListBox>
            </Border>

            <!-- Right-side content area -->
            <Border Grid.Column="1" Background="White"
                    BorderBrush="#DDD" BorderThickness="1,0,0,0">
                <Grid x:Name="contentArea" Margin="16">
                    <!-- Swap children here based on navPanel selection -->
                    <TextBlock Text="Select an item from the navigation panel."
                               HorizontalAlignment="Center"
                               VerticalAlignment="Center"
                               FontSize="14" Foreground="#888"/>
                </Grid>
            </Border>
        </Grid>

        <!-- Status bar -->
        <Border Grid.Row="2" Background="#E0E0E0" BorderBrush="#CCC"
                BorderThickness="0,1,0,0">
            <Grid Margin="8,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="lblStatus" Grid.Column="0"
                           Text="Ready" FontSize="11" Foreground="#555"
                           VerticalAlignment="Center"/>
                <TextBlock x:Name="lblStatusRight" Grid.Column="1"
                           Text="" FontSize="11" Foreground="#888"
                           VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@
    }

    $xaml = $templates[$Name]
    if (-not $xaml) {
        throw "Unknown template '$Name'. Valid names: Basic, Console, Form, Split."
    }
    return $xaml
}
#endregion


#region ======== Module Exports ========
Export-ModuleMember -Function @(
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
#endregion
