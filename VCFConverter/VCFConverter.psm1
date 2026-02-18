#region ======== Private VCF Parsing (self-contained, no external module required) ========

function pvt_ConvertFrom-VCFPropertyLine {
    param([string]$Line)
    if ($Line -notmatch '^(?:[A-Za-z0-9\-]+\.)?([A-Za-z0-9\-]+)((?:;[^:]*)*):(.*)?$') { return $null }
    $propName = $Matches[1].ToUpper()
    $paramRaw = $Matches[2]
    $value    = $Matches[3]

    $parameters = [ordered]@{}
    if ($paramRaw) {
        foreach ($part in ($paramRaw.TrimStart(';') -split ';')) {
            if ($part -match '^([^=]+)=(.+)$') {
                $pName = $Matches[1].ToUpper()
                $pVals = $Matches[2] -split ','
                if ($parameters.Contains($pName)) { $parameters[$pName] = @($parameters[$pName]) + $pVals }
                else { $parameters[$pName] = $pVals }
            }
            elseif ($part -match '^[A-Za-z0-9]+$') {
                if ($parameters.Contains('TYPE')) { $parameters['TYPE'] = @($parameters['TYPE']) + $part.ToUpper() }
                else { $parameters['TYPE'] = @($part.ToUpper()) }
            }
        }
    }

    $enc = if ($parameters.Contains('ENCODING')) { ($parameters['ENCODING'] | Select-Object -First 1).ToUpper() } else { '' }
    if ($enc -in @('QUOTED-PRINTABLE', 'QP')) {
        $value = [System.Text.RegularExpressions.Regex]::Replace(
            $value, '=([0-9A-Fa-f]{2})',
            { [char][System.Convert]::ToInt32($args[0].Groups[1].Value, 16) })
    }

    if ($propName -notin @('PHOTO', 'LOGO', 'SOUND', 'KEY')) {
        $value = $value -replace '\\n', "`n" -replace '\\N', "`n" `
                        -replace '\\,', ',' -replace '\\;', ';' -replace '\\\\', '\'
    }

    return [PSCustomObject]@{ Name = $propName; Parameters = $parameters; Value = $value }
}

function pvt_Resolve-VCFTypes {
    param([ordered]$Parameters)
    if (-not $Parameters.Contains('TYPE')) { return @() }
    $raw = $Parameters['TYPE']
    if ($raw -is [string]) { $raw = @($raw) }
    return $raw | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }
}

function pvt_Split-VCFComponents {
    param([string]$Value, [int]$Expected = 0)
    $parts = [regex]::Split($Value, '(?<!\\);')
    while ($Expected -gt 0 -and $parts.Count -lt $Expected) { $parts += '' }
    return $parts
}

function pvt_Parse-VCard {
    param([string]$CardText)

    $unfolded = $CardText -replace "`r`n[ `t]", '' -replace "`n[ `t]", '' -replace "`r[ `t]", ''
    $lines = $unfolded -split "`r?`n" |
        Where-Object { $_ -and $_ -notmatch '^BEGIN:VCARD' -and $_ -notmatch '^END:VCARD' }

    $props = $lines | ForEach-Object { pvt_ConvertFrom-VCFPropertyLine $_ } | Where-Object { $_ }

    $c = [PSCustomObject]@{
        FirstName = ''; MiddleName = ''; LastName = ''; NamePrefix = ''; NameSuffix = ''
        FullName = ''; Nickname = ''; Company = ''; Department = ''; JobTitle = ''
        OfficeLocation = ''
        EmailAddresses = [System.Collections.Generic.List[object]]::new()
        PhoneNumbers   = [System.Collections.Generic.List[object]]::new()
        Addresses      = [System.Collections.Generic.List[object]]::new()
        URLs           = [System.Collections.Generic.List[object]]::new()
        IMAddresses    = [System.Collections.Generic.List[object]]::new()
        Birthday = $null; Anniversary = $null; Spouse = ''; Notes = ''
        Categories = @(); Photo = ''
        CustomFields = [ordered]@{}
    }

    $imProtocols  = 'IMPP','X-AIM','X-SKYPE','X-MSN','X-YAHOO','X-JABBER','X-ICQ','X-GOOGLE-TALK','X-MS-IMADDRESS'
    $silentIgnore = 'VERSION','BEGIN','END','REV','UID','PRODID','CLASS','MAILER','X-MS-OL-DESIGN'

    foreach ($p in $props) {
        switch ($p.Name) {
            'FN'       { $c.FullName  = $p.Value }
            'NICKNAME' { $c.Nickname  = $p.Value }
            'TITLE'    { $c.JobTitle  = $p.Value }
            'ROLE'     { if (-not $c.JobTitle) { $c.JobTitle = $p.Value } }
            'NOTE'     { $c.Notes     = $p.Value }
            'PHOTO'    { $c.Photo     = $p.Value }
            'CATEGORIES' { $c.Categories = ($p.Value -split '[,;]') | ForEach-Object { $_.Trim() } }
            'N' {
                $parts = pvt_Split-VCFComponents $p.Value -Expected 5
                $c.LastName = $parts[0]; $c.FirstName = $parts[1]; $c.MiddleName = $parts[2]
                $c.NamePrefix = $parts[3]; $c.NameSuffix = $parts[4]
            }
            'ORG' {
                $parts = pvt_Split-VCFComponents $p.Value -Expected 2
                $c.Company = $parts[0]; $c.Department = $parts[1]
            }
            'EMAIL' {
                $c.EmailAddresses.Add([PSCustomObject]@{
                    Types = pvt_Resolve-VCFTypes $p.Parameters; Address = $p.Value })
            }
            'TEL' {
                $c.PhoneNumbers.Add([PSCustomObject]@{
                    Types = pvt_Resolve-VCFTypes $p.Parameters; Number = $p.Value })
            }
            'ADR' {
                $parts = pvt_Split-VCFComponents $p.Value -Expected 7
                $c.Addresses.Add([PSCustomObject]@{
                    Types = pvt_Resolve-VCFTypes $p.Parameters
                    POBox = $parts[0]; ExtendedAddress = $parts[1]; Street = $parts[2]
                    City  = $parts[3]; State = $parts[4]; PostalCode = $parts[5]; Country = $parts[6]
                })
            }
            'URL' {
                $c.URLs.Add([PSCustomObject]@{
                    Types = pvt_Resolve-VCFTypes $p.Parameters; URL = $p.Value })
            }
            'BDAY' {
                $d = $p.Value -replace '[^0-9\-]', ''
                if ($d -match '^(\d{4})-?(\d{2})-?(\d{2})$') {
                    try { $c.Birthday = [datetime]::ParseExact("$($Matches[1])$($Matches[2])$($Matches[3])", 'yyyyMMdd', $null) } catch { }
                }
            }
            'ANNIVERSARY' {
                $d = $p.Value -replace '[^0-9\-]', ''
                if ($d -match '^(\d{4})-?(\d{2})-?(\d{2})$') {
                    try { $c.Anniversary = [datetime]::ParseExact("$($Matches[1])$($Matches[2])$($Matches[3])", 'yyyyMMdd', $null) } catch { }
                }
            }
            { $_ -in @('X-MS-SPOUSE', 'X-SPOUSE') }   { $c.Spouse = $p.Value }
            { $_ -in $imProtocols } {
                $c.IMAddresses.Add([PSCustomObject]@{
                    Protocol = $p.Name; Types = pvt_Resolve-VCFTypes $p.Parameters; Address = $p.Value })
            }
            { $_ -in $silentIgnore } { }
            default {
                if ($c.CustomFields.Contains($p.Name)) {
                    $existing = $c.CustomFields[$p.Name]
                    if ($existing -is [System.Collections.Generic.List[string]]) { $existing.Add($p.Value) }
                    else {
                        $list = [System.Collections.Generic.List[string]]::new()
                        $list.Add($existing); $list.Add($p.Value)
                        $c.CustomFields[$p.Name] = $list
                    }
                }
                else { $c.CustomFields[$p.Name] = $p.Value }
            }
        }
    }

    if (-not $c.FullName) {
        $c.FullName = (@($c.NamePrefix,$c.FirstName,$c.MiddleName,$c.LastName,$c.NameSuffix) | Where-Object { $_ }) -join ' '
    }
    return $c
}

function pvt_Read-VCF {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $matches_ = [regex]::Matches($raw, 'BEGIN:VCARD[\s\S]*?END:VCARD',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $matches_) { pvt_Parse-VCard -CardText $m.Value }
}

#endregion


#region ======== CSV Builder Helpers ========

# Exact Outlook column order. These names must match Outlook's import template precisely.
$script:OutlookColumns = @(
    'Title', 'First Name', 'Middle Name', 'Last Name', 'Suffix', 'Nickname',
    'Given Yomi', 'Surname Yomi',
    'E-mail Address', 'E-mail 2 Address', 'E-mail 3 Address',
    'Home Phone', 'Home Phone 2',
    'Business Phone', 'Business Phone 2',
    'Mobile Phone', 'Car Phone', 'Other Phone', 'Primary Phone', 'Pager',
    'Business Fax', 'Home Fax', 'Other Fax',
    'Company Main Phone', 'Callback', 'Radio Phone', 'Telex', 'TTY/TDD Phone',
    'IMAddress',
    'Job Title', 'Department', 'Company', 'Office Location',
    "Manager's Name", "Assistant's Name", "Assistant's Phone",
    'Business Street', 'Business Street 2', 'Business Street 3',
    'Business City', 'Business State', 'Business Postal Code', 'Business Country/Region',
    'Home Street', 'Home Street 2', 'Home Street 3',
    'Home City', 'Home State', 'Home Postal Code', 'Home Country/Region',
    'Other Street', 'Other Street 2', 'Other Street 3',
    'Other City', 'Other State', 'Other Postal Code', 'Other Country/Region',
    'Personal Web Page', 'Spouse', 'Schools', 'Hobby', 'Location', 'Web Page',
    'Birthday', 'Anniversary',
    'Notes'
)

function New-OutlookRow {
    $row = [ordered]@{}
    foreach ($col in $script:OutlookColumns) { $row[$col] = '' }
    return $row
}

<#
.SYNOPSIS
Classifies a phone number into one of the Outlook slot buckets.
Returns the bucket name as a string.
#>
function Get-PhoneBucket {
    param([string[]]$Types)
    if ($Types -contains 'PAGER')                                     { return 'Pager' }
    if ($Types -contains 'CAR')                                       { return 'Car' }
    if (($Types -contains 'FAX') -and ($Types -contains 'WORK'))      { return 'WorkFax' }
    if (($Types -contains 'FAX') -and ($Types -contains 'HOME'))      { return 'HomeFax' }
    if ($Types -contains 'FAX')                                       { return 'OtherFax' }
    if ($Types -contains 'CELL' -or $Types -contains 'MOBILE')        { return 'Mobile' }
    if ($Types -contains 'WORK')                                      { return 'Work' }
    if ($Types -contains 'HOME')                                      { return 'Home' }
    return 'Other'
}

<#
.SYNOPSIS
Maps an address object to the three Outlook street/city/state/zip/country columns.
Returns an [ordered] hashtable of the column values.
#>
function Get-AddressFields {
    param(
        [object]$Addr,
        [string]$Prefix   # 'Business', 'Home', or 'Other'
    )
    $fields = [ordered]@{}

    # Street line 1 = primary street, line 2 = extended address, line 3 = PO Box
    $fields["$Prefix Street"]  = $Addr.Street
    $fields["$Prefix Street 2"] = $Addr.ExtendedAddress
    $fields["$Prefix Street 3"] = $Addr.POBox

    $suffix = if ($Prefix -eq 'Business') { 'Country/Region' } else { 'Country/Region' }
    $fields["$Prefix City"]         = $Addr.City
    $fields["$Prefix State"]        = $Addr.State
    $fields["$Prefix Postal Code"]  = $Addr.PostalCode
    $fields["$Prefix Country/Region"] = $Addr.Country

    return $fields
}

<#
.SYNOPSIS
Appends a line to notes, preserving any existing content.
#>
function Append-Note {
    param([string]$Existing, [string]$Addition)
    if (-not $Existing) { return $Addition }
    if (-not $Addition) { return $Existing }
    return "$Existing`n$Addition"
}

#endregion


#region ======== Convert-VCFToCSV ========
<#
.SYNOPSIS
Converts a VCF file (or piped contact objects) to an Outlook-importable CSV.

.DESCRIPTION
Produces a CSV whose column headers exactly match what Outlook's Contact
Import wizard expects, so no manual field mapping is required.

Field mapping strategy:
  - Up to 3 email addresses fill E-mail Address / E-mail 2 Address / E-mail 3 Address.
  - Phone numbers are classified by VCF TYPE and distributed across the
    corresponding Outlook columns. A second Work or Home phone fills the
    "Phone 2" slot. Any beyond that are appended to Notes.
  - The first WORK address fills Business columns, the first HOME address
    fills Home columns, the first remaining address fills Other columns.
    Additional addresses are appended to Notes.
  - Custom X- fields and any non-standard properties stored in CustomFields
    are appended to Notes as "FieldName: Value" lines.
  - The original VCF Notes content (if any) is always kept at the top of
    the Notes column; overflow is appended below, so existing notes are
    never lost or overwritten.

.PARAMETER Path
Path to the source .vcf file.

.PARAMETER InputObject
Contact object(s) piped in (e.g. from Read-VCF in the ContactManagement module).
When both -Path and pipeline input are provided, they are combined.

.PARAMETER OutputPath
Path for the output .csv file. Overwritten if it already exists.

.EXAMPLE
Convert-VCFToCSV -Path 'C:\Exports\contacts.vcf' -OutputPath 'C:\Exports\contacts.csv'

.EXAMPLE
# Works with the ContactManagement module when it is also imported
Import-Module ContactManagement
Read-VCF -Path 'contacts.vcf' | Convert-VCFToCSV -OutputPath 'outlook.csv'
#>
function Convert-VCFToCSV {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(ValueFromPipeline)]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    begin {
        $allContacts = [System.Collections.Generic.List[object]]::new()
    }

    process {
        # Contacts piped in directly
        if ($InputObject) {
            foreach ($obj in $InputObject) { $allContacts.Add($obj) }
        }

        # Contacts from a VCF file path
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            foreach ($c in (pvt_Read-VCF -Path $Path)) { $allContacts.Add($c) }
        }
    }

    end {
        if ($allContacts.Count -eq 0) {
            Write-Warning 'No contacts to convert.'
            return
        }

        $rows = [System.Collections.Generic.List[object]]::new()

        foreach ($c in $allContacts) {

            $row = New-OutlookRow

            # ── Name ──────────────────────────────────────────────────────────
            $row['Title']       = $c.NamePrefix
            $row['First Name']  = $c.FirstName
            $row['Middle Name'] = $c.MiddleName
            $row['Last Name']   = $c.LastName
            $row['Suffix']      = $c.NameSuffix
            $row['Nickname']    = $c.Nickname

            # ── Organization ──────────────────────────────────────────────────
            $row['Company']         = $c.Company
            $row['Department']      = $c.Department
            $row['Job Title']       = $c.JobTitle
            $row['Office Location'] = $c.OfficeLocation

            # ── Spouse ────────────────────────────────────────────────────────
            $row['Spouse'] = $c.Spouse

            # ── Notes: start with original VCF note ───────────────────────────
            $notes = $c.Notes   # may be empty string

            # ── Email addresses ───────────────────────────────────────────────
            # Sort so WORK types come first, then HOME, then rest
            $sortedEmails = @(
                @($c.EmailAddresses | Where-Object { $_.Types -contains 'WORK'  })
                @($c.EmailAddresses | Where-Object { $_.Types -notcontains 'WORK' -and $_.Types -notcontains 'HOME' })
                @($c.EmailAddresses | Where-Object { $_.Types -contains 'HOME'  })
            ) | Where-Object { $_ }

            $emailSlots = @('E-mail Address', 'E-mail 2 Address', 'E-mail 3 Address')
            for ($i = 0; $i -lt $sortedEmails.Count; $i++) {
                if ($i -lt 3) {
                    $row[$emailSlots[$i]] = $sortedEmails[$i].Address
                }
                else {
                    $notes = Append-Note $notes "Email: $($sortedEmails[$i].Address)"
                }
            }

            # ── Phone numbers ─────────────────────────────────────────────────
            $buckets = [ordered]@{
                Work    = [System.Collections.Generic.List[string]]::new()
                Home    = [System.Collections.Generic.List[string]]::new()
                Mobile  = [System.Collections.Generic.List[string]]::new()
                Car     = [System.Collections.Generic.List[string]]::new()
                Pager   = [System.Collections.Generic.List[string]]::new()
                WorkFax = [System.Collections.Generic.List[string]]::new()
                HomeFax = [System.Collections.Generic.List[string]]::new()
                OtherFax = [System.Collections.Generic.List[string]]::new()
                Other   = [System.Collections.Generic.List[string]]::new()
            }
            foreach ($ph in $c.PhoneNumbers) {
                $bucket = Get-PhoneBucket -Types $ph.Types
                $buckets[$bucket].Add($ph.Number)
            }

            # Fill primary slots
            if ($buckets.Work.Count    -ge 1) { $row['Business Phone']   = $buckets.Work[0] }
            if ($buckets.Work.Count    -ge 2) { $row['Business Phone 2'] = $buckets.Work[1] }
            if ($buckets.Home.Count    -ge 1) { $row['Home Phone']       = $buckets.Home[0] }
            if ($buckets.Home.Count    -ge 2) { $row['Home Phone 2']     = $buckets.Home[1] }
            if ($buckets.Mobile.Count  -ge 1) { $row['Mobile Phone']     = $buckets.Mobile[0] }
            if ($buckets.Car.Count     -ge 1) { $row['Car Phone']        = $buckets.Car[0] }
            if ($buckets.Pager.Count   -ge 1) { $row['Pager']            = $buckets.Pager[0] }
            if ($buckets.WorkFax.Count -ge 1) { $row['Business Fax']     = $buckets.WorkFax[0] }
            if ($buckets.HomeFax.Count -ge 1) { $row['Home Fax']         = $buckets.HomeFax[0] }
            if ($buckets.OtherFax.Count -ge 1){ $row['Other Fax']        = $buckets.OtherFax[0] }
            if ($buckets.Other.Count   -ge 1) { $row['Other Phone']      = $buckets.Other[0] }

            # Overflow → Notes
            $overflowPhones = @(
                @{ Label='Business Phone';  Items=$buckets.Work;     Skip=2 }
                @{ Label='Home Phone';      Items=$buckets.Home;     Skip=2 }
                @{ Label='Mobile';          Items=$buckets.Mobile;   Skip=1 }
                @{ Label='Car Phone';       Items=$buckets.Car;      Skip=1 }
                @{ Label='Pager';           Items=$buckets.Pager;    Skip=1 }
                @{ Label='Business Fax';    Items=$buckets.WorkFax;  Skip=1 }
                @{ Label='Home Fax';        Items=$buckets.HomeFax;  Skip=1 }
                @{ Label='Other Fax';       Items=$buckets.OtherFax; Skip=1 }
                @{ Label='Other Phone';     Items=$buckets.Other;    Skip=1 }
            )
            foreach ($bucket in $overflowPhones) {
                if ($bucket.Items.Count -gt $bucket.Skip) {
                    $bucket.Skip..($bucket.Items.Count - 1) | ForEach-Object {
                        $notes = Append-Note $notes "$($bucket.Label): $($bucket.Items[$_])"
                    }
                }
            }

            # ── Addresses ─────────────────────────────────────────────────────
            $workAddr  = $c.Addresses | Where-Object { $_.Types -contains 'WORK'  } | Select-Object -First 1
            $homeAddr  = $c.Addresses | Where-Object { $_.Types -contains 'HOME'  } | Select-Object -First 1
            # First address that's neither WORK nor HOME becomes "Other"
            $otherAddr = $c.Addresses |
                Where-Object { ($_.Types -notcontains 'WORK') -and ($_.Types -notcontains 'HOME') } |
                Select-Object -First 1

            # If there's no HOME and no OTHER but there are more addresses, slot them
            if (-not $homeAddr -and -not $otherAddr) {
                $remaining = @($c.Addresses | Where-Object { $_ -ne $workAddr })
                if ($remaining.Count -ge 1) { $homeAddr  = $remaining[0] }
                if ($remaining.Count -ge 2) { $otherAddr = $remaining[1] }
            }

            if ($workAddr) {
                $af = Get-AddressFields -Addr $workAddr -Prefix 'Business'
                foreach ($k in $af.Keys) { $row[$k] = $af[$k] }
            }
            if ($homeAddr) {
                $af = Get-AddressFields -Addr $homeAddr -Prefix 'Home'
                foreach ($k in $af.Keys) { $row[$k] = $af[$k] }
            }
            if ($otherAddr) {
                $af = Get-AddressFields -Addr $otherAddr -Prefix 'Other'
                foreach ($k in $af.Keys) { $row[$k] = $af[$k] }
            }

            # Extra addresses beyond the three slots
            $usedAddresses = @($workAddr, $homeAddr, $otherAddr) | Where-Object { $_ }
            $extraAddresses = $c.Addresses | Where-Object { $_ -notin $usedAddresses }
            foreach ($addr in $extraAddresses) {
                $label = ($addr.Types | Select-Object -First 1)
                $addrStr = (@($addr.Street, $addr.ExtendedAddress, $addr.POBox, $addr.City,
                              $addr.State, $addr.PostalCode, $addr.Country) | Where-Object { $_ }) -join ', '
                $notes = Append-Note $notes "Additional Address$(if($label){" ($label)"}): $addrStr"
            }

            # ── URLs ──────────────────────────────────────────────────────────
            $homeURL = $c.URLs | Where-Object { $_.Types -contains 'HOME' } | Select-Object -First 1 -ExpandProperty URL
            $workURL = $c.URLs | Where-Object { $_.Types -contains 'WORK' } | Select-Object -First 1 -ExpandProperty URL
            if (-not $homeURL -and -not $workURL -and $c.URLs.Count -gt 0) {
                $homeURL = $c.URLs[0].URL
            }
            $row['Personal Web Page'] = $homeURL
            $row['Web Page']          = $workURL

            $extraURLs = $c.URLs | Where-Object { $_.URL -ne $homeURL -and $_.URL -ne $workURL }
            foreach ($u in $extraURLs) { $notes = Append-Note $notes "URL: $($u.URL)" }

            # ── IM ────────────────────────────────────────────────────────────
            if ($c.IMAddresses.Count -ge 1) { $row['IMAddress'] = $c.IMAddresses[0].Address }
            if ($c.IMAddresses.Count -ge 2) {
                1..($c.IMAddresses.Count - 1) | ForEach-Object {
                    $notes = Append-Note $notes "IM ($($c.IMAddresses[$_].Protocol)): $($c.IMAddresses[$_].Address)"
                }
            }

            # ── Dates ─────────────────────────────────────────────────────────
            if ($c.Birthday)    { $row['Birthday']    = $c.Birthday.ToString('M/d/yyyy') }
            if ($c.Anniversary) { $row['Anniversary'] = $c.Anniversary.ToString('M/d/yyyy') }

            # ── Custom / overflow fields → Notes ──────────────────────────────
            if ($c.CustomFields -and $c.CustomFields.Count -gt 0) {
                $notes = Append-Note $notes ''   # blank separator line
                foreach ($key in $c.CustomFields.Keys) {
                    $val = $c.CustomFields[$key]
                    if ($val -is [System.Collections.Generic.List[string]]) {
                        foreach ($v in $val) { $notes = Append-Note $notes "${key}: $v" }
                    }
                    else {
                        $notes = Append-Note $notes "${key}: $val"
                    }
                }
            }

            $row['Notes'] = $notes

            $rows.Add([PSCustomObject]$row)
        }

        # Write CSV with exact Outlook column headers
        $sb = [System.Text.StringBuilder]::new()

        # Header row
        $headerLine = ($script:OutlookColumns | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ','
        [void]$sb.AppendLine($headerLine)

        # Data rows
        foreach ($row in $rows) {
            $cells = $script:OutlookColumns | ForEach-Object {
                $cell = if ($null -ne $row.$_) { $row.$_ } else { '' }
                # Quote every cell; double any embedded quotes
                '"' + ($cell -replace '"', '""') + '"'
            }
            [void]$sb.AppendLine($cells -join ',')
        }

        [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
        Write-Verbose "Exported $($rows.Count) contact(s) to $OutputPath"
        Write-Host "Exported $($rows.Count) contact(s) to: $OutputPath"
    }
}
#endregion


Export-ModuleMember -Function Convert-VCFToCSV
