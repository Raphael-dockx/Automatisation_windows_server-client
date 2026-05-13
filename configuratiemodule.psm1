# ==============================================================================
#  ConfiguratieModule.psm1
#  Gedeelde functies voor server- en clientconfiguratie
#  Geoptimaliseerd voor robuuste foutafhandeling en automatisering
# ==============================================================================

# ──────────────────────────────────────────────────────────────────────────────
#  1. Hervattingstaak beheer (RunOnce & AutoLogon)
# ──────────────────────────────────────────────────────────────────────────────

function Set-RunOnce {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScriptPad
    )

    if (-not (Test-Path $ScriptPad)) {
        Write-Warning "Kan het script niet vinden op pad: $ScriptPad. RunOnce is mogelijk niet correct ingesteld."
    }

    $fullPath = (Get-Item -LiteralPath $ScriptPad -ErrorAction SilentlyContinue).FullName
    $command  = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fullPath`""
    $regPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"

    try {
        Set-ItemProperty -Path $regPath -Name "ScriptHervatting" -Value $command -ErrorAction Stop
        Write-Host "[+] RunOnce succesvol geregistreerd voor de volgende herstart." -ForegroundColor Green
    } catch {
        Write-Warning "[-] Kon RunOnce niet instellen in het register: $_"
    }
}

function Set-AutoLogon {
    param(
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$Password,
        [string]$Domain = "."
    )

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    try {
        Set-ItemProperty -Path $regPath -Name "AutoAdminLogon"   -Value "1"       -ErrorAction Stop
        Set-ItemProperty -Path $regPath -Name "DefaultUserName"  -Value $Username  -ErrorAction Stop
        Set-ItemProperty -Path $regPath -Name "DefaultPassword"  -Value $Password  -ErrorAction Stop
        Set-ItemProperty -Path $regPath -Name "DefaultDomainName"-Value $Domain    -ErrorAction Stop
        Write-Host "[+] Auto-Logon ingeschakeld voor gebruiker '$Username'." -ForegroundColor Green
    } catch {
        Write-Warning "[-] Kon Auto-Logon instellingen niet wegschrijven: $_"
    }
}

function Clear-AutoLogon {
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

    try {
        Set-ItemProperty    -Path $regPath -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Write-Host "[+] Auto-Logon veilig uitgeschakeld en wachtwoord verwijderd." -ForegroundColor Yellow
    } catch {
        Write-Warning "[-] Fout tijdens het opschonen van Auto-Logon."
    }
}

# ──────────────────────────────────────────────────────────────────────────────
#  2. Hulpfunctie — DC-detectie
# ──────────────────────────────────────────────────────────────────────────────

function Test-IsDomainController {
    <#
    .SYNOPSIS
        Geeft $true terug als de lokale machine een Domain Controller is.
    .NOTES
        DomainRole: 0=Standalone WS | 1=Member WS | 2=Standalone Server
                    3=Member Server  | 4=Backup DC  | 5=Primary DC
    #>
    try {
        $role = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).DomainRole
        return ($role -ge 4)
    } catch {
        return $false
    }
}

# ──────────────────────────────────────────────────────────────────────────────
#  3. Netwerkconfiguratie
# ──────────────────────────────────────────────────────────────────────────────

function Toon-NetwerkInstellingen {
    Write-Host "`n--- Huidige Netwerkinstellingen ---" -ForegroundColor Cyan
    Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer |
        Format-Table -AutoSize
}

function Stel-NetwerkIn {
    param(
        [string]$InterfaceNaam,
        [string]$IP,
        [string]$Prefix,
        [string]$Gateway,
        [string]$DNS
    )

    # Automatische fallback naar interactieve modus als parameters ontbreken
    if ([string]::IsNullOrWhiteSpace($InterfaceNaam)) {
        Toon-NetwerkInstellingen
        $interfaces = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        Write-Host "Beschikbare actieve adapters:"
        $interfaces | ForEach-Object { Write-Host "  - $($_.Name)" }
        $InterfaceNaam = Read-Host "`nVoer de adapternaam in"
    }

    if ([string]::IsNullOrWhiteSpace($IP))     { $IP     = Read-Host "Voer het IP-adres in (bijv. 192.168.1.10)" }
    if ([string]::IsNullOrWhiteSpace($Prefix)) { $Prefix = Read-Host "Voer het subnetmasker in (bijv. 24)" }

    # Gateway en DNS alleen interactief vragen als we in manuele modus zitten
    # (d.w.z. InterfaceNaam werd niet via parameter meegegeven)
    # In auto-modus kunnen deze leeg zijn — dat is toegestaan
    if ([string]::IsNullOrWhiteSpace($Gateway)) { $Gateway = Read-Host "Voer de default gateway in (leeg = geen gateway)" }
    if ([string]::IsNullOrWhiteSpace($DNS))     { $DNS     = Read-Host "Voer het primaire DNS-adres in (leeg = geen DNS)" }

    try {
        Write-Host "Netwerkinstellingen toepassen op '$InterfaceNaam'..." -ForegroundColor Cyan

        # Verwijder bestaand IP-adres
        $bestaandeIP = Get-NetIPAddress -InterfaceAlias $InterfaceNaam -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($bestaandeIP) {
            Remove-NetIPAddress -InterfaceAlias $InterfaceNaam -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Verwijder bestaande default gateway route (voorkomt conflicten bij meerdere adapters)
        $bestaandeRoute = Get-NetRoute -InterfaceAlias $InterfaceNaam -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        if ($bestaandeRoute) {
            Remove-NetRoute -InterfaceAlias $InterfaceNaam -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Gateway is optioneel — New-NetIPAddress crasht als je een lege string meegeeft
        if ([string]::IsNullOrWhiteSpace($Gateway)) {
            New-NetIPAddress -InterfaceAlias $InterfaceNaam -IPAddress $IP `
                             -PrefixLength ([int]$Prefix) -ErrorAction Stop | Out-Null
            Write-Host "  [INFO] Geen gateway ingesteld voor $IP." -ForegroundColor DarkYellow
        } else {
            New-NetIPAddress -InterfaceAlias $InterfaceNaam -IPAddress $IP `
                             -PrefixLength ([int]$Prefix) -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
        }

        # DNS is optioneel
        if (-not [string]::IsNullOrWhiteSpace($DNS)) {
            Set-DnsClientServerAddress -InterfaceAlias $InterfaceNaam -ServerAddresses $DNS -ErrorAction Stop
        }

        Write-Host "[+] Netwerk succesvol ingesteld op $IP." -ForegroundColor Green
    } catch {
        Write-Host "[-] Fout bij het instellen van het netwerk: $_" -ForegroundColor Red
    }
}

# ──────────────────────────────────────────────────────────────────────────────
#  4. Systeemconfiguratie (Tijdzone & Computernaam)
# ──────────────────────────────────────────────────────────────────────────────

function Stel-TijdzoneIn {
    Write-Host "Huidige tijdzone: $((Get-TimeZone).DisplayName)" -ForegroundColor Cyan
    Write-Host "Veelgebruikte ID's: 'W. Europe Standard Time', 'UTC'"
    $tz = Read-Host "Voer de TimeZone ID in"

    if ([string]::IsNullOrWhiteSpace($tz)) {
        Write-Host "[-] Geen tijdzone ingevoerd. Actie geannuleerd." -ForegroundColor Yellow
        return
    }

    try {
        Set-TimeZone -Id $tz -ErrorAction Stop
        Write-Host "[+] Tijdzone succesvol aangepast naar '$tz'." -ForegroundColor Green
    } catch {
        Write-Host "[-] Fout: Ongeldige tijdzone. Gebruik 'Get-TimeZone -ListAvailable' voor een overzicht." -ForegroundColor Red
    }
}

function Stel-ComputernaamIn {
    param([string]$ScriptPad)

    Write-Host "Huidige computernaam: $env:COMPUTERNAME" -ForegroundColor Cyan
    $nieuweNaam = Read-Host "Voer de nieuwe computernaam in"

    if ([string]::IsNullOrWhiteSpace($nieuweNaam)) {
        Write-Host "[-] Naam is leeg, actie geannuleerd." -ForegroundColor Yellow
        return
    }

    $user      = Read-Host "Gebruikersnaam voor auto-logon na herstart"
    $pass      = Read-Host "Wachtwoord voor auto-logon" -AsSecureString
    $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                     [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))

    Set-AutoLogon -Username $user -Password $passPlain -Domain "."
    Set-RunOnce   -ScriptPad $ScriptPad

    Write-Host "[!] Computernaam wordt gewijzigd naar '$nieuweNaam'. Het systeem herstart nu..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    Rename-Computer -NewName $nieuweNaam -Restart -Force
}

# ──────────────────────────────────────────────────────────────────────────────
#  5. Domeincontroller Installatie
#     -AutoDomein    : domeinnaam zonder prompt (voor -Auto modus)
#     -AutoWachtwoord: SecureString zonder prompt (voor -Auto modus)
# ──────────────────────────────────────────────────────────────────────────────

function Installeer-DomeinController {
    param(
        [string]$ScriptPad,
        [string]$AutoDomein,
        [System.Security.SecureString]$AutoWachtwoord
    )

    Write-Host "`n--- DOMEINCONTROLLER INSTALLATIE ---" -ForegroundColor Magenta

    # ── Blokkering: al een DC? ─────────────────────────────────────────────────
    if (Test-IsDomainController) {
        Write-Host ""
        Write-Host "  ╔═══════════════════════════════════════════════════════╗" -ForegroundColor DarkRed
        Write-Host "  ║  GEBLOKKEERD: Deze machine is al een Domain Controller ║" -ForegroundColor DarkRed
        Write-Host "  ║  DC-promotie kan niet twee keer worden uitgevoerd.     ║" -ForegroundColor DarkRed
        Write-Host "  ╚═══════════════════════════════════════════════════════╝" -ForegroundColor DarkRed
        Write-Host ""
        return
    }

    # ── Stap 1: AD DS rol installeren ─────────────────────────────────────────
    Write-Host "[1/3] Controleren/Installeren van de AD DS Server Rol..." -ForegroundColor Cyan
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop | Out-Null
    Write-Host "[+] AD DS Rol is aanwezig." -ForegroundColor Green

    # ── Stap 2: Domeinnaam bepalen ────────────────────────────────────────────
    $domainName = $AutoDomein
    if ([string]::IsNullOrWhiteSpace($domainName)) {
        $domainName = Read-Host "`n[2/3] Voer de gewenste domeinnaam in (bijv. 'bedrijf.local')"
    } else {
        Write-Host "[2/3] Domeinnaam uit configuratie: $domainName" -ForegroundColor Gray
    }

    if ([string]::IsNullOrWhiteSpace($domainName)) {
        Write-Host "[-] Ongeldige domeinnaam. Installatie afgebroken." -ForegroundColor Red
        return
    }

    # ── Stap 3: AutoLogon + RunOnce + Promotie ────────────────────────────────
    Write-Host "`n[3/3] Configuratie voor herstart (AutoLogon voor Domain Admin)..." -ForegroundColor Cyan

    $pass = $AutoWachtwoord
    if ($null -eq $pass) {
        $user      = Read-Host "Administrator gebruikersnaam"
        $pass      = Read-Host "Administrator wachtwoord (en DSRM wachtwoord)" -AsSecureString
        $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                         [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
        Set-AutoLogon -Username $user -Password $passPlain -Domain $env:COMPUTERNAME
    } else {
        # Auto-modus: gebruik ingebouwde Administrator-account
        $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                         [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
        Set-AutoLogon -Username "Administrator" -Password $passPlain -Domain $env:COMPUTERNAME
    }

    Set-RunOnce -ScriptPad $ScriptPad

    Write-Host "[!] Installatie start. De server herstart automatisch zodra dit klaar is." -ForegroundColor Yellow
    Start-Sleep -Seconds 3

    Install-ADDSForest `
        -DomainName                    $domainName `
        -SafeModeAdministratorPassword $pass `
        -InstallDns `
        -Force `
        -NoRebootOnCompletion:$false
}

# ──────────────────────────────────────────────────────────────────────────────
#  6. Module Exports
# ──────────────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function `
    Set-RunOnce,
    Set-AutoLogon,
    Clear-AutoLogon,
    Test-IsDomainController,
    Toon-NetwerkInstellingen,
    Stel-NetwerkIn,
    Stel-TijdzoneIn,
    Stel-ComputernaamIn,
    Installeer-DomeinController
