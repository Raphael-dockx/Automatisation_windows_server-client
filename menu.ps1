cls
while ($true) {
    Write-Host "`n--- HOOFDMENU ---" -ForegroundColor Cyan
    Write-Host "Kies: [server] [client] of [exit]"
    $Operating_system = Read-Host "Selectie"

    if ($Operating_system -eq 'exit') { break }

    switch ($Operating_system) {
        "client" {
            while ($true) {
                Write-Host "`n--- CLIENT CONFIGURATIE ---" -ForegroundColor Yellow
                Write-Host "Opties: [netwerk] [tijd] [naam] [terug]"
                $action = Read-Host "Wat wilt u doen?"

                if ($action -eq 'terug') { break }

                switch ($action) {
                    "netwerk" {
                        Write-Host "Huidige netwerkinstellingen:"
                        Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address
                        Write-Host "Let op: Het aanpassen van IP-adressen kan de verbinding verbreken."
                    }
                    "tijd" {
                        $tz = Read-Host "Voer de TimeZone ID in (bijv. 'W. Europe Standard Time')"
                        try {
                            Set-TimeZone -Id $tz -ErrorAction Stop
                            Write-Host "Tijdzone succesvol aangepast naar $tz" -ForegroundColor Green
                        } catch {
                            Write-Host "Fout: Kon tijdzone niet wijzigen. Controleer de ID." -ForegroundColor Red
                        }
                    }
                    "naam" {
                        $nieuweNaam = Read-Host "Voer de nieuwe computernaam in"
                        try {
                            Rename-Computer -NewName $nieuweNaam -Restart -Force
                            Write-Host "Computernaam aangepast. Computer start nu opnieuw op..." -ForegroundColor Green
                        } catch {
                            Write-Host "Fout: Kon naam niet wijzigen." -ForegroundColor Red
                        }
                    }
                    Default { Write-Host "Ongeldige optie." }
                }
            }
        }

        "server" {
            while ($true) {
                Write-Host "`n--- SERVER CONFIGURATIE ---" -ForegroundColor Yellow
                Write-Host "Opties: [netwerk] [tijd] [naam] [dc] [terug]"
                $action = Read-Host "Wat wilt u doen?"

                if ($action -eq 'terug') { break }

                switch ($action) {
                    "netwerk" {
                        Write-Host "Huidige netwerkinstellingen:"
                        Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address
                        Write-Host "Let op: Het aanpassen van IP-adressen kan de verbinding verbreken."
                    }
                    "tijd" {
                        $tz = Read-Host "Voer de TimeZone ID in (bijv. 'W. Europe Standard Time')"
                        try {
                            Set-TimeZone -Id $tz -ErrorAction Stop
                            Write-Host "Tijdzone succesvol aangepast naar $tz" -ForegroundColor Green
                        } catch {
                            Write-Host "Fout: Kon tijdzone niet wijzigen. Controleer de ID." -ForegroundColor Red
                        }
                    }
                    "naam" {
                        $nieuweNaam = Read-Host "Voer de nieuwe computernaam in"
                        try {
                            Rename-Computer -NewName $nieuweNaam -Restart -Force
                            Write-Host "Computernaam aangepast. Computer start nu opnieuw op..." -ForegroundColor Green
                        } catch {
                            Write-Host "Fout: Kon naam niet wijzigen." -ForegroundColor Red
                        }
                    }

                    "dc" {
                        Write-Host "`n--- DOMEINCONTROLLER INSTALLATIE ---" -ForegroundColor Magenta

                        # Stap 1: AD DS rol installeren
                        Write-Host "`nStap 1: AD DS rol installeren..." -ForegroundColor Cyan
                        try {
                            Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
                            Write-Host "AD DS rol succesvol geinstalleerd." -ForegroundColor Green
                        } catch {
                            Write-Host "Fout bij installeren van AD DS rol: $_" -ForegroundColor Red
                            break
                        }

                        # Stap 2: Domeingegevens opvragen
                        Write-Host "`nStap 2: Domein configureren..." -ForegroundColor Cyan
                        $domainName = Read-Host "Voer de domeinnaam in (bijv. 'bedrijf.local')"
                        $netbiosName = Read-Host "Voer de NetBIOS naam in (bijv. 'BEDRIJF')"
                        $safeModePassword = Read-Host "Voer het DSRM (Safe Mode) wachtwoord in" -AsSecureString

                        # Stap 3: Promoveren naar Domain Controller
                        Write-Host "`nStap 3: Server promoveren naar Domain Controller..." -ForegroundColor Cyan
                        Write-Host "De server zal na de installatie automatisch herstarten." -ForegroundColor Yellow

                        try {
                            Install-ADDSForest `
                                -DomainName $domainName `
                                -DomainNetbiosName $netbiosName `
                                -SafeModeAdministratorPassword $safeModePassword `
                                -InstallDns `
                                -Force ` 
                                -ErrorAction Stop

                            Write-Host "Promotie voltooid. Server herstart nu automatisch..." -ForegroundColor Green
                        } catch {
                            Write-Host "Fout bij promoveren naar DC: $_" -ForegroundColor Red
                        }
                    }

                    Default { Write-Host "Ongeldige optie." }
                }
            }
        }

        Default { Write-Host "Ongeldige keuze." }
    }
}
