#region Module Initialization
# This section runs once when the module is imported.
# We create reusable PerformanceCounter objects so we don't incur
# overhead by recreating them every time we sample system load.

try {
    # Tracks overall CPU utilization across all logical processors
    $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total")
    $script:CpuCounter.NextValue() | Out-Null  # First read always returns 0

    # Tracks how many threads are waiting for CPU time
    # This helps detect CPU contention in virtual machines
    $script:QueueCounter = New-Object System.Diagnostics.PerformanceCounter("System", "Processor Queue Length")
    $script:QueueCounter.NextValue() | Out-Null

    # Small delay allows counters to begin returning valid values
    Start-Sleep -Milliseconds 500
}
catch {
    Write-Warning "Performance counters could not be initialized. System load monitoring may not function correctly."
}
#endregion


#region Test-IsVMwareVM
<#
.SYNOPSIS
Determines whether the current system is a VMware virtual machine.

.DESCRIPTION
This function checks the system model reported by Windows.
If the model name contains 'VMware', the system is treated as a virtual desktop.
Virtual machines require additional load checks because CPU scheduling
delays from the hypervisor are not visible through CPU percentage alone.
#>
function Test-IsVMwareVM {
    [CmdletBinding()]
    param()

    $model = (Get-CimInstance Win32_ComputerSystem).Model
    return $model -match 'VMware'
}
#endregion


#region Get-SystemLoadSnapshot
<#
.SYNOPSIS
Captures a real-time snapshot of CPU and processor queue load.

.DESCRIPTION
This function reads from Performance Counters to determine:
• Total CPU usage across all logical processors
• Number of threads waiting for CPU time (Processor Queue Length)
• Total logical processor count

The returned object is used by the execution gate to determine
whether the system is currently under CPU pressure.
#>
function Get-SystemLoadSnapshot {
    [CmdletBinding()]
    param()

    $cpu = $script:CpuCounter.NextValue()
    $queue = $script:QueueCounter.NextValue()
    $logicalCores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

    [PSCustomObject]@{
        CPUPercent   = [math]::Round($cpu, 2)
        QueueLength  = [math]::Round($queue, 2)
        LogicalCores = $logicalCores
    }
}
#endregion


#region Wait-ForSystemReadyToRun
<#
.SYNOPSIS
Delays task execution until system CPU load is within safe limits.

.DESCRIPTION
This function acts as a safeguard before running scheduled tasks.
It begins monitoring system load shortly before the task is set to start.

If CPU usage exceeds the defined threshold, execution is delayed until:
• CPU usage remains below the threshold for a continuous stability period
• On VMware VMs, processor queue length must also remain below the number of logical cores

This ensures tasks do not start during periods of high system load
or CPU scheduling contention.
#>
function Wait-ForSystemReadyToRun {
    [CmdletBinding()]
    param(
        # Maximum CPU percentage allowed before delaying execution
        [int]$CpuThreshold = 70,

        # How many seconds before task start we begin monitoring
        [int]$PreCheckWindow = 30,

        # How long CPU must remain stable before allowing execution
        [int]$StableTimeRequired = 30,

        # How often (in seconds) system load is sampled
        [int]$SampleInterval = 5
    )

    $isVMwareVM = Test-IsVMwareVM
    $stableTime = 0
    $elapsedPreCheck = 0

    Write-Verbose "System Type: $($isVMwareVM ? 'VMware VM' : 'Physical Desktop')"
    Write-Verbose "Starting pre-run monitoring..."

    # Phase 1 — Monitor system load before the scheduled task time
    # If the system is already under load, we immediately move to delay mode
    while ($elapsedPreCheck -lt $PreCheckWindow) {
        $load = Get-SystemLoadSnapshot

        if ($isVMwareVM) {
            if ($load.CPUPercent -ge $CpuThreshold -or $load.QueueLength -ge $load.LogicalCores) { break }
        }
        else {
            if ($load.CPUPercent -ge $CpuThreshold) { break }
        }

        Start-Sleep -Seconds $SampleInterval
        $elapsedPreCheck += $SampleInterval
    }

    Write-Verbose "Waiting for stable system conditions..."

    # Phase 2 — Require sustained healthy system state before execution
    while ($true) {
        $load = Get-SystemLoadSnapshot

        if ($isVMwareVM) {
            # On VMware VMs, both CPU usage and queue length must be healthy
            $healthy = ($load.CPUPercent -lt $CpuThreshold) -and ($load.QueueLength -lt $load.LogicalCores)
        }
        else {
            # On physical desktops, CPU usage alone is sufficient
            $healthy = $load.CPUPercent -lt $CpuThreshold
        }

        Write-Verbose "CPU: $($load.CPUPercent)% | Queue: $($load.QueueLength) | Healthy: $healthy"

        if ($healthy) {
            $stableTime += $SampleInterval
            if ($stableTime -ge $StableTimeRequired) {
                Write-Verbose "System stable. Task cleared to run."
                return $true
            }
        }
        else {
            # Any spike resets the stability timer
            $stableTime = 0
        }

        Start-Sleep -Seconds $SampleInterval
    }
}
#endregion


# Export only the public functions
Export-ModuleMember -Function Test-IsVMwareVM, Get-SystemLoadSnapshot, Wait-ForSystemReadyToRun
