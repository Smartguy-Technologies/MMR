#region ======== Private Helpers ========

<#
.SYNOPSIS
Parses one property line from a vCard block.

.DESCRIPTION
Handles grouped properties (item1.EMAIL), bare type tokens (vCard 2.1),
Quoted-Printable decoding, and backslash-escape removal for text values.
Returns $null for lines that cannot be parsed.
#>
function ConvertFrom-VCFPropertyLine {
    param([string]$Line)

    # Pattern: [group.]NAME[;PARAMS]:VALUE
    if ($Line -notmatch '^(?:[A-Za-z0-9\-]+\.)?([A-Za-z0-9\-]+)((?:;[^:]*)*):(.*)?$') {
        return $null
    }

    $propName = $Matches[1].ToUpper()
    $paramRaw = $Matches[2]
    $value    = $Matches[3]

    # Parse parameter list
    $parameters = [ordered]@{}
    if ($paramRaw) {
        foreach ($part in ($paramRaw.TrimStart(';') -split ';')) {
            if ($part -match '^([^=]+)=(.+)$') {
                $pName = $Matches[1].ToUpper()
                $pVals = $Matches[2] -split ','
                if ($parameters.Contains($pName)) {
                    $parameters[$pName] = @($parameters[$pName]) + $pVals
                }
                else {
                    $parameters[$pName] = $pVals
                }
            }
            elseif ($part -match '^[A-Za-z0-9]+$') {
                # Bare token (vCard 2.1 style: TEL;HOME;VOICE:...)
                if ($parameters.Contains('TYPE')) {
                    $parameters['TYPE'] = @($parameters['TYPE']) + $part.ToUpper()
                }
                else {
                    $parameters['TYPE'] = @($part.ToUpper())
                }
            }
        }
    }

    # Decode Quoted-Printable if indicated
    $enc = if ($parameters.Contains('ENCODING')) { ($parameters['ENCODING'] | Select-Object -First 1).ToUpper() } else { '' }
    if ($enc -in @('QUOTED-PRINTABLE', 'QP')) {
        $value = [System.Text.RegularExpressions.Regex]::Replace(
            $value,
            '=([0-9A-Fa-f]{2})',
            { [char][System.Convert]::ToInt32($args[0].Groups[1].Value, 16) }
        )
    }

    # Unescape backslash sequences in text-type properties
    if ($propName -notin @('PHOTO', 'LOGO', 'SOUND', 'KEY')) {
        $value = $value -replace '\\n', "`n" -replace '\\N', "`n"
        $value = $value -replace '\\,', ','
        $value = $value -replace '\\;', ';'
        $value = $value -replace '\\\\', '\'
    }

    return [PSCustomObject]@{
        Name       = $propName
        Parameters = $parameters
        Value      = $value
    }
}

<#
.SYNOPSIS
Returns all TYPE values for a property as a flat, upper-cased string array.
#>
function Resolve-VCFTypes {
    param([ordered]$Parameters)
    if (-not $Parameters.Contains('TYPE')) { return @() }
    $raw = $Parameters['TYPE']
    if ($raw -is [string]) { $raw = @($raw) }
    return $raw | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }
}

<#
.SYNOPSIS
Splits a structured VCF value (N, ADR, ORG) on unescaped semicolons.
#>
function Split-VCFComponents {
    param([string]$Value, [int]$Expected = 0)
    $parts = [regex]::Split($Value, '(?<!\\);')
    # Ensure we have at least $Expected elements
    while ($Expected -gt 0 -and $parts.Count -lt $Expected) { $parts += '' }
    return $parts
}

<#
.SYNOPSIS
Escapes a plain string for use as a vCard text property value.
#>
function ConvertTo-VCFText {
    param([string]$Value)
    if (-not $Value) { return '' }
    return $Value `
        -replace '\\', '\\' `
        -replace ';',  '\;' `
        -replace ',',  '\,' `
        -replace "`r`n", '\n' `
        -replace "`n", '\n' `
        -replace "`r", '\n'
}

<#
.SYNOPSIS
Folds a long vCard property line at 75 octets as required by RFC 6350.
#>
function Format-VCFLine {
    param([string]$Line)
    if ($Line.Length -le 75) { return $Line }
    $sb = [System.Text.StringBuilder]::new()
    $pos = 0
    $first = $true
    while ($pos -lt $Line.Length) {
        $take = if ($first) { 75 } else { 74 }
        if ($pos + $take -gt $Line.Length) { $take = $Line.Length - $pos }
        if (-not $first) { [void]$sb.Append("`r`n ") }
        [void]$sb.Append($Line.Substring($pos, $take))
        $pos += $take
        $first = $false
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
Creates a new empty contact object used as the standard exchange format across this module.
#>
function New-ContactObject {
    return [PSCustomObject]@{
        FirstName      = ''
        MiddleName     = ''
        LastName       = ''
        NamePrefix     = ''   # Mr., Dr., etc.
        NameSuffix     = ''   # Jr., Sr., III, etc.
        FullName       = ''
        Nickname       = ''
        Company        = ''
        Department     = ''
        JobTitle       = ''
        OfficeLocation = ''
        # Arrays of [PSCustomObject]@{Types=@(); Address=''}
        EmailAddresses = [System.Collections.Generic.List[object]]::new()
        # Arrays of [PSCustomObject]@{Types=@(); Number=''}
        PhoneNumbers   = [System.Collections.Generic.List[object]]::new()
        # Arrays of [PSCustomObject]@{Types; POBox; ExtendedAddress; Street; City; State; PostalCode; Country}
        Addresses      = [System.Collections.Generic.List[object]]::new()
        # Arrays of [PSCustomObject]@{Types=@(); URL=''}
        URLs           = [System.Collections.Generic.List[object]]::new()
        # Arrays of [PSCustomObject]@{Protocol=''; Types=@(); Address=''}
        IMAddresses    = [System.Collections.Generic.List[object]]::new()
        Birthday       = $null
        Anniversary    = $null
        Spouse         = ''
        Notes          = ''
        Categories     = @()
        Photo          = ''   # Base64 string or data URI
        # Ordered dict of unrecognised X-* and extended properties
        CustomFields   = [ordered]@{}
    }
}

<#
.SYNOPSIS
Converts an unfolded vCard text block into a contact object.
#>
function ConvertFrom-VCard {
    param([string]$CardText)

    # Unfold continuation lines (RFC 6350 §3.2)
    $unfolded = $CardText `
        -replace "`r`n[ `t]", '' `
        -replace "`n[ `t]",   '' `
        -replace "`r[ `t]",   ''

    $lines = $unfolded -split "`r?`n" |
        Where-Object { $_ -and $_ -notmatch '^BEGIN:VCARD' -and $_ -notmatch '^END:VCARD' }

    $props = $lines |
        ForEach-Object { ConvertFrom-VCFPropertyLine -Line $_ } |
        Where-Object { $_ }

    $c = New-ContactObject

    # Properties whose excess values go to Notes
    $imProtocols = 'IMPP','X-AIM','X-SKYPE','X-MSN','X-YAHOO','X-JABBER','X-ICQ','X-GOOGLE-TALK','X-MS-IMADDRESS'
    # Properties silently ignored (internal vCard metadata)
    $silentIgnore = 'VERSION','BEGIN','END','REV','UID','PRODID','CLASS','MAILER','X-MS-OL-DESIGN'

    foreach ($p in $props) {
        switch ($p.Name) {
            'FN'       { $c.FullName  = $p.Value }
            'NICKNAME' { $c.Nickname  = $p.Value }
            'TITLE'    { $c.JobTitle  = $p.Value }
            'ROLE'     { if (-not $c.JobTitle) { $c.JobTitle = $p.Value } }
            'NOTE'     { $c.Notes     = $p.Value }
            'PHOTO'    { $c.Photo     = $p.Value }
            'CATEGORIES' {
                $c.Categories = ($p.Value -split '[,;]') | ForEach-Object { $_.Trim() }
            }
            'N' {
                $parts = Split-VCFComponents $p.Value -Expected 5
                $c.LastName   = $parts[0]
                $c.FirstName  = $parts[1]
                $c.MiddleName = $parts[2]
                $c.NamePrefix = $parts[3]
                $c.NameSuffix = $parts[4]
            }
            'ORG' {
                $parts = Split-VCFComponents $p.Value -Expected 2
                $c.Company    = $parts[0]
                $c.Department = $parts[1]
            }
            'EMAIL' {
                $c.EmailAddresses.Add([PSCustomObject]@{
                    Types   = Resolve-VCFTypes $p.Parameters
                    Address = $p.Value
                })
            }
            'TEL' {
                $c.PhoneNumbers.Add([PSCustomObject]@{
                    Types  = Resolve-VCFTypes $p.Parameters
                    Number = $p.Value
                })
            }
            'ADR' {
                $parts = Split-VCFComponents $p.Value -Expected 7
                $c.Addresses.Add([PSCustomObject]@{
                    Types           = Resolve-VCFTypes $p.Parameters
                    POBox           = $parts[0]
                    ExtendedAddress = $parts[1]
                    Street          = $parts[2]
                    City            = $parts[3]
                    State           = $parts[4]
                    PostalCode      = $parts[5]
                    Country         = $parts[6]
                })
            }
            'URL' {
                $c.URLs.Add([PSCustomObject]@{
                    Types = Resolve-VCFTypes $p.Parameters
                    URL   = $p.Value
                })
            }
            'BDAY' {
                $d = $p.Value -replace '[^0-9\-]', ''
                if ($d -match '^(\d{4})-?(\d{2})-?(\d{2})$') {
                    try { $c.Birthday = [datetime]::ParseExact("$($Matches[1])$($Matches[2])$($Matches[3])", 'yyyyMMdd', $null) }
                    catch { }
                }
            }
            'ANNIVERSARY' {
                $d = $p.Value -replace '[^0-9\-]', ''
                if ($d -match '^(\d{4})-?(\d{2})-?(\d{2})$') {
                    try { $c.Anniversary = [datetime]::ParseExact("$($Matches[1])$($Matches[2])$($Matches[3])", 'yyyyMMdd', $null) }
                    catch { }
                }
            }
            { $_ -in @('X-MS-SPOUSE', 'X-SPOUSE') } {
                $c.Spouse = $p.Value
            }
            { $_ -in $imProtocols } {
                $c.IMAddresses.Add([PSCustomObject]@{
                    Protocol = $p.Name
                    Types    = Resolve-VCFTypes $p.Parameters
                    Address  = $p.Value
                })
            }
            { $_ -in $silentIgnore } { <# skip #> }
            default {
                # Everything else is stored as a custom field
                if ($c.CustomFields.Contains($p.Name)) {
                    $existing = $c.CustomFields[$p.Name]
                    if ($existing -is [System.Collections.Generic.List[string]]) {
                        $existing.Add($p.Value)
                    }
                    else {
                        $list = [System.Collections.Generic.List[string]]::new()
                        $list.Add($existing)
                        $list.Add($p.Value)
                        $c.CustomFields[$p.Name] = $list
                    }
                }
                else {
                    $c.CustomFields[$p.Name] = $p.Value
                }
            }
        }
    }

    # Build FullName from N components when FN is missing
    if (-not $c.FullName) {
        $c.FullName = (@($c.NamePrefix, $c.FirstName, $c.MiddleName, $c.LastName, $c.NameSuffix) |
            Where-Object { $_ }) -join ' '
    }

    return $c
}

#endregion Private Helpers


#region ======== Read-VCF ========
<#
.SYNOPSIS
Reads one or more vCards from a .vcf file and returns structured contact objects.

.DESCRIPTION
Parses VCF/vCard files (versions 2.1, 3.0, and 4.0) into PSCustomObjects.
Each object exposes properties for name, organization, email addresses,
phone numbers, addresses, URLs, IM handles, notes, and any custom X- fields.

Standard fields are mapped to named properties. Additional values that exceed
the primary slots (e.g. a fourth email address, or a non-standard X- property)
are captured in the CustomFields ordered dictionary.

.PARAMETER Path
Full path to the .vcf file. Multiple vCards in a single file are all returned.

.EXAMPLE
$contacts = Read-VCF -Path 'C:\Contacts\export.vcf'
$contacts | Select-Object FullName, Company

.EXAMPLE
Read-VCF -Path '.\contacts.vcf' | Write-OutlookContact
#>
function Read-VCF {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path
    )

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Error "File not found: $Path"
            return
        }

        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)

        $cardMatches = [regex]::Matches($raw, 'BEGIN:VCARD[\s\S]*?END:VCARD',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if ($cardMatches.Count -eq 0) {
            Write-Warning "No vCard blocks found in: $Path"
            return
        }

        foreach ($m in $cardMatches) {
            ConvertFrom-VCard -CardText $m.Value
        }
    }
}
#endregion


#region ======== Write-VCF ========
<#
.SYNOPSIS
Writes one or more contact objects to a VCF (vCard 3.0) file.

.DESCRIPTION
Accepts contact objects as produced by Read-VCF, Read-OutlookContact, or
manually constructed PSCustomObjects that share the same schema. Each contact
becomes a BEGIN:VCARD … END:VCARD block in the output file.

Long lines are folded at 75 octets per RFC 6350. Text values are backslash-
escaped. Custom fields stored in CustomFields are written back verbatim.

.PARAMETER Contact
One or more contact objects from the pipeline or -Contact parameter.

.PARAMETER Path
Destination file path. Created or overwritten unless -Append is specified.

.PARAMETER Append
Add vCards to an existing file rather than overwriting it.

.EXAMPLE
Read-VCF -Path 'in.vcf' | Write-VCF -Path 'out.vcf'

.EXAMPLE
Read-OutlookContact | Write-VCF -Path 'backup.vcf'
#>
function Write-VCF {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Contact,

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$Append
    )

    begin {
        $lines = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($c in $Contact) {
            $lines.Add('BEGIN:VCARD')
            $lines.Add('VERSION:3.0')

            # FN
            $fn = if ($c.FullName) { $c.FullName }
                  else { (@($c.NamePrefix,$c.FirstName,$c.MiddleName,$c.LastName,$c.NameSuffix) | Where-Object { $_ }) -join ' ' }
            $lines.Add((Format-VCFLine "FN:$(ConvertTo-VCFText $fn)"))

            # N
            $lines.Add((Format-VCFLine ("N:{0};{1};{2};{3};{4}" -f
                (ConvertTo-VCFText $c.LastName),
                (ConvertTo-VCFText $c.FirstName),
                (ConvertTo-VCFText $c.MiddleName),
                (ConvertTo-VCFText $c.NamePrefix),
                (ConvertTo-VCFText $c.NameSuffix))))

            if ($c.Nickname)       { $lines.Add("NICKNAME:$(ConvertTo-VCFText $c.Nickname)") }
            if ($c.Company -or $c.Department) {
                $lines.Add((Format-VCFLine "ORG:$(ConvertTo-VCFText $c.Company);$(ConvertTo-VCFText $c.Department)"))
            }
            if ($c.JobTitle)       { $lines.Add("TITLE:$(ConvertTo-VCFText $c.JobTitle)") }
            if ($c.OfficeLocation) { $lines.Add("X-MS-OFFICE:$(ConvertTo-VCFText $c.OfficeLocation)") }

            foreach ($email in $c.EmailAddresses) {
                $t = if ($email.Types) { ";TYPE=$($email.Types -join ',')" } else { '' }
                $lines.Add("EMAIL${t}:$($email.Address)")
            }

            foreach ($phone in $c.PhoneNumbers) {
                $t = if ($phone.Types) { ";TYPE=$($phone.Types -join ',')" } else { '' }
                $lines.Add("TEL${t}:$($phone.Number)")
            }

            foreach ($addr in $c.Addresses) {
                $t = if ($addr.Types) { ";TYPE=$($addr.Types -join ',')" } else { '' }
                $lines.Add((Format-VCFLine ("ADR${t}:{0};{1};{2};{3};{4};{5};{6}" -f
                    (ConvertTo-VCFText $addr.POBox),
                    (ConvertTo-VCFText $addr.ExtendedAddress),
                    (ConvertTo-VCFText $addr.Street),
                    (ConvertTo-VCFText $addr.City),
                    (ConvertTo-VCFText $addr.State),
                    (ConvertTo-VCFText $addr.PostalCode),
                    (ConvertTo-VCFText $addr.Country))))
            }

            foreach ($url in $c.URLs) {
                $t = if ($url.Types) { ";TYPE=$($url.Types -join ',')" } else { '' }
                $lines.Add("URL${t}:$($url.URL)")
            }

            foreach ($im in $c.IMAddresses) {
                $t = if ($im.Types) { ";TYPE=$($im.Types -join ',')" } else { '' }
                $lines.Add("$($im.Protocol)${t}:$($im.Address)")
            }

            if ($c.Birthday)    { $lines.Add("BDAY:$($c.Birthday.ToString('yyyy-MM-dd'))") }
            if ($c.Anniversary) { $lines.Add("ANNIVERSARY:$($c.Anniversary.ToString('yyyy-MM-dd'))") }
            if ($c.Spouse)      { $lines.Add("X-MS-SPOUSE:$(ConvertTo-VCFText $c.Spouse)") }

            if ($c.Categories -and $c.Categories.Count -gt 0) {
                $lines.Add("CATEGORIES:$($c.Categories -join ',')")
            }

            if ($c.Notes) {
                # Newlines in NOTE values are represented as \n in vCard 3.0
                $noteEsc = (ConvertTo-VCFText $c.Notes)
                $lines.Add((Format-VCFLine "NOTE:$noteEsc"))
            }

            foreach ($key in $c.CustomFields.Keys) {
                $val = $c.CustomFields[$key]
                if ($val -is [System.Collections.Generic.List[string]]) {
                    foreach ($v in $val) { $lines.Add((Format-VCFLine "${key}:$(ConvertTo-VCFText $v)")) }
                }
                else {
                    $lines.Add((Format-VCFLine "${key}:$(ConvertTo-VCFText $val)"))
                }
            }

            $lines.Add('END:VCARD')
            $lines.Add('')
        }
    }

    end {
        if ($PSCmdlet.ShouldProcess($Path, 'Write VCF')) {
            $content = $lines -join "`r`n"
            if ($Append -and (Test-Path -LiteralPath $Path)) {
                [System.IO.File]::AppendAllText($Path, $content, [System.Text.Encoding]::UTF8)
            }
            else {
                [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::UTF8)
            }
            Write-Verbose "Wrote $($lines | Where-Object { $_ -eq 'BEGIN:VCARD' } | Measure-Object | Select-Object -ExpandProperty Count) vCard(s) to $Path"
        }
    }
}
#endregion


#region ======== Read-OutlookContact ========
<#
.SYNOPSIS
Reads contacts from the Outlook default Contacts folder via COM automation.

.DESCRIPTION
Opens an Outlook COM session and iterates every ContactItem in the default
Contacts folder, returning each as a contact object compatible with Write-VCF
and Convert-VCFToCSV. Requires Outlook to be installed.

.PARAMETER Filter
An optional Outlook DASL/Jet filter string to limit which contacts are returned.
Example: "[LastName] = 'Smith'"

.EXAMPLE
Read-OutlookContact | Write-VCF -Path 'C:\Backup\contacts.vcf'

.EXAMPLE
Read-OutlookContact -Filter "[CompanyName] = 'Acme'"
#>
function Read-OutlookContact {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [string]$Filter
    )

    $outlook   = $null
    $namespace = $null
    $folder    = $null

    try {
        $outlook = New-Object -ComObject Outlook.Application -ErrorAction Stop
    }
    catch {
        Write-Error "Could not connect to Outlook. Ensure Outlook is installed and a profile is configured. Error: $_"
        return
    }

    try {
        $namespace = $outlook.GetNamespace('MAPI')
        $folder    = $namespace.GetDefaultFolder(10)  # 10 = olFolderContacts

        $items = if ($Filter) { $folder.Items.Restrict($Filter) } else { $folder.Items }

        foreach ($item in $items) {
            if ($item.Class -ne 40) { continue }  # 40 = olContact

            $c = New-ContactObject
            $c.NamePrefix     = $item.Title
            $c.FirstName      = $item.FirstName
            $c.MiddleName     = $item.MiddleName
            $c.LastName       = $item.LastName
            $c.NameSuffix     = $item.Suffix
            $c.FullName       = $item.FullName
            $c.Nickname       = $item.NickName
            $c.Company        = $item.CompanyName
            $c.Department     = $item.Department
            $c.JobTitle       = $item.JobTitle
            $c.OfficeLocation = $item.OfficeLocation
            $c.Spouse         = $item.SpouseName
            $c.Notes          = $item.Body
            $c.Categories     = if ($item.Categories) { $item.Categories -split ',\s*' } else { @() }

            # Emails
            foreach ($pair in @(
                @{Addr=$item.Email1Address; Types=@('INTERNET')},
                @{Addr=$item.Email2Address; Types=@('INTERNET')},
                @{Addr=$item.Email3Address; Types=@('INTERNET')}
            )) {
                if ($pair.Addr) {
                    $c.EmailAddresses.Add([PSCustomObject]@{ Types=$pair.Types; Address=$pair.Addr })
                }
            }

            # Phones — map Outlook properties to VCF type arrays
            $phoneMap = [ordered]@{
                BusinessTelephoneNumber  = @('WORK','VOICE')
                Business2TelephoneNumber = @('WORK','VOICE')
                HomeTelephoneNumber      = @('HOME','VOICE')
                Home2TelephoneNumber     = @('HOME','VOICE')
                MobileTelephoneNumber    = @('CELL')
                CarTelephoneNumber       = @('CAR')
                OtherTelephoneNumber     = @('OTHER')
                PagerNumber              = @('PAGER')
                BusinessFaxNumber        = @('WORK','FAX')
                HomeFaxNumber            = @('HOME','FAX')
                OtherFaxNumber           = @('OTHER','FAX')
                AssistantTelephoneNumber = @('WORK')
                CompanyMainTelephoneNumber = @('WORK')
            }
            foreach ($prop in $phoneMap.Keys) {
                $num = $item.$prop
                if ($num) {
                    $c.PhoneNumbers.Add([PSCustomObject]@{ Types=$phoneMap[$prop]; Number=$num })
                }
            }

            # Addresses
            foreach ($addrSet in @(
                @{Types=@('WORK'); Street=$item.BusinessAddressStreet; City=$item.BusinessAddressCity; State=$item.BusinessAddressState; Zip=$item.BusinessAddressPostalCode; Country=$item.BusinessAddressCountry; PO=''; Ext=''},
                @{Types=@('HOME'); Street=$item.HomeAddressStreet; City=$item.HomeAddressCity; State=$item.HomeAddressState; Zip=$item.HomeAddressPostalCode; Country=$item.HomeAddressCountry; PO=''; Ext=''},
                @{Types=@('OTHER'); Street=$item.OtherAddressStreet; City=$item.OtherAddressCity; State=$item.OtherAddressState; Zip=$item.OtherAddressPostalCode; Country=$item.OtherAddressCountry; PO=''; Ext=''}
            )) {
                if ($addrSet.Street -or $addrSet.City -or $addrSet.Zip) {
                    $c.Addresses.Add([PSCustomObject]@{
                        Types           = $addrSet.Types
                        POBox           = $addrSet.PO
                        ExtendedAddress = $addrSet.Ext
                        Street          = $addrSet.Street
                        City            = $addrSet.City
                        State           = $addrSet.State
                        PostalCode      = $addrSet.Zip
                        Country         = $addrSet.Country
                    })
                }
            }

            # URLs
            if ($item.PersonalHomePage) {
                $c.URLs.Add([PSCustomObject]@{ Types=@('HOME'); URL=$item.PersonalHomePage })
            }
            if ($item.BusinessHomePage) {
                $c.URLs.Add([PSCustomObject]@{ Types=@('WORK'); URL=$item.BusinessHomePage })
            }

            # IM
            if ($item.IMAddress) {
                $c.IMAddresses.Add([PSCustomObject]@{ Protocol='X-MS-IMADDRESS'; Types=@(); Address=$item.IMAddress })
            }

            # Dates — Outlook stores unset dates as year 4501
            if ($item.Birthday.Year -ne 4501 -and $item.Birthday.Year -gt 1900) {
                $c.Birthday = $item.Birthday
            }
            if ($item.Anniversary.Year -ne 4501 -and $item.Anniversary.Year -gt 1900) {
                $c.Anniversary = $item.Anniversary
            }

            $c
        }
    }
    catch {
        Write-Error "Error reading Outlook contacts: $_"
    }
    finally {
        foreach ($obj in @($folder, $namespace, $outlook)) {
            if ($obj) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch { }
            }
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}
#endregion


#region ======== Write-OutlookContact ========
<#
.SYNOPSIS
Creates or updates contacts in the Outlook default Contacts folder via COM.

.DESCRIPTION
Accepts contact objects from the pipeline (as produced by Read-VCF or
Read-OutlookContact) and writes them to Outlook. By default each contact
is always created as a new entry. Use -Overwrite to search for an existing
contact with the same full name and update it instead.

Phone, email, and address slots beyond what Outlook's ContactItem supports
are appended to the contact's Notes field so no information is lost.

.PARAMETER Contact
One or more contact objects from the pipeline or -Contact parameter.

.PARAMETER Overwrite
If a contact with the same FullName already exists, update it instead of
creating a duplicate.

.EXAMPLE
Read-VCF -Path 'contacts.vcf' | Write-OutlookContact

.EXAMPLE
Read-VCF -Path 'updated.vcf' | Write-OutlookContact -Overwrite
#>
function Write-OutlookContact {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$Contact,

        [switch]$Overwrite
    )

    begin {
        $outlook   = $null
        $namespace = $null
        $folder    = $null

        try {
            $outlook   = New-Object -ComObject Outlook.Application -ErrorAction Stop
            $namespace = $outlook.GetNamespace('MAPI')
            $folder    = $namespace.GetDefaultFolder(10)
        }
        catch {
            Write-Error "Could not connect to Outlook: $_"
            return
        }
    }

    process {
        foreach ($c in $Contact) {
            $fn = if ($c.FullName) { $c.FullName }
                  else { (@($c.NamePrefix,$c.FirstName,$c.MiddleName,$c.LastName,$c.NameSuffix) | Where-Object { $_ }) -join ' ' }

            if (-not $PSCmdlet.ShouldProcess($fn, 'Write to Outlook Contacts')) { continue }

            # Find existing or create new
            $item = $null
            if ($Overwrite -and $fn) {
                try {
                    $item = $folder.Items.Find("[FullName] = '$($fn -replace "'","''")'")
                }
                catch { }
            }
            if (-not $item) {
                $item = $folder.Items.Add()  # adds an olContactItem by default
            }

            $item.Title      = $c.NamePrefix
            $item.FirstName  = $c.FirstName
            $item.MiddleName = $c.MiddleName
            $item.LastName   = $c.LastName
            $item.Suffix     = $c.NameSuffix
            $item.NickName   = $c.Nickname
            $item.CompanyName   = $c.Company
            $item.Department    = $c.Department
            $item.JobTitle      = $c.JobTitle
            $item.OfficeLocation = $c.OfficeLocation
            $item.SpouseName    = $c.Spouse
            if ($c.Categories) { $item.Categories = $c.Categories -join ', ' }

            # Emails (Outlook supports 3)
            $emails = @($c.EmailAddresses)
            if ($emails.Count -ge 1) { $item.Email1Address = $emails[0].Address }
            if ($emails.Count -ge 2) { $item.Email2Address = $emails[1].Address }
            if ($emails.Count -ge 3) { $item.Email3Address = $emails[2].Address }

            # Phones — classify by type, fill Outlook slots, overflow to notes
            $overflow = [System.Collections.Generic.List[string]]::new()
            $slots = [ordered]@{
                WorkVoice  = [System.Collections.Generic.List[string]]::new()
                HomeVoice  = [System.Collections.Generic.List[string]]::new()
                Cell       = [System.Collections.Generic.List[string]]::new()
                Car        = [System.Collections.Generic.List[string]]::new()
                Pager      = [System.Collections.Generic.List[string]]::new()
                WorkFax    = [System.Collections.Generic.List[string]]::new()
                HomeFax    = [System.Collections.Generic.List[string]]::new()
                OtherFax   = [System.Collections.Generic.List[string]]::new()
                Other      = [System.Collections.Generic.List[string]]::new()
            }
            foreach ($ph in $c.PhoneNumbers) {
                $t = $ph.Types
                if     ($t -contains 'PAGER')                       { $slots.Pager.Add($ph.Number) }
                elseif ($t -contains 'CAR')                         { $slots.Car.Add($ph.Number) }
                elseif (($t -contains 'FAX') -and ($t -contains 'WORK')) { $slots.WorkFax.Add($ph.Number) }
                elseif (($t -contains 'FAX') -and ($t -contains 'HOME')) { $slots.HomeFax.Add($ph.Number) }
                elseif ($t -contains 'FAX')                         { $slots.OtherFax.Add($ph.Number) }
                elseif ($t -contains 'CELL' -or $t -contains 'MOBILE') { $slots.Cell.Add($ph.Number) }
                elseif ($t -contains 'WORK')                        { $slots.WorkVoice.Add($ph.Number) }
                elseif ($t -contains 'HOME')                        { $slots.HomeVoice.Add($ph.Number) }
                else                                                { $slots.Other.Add($ph.Number) }
            }

            if ($slots.WorkVoice.Count -ge 1) { $item.BusinessTelephoneNumber  = $slots.WorkVoice[0] }
            if ($slots.WorkVoice.Count -ge 2) { $item.Business2TelephoneNumber = $slots.WorkVoice[1] }
            if ($slots.WorkVoice.Count -ge 3) {
                1..($slots.WorkVoice.Count-1) | Where-Object { $_ -ge 2 } |
                    ForEach-Object { $overflow.Add("Business Phone: $($slots.WorkVoice[$_])") }
            }

            if ($slots.HomeVoice.Count -ge 1) { $item.HomeTelephoneNumber  = $slots.HomeVoice[0] }
            if ($slots.HomeVoice.Count -ge 2) { $item.Home2TelephoneNumber = $slots.HomeVoice[1] }
            if ($slots.HomeVoice.Count -ge 3) {
                2..($slots.HomeVoice.Count-1) | ForEach-Object { $overflow.Add("Home Phone: $($slots.HomeVoice[$_])") }
            }

            if ($slots.Cell.Count -ge 1)    { $item.MobileTelephoneNumber  = $slots.Cell[0] }
            if ($slots.Cell.Count -ge 2)    { 1..($slots.Cell.Count-1) | ForEach-Object { $overflow.Add("Mobile: $($slots.Cell[$_])") } }

            if ($slots.Car.Count -ge 1)     { $item.CarTelephoneNumber     = $slots.Car[0] }
            if ($slots.Car.Count -ge 2)     { 1..($slots.Car.Count-1) | ForEach-Object { $overflow.Add("Car Phone: $($slots.Car[$_])") } }

            if ($slots.Pager.Count -ge 1)   { $item.PagerNumber            = $slots.Pager[0] }
            if ($slots.Pager.Count -ge 2)   { 1..($slots.Pager.Count-1) | ForEach-Object { $overflow.Add("Pager: $($slots.Pager[$_])") } }

            if ($slots.WorkFax.Count -ge 1) { $item.BusinessFaxNumber      = $slots.WorkFax[0] }
            if ($slots.WorkFax.Count -ge 2) { 1..($slots.WorkFax.Count-1) | ForEach-Object { $overflow.Add("Business Fax: $($slots.WorkFax[$_])") } }

            if ($slots.HomeFax.Count -ge 1) { $item.HomeFaxNumber          = $slots.HomeFax[0] }
            if ($slots.HomeFax.Count -ge 2) { 1..($slots.HomeFax.Count-1) | ForEach-Object { $overflow.Add("Home Fax: $($slots.HomeFax[$_])") } }

            if ($slots.OtherFax.Count -ge 1) { $item.OtherFaxNumber        = $slots.OtherFax[0] }
            if ($slots.Other.Count -ge 1)    { $item.OtherTelephoneNumber  = $slots.Other[0] }
            foreach ($n in (@($slots.OtherFax | Select-Object -Skip 1) + @($slots.Other | Select-Object -Skip 1))) {
                $overflow.Add("Other Phone: $n")
            }

            # Addresses — first WORK, first HOME, first OTHER
            $workAddr  = $c.Addresses | Where-Object { $_.Types -contains 'WORK'  } | Select-Object -First 1
            $homeAddr  = $c.Addresses | Where-Object { $_.Types -contains 'HOME'  } | Select-Object -First 1
            $otherAddr = $c.Addresses | Where-Object { $_.Types -notcontains 'WORK' -and $_.Types -notcontains 'HOME' } | Select-Object -First 1
            $extraAddr = $c.Addresses | Select-Object -Skip (
                ($workAddr ? 1 : 0) + ($homeAddr ? 1 : 0) + ($otherAddr ? 1 : 0)
            )

            if ($workAddr) {
                $item.BusinessAddressStreet     = (@($workAddr.Street, $workAddr.ExtendedAddress, $workAddr.POBox) | Where-Object { $_ }) -join "`n"
                $item.BusinessAddressCity       = $workAddr.City
                $item.BusinessAddressState      = $workAddr.State
                $item.BusinessAddressPostalCode = $workAddr.PostalCode
                $item.BusinessAddressCountry    = $workAddr.Country
            }
            if ($homeAddr) {
                $item.HomeAddressStreet     = (@($homeAddr.Street, $homeAddr.ExtendedAddress, $homeAddr.POBox) | Where-Object { $_ }) -join "`n"
                $item.HomeAddressCity       = $homeAddr.City
                $item.HomeAddressState      = $homeAddr.State
                $item.HomeAddressPostalCode = $homeAddr.PostalCode
                $item.HomeAddressCountry    = $homeAddr.Country
            }
            if ($otherAddr) {
                $item.OtherAddressStreet     = (@($otherAddr.Street, $otherAddr.ExtendedAddress, $otherAddr.POBox) | Where-Object { $_ }) -join "`n"
                $item.OtherAddressCity       = $otherAddr.City
                $item.OtherAddressState      = $otherAddr.State
                $item.OtherAddressPostalCode = $otherAddr.PostalCode
                $item.OtherAddressCountry    = $otherAddr.Country
            }
            foreach ($a in $extraAddr) {
                $addrStr = (@($a.Street, $a.City, $a.State, $a.PostalCode, $a.Country) | Where-Object { $_ }) -join ', '
                $overflow.Add("Additional Address: $addrStr")
            }

            # Emails beyond slot 3 to notes
            if ($emails.Count -ge 4) {
                3..($emails.Count-1) | ForEach-Object { $overflow.Add("Email: $($emails[$_].Address)") }
            }

            # URLs
            $homeURL = $c.URLs | Where-Object { $_.Types -contains 'HOME' } | Select-Object -First 1 -ExpandProperty URL
            $workURL = $c.URLs | Where-Object { $_.Types -contains 'WORK' } | Select-Object -First 1 -ExpandProperty URL
            if (-not $homeURL -and -not $workURL -and $c.URLs.Count -gt 0) {
                $homeURL = $c.URLs[0].URL
            }
            if ($homeURL) { $item.PersonalHomePage = $homeURL }
            if ($workURL) { $item.BusinessHomePage = $workURL }
            $extraURLs = $c.URLs | Where-Object { $_.URL -ne $homeURL -and $_.URL -ne $workURL }
            foreach ($u in $extraURLs) { $overflow.Add("URL: $($u.URL)") }

            # IM
            if ($c.IMAddresses.Count -ge 1) { $item.IMAddress = $c.IMAddresses[0].Address }
            if ($c.IMAddresses.Count -ge 2) {
                1..($c.IMAddresses.Count-1) | ForEach-Object { $overflow.Add("IM: $($c.IMAddresses[$_].Address)") }
            }

            # Dates
            if ($c.Birthday)    { $item.Birthday    = $c.Birthday }
            if ($c.Anniversary) { $item.Anniversary = $c.Anniversary }

            # Custom fields
            foreach ($key in $c.CustomFields.Keys) {
                $val = $c.CustomFields[$key]
                if ($val -is [System.Collections.Generic.List[string]]) {
                    foreach ($v in $val) { $overflow.Add("${key}: $v") }
                }
                else {
                    $overflow.Add("${key}: $val")
                }
            }

            # Compose notes — original notes first, overflow appended
            $noteLines = [System.Collections.Generic.List[string]]::new()
            if ($c.Notes) { $noteLines.Add($c.Notes) }
            if ($overflow.Count -gt 0) {
                $noteLines.Add('')
                $noteLines.Add('[Additional Fields]')
                $noteLines.AddRange($overflow)
            }
            $item.Body = $noteLines -join "`n"

            $item.Save()
            Write-Verbose "Saved contact: $fn"
        }
    }

    end {
        foreach ($obj in @($folder, $namespace, $outlook)) {
            if ($obj) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch { }
            }
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}
#endregion


Export-ModuleMember -Function Read-VCF, Write-VCF, Read-OutlookContact, Write-OutlookContact
