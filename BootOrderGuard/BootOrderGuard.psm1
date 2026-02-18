function Get-BootOrderInfo {
    [CmdletBinding()]
    param()

    $fwManagerOutput = & bcdedit /enum '{fwbootmgr}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $fwManagerOutput) {
        throw "Unable to read firmware boot manager data. Ensure this is a UEFI system and bcdedit is available."
    }

    $firmwareOutput = & bcdedit /enum firmware 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $firmwareOutput) {
        throw "Unable to enumerate firmware entries."
    }

    $displayOrder = @()
    $capture = $false
    foreach ($line in $fwManagerOutput) {
        if ($line -match '^\s*displayorder\s+(\{[^\}]+\})\s*$') {
            $displayOrder += $Matches[1]
            $capture = $true
            continue
        }

        if ($capture -and $line -match '^\s*(\{[^\}]+\})\s*$') {
            $displayOrder += $Matches[1]
            continue
        }

        if ($capture -and $line.Trim() -eq '') {
            break
        }
    }

    if (-not $displayOrder) {
        throw "No firmware displayorder entries were found."
    }

    $entries = @{}
    $currentId = $null

    foreach ($line in $firmwareOutput) {
        if ($line -match '^\s*identifier\s+(\{[^\}]+\})\s*$') {
            $currentId = $Matches[1]
            if (-not $entries.ContainsKey($currentId)) {
                $entries[$currentId] = [ordered]@{
                    Identifier  = $currentId
                    Description = $null
                    Path        = $null
                }
            }
            continue
        }

        if (-not $currentId) {
            continue
        }

        if ($line -match '^\s*description\s+(.+)$') {
            $entries[$currentId].Description = $Matches[1].Trim()
            continue
        }

        if ($line -match '^\s*path\s+(.+)$') {
            $entries[$currentId].Path = $Matches[1].Trim()
        }
    }

    $rank = 1
    foreach ($id in $displayOrder) {
        $entry = $entries[$id]
        if (-not $entry) {
            $entry = [ordered]@{
                Identifier  = $id
                Description = $null
                Path        = $null
            }
        }

        [PSCustomObject]@{
            Order       = $rank
            Identifier  = $entry.Identifier
            Description = $entry.Description
            Path        = $entry.Path
            IsFirst     = ($rank -eq 1)
        }

        $rank++
    }
}

function Test-NetworkBootFirst {
    [CmdletBinding()]
    param()

    $bootOrder = @(Get-BootOrderInfo)
    if (-not $bootOrder) {
        return $false
    }

    $firstEntry = $bootOrder | Where-Object { $_.IsFirst } | Select-Object -First 1
    if (-not $firstEntry) {
        return $false
    }

    $networkPattern = '(?i)(pxe|network|lan|nic|ipv4|ipv6|iba)'
    $firstText = @($firstEntry.Description, $firstEntry.Path) -join ' '

    return [bool]($firstText -match $networkPattern)
}

function Assert-NetworkBootFirstForRebuild {
    [CmdletBinding()]
    param(
        [switch]$PassThru
    )

    $bootOrder = @(Get-BootOrderInfo)
    $isNetworkFirst = $false

    if ($bootOrder) {
        $firstEntry = $bootOrder | Where-Object { $_.IsFirst } | Select-Object -First 1
        if ($firstEntry) {
            $networkPattern = '(?i)(pxe|network|lan|nic|ipv4|ipv6|iba)'
            $firstText = @($firstEntry.Description, $firstEntry.Path) -join ' '
            $isNetworkFirst = [bool]($firstText -match $networkPattern)
        }
    }

    $result = [PSCustomObject]@{
        IsNetworkFirst = $isNetworkFirst
        FirstEntry     = ($bootOrder | Where-Object { $_.IsFirst } | Select-Object -First 1)
        BootOrder      = $bootOrder
    }

    if (-not $isNetworkFirst) {
        throw "Rebuild tollgate failed: network adapter is not first in firmware boot order."
    }

    if ($PassThru) {
        return $result
    }

    return $true
}

Export-ModuleMember -Function Get-BootOrderInfo, Test-NetworkBootFirst, Assert-NetworkBootFirstForRebuild
