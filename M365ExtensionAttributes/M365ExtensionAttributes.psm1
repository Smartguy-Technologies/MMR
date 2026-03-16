#region ======== Private Helpers ========

function Assert-MgGraphConnection {
    param(
        [string[]]$RequiredScopes = @('User.ReadWrite.All')
    )

    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Users')) {
        throw "Microsoft.Graph.Users module is not installed. Run: Install-Module Microsoft.Graph -Scope CurrentUser"
    }

    $ctx = Get-MgContext
    if (-not $ctx) {
        Connect-MgGraph -Scopes $RequiredScopes -NoWelcome
        return
    }

    $missing = $RequiredScopes | Where-Object { $_ -notin $ctx.Scopes }
    if ($missing) {
        Connect-MgGraph -Scopes $RequiredScopes -NoWelcome
    }
}

function Resolve-ExtensionAttributes {
    param([object]$User)

    $attrs = @()
    for ($i = 1; $i -le 15; $i++) {
        $prop = "ExtensionAttribute$i"
        $val = $null
        if ($User -and $User.OnPremisesExtensionAttributes) {
            $val = $User.OnPremisesExtensionAttributes.$prop
        }
        $attrs += $val
    }
    return ,$attrs
}

function ConvertTo-ExtensionAttributesHashtable {
    param([object[]]$Attributes)

    if (-not $Attributes -or $Attributes.Count -ne 15) {
        throw "Attributes array must contain exactly 15 items."
    }

    $hash = [ordered]@{}
    for ($i = 1; $i -le 15; $i++) {
        $hash["ExtensionAttribute$i"] = $Attributes[$i - 1]
    }
    return $hash
}

function Test-HasDuplicateAttributeValue {
    param([object[]]$Attributes, [string]$Value, [int]$ExcludeIndex = -1)

    if (-not $Value) { return $false }
    for ($i = 0; $i -lt $Attributes.Count; $i++) {
        if ($i -eq $ExcludeIndex) { continue }
        $item = $Attributes[$i]
        if ($null -ne $item -and $item.ToString().Trim() -ne '') {
            if ($item.ToString().Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Find-AttributeIndexByValue {
    param([object[]]$Attributes, [string]$Value, [switch]$Wildcard)

    for ($i = 0; $i -lt $Attributes.Count; $i++) {
        $item = $Attributes[$i]
        if ($null -ne $item -and $item.ToString().Trim() -ne '') {
            if ($Wildcard) {
                if ($item.ToString() -like $Value) { return $i }
            }
            else {
                if ($item.ToString().Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $i
                }
            }
        }
    }
    return -1
}

function Find-FirstEmptyAttributeIndex {
    param([object[]]$Attributes)

    for ($i = 0; $i -lt $Attributes.Count; $i++) {
        $item = $Attributes[$i]
        if ($null -eq $item -or $item.ToString().Trim() -eq '') {
            return $i
        }
    }
    return -1
}

function Shift-ExtensionAttributesLeft {
    param([object[]]$Attributes, [int]$RemoveIndex)

    if ($RemoveIndex -lt 0 -or $RemoveIndex -gt 14) {
        throw "RemoveIndex must be between 0 and 14."
    }

    $list = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Attributes.Count; $i++) {
        if ($i -ne $RemoveIndex) {
            $list.Add($Attributes[$i])
        }
    }

    while ($list.Count -lt 15) { $list.Add($null) }

    return ,$list.ToArray()
}

function Get-MgUserWithExtensionAttributes {
    param([string]$UserId)

    $props = 'id,displayName,userPrincipalName,onPremisesExtensionAttributes'
    return Get-MgUser -UserId $UserId -Property $props
}

function ConvertTo-ODataStringLiteral {
    param([string]$Value)

    return $Value -replace "'", "''"
}

function Get-NaturalSortKey {
    param([string]$Value)

    # Split on digit runs; pad each numeric segment so string comparison == numeric comparison
    $parts = [regex]::Split($Value, '(\d+)')
    ($parts | ForEach-Object {
        if ($_ -match '^\d+$') { $_.PadLeft(20, '0') } else { $_.ToLowerInvariant() }
    }) -join ''
}

function Invoke-ExtensionAttributeOptimize {
    param(
        [object]$User,
        [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    $attrs = Resolve-ExtensionAttributes -User $User

    # Collect unique non-empty values (first occurrence wins for duplicates)
    $seen   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unique = [System.Collections.Generic.List[string]]::new()
    $duplicatesRemoved = 0

    foreach ($attr in $attrs) {
        if ($null -ne $attr -and $attr.ToString().Trim() -ne '') {
            if ($seen.Add($attr.ToString())) {
                $unique.Add($attr.ToString())
            } else {
                $duplicatesRemoved++
            }
        }
    }

    # Natural sort (alpha + numeric ordering within strings)
    $sorted = @($unique | Sort-Object { Get-NaturalSortKey $_ })

    # Pack into a fresh 15-slot array with no gaps
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $sorted) { $list.Add($v) }
    while ($list.Count -lt 15) { $list.Add($null) }
    $newAttrs = $list.ToArray()

    # Determine whether anything actually changed
    $changed = $false
    for ($i = 0; $i -lt 15; $i++) {
        $orig = if ($null -eq $attrs[$i])    { '' } else { $attrs[$i].ToString() }
        $new  = if ($null -eq $newAttrs[$i]) { '' } else { $newAttrs[$i].ToString() }
        if ($orig -ne $new) { $changed = $true; break }
    }

    if ($changed) {
        $action = "Remove $duplicatesRemoved duplicate(s), sort and compact extension attributes"
        if ($Cmdlet.ShouldProcess($User.UserPrincipalName, $action)) {
            $payload = ConvertTo-ExtensionAttributesHashtable -Attributes $newAttrs
            Update-MgUser -UserId $User.Id -OnPremisesExtensionAttributes $payload | Out-Null
        }
    }

    [PSCustomObject]@{
        Id                = $User.Id
        UserPrincipalName = $User.UserPrincipalName
        DisplayName       = $User.DisplayName
        Changed           = $changed
        DuplicatesRemoved = $duplicatesRemoved
        Before            = $attrs
        After             = $newAttrs
    }
}

#endregion

#region ======== Public Functions ========

<#[
.SYNOPSIS
Adds an extension attribute value to a user without creating duplicates.

.DESCRIPTION
Adds a value to the first available extensionAttribute slot unless a specific
AttributeNumber is provided. Will not overwrite existing values unless
-AllowOverwrite is specified. Prevents adding duplicate values across all 15
extension attributes.

.PARAMETER UserId
User ID or UPN.

.PARAMETER Value
Value to add.

.PARAMETER AttributeNumber
Optional specific slot (1-15).

.PARAMETER AllowOverwrite
Allows overwriting a populated slot when AttributeNumber is specified.
#>
function Add-M365ExtensionAttribute {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [string]$UserId,

        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter()]
        [ValidateRange(1, 15)]
        [int]$AttributeNumber,

        [switch]$AllowOverwrite
    )

    process {
        Assert-MgGraphConnection
        if ($Value.Trim() -eq '') { throw "Value cannot be empty." }

        $user = Get-MgUserWithExtensionAttributes -UserId $UserId
        $attrs = Resolve-ExtensionAttributes -User $user

        if ($PSBoundParameters.ContainsKey('AttributeNumber')) {
            $index = $AttributeNumber - 1
            $current = $attrs[$index]
            if ($null -ne $current -and $current.ToString().Trim() -ne '') {
                if ($current.ToString().Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [PSCustomObject]@{
                        UserId         = $user.Id
                        UserPrincipalName = $user.UserPrincipalName
                        AddedAttribute = "ExtensionAttribute$AttributeNumber"
                        Value          = $Value
                        Attributes     = $attrs
                    }
                }
                if (-not $AllowOverwrite) {
                    throw "extensionAttribute$AttributeNumber already has a value. Use -AllowOverwrite to replace it."
                }
            }
            if (Test-HasDuplicateAttributeValue -Attributes $attrs -Value $Value -ExcludeIndex $index) {
                throw "Value already exists in extension attributes for user '$UserId'."
            }
            $attrs[$index] = $Value
            $targetSlot = $AttributeNumber
        }
        else {
            if (Test-HasDuplicateAttributeValue -Attributes $attrs -Value $Value) {
                throw "Value already exists in extension attributes for user '$UserId'."
            }
            $index = Find-FirstEmptyAttributeIndex -Attributes $attrs
            if ($index -lt 0) { throw "No empty extensionAttribute slots available for user '$UserId'." }
            $attrs[$index] = $Value
            $targetSlot = $index + 1
        }

        $payload = ConvertTo-ExtensionAttributesHashtable -Attributes $attrs

        if ($PSCmdlet.ShouldProcess($UserId, "Add extensionAttribute$targetSlot")) {
            Update-MgUser -UserId $UserId -OnPremisesExtensionAttributes $payload | Out-Null
        }

        [PSCustomObject]@{
            UserId         = $user.Id
            UserPrincipalName = $user.UserPrincipalName
            AddedAttribute = "ExtensionAttribute$targetSlot"
            Value          = $Value
            Attributes     = $attrs
        }
    }
}

<#[
.SYNOPSIS
Updates an extension attribute value in a specific slot.

.DESCRIPTION
Sets the specified extensionAttribute slot. Will not overwrite an existing
value unless -AllowOverwrite is specified. Prevents duplicates across all 15
extension attributes.

.PARAMETER UserId
User ID or UPN.

.PARAMETER AttributeNumber
Slot number (1-15).

.PARAMETER Value
New value.

.PARAMETER AllowOverwrite
Allows overwriting a populated slot.
#>
function Set-M365ExtensionAttribute {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$UserId,

        [Parameter(Mandatory)]
        [ValidateRange(1, 15)]
        [int]$AttributeNumber,

        [Parameter(Mandatory)]
        [string]$Value,

        [switch]$AllowOverwrite
    )

    Assert-MgGraphConnection
    if ($Value.Trim() -eq '') { throw "Value cannot be empty." }

    $user = Get-MgUserWithExtensionAttributes -UserId $UserId
    $attrs = Resolve-ExtensionAttributes -User $user

    $index = $AttributeNumber - 1
    $current = $attrs[$index]
    if ($null -ne $current -and $current.ToString().Trim() -ne '') {
        if ($current.ToString().Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                UserId         = $user.Id
                UserPrincipalName = $user.UserPrincipalName
                UpdatedAttribute = "ExtensionAttribute$AttributeNumber"
                Value          = $Value
                Attributes     = $attrs
            }
        }
        if (-not $AllowOverwrite) {
            throw "extensionAttribute$AttributeNumber already has a value. Use -AllowOverwrite to replace it."
        }
    }

    if (Test-HasDuplicateAttributeValue -Attributes $attrs -Value $Value -ExcludeIndex $index) {
        throw "Value already exists in extension attributes for user '$UserId'."
    }

    $attrs[$index] = $Value
    $payload = ConvertTo-ExtensionAttributesHashtable -Attributes $attrs

    if ($PSCmdlet.ShouldProcess($UserId, "Set extensionAttribute$AttributeNumber")) {
        Update-MgUser -UserId $UserId -OnPremisesExtensionAttributes $payload | Out-Null
    }

    [PSCustomObject]@{
        UserId         = $user.Id
        UserPrincipalName = $user.UserPrincipalName
        UpdatedAttribute = "ExtensionAttribute$AttributeNumber"
        Value          = $Value
        Attributes     = $attrs
    }
}

<#[
.SYNOPSIS
Removes an extension attribute value and shifts remaining values left.

.DESCRIPTION
Removes a value by slot or by matching value. After removal, all subsequent
attributes shift left to avoid gaps. The last slot becomes empty.

.PARAMETER UserId
User ID or UPN.

.PARAMETER AttributeNumber
Slot number (1-15) to remove.

.PARAMETER Value
Value to remove.
#>
function Remove-M365ExtensionAttribute {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Id')]
        [string]$UserId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidateRange(1, 15)]
        [int]$AttributeNumber,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Value
    )

    process {
        Assert-MgGraphConnection
        if (-not $PSBoundParameters.ContainsKey('AttributeNumber') -and -not $PSBoundParameters.ContainsKey('Value')) {
            throw "Either -AttributeNumber or -Value must be specified."
        }

        $user = Get-MgUserWithExtensionAttributes -UserId $UserId
        $attrs = Resolve-ExtensionAttributes -User $user

        if ($PSBoundParameters.ContainsKey('Value')) {
            $index = Find-AttributeIndexByValue -Attributes $attrs -Value $Value
            if ($index -lt 0) { throw "Value '$Value' not found in extension attributes for user '$UserId'." }
            $attributeLabel = "ExtensionAttribute" + ($index + 1)
        }
        else {
            $index = $AttributeNumber - 1
            $attributeLabel = "ExtensionAttribute$AttributeNumber"
            if ($null -eq $attrs[$index] -or $attrs[$index].ToString().Trim() -eq '') {
                throw "extensionAttribute$AttributeNumber is already empty for user '$UserId'."
            }
        }

        $removedValue = $attrs[$index]
        $newAttrs = Shift-ExtensionAttributesLeft -Attributes $attrs -RemoveIndex $index
        $payload = ConvertTo-ExtensionAttributesHashtable -Attributes $newAttrs

        if ($PSCmdlet.ShouldProcess($UserId, "Remove $attributeLabel ('$removedValue') and shift left")) {
            Update-MgUser -UserId $UserId -OnPremisesExtensionAttributes $payload | Out-Null
        }

        [PSCustomObject]@{
            UserId            = $user.Id
            UserPrincipalName = $user.UserPrincipalName
            RemovedAttribute  = $attributeLabel
            RemovedValue      = $removedValue
            Attributes        = $newAttrs
        }
    }
}

<#[
.SYNOPSIS
Finds users with a matching extension attribute value.

.DESCRIPTION
Searches for users with a matching value across all extensionAttribute slots,
or within a specific slot if AttributeNumber is provided. Supports PowerShell
wildcard characters (* and ?) in the Value parameter. When wildcards are
detected, filtering is performed client-side after fetching all users, which
may be slower on large tenants.

.PARAMETER Value
Value to search for. Supports PowerShell wildcards (* and ?).

.PARAMETER AttributeNumber
Optional specific slot (1-15).

.PARAMETER All
Return all pages of results.
#>
function Find-M365UsersWithExtensionAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter()]
        [ValidateRange(1, 15)]
        [int]$AttributeNumber,

        [switch]$All
    )

    Assert-MgGraphConnection
    if ($Value.Trim() -eq '') { throw "Value cannot be empty." }

    $isWildcard = [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Value)
    $props = 'id,displayName,userPrincipalName,onPremisesExtensionAttributes'

    if ($isWildcard) {
        # Client-side wildcard filtering — fetch users that have any extension attribute set
        $slotNumbers = if ($PSBoundParameters.ContainsKey('AttributeNumber')) {
            @($AttributeNumber)
        } else {
            1..15
        }

        $parts = $slotNumbers | ForEach-Object {
            "onPremisesExtensionAttributes/extensionAttribute$_ ne null"
        }
        $filter = $parts -join ' or '

        $params = @{ Filter = $filter; Property = $props; ConsistencyLevel = 'eventual'; CountVariable = 'userCount' }
        if ($All) { $params['All'] = $true }

        foreach ($user in (Get-MgUser @params)) {
            $attrs = Resolve-ExtensionAttributes -User $user
            $matched = @()
            foreach ($slot in $slotNumbers) {
                $item = $attrs[$slot - 1]
                if ($null -ne $item -and $item.ToString().Trim() -ne '' -and $item.ToString() -like $Value) {
                    $matched += $slot
                }
            }
            foreach ($slot in $matched) {
                [PSCustomObject]@{
                    Id                            = $user.Id
                    UserPrincipalName             = $user.UserPrincipalName
                    DisplayName                   = $user.DisplayName
                    Value                         = $attrs[$slot - 1]
                    AttributeNumber               = $slot
                    OnPremisesExtensionAttributes = $user.OnPremisesExtensionAttributes
                }
            }
        }
    }
    else {
        $safeValue = ConvertTo-ODataStringLiteral -Value $Value

        if ($PSBoundParameters.ContainsKey('AttributeNumber')) {
            $filter = "onPremisesExtensionAttributes/extensionAttribute$AttributeNumber eq '$safeValue'"
        }
        else {
            $parts = @()
            for ($i = 1; $i -le 15; $i++) {
                $parts += "onPremisesExtensionAttributes/extensionAttribute$i eq '$safeValue'"
            }
            $filter = $parts -join ' or '
        }

        $params = @{ Filter = $filter; Property = $props; ConsistencyLevel = 'eventual'; CountVariable = 'userCount' }
        if ($All) { $params['All'] = $true }

        foreach ($user in (Get-MgUser @params)) {
            $attrs = Resolve-ExtensionAttributes -User $user
            $index = Find-AttributeIndexByValue -Attributes $attrs -Value $Value
            [PSCustomObject]@{
                Id                            = $user.Id
                UserPrincipalName             = $user.UserPrincipalName
                DisplayName                   = $user.DisplayName
                Value                         = $Value
                AttributeNumber               = if ($index -ge 0) { $index + 1 } else { $null }
                OnPremisesExtensionAttributes = $user.OnPremisesExtensionAttributes
            }
        }
    }
}

<#[
.SYNOPSIS
Gets all extension attributes for a single user.

.DESCRIPTION
Retrieves extensionAttribute1-15 for the specified user and returns them as a
structured object. Empty slots are returned as null.

.PARAMETER UserId
User ID or UPN.
#>
function Get-M365ExtensionAttributes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Id', 'UserPrincipalName')]
        [string]$UserId
    )

    process {
        Assert-MgGraphConnection
        $user = Get-MgUserWithExtensionAttributes -UserId $UserId
        $attrs = Resolve-ExtensionAttributes -User $user

        $result = [ordered]@{
            Id                = $user.Id
            UserPrincipalName = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
        }
        for ($i = 1; $i -le 15; $i++) {
            $result["ExtensionAttribute$i"] = $attrs[$i - 1]
        }

        [PSCustomObject]$result
    }
}

<#[
.SYNOPSIS
Adds an extension attribute value to multiple users.

.DESCRIPTION
Adds the value to each user, respecting duplicate and overwrite protections.
Returns a result object for each user with success or error details.
#>
function Add-M365ExtensionAttributeBulk {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string[]]$UserIds,

        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter()]
        [ValidateRange(1, 15)]
        [int]$AttributeNumber,

        [switch]$AllowOverwrite
    )

    $results = @()
    foreach ($userId in $UserIds) {
        try {
            $extraParams = @{}
            if ($PSBoundParameters.ContainsKey('AttributeNumber')) { $extraParams['AttributeNumber'] = $AttributeNumber }

            $result = Add-M365ExtensionAttribute -UserId $userId -Value $Value `
                @extraParams -AllowOverwrite:$AllowOverwrite -ErrorAction Stop -WhatIf:$WhatIfPreference
            $results += [PSCustomObject]@{ UserId = $userId; Success = $true; Result = $result; Error = $null }
        }
        catch {
            $results += [PSCustomObject]@{ UserId = $userId; Success = $false; Result = $null; Error = $_.Exception.Message }
        }
    }
    return $results
}

<#[
.SYNOPSIS
Removes an extension attribute from multiple users and shifts left.

.DESCRIPTION
Removes by slot or by value for each user, shifting remaining attributes left.
Returns a result object for each user with success or error details.
#>
function Remove-M365ExtensionAttributeBulk {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByNumber')]
    param(
        [Parameter(Mandatory)]
        [string[]]$UserIds,

        [Parameter(Mandatory, ParameterSetName = 'ByNumber')]
        [ValidateRange(1, 15)]
        [int]$AttributeNumber,

        [Parameter(Mandatory, ParameterSetName = 'ByValue')]
        [string]$Value
    )

    $results = @()
    foreach ($userId in $UserIds) {
        try {
            if ($PSCmdlet.ParameterSetName -eq 'ByValue') {
                $result = Remove-M365ExtensionAttribute -UserId $userId -Value $Value `
                    -ErrorAction Stop -WhatIf:$WhatIfPreference
            }
            else {
                $result = Remove-M365ExtensionAttribute -UserId $userId -AttributeNumber $AttributeNumber `
                    -ErrorAction Stop -WhatIf:$WhatIfPreference
            }

            $results += [PSCustomObject]@{ UserId = $userId; Success = $true; Result = $result; Error = $null }
        }
        catch {
            $results += [PSCustomObject]@{ UserId = $userId; Success = $false; Result = $null; Error = $_.Exception.Message }
        }
    }
    return $results
}

<#[
.SYNOPSIS
Deduplicates, sorts, and compacts extension attributes for one user or all users.

.DESCRIPTION
For each processed user, this function:
  1. Removes duplicate values (case-insensitive; the first occurrence is kept).
  2. Sorts the remaining values in natural order (alphabetical with proper
     numeric ordering, so "Group2" sorts before "Group10").
  3. Compacts the values into consecutive slots starting at extensionAttribute1
     with no gaps (e.g. will never leave extensionAttribute4 empty while
     extensionAttribute5 is populated).

Returns a result object per user showing whether a change was made, how many
duplicates were removed, and the Before/After attribute arrays. Use -WhatIf to
preview changes without writing anything.

.PARAMETER UserId
User ID or UPN of a single user to optimise. Accepts pipeline input.

.PARAMETER All
Process every user in the tenant that has at least one extension attribute set.

.EXAMPLE
Optimize-M365ExtensionAttributes -UserId 'jdoe@contoso.com' -WhatIf

.EXAMPLE
# Process all users; show only those that were actually changed
Optimize-M365ExtensionAttributes -All | Where-Object Changed
#>
function Optimize-M365ExtensionAttributes {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByUser')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByUser',
                   ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Id', 'UserPrincipalName')]
        [string]$UserId,

        [Parameter(Mandatory, ParameterSetName = 'AllUsers')]
        [switch]$All
    )

    begin { Assert-MgGraphConnection }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'AllUsers') {
            $filter = (1..15 | ForEach-Object {
                "onPremisesExtensionAttributes/extensionAttribute$_ ne null"
            }) -join ' or '

            $props = 'id,displayName,userPrincipalName,onPremisesExtensionAttributes'
            Get-MgUser -Filter $filter -Property $props `
                       -ConsistencyLevel 'eventual' -CountVariable 'userCount' -All |
                ForEach-Object { Invoke-ExtensionAttributeOptimize -User $_ -Cmdlet $PSCmdlet }
        }
        else {
            $user = Get-MgUserWithExtensionAttributes -UserId $UserId
            Invoke-ExtensionAttributeOptimize -User $user -Cmdlet $PSCmdlet
        }
    }
}

#endregion
