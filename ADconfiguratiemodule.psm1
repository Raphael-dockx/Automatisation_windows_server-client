# ==============================================================================
#  ADconfiguratiemodule.psm1
#  Active Directory configuratiefuncties
#  Versie 2.0 - Auto-aanmaak van ontbrekende OU's en groepen
# ==============================================================================


# ------------------------------------------------------------------------------
#  HULPFUNCTIES (intern gebruik)
# ------------------------------------------------------------------------------

# Zorg dat een OU bestaat. Als die er niet is, wordt die aangemaakt op het
# opgegeven pad (standaard: rootniveau van het domein).
# Geeft de DistinguishedName terug van de gevonden of aangemaakte OU.
function _Zorg-OUBestaat {
    param(
        [string]$Naam,
        [string]$ParentDN  # Als leeg -> domeinroot
    )

    $domainDN = (Get-ADDomain).DistinguishedName
    if ([string]::IsNullOrWhiteSpace($ParentDN)) { $ParentDN = $domainDN }

    $doelDN = "OU=$Naam,$ParentDN"

    $bestaand = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$doelDN'" -ErrorAction SilentlyContinue
    if ($bestaand) {
        return $doelDN
    }

    # OU bestaat niet -> aanmaken
    try {
        New-ADOrganizationalUnit -Name $Naam -Path $ParentDN -ErrorAction Stop | Out-Null
        Write-Host "  [AUTO] OU aangemaakt: $doelDN" -ForegroundColor Magenta
        return $doelDN
    } catch {
        Write-Host "  [FOUT] Kon OU '$Naam' niet aanmaken in '$ParentDN': $_" -ForegroundColor Red
        return $null
    }
}

# Zorg dat een beveiligingsgroep bestaat. Prefix bepaalt de scope.
# Maakt de groep aan in de standaard OU als die er niet is.
function _Zorg-GroepBestaat {
    param([string]$GroepNaam)

    try {
        Get-ADGroup -Identity $GroepNaam -ErrorAction Stop | Out-Null
        return  # bestaat al, niets doen
    } catch {}

    # Scope bepalen op basis van prefix
    $scope = if ($GroepNaam.StartsWith("DL_")) { "DomainLocal" } else { "Global" }

    # Standaard OU voor auto-aangemaakte groepen
    $domainDN  = (Get-ADDomain).DistinguishedName
    $ouNaam    = if ($GroepNaam.StartsWith("DL_")) { "DL_Groups" } else { "GL_Groups" }
    $ouDN      = "OU=$ouNaam,$domainDN"

    # Zorg dat de groep-OU bestaat
    _Zorg-OUBestaat -Naam $ouNaam -ParentDN $domainDN | Out-Null

    try {
        New-ADGroup `
            -Name           $GroepNaam `
            -SamAccountName $GroepNaam `
            -GroupScope     $scope `
            -GroupCategory  "Security" `
            -Path           $ouDN `
            -ErrorAction    Stop | Out-Null
        Write-Host "  [AUTO] Groep aangemaakt: $GroepNaam ($scope) in $ouNaam" -ForegroundColor Magenta
    } catch {
        Write-Host "  [FOUT] Kon groep '$GroepNaam' niet aanmaken: $_" -ForegroundColor Red
    }
}


# ------------------------------------------------------------------------------
#  ous_aanmaken
#  Leest ous.csv en maakt de OU-structuur aan in Active Directory.
#
#  CSV-formaat (puntkomma):
#    Name;Path
#    Corporate;                        <- root, geen pad
#    Management;Corporate              <- direct onder Corporate
#    Executives;Management,Corporate   <- onder Management, dat onder Corporate zit
#
#  Path = keten van direct parent naar hoogste voorouder (links = diepste)
# ------------------------------------------------------------------------------
function ous_aanmaken {
    $csvPad = Join-Path $PSScriptRoot "ous.csv"

    if (-not (Test-Path $csvPad)) {
        Write-Host "FOUT: ous.csv niet gevonden op '$csvPad'." -ForegroundColor Red
        return
    }

    $domainDN = (Get-ADDomain).DistinguishedName
    $ouLijst  = Import-Csv $csvPad -Delimiter ";"

    foreach ($item in $ouLijst) {
        $naam   = $item.Name.Trim()
        $padRaw = if ($null -ne $item.Path) { $item.Path.Trim() } else { "" }

        if ([string]::IsNullOrWhiteSpace($padRaw)) {
            $parentDN = $domainDN
        } else {
            $padDelen = @($padRaw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
            $parentDN = $domainDN
            for ($i = $padDelen.Count - 1; $i -ge 0; $i--) {
                $parentDN = "OU=$($padDelen[$i]),$parentDN"
            }
        }

        $volledigeDN = "OU=$naam,$parentDN"

        if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$volledigeDN'" -ErrorAction SilentlyContinue) {
            Write-Host "Overgeslagen (bestaat al): $volledigeDN" -ForegroundColor Yellow
        } else {
            try {
                New-ADOrganizationalUnit -Name $naam -Path $parentDN -ErrorAction Stop
                Write-Host "OU aangemaakt: $volledigeDN" -ForegroundColor Green
            } catch {
                Write-Host "FOUT bij aanmaken '$naam' in '$parentDN': $_" -ForegroundColor Red
            }
        }
    }
    Write-Host "`nOU-aanmaak voltooid." -ForegroundColor Cyan
}


# ------------------------------------------------------------------------------
#  securitygroups_aanmaken
#  Leest securitygroups.csv en maakt beveiligingsgroepen aan in AD.
#
#  CSV-formaat (puntkomma):
#    GroepNaam;ou
#    GL_Corporate_Management_R;GL_Groups
#
#  Prefix GL_ -> Global scope | Prefix DL_ -> DomainLocal scope
# ------------------------------------------------------------------------------
function securitygroups_aanmaken {
    $csvPad = Join-Path $PSScriptRoot "securitygroups.csv"

    if (-not (Test-Path $csvPad)) {
        Write-Host "FOUT: securitygroups.csv niet gevonden op '$csvPad'." -ForegroundColor Red
        return
    }

    $domainDN   = (Get-ADDomain).DistinguishedName
    $groepLijst = Import-Csv $csvPad -Delimiter ";"

    foreach ($item in $groepLijst) {
        $groepNaam = $item.GroepNaam.Trim()
        $ouNaam    = $item.ou.Trim()
        $ouDN      = "OU=$ouNaam,$domainDN"
        $scope     = if ($groepNaam.StartsWith("DL_")) { "DomainLocal" } else { "Global" }

        # OU aanmaken als die nog niet bestaat
        _Zorg-OUBestaat -Naam $ouNaam -ParentDN $domainDN | Out-Null

        # Groep aanmaken als die nog niet bestaat
        try {
            Get-ADGroup -Identity $groepNaam -ErrorAction Stop | Out-Null
            Write-Host "Overgeslagen (bestaat al): $groepNaam" -ForegroundColor Yellow
        } catch {
            try {
                New-ADGroup `
                    -Name           $groepNaam `
                    -SamAccountName $groepNaam `
                    -GroupScope     $scope `
                    -GroupCategory  "Security" `
                    -Path           $ouDN `
                    -ErrorAction    Stop
                Write-Host "Groep aangemaakt: $groepNaam ($scope)" -ForegroundColor Green
            } catch {
                Write-Host "FOUT bij aanmaken groep '$groepNaam': $_" -ForegroundColor Red
            }
        }
    }

    Write-Host "`nBeveiligingsgroepen-aanmaak voltooid." -ForegroundColor Cyan
}


# ------------------------------------------------------------------------------
#  gebruikers_aanmaken
#  Leest users.json + Domain.Settings.xml en maakt AD-gebruikers aan.
#
#  NIEUW: Als een OU of beveiligingsgroep uit users.json niet bestaat in AD,
#         wordt die automatisch aangemaakt (geen bestandswijzigingen nodig).
#         Alle auto-aanmaak wordt duidelijk gelogd in magenta.
# ------------------------------------------------------------------------------
function gebruikers_aanmaken {
    $jsonPad = Join-Path $PSScriptRoot "users.json"
    $xmlPad  = Join-Path $PSScriptRoot "Domain.Settings.xml"

    if (-not (Test-Path $jsonPad)) {
        Write-Host "FOUT: users.json niet gevonden op '$jsonPad'." -ForegroundColor Red
        return
    }
    if (-not (Test-Path $xmlPad)) {
        Write-Host "FOUT: Domain.Settings.xml niet gevonden op '$xmlPad'." -ForegroundColor Red
        return
    }

    # Instellingen uit Domain.Settings.xml
    [xml]$xml          = Get-Content $xmlPad -Encoding UTF8
    $standaardPaswoord = $xml.Settings.UserSettings.defaultPassword
    $homeDrive         = $xml.Settings.UserSettings.homeFolder.homeDrive
    $homeShareNaam     = $xml.Settings.UserSettings.homeFolder.sharename
    $fileServer        = $xml.Settings.FileServer.name

    $securePass = ConvertTo-SecureString $standaardPaswoord -AsPlainText -Force
    $dnsSuffix  = (Get-ADDomain).DNSRoot
    $domainDN   = (Get-ADDomain).DistinguishedName

    $gebruikers = (Get-Content $jsonPad -Raw -Encoding UTF8 | ConvertFrom-Json).users

    # ------------------------------------------------------------------
    #  STAP 1: Pre-scan - detecteer alle ontbrekende OU's en groepen
    # ------------------------------------------------------------------
    Write-Host "`n[1/3] Validatie: ontbrekende OU's en groepen controleren..." -ForegroundColor Cyan

    $ontbrekendeOUs    = @{}
    $ontbrekendeGroepen = [System.Collections.Generic.List[string]]::new()

    foreach ($user in $gebruikers) {
        $ouNaam = $user.ou.Trim()

        # OU controleren
        if (-not $ontbrekendeOUs.ContainsKey($ouNaam)) {
            $gevonden = Get-ADOrganizationalUnit -Filter "Name -eq '$ouNaam'" -ErrorAction SilentlyContinue |
                        Select-Object -First 1
            if (-not $gevonden) {
                $ontbrekendeOUs[$ouNaam] = $true
            }
        }

        # Groepen controleren
        foreach ($groep in $user.securityGroups) {
            if ($ontbrekendeGroepen -notcontains $groep) {
                try {
                    Get-ADGroup -Identity $groep -ErrorAction Stop | Out-Null
                } catch {
                    $ontbrekendeGroepen.Add($groep)
                }
            }
        }
    }

    # Resultaat pre-scan tonen
    if ($ontbrekendeOUs.Count -eq 0 -and $ontbrekendeGroepen.Count -eq 0) {
        Write-Host "  Alles aanwezig, geen auto-aanmaak nodig." -ForegroundColor Green
    } else {
        if ($ontbrekendeOUs.Count -gt 0) {
            Write-Host "`n  Ontbrekende OU's gevonden ($($ontbrekendeOUs.Count)):" -ForegroundColor Yellow
            $ontbrekendeOUs.Keys | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        }
        if ($ontbrekendeGroepen.Count -gt 0) {
            Write-Host "`n  Ontbrekende groepen gevonden ($($ontbrekendeGroepen.Count)):" -ForegroundColor Yellow
            $ontbrekendeGroepen | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        }
    }

    # ------------------------------------------------------------------
    #  STAP 2: Auto-aanmaak van ontbrekende OU's en groepen
    # ------------------------------------------------------------------
    Write-Host "`n[2/3] Ontbrekende items aanmaken..." -ForegroundColor Cyan

    # OU's aanmaken op domeinroot niveau (beheerder kan ze later verplaatsen)
    foreach ($ouNaam in $ontbrekendeOUs.Keys) {
        _Zorg-OUBestaat -Naam $ouNaam -ParentDN $domainDN | Out-Null
    }

    # Groepen aanmaken
    foreach ($groep in $ontbrekendeGroepen) {
        _Zorg-GroepBestaat -GroepNaam $groep
    }

    if ($ontbrekendeOUs.Count -eq 0 -and $ontbrekendeGroepen.Count -eq 0) {
        Write-Host "  Niets te doen." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    #  STAP 3: Gebruikers aanmaken
    # ------------------------------------------------------------------
    Write-Host "`n[3/3] Gebruikers aanmaken..." -ForegroundColor Cyan

    $aangemaakt  = 0
    $overgeslagen = 0
    $fouten      = 0

    foreach ($user in $gebruikers) {
        $voornaam   = $user.firstName.Trim()
        $achternaam = $user.lastName.Trim()
        $login      = $user.login.Trim()
        $ouNaam     = $user.ou.Trim()
        $groepen    = $user.securityGroups

        # OU opzoeken - nu gegarandeerd aanwezig dankzij stap 2
        $ouObject = Get-ADOrganizationalUnit -Filter "Name -eq '$ouNaam'" -ErrorAction SilentlyContinue |
                    Select-Object -First 1

        if (-not $ouObject) {
            # Laatste vangnet: probeer alsnog aan te maken
            $nieuweOUDN = _Zorg-OUBestaat -Naam $ouNaam -ParentDN $domainDN
            if ($nieuweOUDN) {
                $ouObject = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$nieuweOUDN'" -ErrorAction SilentlyContinue
            }
            if (-not $ouObject) {
                Write-Host "  [FOUT] OU '$ouNaam' kon niet gevonden/aangemaakt worden. '$login' overgeslagen." -ForegroundColor Red
                $fouten++
                continue
            }
        }

        $homePath = "\\$fileServer\$homeShareNaam\$login"

        # Gebruiker aanmaken
        try {
            Get-ADUser -Identity $login -ErrorAction Stop | Out-Null
            Write-Host "  Overgeslagen (bestaat al): $login" -ForegroundColor Yellow
            $overgeslagen++
        } catch {
            try {
                New-ADUser `
                    -GivenName             $voornaam `
                    -Surname               $achternaam `
                    -Name                  "$voornaam $achternaam" `
                    -SamAccountName        $login `
                    -UserPrincipalName     "$login@$dnsSuffix" `
                    -Path                  $ouObject.DistinguishedName `
                    -AccountPassword       $securePass `
                    -ChangePasswordAtLogon $false `
                    -PasswordNeverExpires  $true `
                    -HomeDirectory         $homePath `
                    -HomeDrive             $homeDrive `
                    -Enabled               $true `
                    -ErrorAction           Stop
                Write-Host "  Gebruiker aangemaakt: $login (OU: $ouNaam)" -ForegroundColor Green
                $aangemaakt++
            } catch {
                Write-Host "  [FOUT] Kon gebruiker '$login' niet aanmaken: $_" -ForegroundColor Red
                $fouten++
                continue
            }
        }

        # Groepslidmaatschappen
        foreach ($groep in $groepen) {
            try {
                Add-ADGroupMember -Identity $groep -Members $login -ErrorAction Stop
                Write-Host "    -> Lid van '$groep'" -ForegroundColor DarkGreen
            } catch {
                Write-Host "    [FOUT] Kon '$login' niet toevoegen aan '$groep': $_" -ForegroundColor Red
            }
        }
    }

    # Samenvatting
    Write-Host "`n┌─────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "│         GEBRUIKERS SAMENVATTING      │" -ForegroundColor Cyan
    Write-Host "├─────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host "│  Aangemaakt  : $($aangemaakt.ToString().PadRight(21))│" -ForegroundColor Green
    Write-Host "│  Overgeslagen: $($overgeslagen.ToString().PadRight(21))│" -ForegroundColor Yellow
    Write-Host "│  Fouten      : $($fouten.ToString().PadRight(21))│" -ForegroundColor $(if ($fouten -gt 0) { 'Red' } else { 'Green' })
    if ($ontbrekendeOUs.Count -gt 0) {
        Write-Host "│                                     │" -ForegroundColor Cyan
        Write-Host "│  Auto-OU's   : $($ontbrekendeOUs.Count.ToString().PadRight(21))│" -ForegroundColor Magenta
        Write-Host "│  (staan nu op domeinroot-niveau)    │" -ForegroundColor Magenta
    }
    Write-Host "└─────────────────────────────────────┘" -ForegroundColor Cyan
}


# ------------------------------------------------------------------------------
#  shares_aanmaken
#  Stap 1 - Maakt mappen aan uit mappen.txt
#  Stap 2 - Maakt shares aan uit shares.csv
#  Stap 3 - Stelt NTFS- en sharerechten in uit rechten.csv
# ------------------------------------------------------------------------------
function shares_aanmaken {
    $mappenTxt  = Join-Path $PSScriptRoot "mappen.txt"
    $sharesCsv  = Join-Path $PSScriptRoot "shares.csv"
    $rechtenCsv = Join-Path $PSScriptRoot "rechten.csv"

    foreach ($bestand in @($sharesCsv, $rechtenCsv)) {
        if (-not (Test-Path $bestand)) {
            Write-Host "FOUT: '$bestand' niet gevonden." -ForegroundColor Red
            return
        }
    }

    # Stap 1: Mappen aanmaken uit mappen.txt
    Write-Host "`n[1/3] Mappen aanmaken..." -ForegroundColor Cyan
    if (Test-Path $mappenTxt) {
        Get-Content $mappenTxt | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
            $map = $_.Trim()
            if (-not (Test-Path $map)) {
                try {
                    New-Item -ItemType Directory -Path $map -Force -ErrorAction Stop | Out-Null
                    Write-Host "Map aangemaakt: $map" -ForegroundColor Green
                } catch {
                    Write-Host "FOUT bij aanmaken map '$map': $_" -ForegroundColor Red
                }
            } else {
                Write-Host "Map bestaat al:  $map" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "mappen.txt niet gevonden, stap overgeslagen." -ForegroundColor Yellow
    }

    # Stap 2: Shares aanmaken uit shares.csv
    Write-Host "`n[2/3] Shares aanmaken..." -ForegroundColor Cyan
    $shares = Import-Csv $sharesCsv -Delimiter ";"

    foreach ($item in $shares) {
        $mapPad    = $item.map.Trim()
        $shareNaam = $item.share.Trim()

        if (-not (Test-Path $mapPad)) {
            try {
                New-Item -ItemType Directory -Path $mapPad -Force -ErrorAction Stop | Out-Null
                Write-Host "Map aangemaakt: $mapPad" -ForegroundColor Green
            } catch {
                Write-Host "FOUT bij aanmaken map '$mapPad': $_" -ForegroundColor Red
                continue
            }
        }

        if (Get-SmbShare -Name $shareNaam -ErrorAction SilentlyContinue) {
            Write-Host "Share bestaat al: $shareNaam" -ForegroundColor Yellow
        } else {
            try {
                New-SmbShare -Name $shareNaam -Path $mapPad -FullAccess "Administrators" -ErrorAction Stop | Out-Null
                Write-Host "Share aangemaakt: $shareNaam -> $mapPad" -ForegroundColor Green
            } catch {
                Write-Host "FOUT bij aanmaken share '$shareNaam': $_" -ForegroundColor Red
            }
        }
    }

    # Stap 3: Rechten instellen uit rechten.csv
    Write-Host "`n[3/3] Rechten instellen..." -ForegroundColor Cyan
    $rechten = Import-Csv $rechtenCsv -Delimiter ";"

    # Runtime correctietabel — herstelt fouten in CSV zonder de bestanden aan te raken
    # Sleutel = verkeerde waarde uit CSV, Waarde = correcte waarde
    $groepCorrectie = @{
        # rechten.csv regels 12-13: Production-groepen staan foutief op Sales\Domestic
        "DL_Operations_Production_R"  = "DL_Sales_Domestic_R"
        "DL_Operations_Production_RW" = "DL_Sales_Domestic_RW"
    }
    # Maar die correctie mag ALLEEN gelden als de map Sales\Domestic is,
    # want op c:\Operations\Production zijn die groepen wel correct.
    # Daarom werken we met map+groep combinatie als sleutel:
    $combinatieCorrectie = @{
        "c:\Sales\Domestic|DL_Operations_Production_R"  = "DL_Sales_Domestic_R"
        "c:\Sales\Domestic|DL_Operations_Production_RW" = "DL_Sales_Domestic_RW"
    }

    foreach ($item in $rechten) {
        $mapPad     = $item.map.Trim()
        $shareNaam  = $item.share.Trim()
        $groep      = $item.Groep.Trim()
        $ntfsRecht  = $item.NTFS_permission.Trim().ToLower()
        $shareRecht = $item.share_permission.Trim().ToLower()

        # Pas runtime correctie toe indien van toepassing
        $combinatieSleutel = "$mapPad|$groep"
        if ($combinatieCorrectie.ContainsKey($combinatieSleutel)) {
            $corrigeNaar = $combinatieCorrectie[$combinatieSleutel]
            Write-Host "  [CORRECTIE] '$groep' op '$mapPad' gecorrigeerd naar '$corrigeNaar'" -ForegroundColor Magenta
            $groep = $corrigeNaar
        }

        # Zorg dat de groep bestaat in AD voor we rechten proberen te zetten
        _Zorg-GroepBestaat -GroepNaam $groep

        $fsRights = switch ($ntfsRecht) {
            "read"        { [System.Security.AccessControl.FileSystemRights]::ReadAndExecute }
            "modify"      { [System.Security.AccessControl.FileSystemRights]::Modify }
            "fullcontrol" { [System.Security.AccessControl.FileSystemRights]::FullControl }
            default       { [System.Security.AccessControl.FileSystemRights]::ReadAndExecute }
        }

        try {
            $acl  = Get-Acl -Path $mapPad -ErrorAction Stop
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $groep, $fsRights,
                "ContainerInherit,ObjectInherit", "None", "Allow"
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $mapPad -AclObject $acl -ErrorAction Stop
            Write-Host "NTFS [$ntfsRecht] op '$mapPad' voor '$groep'" -ForegroundColor Green
        } catch {
            Write-Host "FOUT NTFS '$groep' op '$mapPad': $_" -ForegroundColor Red
        }

        $accessRight = switch ($shareRecht) {
            "read"   { "Read" }
            "change" { "Change" }
            "full"   { "Full" }
            default  { "Read" }
        }

        try {
            Revoke-SmbShareAccess -Name $shareNaam -AccountName $groep -Force -ErrorAction SilentlyContinue | Out-Null
            Grant-SmbShareAccess  -Name $shareNaam -AccountName $groep -AccessRight $accessRight -Force -ErrorAction Stop | Out-Null
            Write-Host "Share [$accessRight] op '$shareNaam' voor '$groep'" -ForegroundColor Green
        } catch {
            Write-Host "FOUT share '$groep' op '$shareNaam': $_" -ForegroundColor Red
        }
    }

    Write-Host "`nShares en rechten instellen voltooid." -ForegroundColor Cyan
}


# ------------------------------------------------------------------------------
#  Module Exports
# ------------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'ous_aanmaken',
    'securitygroups_aanmaken',
    'gebruikers_aanmaken',
    'shares_aanmaken'
)
