#Requires -Version 5.1

#region ======== Constants ========

$script:MaxTransitiveDepth = 10

#endregion


#region ======== Private: New-DependencyNode ========

function New-DependencyNode {
    param(
        [string]$Name,
        [string]$Source,
        [string]$RequiredVersion,
        [string]$ResolvedPath,
        [string]$Status,
        [int]$Depth,
        [object[]]$TransitiveDeps
    )
    [PSCustomObject]@{
        PSTypeName      = 'DependencyNode'
        Name            = $Name
        Source          = $Source
        RequiredVersion = $RequiredVersion
        ResolvedPath    = $ResolvedPath
        Status          = $Status
        Depth           = $Depth
        TransitiveDeps  = if ($TransitiveDeps) { $TransitiveDeps } else { @() }
    }
}

#endregion


#region ======== Private: Resolve-ScriptImports ========

<#
.SYNOPSIS
Parses a .ps1 file for all module dependency declarations without executing it.

.DESCRIPTION
Applies seven regex patterns to detect:
  #Requires -Modules (bare name and hashtable form)
  Import-Module (bare name, absolute path, relative path)
  using module (bare name and path)

Returns an array of raw import descriptor objects. Deduplicates on (RawName, Source).
#>
function Resolve-ScriptImports {
    param([string]$ScriptPath)

    $scriptDir = [System.IO.Path]::GetDirectoryName($ScriptPath)
    $content   = [System.IO.File]::ReadAllText($ScriptPath)
    $results   = [System.Collections.Generic.List[object]]::new()
    $seen      = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    function Add-Import {
        param([string]$RawName, [string]$Source, [string]$ReqVer, [bool]$IsPath)
        $key = "$Source|$RawName"
        if ($seen.Add($key)) {
            $results.Add([PSCustomObject]@{
                RawName         = $RawName
                Source          = $Source
                RequiredVersion = $ReqVer
                IsPath          = $IsPath
            })
        }
    }

    function Resolve-RelativePath {
        param([string]$Fragment)
        try {
            [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, $Fragment))
        }
        catch { $Fragment }
    }

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    # ---- Pattern 1: #Requires -Modules BareModuleName ----
    $rx1 = [regex]::new('#Requires\s+-Modules\s+([A-Za-z][A-Za-z0-9_\-\.]*)(?!\s*@)', $opts)
    foreach ($m in $rx1.Matches($content)) {
        Add-Import -RawName $m.Groups[1].Value -Source '#Requires' -ReqVer $null -IsPath $false
    }

    # ---- Pattern 2: #Requires -Modules @{ModuleName='X'; ModuleVersion='1.0'} ----
    $rx2 = [regex]::new('#Requires\s+-Modules\s+(@\{[^}]+\})', $opts)
    foreach ($m in $rx2.Matches($content)) {
        $block = $m.Groups[1].Value

        $nameMatch = [regex]::Match($block, 'ModuleName\s*=\s*[''"]?([A-Za-z][A-Za-z0-9_\-\.]*)[''"]?', $opts)
        if (-not $nameMatch.Success) { continue }
        $modName = $nameMatch.Groups[1].Value

        $verMatch = [regex]::Match($block, 'ModuleVersion\s*=\s*[''"]?([0-9]+(?:\.[0-9]+){1,3})[''"]?', $opts)
        $modVer   = if ($verMatch.Success) { $verMatch.Groups[1].Value } else { $null }

        Add-Import -RawName $modName -Source '#Requires' -ReqVer $modVer -IsPath $false
    }

    # ---- Pattern 3: Import-Module BareModuleName ----
    # Must NOT start with a quote, backslash, dot, or drive letter (those are paths)
    $rx3 = [regex]::new('Import-Module\s+(?:-Name\s+)?([A-Za-z][A-Za-z0-9_\-\.]*)(?=\s|$|#|;|-)', $opts)
    foreach ($m in $rx3.Matches($content)) {
        $name = $m.Groups[1].Value
        # Skip if the captured name is a known parameter (common false positives)
        if ($name -in @('Force','AsCustomObject','Prefix','Scope','Global','Local','PassThru',
                        'NoClobber','DisableNameChecking','WarningAction','ErrorAction',
                        'Verbose','Debug','Function','Cmdlet','Variable','Alias')) { continue }
        Add-Import -RawName $name -Source 'Import-Module' -ReqVer $null -IsPath $false
    }

    # ---- Pattern 4: Import-Module 'C:\...' or "C:\..." (absolute path) ----
    $rx4 = [regex]::new('Import-Module\s+(?:-Name\s+)?[''"]([A-Za-z]:[/\\][^''"]+)[''"]', $opts)
    foreach ($m in $rx4.Matches($content)) {
        Add-Import -RawName $m.Groups[1].Value -Source 'Import-Module' -ReqVer $null -IsPath $true
    }
    # Unquoted absolute path
    $rx4b = [regex]::new('Import-Module\s+(?:-Name\s+)?([A-Za-z]:[/\\][^\s;#]+)', $opts)
    foreach ($m in $rx4b.Matches($content)) {
        Add-Import -RawName $m.Groups[1].Value -Source 'Import-Module' -ReqVer $null -IsPath $true
    }

    # ---- Pattern 5: Import-Module .\relative or ./relative ----
    $rx5 = [regex]::new('Import-Module\s+(?:-Name\s+)?[''"]?(\.[\\/][^''";\s]+)[''"]?', $opts)
    foreach ($m in $rx5.Matches($content)) {
        $resolved = Resolve-RelativePath $m.Groups[1].Value
        Add-Import -RawName $resolved -Source 'Import-Module' -ReqVer $null -IsPath $true
    }

    $multiOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                 [System.Text.RegularExpressions.RegexOptions]::Multiline

    # ---- Pattern 6: using module BareModuleName ----
    $rx6 = [regex]::new('^using\s+module\s+([A-Za-z][A-Za-z0-9_\-\.]*)(?:\s|$)', $multiOpts)
    foreach ($m in $rx6.Matches($content)) {
        Add-Import -RawName $m.Groups[1].Value -Source 'using module' -ReqVer $null -IsPath $false
    }

    # ---- Pattern 7: using module 'C:\...' or .\relative ----
    $rx7 = [regex]::new('^using\s+module\s+[''"]?([A-Za-z]:[/\\][^''";\s]+|\.[\\/][^''";\s]+)[''"]?', $multiOpts)
    foreach ($m in $rx7.Matches($content)) {
        $raw = $m.Groups[1].Value
        if ($raw -match '^\.') { $raw = Resolve-RelativePath $raw }
        Add-Import -RawName $raw -Source 'using module' -ReqVer $null -IsPath $true
    }

    return $results.ToArray()
}

#endregion


#region ======== Private: Find-ModuleOnDisk ========

<#
.SYNOPSIS
Searches known locations for a module by bare name and returns its .psd1 or .psm1 path.

.DESCRIPTION
Search order:
  1. Each directory in $env:PSModulePath
  2. The script's own directory
  3. The parent of the script's directory (covers project-local layouts like MMR)
  4. One-level subdirectories of the script's directory

Prefers .psd1 over .psm1 (required for transitive resolution).
Returns $null if not found.
#>
function Find-ModuleOnDisk {
    param(
        [string]$ModuleName,
        [string]$ScriptDir
    )

    $candidates = [System.Collections.Generic.List[string]]::new()

    # 1. PSModulePath entries
    foreach ($entry in ($env:PSModulePath -split ';')) {
        $entry = $entry.TrimEnd('\', '/').Trim()
        if ($entry) { $candidates.Add($entry) }
    }

    # 2. Script's own directory
    if ($ScriptDir -and [System.IO.Directory]::Exists($ScriptDir)) {
        $candidates.Add($ScriptDir)

        # 3. Walk up to 3 ancestor levels (covers project layouts like MMR\Module\Examples\script.ps1)
        $ancestor = $ScriptDir
        for ($i = 0; $i -lt 3; $i++) {
            $ancestor = [System.IO.Path]::GetDirectoryName($ancestor)
            if ($ancestor -and [System.IO.Directory]::Exists($ancestor)) {
                $candidates.Add($ancestor)
            } else { break }
        }

        # 4. One-level subdirectories of script dir
        try {
            foreach ($sub in [System.IO.Directory]::GetDirectories($ScriptDir)) {
                $candidates.Add($sub)
            }
        }
        catch { }
    }

    foreach ($base in $candidates) {
        # Standard layout: <base>\<ModuleName>\<ModuleName>.psd1
        $psd1 = [System.IO.Path]::Combine($base, $ModuleName, "$ModuleName.psd1")
        if ([System.IO.File]::Exists($psd1)) { return $psd1 }

        $psm1 = [System.IO.Path]::Combine($base, $ModuleName, "$ModuleName.psm1")
        if ([System.IO.File]::Exists($psm1)) { return $psm1 }

        # Flat layout: <base>\<ModuleName>.psd1
        $psd1flat = [System.IO.Path]::Combine($base, "$ModuleName.psd1")
        if ([System.IO.File]::Exists($psd1flat)) { return $psd1flat }
    }

    return $null
}

#endregion


#region ======== Private: Resolve-TransitiveDeps ========

<#
.SYNOPSIS
Recursively resolves RequiredModules from a .psd1 manifest.

.DESCRIPTION
Uses Import-PowerShellDataFile (safe, no code execution) to parse the manifest.
Tracks visited paths to prevent infinite cycles.
Stops at $script:MaxTransitiveDepth regardless.
#>
function Resolve-TransitiveDeps {
    param(
        [string]$PsdPath,
        [int]$CurrentDepth,
        [hashtable]$Visited
    )

    if ($CurrentDepth -ge $script:MaxTransitiveDepth) { return @() }

    $normalKey = $PsdPath.ToLowerInvariant()
    if ($Visited.ContainsKey($normalKey)) { return @() }
    $Visited[$normalKey] = $true

    try {
        $psdData = Import-PowerShellDataFile -LiteralPath $PsdPath -ErrorAction Stop
    }
    catch {
        Write-Warning "DependencyChecker: Could not parse '$PsdPath': $_"
        return @()
    }

    $reqMods = $psdData['RequiredModules']
    if (-not $reqMods) { return @() }

    $psdDir  = Split-Path -LiteralPath $PsdPath -Parent
    $nodes   = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $reqMods) {
        $modName = $null
        $modVer  = $null

        if ($entry -is [string]) {
            $modName = $entry
        }
        elseif ($entry -is [hashtable]) {
            $modName = $entry['ModuleName']
            if (-not $modName) { $modName = $entry['Name'] }
            $modVer  = $entry['ModuleVersion']
            if (-not $modVer) { $modVer = $entry['RequiredVersion'] }
        }

        if (-not $modName) { continue }

        $found  = Find-ModuleOnDisk -ModuleName $modName -ScriptDir $psdDir
        $status = if ($found) { 'Found' } else { 'NotFound' }

        $transitive = @()
        if ($found -and $found.EndsWith('.psd1')) {
            $transitive = Resolve-TransitiveDeps -PsdPath $found -CurrentDepth ($CurrentDepth + 1) -Visited $Visited
        }

        $nodes.Add((New-DependencyNode `
            -Name            $modName `
            -Source          'RequiredModules' `
            -RequiredVersion $modVer `
            -ResolvedPath    $found `
            -Status          $status `
            -Depth           $CurrentDepth `
            -TransitiveDeps  $transitive))
    }

    return $nodes.ToArray()
}

#endregion


#region ======== Private: Resolve-PathImport ========

<#
.SYNOPSIS
Resolves a path-based import to a .psd1 or .psm1 file path.
#>
function Resolve-PathImport {
    param([string]$ImportPath)

    # If it's a directory, look for <dir>\<basename>.psd1 inside it
    if ([System.IO.Directory]::Exists($ImportPath)) {
        $baseName = [System.IO.Path]::GetFileName($ImportPath.TrimEnd('\', '/'))
        $psd1 = [System.IO.Path]::Combine($ImportPath, "$baseName.psd1")
        if ([System.IO.File]::Exists($psd1)) { return $psd1 }
        $psm1 = [System.IO.Path]::Combine($ImportPath, "$baseName.psm1")
        if ([System.IO.File]::Exists($psm1)) { return $psm1 }
        return $null
    }

    # Direct file path
    if ([System.IO.File]::Exists($ImportPath)) { return $ImportPath }

    # Try appending .psd1 / .psm1 if no extension given
    if (-not [System.IO.Path]::HasExtension($ImportPath)) {
        $psd1 = $ImportPath + '.psd1'
        if ([System.IO.File]::Exists($psd1)) { return $psd1 }
        $psm1 = $ImportPath + '.psm1'
        if ([System.IO.File]::Exists($psm1)) { return $psm1 }
    }

    return $null
}

#endregion


#region ======== Private: Count-UnresolvedNodes ========

function Count-UnresolvedNodes {
    param([object[]]$Deps)
    $count = 0
    foreach ($dep in $Deps) {
        if ($dep.Status -eq 'NotFound') { $count++ }
        if ($dep.TransitiveDeps) { $count += Count-UnresolvedNodes -Deps $dep.TransitiveDeps }
    }
    return $count
}

#endregion


#region ======== Private: Format-DepTree ========

<#
.SYNOPSIS
Recursively prints a color-coded dependency tree to the console.
#>
function Format-DepTree {
    param(
        [object[]]$Deps,
        [int]$Indent
    )

    $pad = '  ' * $Indent

    foreach ($dep in $Deps) {

        $nameCol    = $dep.Name.PadRight(30)
        $sourceCol  = "($($dep.Source))".PadRight(22)
        $resolvedCol = if ($dep.ResolvedPath) { "-> $($dep.ResolvedPath)" } else { '-> (not found)' }
        $verSuffix   = if ($dep.RequiredVersion) { " v$($dep.RequiredVersion)" } else { '' }

        if ($dep.Depth -eq 0) {
            # Direct dependency
            if ($dep.Status -eq 'Found') {
                $prefix = '[+]'
                $color  = 'Green'
            }
            else {
                $prefix = '[-]'
                $color  = 'Red'
            }
        }
        else {
            # Transitive dependency
            $prefix = '[>]'
            $color  = if ($dep.Status -eq 'Found') { 'Yellow' } else { 'Red' }
        }

        Write-Host "$pad$prefix $nameCol$verSuffix $sourceCol $resolvedCol" -ForegroundColor $color

        if ($dep.TransitiveDeps -and $dep.TransitiveDeps.Count -gt 0) {
            Format-DepTree -Deps $dep.TransitiveDeps -Indent ($Indent + 1)
        }
    }
}

#endregion


#region ======== Private: Process-SingleScript ========

function Process-SingleScript {
    param([string]$FilePath)

    $scriptDir  = [System.IO.Path]::GetDirectoryName($FilePath)
    $rawImports = Resolve-ScriptImports -ScriptPath $FilePath
    $visited    = @{}
    $deps       = [System.Collections.Generic.List[object]]::new()

    foreach ($import in $rawImports) {

        if ($import.IsPath) {
            $resolved = Resolve-PathImport -ImportPath $import.RawName
            $status   = if ($resolved) { 'Found' } else { 'NotFound' }
            $displayName = [System.IO.Path]::GetFileNameWithoutExtension($import.RawName)

            $transitive = @()
            if ($resolved -and $resolved.EndsWith('.psd1')) {
                $transitive = Resolve-TransitiveDeps -PsdPath $resolved -CurrentDepth 1 -Visited $visited
            }

            $deps.Add((New-DependencyNode `
                -Name            $displayName `
                -Source          $import.Source `
                -RequiredVersion $import.RequiredVersion `
                -ResolvedPath    $resolved `
                -Status          $status `
                -Depth           0 `
                -TransitiveDeps  $transitive))
        }
        else {
            $found  = Find-ModuleOnDisk -ModuleName $import.RawName -ScriptDir $scriptDir
            $status = if ($found) { 'Found' } else { 'NotFound' }

            $transitive = @()
            if ($found -and $found.EndsWith('.psd1')) {
                $transitive = Resolve-TransitiveDeps -PsdPath $found -CurrentDepth 1 -Visited $visited
            }

            $deps.Add((New-DependencyNode `
                -Name            $import.RawName `
                -Source          $import.Source `
                -RequiredVersion $import.RequiredVersion `
                -ResolvedPath    $found `
                -Status          $status `
                -Depth           0 `
                -TransitiveDeps  $transitive))
        }
    }

    $depArray   = $deps.ToArray()
    $allResolved = -not ($depArray | Where-Object { $_.Status -eq 'NotFound' })

    [PSCustomObject]@{
        PSTypeName        = 'ScriptDependencyResult'
        ScriptPath        = $FilePath
        TotalDependencies = $depArray.Count
        AllResolved       = $allResolved
        Dependencies      = $depArray
    }
}

#endregion


#region ======== Public: Get-ScriptDependency ========

<#
.SYNOPSIS
Analyzes one or more PowerShell scripts and returns their module dependencies.

.DESCRIPTION
Scans a .ps1 file or every .ps1 file in a folder (recursively) for module
dependency declarations:
  - #Requires -Modules
  - Import-Module (bare name, absolute path, relative path)
  - using module (bare name and path)

Also follows transitive dependencies declared in .psd1 RequiredModules keys,
up to a depth of 10.

Returns a ScriptDependencyResult object for each script analyzed. These objects
can be piped to Show-DependencyReport or inspected directly.

.PARAMETER Path
Path to a .ps1 file or a directory. Directories are searched recursively for
all .ps1 files.

.OUTPUTS
PSCustomObject (PSTypeName: ScriptDependencyResult)

.EXAMPLE
Get-ScriptDependency -Path 'C:\Tools\MyForm.ps1'

.EXAMPLE
Get-ScriptDependency -Path 'C:\Users\James\MMR' | Where-Object { -not $_.AllResolved }
#>
function Get-ScriptDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Path
    )

    process {
        $resolved = [System.IO.Path]::GetFullPath($Path)

        if ([System.IO.File]::Exists($resolved)) {
            if ($resolved -notmatch '\.ps1$') {
                Write-Warning "Get-ScriptDependency: '$resolved' is not a .ps1 file - skipping."
                return
            }
            Process-SingleScript -FilePath $resolved
        }
        elseif ([System.IO.Directory]::Exists($resolved)) {
            $scripts = Get-ChildItem -LiteralPath $resolved -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue
            if (-not $scripts) {
                Write-Warning "Get-ScriptDependency: No .ps1 files found under '$resolved'."
                return
            }
            foreach ($script in $scripts) {
                Process-SingleScript -FilePath $script.FullName
            }
        }
        else {
            Write-Error "Get-ScriptDependency: Path '$resolved' does not exist."
        }
    }
}

#endregion


#region ======== Public: Show-DependencyReport ========

<#
.SYNOPSIS
Prints a color-coded module dependency report to the console.

.DESCRIPTION
Calls Get-ScriptDependency internally and displays the results as a formatted
tree with a summary footer.

Color coding:
  Green  [+]  Direct dependency — found
  Red    [-]  Direct dependency — not found
  Yellow [>]  Transitive dependency — found
  Red    [>]  Transitive dependency — not found

.PARAMETER Path
Path to a .ps1 file or a directory. Directories are searched recursively.

.EXAMPLE
Show-DependencyReport -Path 'C:\Tools\MyForm.ps1'

.EXAMPLE
Show-DependencyReport -Path 'C:\Users\James\MMR'
#>
function Show-DependencyReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $results = Get-ScriptDependency -Path $Path

    $separator = '=' * 72

    Write-Host $separator -ForegroundColor DarkGray
    Write-Host 'DependencyChecker Report' -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor DarkGray
    Write-Host "Analyzed : $([System.IO.Path]::GetFullPath($Path))"
    Write-Host "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ''

    if (-not $results) {
        Write-Host 'No .ps1 files found.' -ForegroundColor Yellow
        Write-Host $separator -ForegroundColor DarkGray
        return
    }

    $totalUnresolved = 0

    foreach ($result in $results) {
        Write-Host "Script: $($result.ScriptPath)" -ForegroundColor White
        Write-Host "  Dependencies: $($result.TotalDependencies)  |  All Resolved: $($result.AllResolved)"
        Write-Host ''

        if ($result.TotalDependencies -eq 0) {
            Write-Host '  (no module dependencies detected)' -ForegroundColor DarkGray
        }
        else {
            Format-DepTree -Deps $result.Dependencies -Indent 1
            $totalUnresolved += Count-UnresolvedNodes -Deps $result.Dependencies
        }

        Write-Host ''
    }

    # Summary footer
    $totalScripts = @($results).Count
    $totalDeps    = ($results | Measure-Object -Property TotalDependencies -Sum).Sum

    Write-Host $separator -ForegroundColor DarkGray
    Write-Host 'SUMMARY' -ForegroundColor Cyan
    Write-Host "  Scripts analyzed : $totalScripts"
    Write-Host "  Total deps found : $totalDeps"

    $unresolvedColor = if ($totalUnresolved -gt 0) { 'Red' } else { 'Green' }
    Write-Host "  Unresolved deps  : $totalUnresolved" -ForegroundColor $unresolvedColor
    Write-Host $separator -ForegroundColor DarkGray
}

#endregion


Export-ModuleMember -Function 'Get-ScriptDependency', 'Show-DependencyReport'
