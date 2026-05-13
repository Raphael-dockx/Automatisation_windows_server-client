# ==============================================================================
#  configuratiemenu.ps1
#  Hoofdscript voor server- en clientconfiguratie
#
#  Gebruik:
#    .\configuratiemenu.ps1           -> interactief menu
#    .\configuratiemenu.ps1 -Auto     -> volledig automatisch (leest XML/CSV)
# ==============================================================================

#Requires -RunAsAdministrator

param(
    [switch]$Auto   # Sla alle prompts over en verwerk alles uit de configuratiebestanden
)

function Get-Gebruikerscode {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║        CONFIGURATIE — GEBRUIKERSIDENTIFICATIE    ║" -ForegroundColor Cyan
    Write-Host "  ║                                                  ║" -ForegroundColor Cyan
    Write-Host "  ║  Vul uw naam in. Deze wordt gebruikt om de       ║" -ForegroundColor Cyan
    Write-Host "  ║  configuratiebestanden te personaliseren.        ║" -ForegroundColor Cyan
    Write-Host "  ║  (bv. Raphael Dockx  →  code: DoRa)             ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    while ($true) {
        $voornaam   = (Read-Host "  Voornaam").Trim()
        $achternaam = (Read-Host "  Achternaam").Trim()

        if ($voornaam.Length -lt 2 -or $achternaam.Length -lt 2) {
            Write-Host "  [!] Voor- en achternaam moeten elk minstens 2 tekens bevatten." -ForegroundColor Yellow
            continue
        }

        # Verwijder diacrieten voor veilige bestandsnamen/domeinnamen
        $normVoornaam   = $voornaam   -replace '[^a-zA-Z]', ''
        $normAchternaam = $achternaam -replace '[^a-zA-Z]', ''

        if ($normVoornaam.Length -lt 2 -or $normAchternaam.Length -lt 2) {
            Write-Host "  [!] Naam bevat te weinig letters (na verwijdering van speciale tekens)." -ForegroundColor Yellow
            continue
        }

        # Code: 2 letters achternaam (hoofdletter + kleine) + 2 letters voornaam (hoofdletter + kleine)
        $code = ($normAchternaam[0].ToString().ToUpper() + $normAchternaam[1].ToString().ToLower() +
                 $normVoornaam[0].ToString().ToUpper()   + $normVoornaam[1].ToString().ToLower())

        Write-Host ""
        Write-Host "  Uw gebruikerscode: " -NoNewline -ForegroundColor Gray
        Write-Host $code -ForegroundColor Green
        Write-Host "  (domein wordt bv.: BelgoCorp$code.lab)" -ForegroundColor DarkGray
        Write-Host ""
        $bevestig = (Read-Host "  Is dit correct? (ja/nee)").Trim().ToLower()
        if ($bevestig -eq 'ja' -or $bevestig -eq 'j') {
            return $code
        }
        Write-Host ""
    }
}

# Controleer of de XML-bestanden nog 'xxx' bevatten (= eerste keer / niet gepersonaliseerd)
$domainXmlPad   = Join-Path $PSScriptRoot "Domain_Settings.xml"
$computerXmlPad = Join-Path $PSScriptRoot "Computer_Settings.xml"

$gebruikerscode = $null

$xmlNoodZaaklijk = $false
if (Test-Path $domainXmlPad) {
    $xmlInhoud = Get-Content $domainXmlPad -Raw -Encoding UTF8
    if ($xmlInhoud -match 'xxx') { $xmlNoodZaaklijk = $true }
}
if (Test-Path $computerXmlPad) {
    $xmlInhoud = Get-Content $computerXmlPad -Raw -Encoding UTF8
    if ($xmlInhoud -match 'xxx') { $xmlNoodZaaklijk = $true }
}

if ($xmlNoodZaaklijk) {
    $script:gebruikerscode = Get-Gebruikerscode

    # Vervang 'xxx' in Domain_Settings.xml
    if (Test-Path $domainXmlPad) {
        $inhoud = Get-Content $domainXmlPad -Raw -Encoding UTF8
        $inhoud = $inhoud -replace 'xxx', $script:gebruikerscode
        Set-Content -Path $domainXmlPad -Value $inhoud -Encoding UTF8
        Write-Host "  [+] Domain_Settings.xml bijgewerkt (xxx → $script:gebruikerscode)" -ForegroundColor Green
    }

    # Vervang 'xxx' in Computer_Settings.xml
    if (Test-Path $computerXmlPad) {
        $inhoud = Get-Content $computerXmlPad -Raw -Encoding UTF8
        $inhoud = $inhoud -replace 'xxx', $script:gebruikerscode
        Set-Content -Path $computerXmlPad -Value $inhoud -Encoding UTF8
        Write-Host "  [+] Computer_Settings.xml bijgewerkt (xxx → $script:gebruikerscode)" -ForegroundColor Green
    }

    Write-Host ""
    Start-Sleep -Seconds 1
} else {
    # Bestanden zijn al gepersonaliseerd — lees de huidige code terug uit het domein
    if (Test-Path $domainXmlPad) {
        [xml]$xmlCheck = Get-Content $domainXmlPad -Encoding UTF8
        $huidigeNaam   = $xmlCheck.Settings.Domain.domainNetbiosName
        # Extraheer de code (alles na 'BelgoCorp')
        if ($huidigeNaam -match 'BelgoCorp(.+)') {
            $script:gebruikerscode = $matches[1]
        }
    }
}


# ------------------------------------------------------------------------------
#  1. Modules laden
# ------------------------------------------------------------------------------

$configuratieModulePad = Join-Path $PSScriptRoot "configuratiemodule.psm1"
$adModulePad           = Join-Path $PSScriptRoot "ADconfiguratiemodule.psm1"

foreach ($pad in @($configuratieModulePad, $adModulePad)) {
    if (-not (Test-Path $pad)) {
        Write-Host "FOUT: Module niet gevonden: '$pad'" -ForegroundColor Red
        Write-Host "Zorg ervoor dat alle bestanden in dezelfde map staan." -ForegroundColor Yellow
        Pause
        exit 1
    }
}

Remove-Module configuratiemodule   -ErrorAction SilentlyContinue
Remove-Module ADconfiguratiemodule -ErrorAction SilentlyContinue
Import-Module $configuratieModulePad -Force
Import-Module $adModulePad           -Force

# ------------------------------------------------------------------------------
#  2. Opruimen na herstart (Loop-breaker)
# ------------------------------------------------------------------------------

Clear-AutoLogon

# ------------------------------------------------------------------------------
#  3. Systeemstatus bepalen
# ------------------------------------------------------------------------------

$isDC = $false
try {
    $domainRole = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue).DomainRole
    $isDC = ($domainRole -ge 4)
} catch {
    $isDC = $false
}

$adBeschikbaar = [bool](Get-Module -ListAvailable ActiveDirectory -ErrorAction SilentlyContinue)

$domainInfo = $null
if ($adBeschikbaar) {
    try { $domainInfo = Get-ADDomain -ErrorAction SilentlyContinue } catch {}
}

# ------------------------------------------------------------------------------
#  4. Verborgen spel
# ------------------------------------------------------------------------------

function Start-VerborgenSpel {
    $spelPad = Join-Path $PSScriptRoot "spel.ps1"
    if (Test-Path $spelPad) {
        Clear-Host
        Write-Host "Spel laden..." -ForegroundColor DarkMagenta
        Start-Sleep -Milliseconds 600
        . $spelPad
    } else {
        Write-Host ""
        Write-Host "  [?] Geen spel gevonden." -ForegroundColor DarkGray
        Write-Host "  Maak 'spel.ps1' aan in dezelfde map en plak er je spelcode in." -ForegroundColor DarkGray
        Write-Host ""
        Start-Sleep -Seconds 2
    }
}

function Lees-Invoer {
    param([string]$Prompt)
    $invoer = (Read-Host $Prompt).Trim().ToLower()
    if ($invoer -eq "ppienter") {
        Start-VerborgenSpel
        return $null
    }
    return $invoer
}

# ------------------------------------------------------------------------------
#  5. Status Banner
# ------------------------------------------------------------------------------

function Toon-StatusBanner {
    Clear-Host
    Write-Host ""
    if ($isDC -and $domainInfo) {
        Write-Host "  [=================================================]" -ForegroundColor DarkGreen
        Write-Host "  [   DOMEINCONTROLLER ACTIEF                        ]" -ForegroundColor DarkGreen
        Write-Host "  [   Domein  : $($domainInfo.DNSRoot.PadRight(37))]" -ForegroundColor DarkGreen
        Write-Host "  [   Server  : $($env:COMPUTERNAME.PadRight(37))]"    -ForegroundColor DarkGreen
        Write-Host "  [=================================================]" -ForegroundColor DarkGreen
    } elseif ($isDC) {
        Write-Host "  [DC] Deze machine is een Domain Controller." -ForegroundColor DarkGreen
    } else {
        Write-Host "  [INFO] Deze machine is GEEN Domain Controller." -ForegroundColor DarkYellow
    }
    Write-Host ""
}

# ------------------------------------------------------------------------------
#  6. Herbruikbare auto/manueel keuze-helper
#     Geeft "auto" of "manueel" terug.
# ------------------------------------------------------------------------------

function Kies-AutoOfManueel {
    param(
        [string]$Titel,
        [string]$AutoLabel,
        [string]$AutoPreview
    )

    Write-Host ""
    Write-Host "  --- $Titel ---" -ForegroundColor Cyan
    Write-Host "  [1] Automatisch — $AutoLabel" -ForegroundColor Cyan
    Write-Host "  [2] Manueel     — zelf invoeren" -ForegroundColor Cyan

    if (-not [string]::IsNullOrWhiteSpace($AutoPreview)) {
        Write-Host "  Preview: $AutoPreview" -ForegroundColor DarkGray
    }
    Write-Host ""

    do {
        $k = (Read-Host "  Keuze (1/2)").Trim()
    } while ($k -notin @('1','2'))

    if ($k -eq '1') { return 'auto' } else { return 'manueel' }
}

# ------------------------------------------------------------------------------
#  7. Actiefuncties met auto/manueel keuze per onderdeel
# ------------------------------------------------------------------------------

# -- Netwerk ------------------------------------------------------------------
function Voer-Netwerk-Uit {
    $computerXmlPad = Join-Path $PSScriptRoot "Computer.Settings.xml"
    $preview = ""
    if (Test-Path $computerXmlPad) {
        [xml]$cx  = Get-Content $computerXmlPad -Encoding UTF8
        $statisch = $cx.Settings.networksettings.networkadapter |
                    Where-Object { $_.dhcpenabled -eq "false" -and -not [string]::IsNullOrWhiteSpace($_.ip) }
        if ($statisch) { $preview = ($statisch | ForEach-Object { $_.ip }) -join ", " }
    }

    $keuze = Kies-AutoOfManueel -Titel "Netwerkconfiguratie" `
                                -AutoLabel "Computer.Settings.xml" `
                                -AutoPreview $preview

    if ($keuze -eq 'manueel') { Stel-NetwerkIn; return }

    if (-not (Test-Path $computerXmlPad)) {
        Write-Host "  Computer.Settings.xml niet gevonden — manuele invoer." -ForegroundColor Yellow
        Stel-NetwerkIn; return
    }

    [xml]$computerXml = Get-Content $computerXmlPad -Encoding UTF8
    foreach ($adapter in $computerXml.Settings.networksettings.networkadapter) {
        if ($adapter.dhcpenabled -ne "false" -or [string]::IsNullOrWhiteSpace($adapter.ip)) { continue }

        $macZoek = ($adapter.macaddress -replace '[-:]', '').ToUpper()
        $fysiekAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                         Where-Object { ($_.MacAddress -replace '[-:]', '').ToUpper() -eq $macZoek }

        if (-not $fysiekAdapter) {
            Write-Host "  [WAARSCHUWING] Geen adapter gevonden met MAC $($adapter.macaddress) — overgeslagen." -ForegroundColor Yellow
            continue
        }

        $interfaceNaam = $fysiekAdapter.Name
        $gateway       = $adapter.gateway

        if ($gateway -eq $adapter.ip) {
            Write-Host "  [WAARSCHUWING] Gateway = eigen IP op '$interfaceNaam' — gateway weggelaten." -ForegroundColor Yellow
            $gateway = ""
        }

        Write-Host "  Adapter: '$interfaceNaam'  MAC: $($adapter.macaddress)  IP: $($adapter.ip)" -ForegroundColor Gray
        Stel-NetwerkIn -InterfaceNaam $interfaceNaam -IP $adapter.ip `
                       -Prefix $adapter.prefixlength -Gateway $gateway -DNS $adapter.dns
    }
}

# -- Computernaam -------------------------------------------------------------
function Voer-Naam-Uit {
    $computerXmlPad = Join-Path $PSScriptRoot "Computer.Settings.xml"
    $preview = ""
    if (Test-Path $computerXmlPad) {
        [xml]$cx = Get-Content $computerXmlPad -Encoding UTF8
        $preview = $cx.Settings.name
    }

    $keuze = Kies-AutoOfManueel -Titel "Computernaam wijzigen" `
                                -AutoLabel "Computer.Settings.xml" `
                                -AutoPreview $preview

    if ($keuze -eq 'manueel') { Stel-ComputernaamIn -ScriptPad $PSCommandPath; return }

    if (-not (Test-Path $computerXmlPad)) {
        Write-Host "  Computer.Settings.xml niet gevonden — manuele invoer." -ForegroundColor Yellow
        Stel-ComputernaamIn -ScriptPad $PSCommandPath; return
    }

    [xml]$cx    = Get-Content $computerXmlPad -Encoding UTF8
    $nieuweNaam = $cx.Settings.name

    if ([string]::IsNullOrWhiteSpace($nieuweNaam)) {
        Write-Host "  [WAARSCHUWING] Geen naam in XML — manuele invoer." -ForegroundColor Yellow
        Stel-ComputernaamIn -ScriptPad $PSCommandPath; return
    }

    Write-Host "  Computernaam uit XML: $nieuweNaam" -ForegroundColor Gray
    $user      = Read-Host "  Gebruikersnaam voor auto-logon na herstart"
    $pass      = Read-Host "  Wachtwoord voor auto-logon" -AsSecureString
    $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                     [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))

    Set-AutoLogon -Username $user -Password $passPlain -Domain "."
    Set-RunOnce   -ScriptPad $PSCommandPath

    Write-Host "  [!] Naam wordt gewijzigd naar '$nieuweNaam'. Systeem herstart nu..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    Rename-Computer -NewName $nieuweNaam -Restart -Force
}

# -- DC-promotie --------------------------------------------------------------
function Voer-DC-Uit {
    if ($isDC) {
        Write-Host ""
        Write-Host "  GEBLOKKEERD: Deze machine is al een Domain Controller." -ForegroundColor DarkRed
        Write-Host "  DC-promotie kan niet twee keer worden uitgevoerd." -ForegroundColor DarkRed
        Write-Host ""
        Start-Sleep -Seconds 2
        return
    }

    $domainXmlPad = Join-Path $PSScriptRoot "Domain.Settings.xml"
    $preview = ""
    if (Test-Path $domainXmlPad) {
        [xml]$dx = Get-Content $domainXmlPad -Encoding UTF8
        $preview = $dx.Settings.Domain.domainname
    }

    $keuze = Kies-AutoOfManueel -Titel "DC-promotie" `
                                -AutoLabel "Domain.Settings.xml" `
                                -AutoPreview $preview

    if ($keuze -eq 'manueel') { Installeer-DomeinController -ScriptPad $PSCommandPath; return }

    if (-not (Test-Path $domainXmlPad)) {
        Write-Host "  Domain.Settings.xml niet gevonden — manuele invoer." -ForegroundColor Yellow
        Installeer-DomeinController -ScriptPad $PSCommandPath; return
    }

    [xml]$dx    = Get-Content $domainXmlPad -Encoding UTF8
    $domeinNaam = $dx.Settings.Domain.domainname

    if ([string]::IsNullOrWhiteSpace($domeinNaam)) {
        Write-Host "  [WAARSCHUWING] Geen domeinnaam in XML — manuele invoer." -ForegroundColor Yellow
        Installeer-DomeinController -ScriptPad $PSCommandPath; return
    }

    Write-Host "  Domeinnaam uit XML: $domeinNaam" -ForegroundColor Gray
    $passwoord = Read-Host "  Geef het DSRM / Administrator wachtwoord op" -AsSecureString
    Installeer-DomeinController -ScriptPad $PSCommandPath -AutoDomein $domeinNaam -AutoWachtwoord $passwoord
}

# -- OU's ---------------------------------------------------------------------
function Voer-OU-Uit {
    $csvPad  = Join-Path $PSScriptRoot "ous.csv"
    $preview = if (Test-Path $csvPad) { "$((Import-Csv $csvPad -Delimiter ';').Count) OU's in ous.csv" } else { "ous.csv niet gevonden" }

    $keuze = Kies-AutoOfManueel -Titel "OU's aanmaken" `
                                -AutoLabel "ous.csv" `
                                -AutoPreview $preview

    if ($keuze -eq 'manueel') {
        Write-Host "  Manuele OU-aanmaak is niet ondersteund. Kies automatisch of pas ous.csv aan." -ForegroundColor Yellow
    } else {
        ous_aanmaken
    }
}

# -- Beveiligingsgroepen ------------------------------------------------------
function Voer-Groepen-Uit {
    $csvPad  = Join-Path $PSScriptRoot "securitygroups.csv"
    $preview = if (Test-Path $csvPad) { "$((Import-Csv $csvPad -Delimiter ';').Count) groepen in securitygroups.csv" } else { "securitygroups.csv niet gevonden" }

    $keuze = Kies-AutoOfManueel -Titel "Beveiligingsgroepen aanmaken" `
                                -AutoLabel "securitygroups.csv" `
                                -AutoPreview $preview

    if ($keuze -eq 'manueel') {
        Write-Host "  Manuele groepsaanmaak is niet ondersteund. Kies automatisch of pas securitygroups.csv aan." -ForegroundColor Yellow
    } else {
        securitygroups_aanmaken
    }
}

# -- Gebruikers ---------------------------------------------------------------
function Voer-Users-Uit {
    $jsonPad = Join-Path $PSScriptRoot "users.json"
    $preview = ""
    if (Test-Path $jsonPad) {
        $count   = ((Get-Content $jsonPad -Raw | ConvertFrom-Json).users).Count
        $preview = "$count gebruikers in users.json"
    } else {
        $preview = "users.json niet gevonden"
    }

    $keuze = Kies-AutoOfManueel -Titel "Gebruikers aanmaken" `
                                -AutoLabel "users.json" `
                                -AutoPreview $preview

    if ($keuze -eq 'manueel') {
        Write-Host "  Manuele gebruikersaanmaak is niet ondersteund. Kies automatisch of pas users.json aan." -ForegroundColor Yellow
    } else {
        gebruikers_aanmaken
    }
}

# -- Shares -------------------------------------------------------------------
function Voer-Shares-Uit {
    $csvPad  = Join-Path $PSScriptRoot "shares.csv"
    $preview = if (Test-Path $csvPad) { "$((Import-Csv $csvPad -Delimiter ';').Count) shares in shares.csv" } else { "shares.csv niet gevonden" }

    $keuze = Kies-AutoOfManueel -Titel "Shares en rechten aanmaken" `
                                -AutoLabel "shares.csv + rechten.csv" `
                                -AutoPreview $preview

    if ($keuze -eq 'manueel') {
        Write-Host "  Manuele share-aanmaak is niet ondersteund. Kies automatisch of pas shares.csv aan." -ForegroundColor Yellow
    } else {
        shares_aanmaken
    }
}

# ------------------------------------------------------------------------------
#  8. VOLLEDIG AUTOMATISCHE MODUS  (-Auto)
# ------------------------------------------------------------------------------

if ($Auto) {
    Toon-StatusBanner
    Write-Host "============================================" -ForegroundColor Magenta
    Write-Host "     AUTOMATISCHE CONFIGURATIE GESTART      " -ForegroundColor Magenta
    Write-Host "============================================" -ForegroundColor Magenta
    Write-Host ""

    $xmlPad = Join-Path $PSScriptRoot "Domain.Settings.xml"
    if (-not (Test-Path $xmlPad)) {
        Write-Host "FOUT: Domain.Settings.xml niet gevonden. Auto-modus afgebroken." -ForegroundColor Red
        exit 1
    }

    # Stap 1: Netwerk
    Write-Host "-- STAP 1/5 : Netwerkconfiguratie --" -ForegroundColor Cyan
    Voer-Netwerk-Uit

    # Stap 2: Computernaam
    Write-Host ""
    Write-Host "-- STAP 2/5 : Computernaam --" -ForegroundColor Cyan
    Voer-Naam-Uit

    # Stap 3: DC-promotie
    Write-Host ""
    Write-Host "-- STAP 3/5 : Domeincontroller --" -ForegroundColor Cyan
    if ($isDC) {
        Write-Host "  [OVERGESLAGEN] Machine is al een Domain Controller." -ForegroundColor Yellow
    } else {
        Voer-DC-Uit
        Write-Host "  Server herstart na promotie. Voer het script opnieuw uit met -Auto." -ForegroundColor Yellow
        exit 0
    }

    # Stap 4 & 5: AD-objecten + Shares
    if ($adBeschikbaar) {
        Write-Host ""
        Write-Host "-- STAP 4/5 : Active Directory objecten --" -ForegroundColor Cyan
        Write-Host "`n  [1/3] OU's aanmaken..."
        Voer-OU-Uit
        Write-Host "`n  [2/3] Beveiligingsgroepen aanmaken..."
        Voer-Groepen-Uit
        Write-Host "`n  [3/3] Gebruikers aanmaken..."
        Voer-Users-Uit

        Write-Host ""
        Write-Host "-- STAP 5/5 : Shares en rechten --" -ForegroundColor Cyan
        Voer-Shares-Uit
    } else {
        Write-Host "  [OVERGESLAGEN] Active Directory module niet beschikbaar." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "     AUTOMATISCHE CONFIGURATIE VOLTOOID     " -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    exit 0
}

# ------------------------------------------------------------------------------
#  9. Interactief Hoofdmenu
# ------------------------------------------------------------------------------

Toon-StatusBanner

:HoofdMenu while ($true) {
    Write-Host "=== HOOFDMENU ===" -ForegroundColor Cyan
    Write-Host "  [1] Server Configuratie"
    Write-Host "  [2] Client Configuratie"
    Write-Host "  [3] Afsluiten"
    Write-Host ""

    $keuze = Lees-Invoer "`nMaak uw keuze (1/2/3)"
    if ($null -eq $keuze) { Toon-StatusBanner; continue }

    switch ($keuze) {

        { $_ -in '3', 'exit', 'afsluiten' } {
            Write-Host "Script wordt afgesloten..." -ForegroundColor Yellow
            break HoofdMenu
        }

        # -- Client Configuratie -----------------------------------------------
        { $_ -in '2', 'client' } {
            Clear-Host
            :ClientMenu while ($true) {
                Write-Host "`n--- CLIENT CONFIGURATIE ---" -ForegroundColor Yellow
                Write-Host "  [netwerk]  IP en DNS instellen"
                Write-Host "  [tijd]     Tijdzone aanpassen"
                Write-Host "  [naam]     Computernaam wijzigen (vereist herstart)"
                Write-Host "  [terug]    Terug naar hoofdmenu"
                Write-Host ""

                $actie = Lees-Invoer "Wat wilt u doen"
                if ($null -eq $actie) { continue }

                switch ($actie) {
                    'terug'   { Clear-Host; break ClientMenu }
                    'netwerk' { Voer-Netwerk-Uit }
                    'tijd'    { Stel-TijdzoneIn }
                    'naam'    { Voer-Naam-Uit }
                    default   { Write-Host "Ongeldige optie. Probeer opnieuw." -ForegroundColor Red }
                }
            }
        }

        # -- Server Configuratie -----------------------------------------------
        { $_ -in '1', 'server' } {
            Clear-Host
            :ServerMenu while ($true) {
                Write-Host "`n--- SERVER CONFIGURATIE ---" -ForegroundColor Yellow
                Write-Host "  [netwerk]  IP en DNS instellen"
                Write-Host "  [tijd]     Tijdzone aanpassen"
                Write-Host "  [naam]     Computernaam wijzigen (vereist herstart)"

                if ($isDC) {
                    Write-Host "  [dc]       Promoveren naar DC  <- al uitgevoerd, geblokkeerd" -ForegroundColor DarkRed
                } else {
                    Write-Host "  [dc]       Promoveren naar Domain Controller (vereist herstart)"
                }

                if ($adBeschikbaar) {
                    Write-Host "  [ad]       Active Directory instellingen" -ForegroundColor Cyan
                }

                Write-Host "  [terug]    Terug naar hoofdmenu"
                Write-Host ""

                $actie = Lees-Invoer "Wat wilt u doen"
                if ($null -eq $actie) { continue }

                switch ($actie) {
                    'terug'   { Clear-Host; break ServerMenu }
                    'netwerk' { Voer-Netwerk-Uit }
                    'tijd'    { Stel-TijdzoneIn }
                    'naam'    { Voer-Naam-Uit }
                    'dc'      { Voer-DC-Uit }

                    'ad' {
                        if (-not $adBeschikbaar) {
                            Write-Host "FOUT: Active Directory module is niet beschikbaar." -ForegroundColor Red
                            continue
                        }

                        Clear-Host
                        :ADMenu while ($true) {
                            Write-Host "`n--- ACTIVE DIRECTORY INSTELLINGEN ---" -ForegroundColor Cyan
                            Write-Host "  [ou]      Organisatie-eenheden (OU's) aanmaken"
                            Write-Host "  [groepen] Beveiligingsgroepen aanmaken"
                            Write-Host "  [users]   Gebruikers aanmaken"
                            Write-Host "  [shares]  Shares en rechten aanmaken"
                            Write-Host "  [alles]   Alles in volgorde uitvoeren (OU -> Groepen -> Users -> Shares)"
                            Write-Host "  [terug]   Terug naar servermenu"
                            Write-Host ""

                            $adKeuze = Lees-Invoer "Wat wilt u doen in AD"
                            if ($null -eq $adKeuze) { continue }

                            switch ($adKeuze) {
                                'terug'   { Clear-Host; break ADMenu }
                                'ou'      { Voer-OU-Uit }
                                'groepen' { Voer-Groepen-Uit }
                                'users'   { Voer-Users-Uit }
                                'shares'  { Voer-Shares-Uit }
                                'alles' {
                                    Write-Host "`n[1/4] OU's..."               -ForegroundColor Yellow; Voer-OU-Uit
                                    Write-Host "`n[2/4] Beveiligingsgroepen..." -ForegroundColor Yellow; Voer-Groepen-Uit
                                    Write-Host "`n[3/4] Gebruikers..."          -ForegroundColor Yellow; Voer-Users-Uit
                                    Write-Host "`n[4/4] Shares en rechten..."   -ForegroundColor Yellow; Voer-Shares-Uit
                                    Write-Host "`nAlle AD-stappen voltooid." -ForegroundColor Green
                                }
                                default { Write-Host "Ongeldige optie in AD menu." -ForegroundColor Red }
                            }
                        }
                    }

                    default { Write-Host "Ongeldige optie. Probeer opnieuw." -ForegroundColor Red }
                }
            }
        }

        default { Write-Host "Ongeldige keuze. Kies 1, 2 of 3." -ForegroundColor Red }
    }
}
