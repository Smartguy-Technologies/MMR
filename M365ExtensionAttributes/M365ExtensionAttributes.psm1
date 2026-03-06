#region ======== Private Helpers ========

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
    param([object[]]$Attributes, [string]$Value)

    for ($i = 0; $i -lt $Attributes.Count; $i++) {
        $item = $Attributes[$i]
        if ($null -ne $item -and $item.ToString().Trim() -ne '') {
            if ($item.ToString().Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $i
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
or within a specific slot if AttributeNumber is provided.

.PARAMETER Value
Value to search for.

.PARAMETER AttributeNumber
Optional specific slot (1-15).
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

    if ($Value.Trim() -eq '') { throw "Value cannot be empty." }

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

    $props = 'id,displayName,userPrincipalName,onPremisesExtensionAttributes'
    $params = @{ Filter = $filter; Property = $props; ConsistencyLevel = 'eventual'; CountVariable = 'userCount' }
    if ($All) { $params['All'] = $true }

    foreach ($user in (Get-MgUser @params)) {
        $attrs = Resolve-ExtensionAttributes -User $user
        $index = Find-AttributeIndexByValue -Attributes $attrs -Value $Value
        [PSCustomObject]@{
            Id                           = $user.Id
            UserPrincipalName            = $user.UserPrincipalName
            DisplayName                  = $user.DisplayName
            Value                        = $Value
            AttributeNumber              = if ($index -ge 0) { $index + 1 } else { $null }
            OnPremisesExtensionAttributes = $user.OnPremisesExtensionAttributes
        }
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

#endregion
