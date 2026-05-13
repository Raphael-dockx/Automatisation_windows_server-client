# ==============================================================================
#  spel.ps1  —  PowerShell Dungeons: The Keep of Shadows
#  Volledig DnD-stijl tekstadventure
#  Wordt dot-sourced vanuit configuratiemenu.ps1 via de "ppienter" easter egg.
# ==============================================================================

# ══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIES
# ══════════════════════════════════════════════════════════════════════════════

function Roll-Dice {
    param(
        [int]$Sides  = 6,
        [int]$Count  = 1,
        [switch]$DropLowest
    )
    $rolls = 1..$Count | ForEach-Object { Get-Random -Minimum 1 -Maximum ($Sides + 1) }
    if ($DropLowest -and $Count -gt 1) {
        $rolls = $rolls | Sort-Object | Select-Object -Skip 1
    }
    return ($rolls | Measure-Object -Sum).Sum
}

function Get-Mod {
    param([int]$Score)
    return [Math]::Floor(($Score - 10) / 2)
}

function Format-Mod {
    param([int]$Score)
    $m = Get-Mod $Score
    if ($m -ge 0) { return "+$m" } else { return "$m" }
}

function Pause-Game {
    param([string]$Message = "Druk op Enter om verder te gaan...")
    Write-Host "`n$Message" -ForegroundColor DarkGray
    Read-Host | Out-Null
}

function Show-Header {
    param([string]$Title, [System.ConsoleColor]$Color = "Cyan")
    Write-Host ""
    Write-Host ("═" * 50) -ForegroundColor $Color
    Write-Host "  $Title" -ForegroundColor $Color
    Write-Host ("═" * 50) -ForegroundColor $Color
    Write-Host ""
}

function Show-Stats {
    param($C)
    $dexMod = Get-Mod $C.DEX
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host ("  │  {0,-41}│" -f "$($C.Name)  ($($C.Race) $($C.SubRace) $($C.Class))") -ForegroundColor White
    Write-Host ("  │  Level {0}  │  XP: {1,-6}  │  HP: {2}/{3,-10}│" -f $C.Level, $C.XP, $C.HP, $C.MaxHP) -ForegroundColor White
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host ("  │  STR {0,2} ({1})  DEX {2,2} ({3})  CON {4,2} ({5})    │" -f $C.STR,(Format-Mod $C.STR),$C.DEX,(Format-Mod $C.DEX),$C.CON,(Format-Mod $C.CON)) -ForegroundColor White
    Write-Host ("  │  INT {0,2} ({1})  WIS {2,2} ({3})  CHA {4,2} ({5})    │" -f $C.INT,(Format-Mod $C.INT),$C.WIS,(Format-Mod $C.WIS),$C.CHA,(Format-Mod $C.CHA)) -ForegroundColor White
    Write-Host "  ├─────────────────────────────────────────┤" -ForegroundColor Cyan
    Write-Host ("  │  Wapen : {0,-32}│" -f "$($C.Weapon.Name) ($($C.Weapon.Dice)d$($C.Weapon.DiceSides)+$($C.Weapon.Bonus))") -ForegroundColor Yellow
    Write-Host ("  │  Pantser: {0,-31}│" -f "$($C.Armor.Name)  (AC $($C.AC))") -ForegroundColor Yellow
    Write-Host ("  │  Goud  : {0,-32}│" -f "$($C.Gold) goudstukken") -ForegroundColor Yellow
    Write-Host ("  │  Drankjes: {0,-30}│" -f "$($C.Potions) levensdrankje(s)") -ForegroundColor Yellow
    if ($C.SpellSlots -gt 0) {
        Write-Host ("  │  Spreuken: {0,-30}│" -f "$($C.SpellSlots) spreukplaatsen") -ForegroundColor Magenta
    }
    Write-Host "  └─────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
}

function Check-LevelUp {
    param($C)
    $xpNeeded = @{ 1 = 300; 2 = 600; 3 = 1200; 4 = 2400; 5 = 99999 }
    if ($C.Level -lt 5 -and $C.XP -ge $xpNeeded[$C.Level]) {
        $C.Level++
        $conMod  = Get-Mod $C.CON
        $hpGain  = (Roll-Dice -Sides $C.HitDie) + $conMod
        if ($hpGain -lt 1) { $hpGain = 1 }
        $C.MaxHP += $hpGain
        $C.HP    += $hpGain
        if ($C.Level -ge 3) { $C.ProfBonus = 3 }
        if ($C.Level -ge 5) { $C.ProfBonus = 4 }
        # Extra spreukplaatsen voor casters
        if ($C.Class -in @("Wizard","Cleric","Ranger")) { $C.SpellSlots += 2 }
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════╗" -ForegroundColor Magenta
        Write-Host ("  ║  🎉 LEVEL UP!  Je bent nu level {0}!   ║" -f $C.Level) -ForegroundColor Magenta
        Write-Host ("  ║  +{0} max HP  |  Proficiency: +{1}      ║" -f $hpGain, $C.ProfBonus) -ForegroundColor Magenta
        Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor Magenta
        Write-Host ""
        Start-Sleep -Seconds 2
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  GEVECHTSSYSTEEM
# ══════════════════════════════════════════════════════════════════════════════

function Do-Combat {
    param($C, $EnemyTemplate)

    # Kloon vijand zodat HP niet blijft hangen
    $e = [PSCustomObject]@{
        Name        = $EnemyTemplate.Name
        HP          = $EnemyTemplate.HP
        MaxHP       = $EnemyTemplate.HP
        AC          = $EnemyTemplate.AC
        AttackBonus = $EnemyTemplate.AttackBonus
        DamageDice  = $EnemyTemplate.DamageDice
        DamageSides = $EnemyTemplate.DamageSides
        InitBonus   = $EnemyTemplate.InitBonus
        XP          = $EnemyTemplate.XP
        GoldDice    = $EnemyTemplate.GoldDice
        Description = $EnemyTemplate.Description
    }

    Show-Header -Title "⚔️  GEVECHT: $($C.Name) vs $($e.Name)!" -Color Red
    Write-Host $e.Description -ForegroundColor DarkYellow
    Write-Host ""

    # Initiative
    $pInit = (Roll-Dice -Sides 20) + (Get-Mod $C.DEX)
    $eInit = (Roll-Dice -Sides 20) + $e.InitBonus
    Write-Host "  Initiative: Jij ($pInit) vs $($e.Name) ($eInit)" -ForegroundColor DarkCyan
    $playerFirst = $pInit -ge $eInit

    $round = 1
    while ($C.HP -gt 0 -and $e.HP -gt 0) {

        Write-Host ""
        Write-Host ("  ─ Ronde {0} ─  Jij: {1}/{2} HP  │  {3}: {4}/{5} HP" -f $round,$C.HP,$C.MaxHP,$e.Name,$e.HP,$e.MaxHP) -ForegroundColor DarkCyan

        # Beschikbare acties
        $acties = "[aanvallen]"
        if ($C.SpellSlots -gt 0) { $acties += " [spreuk]" }
        if ($C.Potions -gt 0)    { $acties += " [drankje]" }
        $acties += " [vluchten] [stats]"
        Write-Host "  $acties" -ForegroundColor Gray

        $actie = (Read-Host "  Jouw actie").Trim().ToLower()

        switch -Regex ($actie) {

            '^a(anval(len)?)?$' {
                $strMod = Get-Mod $C.STR
                $dexMod = Get-Mod $C.DEX
                $atkMod = if ($C.Class -in @("Rogue","Ranger")) { $dexMod } else { $strMod }
                $roll   = Roll-Dice -Sides 20
                $total  = $roll + $atkMod + $C.ProfBonus

                if ($roll -eq 20) {
                    $dmg = (Roll-Dice -Sides $C.Weapon.DiceSides -Count ($C.Weapon.Dice * 2)) + $C.Weapon.Bonus + $atkMod
                    if ($dmg -lt 1) { $dmg = 1 }
                    Write-Host "  💥 KRITIEKE TREFFER! $dmg schade!" -ForegroundColor Magenta
                    $e.HP -= $dmg
                } elseif ($roll -eq 1) {
                    Write-Host "  🎲 Naturel 1 — Je struikelt en mist volledig!" -ForegroundColor DarkRed
                } elseif ($total -ge $e.AC) {
                    $dmg = (Roll-Dice -Sides $C.Weapon.DiceSides -Count $C.Weapon.Dice) + $C.Weapon.Bonus + $atkMod
                    if ($dmg -lt 1) { $dmg = 1 }
                    Write-Host ("  ✅ Geraakt! (gooi {0} vs AC {1}) → {2} schade" -f $total, $e.AC, $dmg) -ForegroundColor Green
                    $e.HP -= $dmg
                } else {
                    Write-Host ("  ❌ Gemist! (gooi {0} vs AC {1})" -f $total, $e.AC) -ForegroundColor Red
                }
            }

            '^s(preuk)?$' {
                if ($C.SpellSlots -le 0) {
                    Write-Host "  ⚠️  Geen spreukplaatsen meer!" -ForegroundColor Yellow
                    continue
                }
                $C.SpellSlots--
                $spellRoll = Roll-Dice -Sides 8 -Count 2
                $intMod    = Get-Mod $C.INT
                if ($C.Class -eq "Cleric") { $intMod = Get-Mod $C.WIS }
                $dmg = $spellRoll + $intMod + $C.Level
                if ($dmg -lt 1) { $dmg = 1 }
                $e.HP -= $dmg
                Write-Host ("  ✨ Spreuk geraakt voor {0} schade! ({1} plaatsen over)" -f $dmg, $C.SpellSlots) -ForegroundColor Cyan
            }

            '^d(rankje)?$' {
                if ($C.Potions -le 0) {
                    Write-Host "  ⚠️  Geen drankjes meer!" -ForegroundColor Yellow
                    continue
                }
                $C.Potions--
                $heal = (Roll-Dice -Sides 8 -Count 2) + 2
                $C.HP = [Math]::Min($C.MaxHP, $C.HP + $heal)
                Write-Host ("  🧪 Drankje gedronken! +{0} HP → {1}/{2}" -f $heal, $C.HP, $C.MaxHP) -ForegroundColor Green
            }

            '^v(luchten)?$' {
                $fleeRoll = Roll-Dice -Sides 20
                if ($fleeRoll -ge 12) {
                    Write-Host "  🏃 Je ontsnapt succesvol!" -ForegroundColor Yellow
                    return "gevlucht"
                } else {
                    Write-Host ("  ❌ Vlucht mislukt! (gooi {0}, had 12+ nodig)" -f $fleeRoll) -ForegroundColor Red
                }
            }

            '^(stats?|karakter)$' {
                Show-Stats -C $C
                continue
            }

            default {
                Write-Host "  ❓ Ongeldige actie." -ForegroundColor DarkGray
                continue
            }
        }

        # Vijand is dood?
        if ($e.HP -le 0) { break }

        # Vijand aanval
        $eRoll  = (Roll-Dice -Sides 20) + $e.AttackBonus
        if ($eRoll -ge $C.AC) {
            $eDmg = Roll-Dice -Sides $e.DamageSides -Count $e.DamageDice
            if ($eDmg -lt 1) { $eDmg = 1 }
            $C.HP -= $eDmg
            Write-Host ("  👹 {0} raakt jou voor {1} schade!" -f $e.Name, $eDmg) -ForegroundColor Red
        } else {
            Write-Host ("  🛡️  {0} mist! (gooi {1} vs jouw AC {2})" -f $e.Name, $eRoll, $C.AC) -ForegroundColor DarkGreen
        }

        $round++
    }

    if ($C.HP -le 0) { return "dood" }

    # Overwinning
    Write-Host ""
    Write-Host ("  🏆 {0} verslagen!" -f $e.Name) -ForegroundColor Green
    $goudWinst = Roll-Dice -Sides $e.GoldDice
    $C.XP   += $e.XP
    $C.Gold += $goudWinst
    Write-Host ("  → +{0} XP  |  +{1} goud" -f $e.XP, $goudWinst) -ForegroundColor Yellow
    Check-LevelUp -C $C
    return "overwinning"
}

# ══════════════════════════════════════════════════════════════════════════════
#  KARAKTERAANMAAK
# ══════════════════════════════════════════════════════════════════════════════

function New-Character {

    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║    ⚔️   POWERSHELL DUNGEONS  ⚔️               ║" -ForegroundColor Magenta
    Write-Host "  ║         The Keep of Shadows                  ║" -ForegroundColor Magenta
    Write-Host "  ║    Een tekstavontuur in D&D-stijl             ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""

    # ── Naam ──────────────────────────────────────────────────────────────────
    do {
        $naam = (Read-Host "  Wat is jouw naam, avonturier?").Trim()
    } while ([string]::IsNullOrWhiteSpace($naam))

    # ── Ras ───────────────────────────────────────────────────────────────────
    $rassenLijst = @("human","elf","half-elf","drow","dwarf","halfling")
    $subrassenMap = @{
        "human"    = @("Militia","Civilian","Warrior")
        "elf"      = @("Wood Elf","High Elf")
        "half-elf" = @("Half-Drow","Half-High Elf","Half-Wood Elf")
        "drow"     = @("Udadrow","Aevendrow","Lorendrow")
        "dwarf"    = @("Hill","Mountain","Duergar")
        "halfling" = @("Lightfoot","Stout","Ghostwise")
    }
    $rasBonus = @{
        "human"    = @{ STR=1; DEX=1; CON=1; INT=1; WIS=1; CHA=1 }
        "elf"      = @{ DEX=2; WIS=1 }
        "half-elf" = @{ CHA=2; DEX=1; INT=1 }
        "drow"     = @{ DEX=2; CHA=1 }
        "dwarf"    = @{ CON=2; STR=1 }
        "halfling" = @{ DEX=2; CHA=1 }
    }
    $rasBeschrijving = @{
        "human"    = "Veelzijdig en aanpasbaar. +1 op alle stats."
        "elf"      = "Sierlijk en scherp. +2 DEX, +1 WIS."
        "half-elf" = "Charismatisch en veelzijdig. +2 CHA, +1 DEX, +1 INT."
        "drow"     = "Duistere elf uit de onderwereld. +2 DEX, +1 CHA."
        "dwarf"    = "Robuust en taai. +2 CON, +1 STR."
        "halfling" = "Klein maar behendig. +2 DEX, +1 CHA."
    }

    Write-Host ""
    Write-Host "  Beschikbare rassen:" -ForegroundColor Cyan
    foreach ($r in $rassenLijst) {
        Write-Host ("  [{0,-10}]  {1}" -f $r, $rasBeschrijving[$r]) -ForegroundColor White
    }
    Write-Host ""

    do {
        $ras = (Read-Host "  Kies je ras").Trim().ToLower()
        if ($ras -notin $rassenLijst) { Write-Host "  ❌ Ongeldig ras." -ForegroundColor Red }
    } while ($ras -notin $rassenLijst)

    # Subras
    $subOpties = $subrassenMap[$ras]
    Write-Host ""
    Write-Host ("  Subrassen voor {0}: [{1}]" -f $ras, ($subOpties -join "] [")) -ForegroundColor Cyan
    do {
        $subInput = (Read-Host "  Kies je subras").Trim()
        $subMatch = $subOpties | Where-Object { $_.ToLower() -eq $subInput.ToLower() }
        if (-not $subMatch) { Write-Host "  ❌ Ongeldig subras." -ForegroundColor Red }
    } while (-not $subMatch)
    $subras = $subMatch

    # ── Klasse ────────────────────────────────────────────────────────────────
    $klasseData = @{
        "Fighter"   = @{ HitDie=10; SpellSlots=0;  Beschrijving="Strijder. Extra aanvallen, hoge HP." }
        "Wizard"    = @{ HitDie=6;  SpellSlots=6;  Beschrijving="Tovenaar. Krachtige spreuken, lage HP." }
        "Rogue"     = @{ HitDie=8;  SpellSlots=0;  Beschrijving="Schurk. Sluipend, DEX-gebaseerd." }
        "Cleric"    = @{ HitDie=8;  SpellSlots=4;  Beschrijving="Priester. Genezend + spreukmagie." }
        "Ranger"    = @{ HitDie=10; SpellSlots=2;  Beschrijving="Jager. DEX-aanvallen + lichte magie." }
        "Barbarian" = @{ HitDie=12; SpellSlots=0;  Beschrijving="Barbaar. Hoogste HP, vernielende aanvallen." }
    }
    $startWapens = @{
        "Fighter"   = @{ Name="Longsword";  Dice=1; DiceSides=8;  Bonus=1 }
        "Wizard"    = @{ Name="Staf";       Dice=1; DiceSides=6;  Bonus=0 }
        "Rogue"     = @{ Name="Dolk (2x)";  Dice=2; DiceSides=4;  Bonus=1 }
        "Cleric"    = @{ Name="Knuppel";    Dice=1; DiceSides=6;  Bonus=1 }
        "Ranger"    = @{ Name="Kortboog";   Dice=1; DiceSides=6;  Bonus=2 }
        "Barbarian" = @{ Name="Strijdbijl"; Dice=1; DiceSides=12; Bonus=0 }
    }
    $startPantser = @{
        "Fighter"   = @{ Name="Maliënkolder"; BaseAC=15 }
        "Wizard"    = @{ Name="Gewaden";      BaseAC=10 }
        "Rogue"     = @{ Name="Leren Pantser";BaseAC=11 }
        "Cleric"    = @{ Name="Schubpantser"; BaseAC=13 }
        "Ranger"    = @{ Name="Leren Pantser";BaseAC=11 }
        "Barbarian" = @{ Name="Huiden";       BaseAC=12 }
    }

    Write-Host ""
    Write-Host "  Beschikbare klassen:" -ForegroundColor Cyan
    foreach ($k in $klasseData.Keys) {
        Write-Host ("  [{0,-10}]  {1}" -f $k, $klasseData[$k].Beschrijving) -ForegroundColor White
    }
    Write-Host ""

    do {
        $klasseInput = (Read-Host "  Kies je klasse").Trim()
        $klasseMatch = $klasseData.Keys | Where-Object { $_.ToLower() -eq $klasseInput.ToLower() }
        if (-not $klasseMatch) { Write-Host "  ❌ Ongeldige klasse." -ForegroundColor Red }
    } while (-not $klasseMatch)
    $klasse = $klasseMatch

    # ── Stats rollen ──────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  Statistieken rollen (4d6, laagste gooi valt weg)..." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500

    $basisStats = @{}
    foreach ($stat in @("STR","DEX","CON","INT","WIS","CHA")) {
        $val = Roll-Dice -Sides 6 -Count 4 -DropLowest
        $basisStats[$stat] = $val
        Write-Host ("  {0}: {1}" -f $stat, $val) -ForegroundColor White
        Start-Sleep -Milliseconds 150
    }

    # Ras bonussen toepassen
    Write-Host ""
    Write-Host ("  Ras bonussen toepassen voor {0}..." -f $ras) -ForegroundColor Cyan
    foreach ($key in $rasBonus[$ras].Keys) {
        $basisStats[$key] += $rasBonus[$ras][$key]
        Write-Host ("  +{0} {1} → {2}" -f $rasBonus[$ras][$key], $key, $basisStats[$key]) -ForegroundColor DarkCyan
    }

    # AC berekening
    $kd      = $klasseData[$klasse]
    $conMod  = Get-Mod $basisStats["CON"]
    $dexMod  = Get-Mod $basisStats["DEX"]
    $pant    = $startPantser[$klasse]
    $ac      = $pant.BaseAC + $dexMod
    $maxHP   = $kd.HitDie + $conMod
    if ($maxHP -lt 5) { $maxHP = 5 }

    $karakter = [PSCustomObject]@{
        Name       = $naam
        Race       = $ras
        SubRace    = $subras
        Class      = $klasse
        Level      = 1
        XP         = 0
        HP         = $maxHP
        MaxHP      = $maxHP
        HitDie     = $kd.HitDie
        STR        = $basisStats["STR"]
        DEX        = $basisStats["DEX"]
        CON        = $basisStats["CON"]
        INT        = $basisStats["INT"]
        WIS        = $basisStats["WIS"]
        CHA        = $basisStats["CHA"]
        AC         = $ac
        ProfBonus  = 2
        SpellSlots = $kd.SpellSlots
        Weapon     = $startWapens[$klasse]
        Armor      = @{ Name = $pant.Name; BaseAC = $pant.BaseAC }
        Gold       = Roll-Dice -Sides 6 -Count 3
        Potions    = 2
    }

    Write-Host ""
    Write-Host "  ✅ Karakter aangemaakt!" -ForegroundColor Green
    Show-Stats -C $karakter
    Pause-Game "Druk op Enter om het avontuur te beginnen..."
    return $karakter
}

# ══════════════════════════════════════════════════════════════════════════════
#  WINKEL
# ══════════════════════════════════════════════════════════════════════════════

function Visit-Shop {
    param($C)

    $winkelItems = @(
        @{ Naam="Levensdrankje (2d8+2 HP)";    Prijs=30;  Type="potion" }
        @{ Naam="Groot Levensdrankje (4d8+4)";  Prijs=60;  Type="bigpotion" }
        @{ Naam="IJzeren Schild (+2 AC)";        Prijs=45;  Type="shield" }
        @{ Naam="Versterkt Pantser (+2 AC base)";Prijs=90;  Type="armor" }
        @{ Naam="Magisch Zwaard (1d8+3)";        Prijs=100; Type="weapon1"; Weapon=@{Name="Magisch Zwaard";Dice=1;DiceSides=8;Bonus=3} }
        @{ Naam="Vlammend Zwaard (2d6+2)";       Prijs=180; Type="weapon2"; Weapon=@{Name="Vlammend Zwaard";Dice=2;DiceSides=6;Bonus=2} }
        @{ Naam="Elixir van Kracht (+2 STR)";    Prijs=75;  Type="str" }
        @{ Naam="Elixir van Behendigheid (+2 DEX)";Prijs=75;Type="dex" }
    )

    Show-Header -Title "🛒  REIZENDE KOOPMAN" -Color Yellow
    Write-Host "  'Hé vriend! Wat heb ik mooie waar voor jou...'" -ForegroundColor DarkYellow
    Write-Host ""

    $winkelen = $true
    while ($winkelen) {
        Write-Host ("  💰 Jouw goud: {0}" -f $C.Gold) -ForegroundColor Yellow
        Write-Host ""
        for ($i = 0; $i -lt $winkelItems.Count; $i++) {
            $item = $winkelItems[$i]
            $kleur = if ($C.Gold -ge $item.Prijs) { "White" } else { "DarkGray" }
            Write-Host ("  [{0}] {1,-40} {2} goud" -f ($i+1), $item.Naam, $item.Prijs) -ForegroundColor $kleur
        }
        Write-Host "  [v] Verlaat winkel" -ForegroundColor Gray
        Write-Host ""

        $keuze = (Read-Host "  Wat wil je kopen?").Trim().ToLower()

        if ($keuze -eq "v") {
            $winkelen = $false
        } elseif ($keuze -match '^\d+$') {
            $idx = [int]$keuze - 1
            if ($idx -ge 0 -and $idx -lt $winkelItems.Count) {
                $item = $winkelItems[$idx]
                if ($C.Gold -ge $item.Prijs) {
                    $C.Gold -= $item.Prijs
                    switch ($item.Type) {
                        "potion"    { $C.Potions++; Write-Host "  ✅ Levensdrankje gekocht!" -ForegroundColor Green }
                        "bigpotion" { $C.Potions += 2; Write-Host "  ✅ 2 grote levensdrankjes gekocht!" -ForegroundColor Green }
                        "shield"    {
                            $C.AC += 2
                            Write-Host ("  ✅ Schild gekocht! AC → {0}" -f $C.AC) -ForegroundColor Green
                        }
                        "armor"     {
                            $C.Armor.BaseAC += 2
                            $dexMod = Get-Mod $C.DEX
                            $C.AC = $C.Armor.BaseAC + $dexMod
                            Write-Host ("  ✅ Versterkt pantser! AC → {0}" -f $C.AC) -ForegroundColor Green
                        }
                        { $_ -in "weapon1","weapon2" } {
                            $C.Weapon = $item.Weapon
                            Write-Host ("  ✅ {0} uitgerust!" -f $item.Weapon.Name) -ForegroundColor Green
                        }
                        "str" { $C.STR += 2; Write-Host "  ✅ +2 STR! → $($C.STR)" -ForegroundColor Green }
                        "dex" {
                            $C.DEX += 2
                            $C.AC = $C.Armor.BaseAC + (Get-Mod $C.DEX)
                            Write-Host ("  ✅ +2 DEX! → {0}  |  AC → {1}" -f $C.DEX, $C.AC) -ForegroundColor Green
                        }
                    }
                } else {
                    Write-Host "  ❌ Niet genoeg goud!" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "  ❓ Ongeldige keuze." -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  AVONTUUR — KAMERS & VERHAAL
# ══════════════════════════════════════════════════════════════════════════════

function Start-Adventure {
    param($C)

    # ── Vijanden definitie ───────────────────────────────────────────────────
    $vijanden = @{
        "Goblin"         = @{ Name="Goblin";          HP=7;  AC=13; AttackBonus=4; DamageDice=1; DamageSides=6;  InitBonus=2;  XP=50;  GoldDice=6;  Description="Een grijnzende goblin springt tevoorschijn met een roestig mes!" }
        "Goblin Sjaaman" = @{ Name="Goblin Sjaaman";  HP=11; AC=12; AttackBonus=3; DamageDice=1; DamageSides=8;  InitBonus=3;  XP=100; GoldDice=8;  Description="Een goblin met een staf van botten mort een vloek!" }
        "Skelet"         = @{ Name="Skelet";           HP=13; AC=13; AttackBonus=4; DamageDice=1; DamageSides=6;  InitBonus=2;  XP=100; GoldDice=4;  Description="Dode botten ratelen terwijl het skelet zijn zwaard heft!" }
        "Skeletridder"   = @{ Name="Skeletridder";     HP=20; AC=15; AttackBonus=5; DamageDice=1; DamageSides=8;  InitBonus=1;  XP=180; GoldDice=10; Description="Een gerusteld skelet in verroest harnas blokkeert de doorgang!" }
        "Ork Strijder"   = @{ Name="Ork Strijder";     HP=18; AC=14; AttackBonus=5; DamageDice=1; DamageSides=12; InitBonus=1;  XP=200; GoldDice=12; Description="Een enorme ork brult en heft zijn slagbijl!" }
        "Duistere Magiër"= @{ Name="Duistere Magiër";  HP=25; AC=12; AttackBonus=5; DamageDice=2; DamageSides=8;  InitBonus=3;  XP=300; GoldDice=20; Description="Duistere energie crackelt rond een in het zwart geklede magiër!" }
        "Drakenwelp"     = @{ Name="Drakenwelp";       HP=38; AC=16; AttackBonus=6; DamageDice=2; DamageSides=10; InitBonus=2;  XP=500; GoldDice=30; Description="Een jonge draak met glanzende schubben sist giftig vuur!" }
        "Grotten Trol"   = @{ Name="Grotten Trol";     HP=84; AC=15; AttackBonus=7; DamageDice=2; DamageSides=8;  InitBonus=-1; XP=900; GoldDice=50; Description="Een kolossale trol met gebarsten groene huid en klauwen als zwaarden!" }
    }

    # ── Kamers definitie ─────────────────────────────────────────────────────
    $kamers = @(

        # ─── ACT 1: Het Dorp ────────────────────────────────────────────────
        @{
            Titel = "Het Dorp van Ashveil"
            Verhaal = @"
  Een kleine nederzetting aan de rand van het Donkere Woud. Angstige dorpelingen
  fluisteren over vreemde figuren die 's nachts het verlaten fort intrekken.
  De dorpsoudste nadert je: 'Avonturier! Het Schimmenfort is wakker geworden.
  Monsters komen elke nacht ons dorp lastigvallen. Ga alsjeblieft — bevrijd ons!'
  
  Je controleert je uitrusting en loopt richting het donkere bos.
"@
            Event = "verhaal"
        }

        # ─── ACT 2: Het Bos ──────────────────────────────────────────────────
        @{
            Titel = "Het Donkere Woud — Bospad"
            Verhaal = "Geknakte takken en gefluister in de duisternis. Ineens —"
            Event = "gevecht"
            Vijand = "Goblin"
        }
        @{
            Titel = "Het Donkere Woud — Verlaten Kamp"
            Verhaal = @"
  Je vindt een verlaten kamp van stropers. Verspreid over de grond liggen
  uitrusting en wat goud — alsof ze in paniek gevlucht zijn.
"@
            Event = "buit"
            Buit = @{ Gold=20; Potions=1; Bericht="Je vindt 20 goud en een levensdrankje!" }
        }
        @{
            Titel = "Het Donkere Woud — Het Moeras"
            Verhaal = "Nevelslierten kronkelen om je enkels. Een goblin-sjaaman roept demonen aan!"
            Event = "gevecht"
            Vijand = "Goblin Sjaaman"
        }

        # ─── ACT 3: De Ruïnes ────────────────────────────────────────────────
        @{
            Titel = "De Ruïnes — Poortbrug"
            Verhaal = "Een oude stenen brug over een droge gracht. Twee skeletten blokkeren de doorgang!"
            Event = "gevecht"
            Vijand = "Skelet"
        }
        @{
            Titel = "De Ruïnes — Wapenruimte"
            Verhaal = @"
  Een oud vertrek vol roestige wapens. Maar in de hoek: een houten kist!
  Je kraakt het slot open...
"@
            Event = "buit"
            Buit = @{ Gold=35; Potions=1; Bericht="Je vindt 35 goud, een drankje en een bruikbaar zwaard!" }
            BuitWapen = @{ Name="Fijn Staal"; Dice=1; DiceSides=8; Bonus=2 }
        }
        @{
            Titel = "De Ruïnes — Binnenplaats"
            Verhaal = @"
  Een koopman in lompen zit geknield tussen kisten. 'Oh goden, eindelijk iemand!
  Die monsters hebben al mijn beschermers gedood. Ik heb nog wat spullen te koop
  als je geïnteresseerd bent — ik moet toch mijn verliezen beperken...'
"@
            Event = "winkel"
        }
        @{
            Titel = "De Ruïnes — Bewakerszaal"
            Verhaal = "Een zware skeletridder in verroest harnas draait zich langzaam naar jou om!"
            Event = "gevecht"
            Vijand = "Skeletridder"
        }

        # ─── ACT 4: Het Fort ─────────────────────────────────────────────────
        @{
            Titel = "Het Schimmenfort — Toegangspoort"
            Verhaal = @"
  De massieve houten poorten van het fort staan open. Het ruikt naar bloed
  en verbrande magie. Een reusachtige ork strijder bewaakt de ingang en
  knakt zijn knokels terwijl hij jou ziet naderen.
"@
            Event = "gevecht"
            Vijand = "Ork Strijder"
        }
        @{
            Titel = "Het Schimmenfort — Geheime Schatkamer"
            Verhaal = @"
  Achter een losstaande steen in de muur vind je een verborgen ruimte.
  Goud, juwelen en magische items liggen opgestapeld — buit van eerdere slachtoffers.
  Je vult je zakken...
"@
            Event = "buit"
            Buit = @{ Gold=60; Potions=2; Bericht="Jackpot! 60 goud en 2 levensdrankjes gevonden!" }
        }
        @{
            Titel = "Het Schimmenfort — Tovergang"
            Verhaal = "In een kamer vol rituele symbolen wacht een duistere magiër. Hij grijnst griezelig..."
            Event = "gevecht"
            Vijand = "Duistere Magiër"
        }
        @{
            Titel = "Het Schimmenfort — Drakennest"
            Verhaal = @"
  Een enorme kamer. Goud en botten bedekken de vloer. Vanuit de duisternis
  klinkt een zacht geblaas — en dan zie je het: een drakenwelp ontvouwt
  zijn vleugels en brumt dreigend!
"@
            Event = "gevecht"
            Vijand = "Drakenwelp"
        }
        @{
            Titel = "Het Schimmenfort — Laatste Rustplaats"
            Verhaal = @"
  Je bent uitgeput maar vastberaden. Een fontein met gloeiend water borrelt
  in de hoek — magisch helend. Je rust even uit voor de eindstrijd.
"@
            Event = "rustplaats"
        }

        # ─── ACT 5: De Eindbaas ───────────────────────────────────────────────
        @{
            Titel = "De Troonsaal — De Grotten Trol"
            Verhaal = @"
  De enorme deuren vliegen open als jij ze aanraakt. In het midden van de
  verrottende troonsaal zit een kolossale trol op een troon van botten.
  Hij staat langzaam op — zijn hoofd raakt bijna het plafond.
  
  'KLEINE DING... IK FIJNMALEN JOU!'
  
  Dit is het. Alles of niets.
"@
            Event = "gevecht"
            Vijand = "Grotten Trol"
        }

        # ─── EINDE ────────────────────────────────────────────────────────────
        @{
            Titel = "✨ OVERWINNING ✨"
            Verhaal = @"
  De trol valt brullend op de grond. Stof en puin dwarrelen omhoog terwijl
  het fort begint te schudden — de duistere magie die het samenhield, lost op.
  
  Je strompelt naar buiten in de frisse ochtendlucht.
  Dorpelingen rennen op je af, juichen en huilen van opluchting.
  
  De dorpsoudste drukt je hand: 'Je hebt ons gered. Ashveil zal jouw naam
  eeuwig herdenken, $naam.'
  
  Het Schimmenfort stort in. De duisternis is verdreven.
"@
            Event = "einde"
        }
    )

    # ── Hoofd-avontuuurlus ───────────────────────────────────────────────────
    $kamerIndex = 0
    $spelenActief = $true

    while ($spelenActief -and $kamerIndex -lt $kamers.Count) {
        $kamer = $kamers[$kamerIndex]

        Clear-Host
        Show-Header -Title $kamer.Titel -Color DarkCyan
        Write-Host $kamer.Verhaal -ForegroundColor White
        Write-Host ""
        Write-Host ("  [HP: {0}/{1}]  [Goud: {2}]  [Drankjes: {3}]  [XP: {4}]" -f $C.HP, $C.MaxHP, $C.Gold, $C.Potions, $C.XP) -ForegroundColor DarkYellow
        Write-Host ""

        switch ($kamer.Event) {

            "verhaal" {
                Pause-Game
            }

            "gevecht" {
                $vijandTempl = $vijanden[$kamer.Vijand]
                $resultaat = Do-Combat -C $C -EnemyTemplate $vijandTempl

                if ($resultaat -eq "dood") {
                    Clear-Host
                    Write-Host ""
                    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor DarkRed
                    Write-Host "  ║          💀  GAME OVER  💀               ║" -ForegroundColor DarkRed
                    Write-Host ("  ║  {0,-42}║" -f "$($C.Name) viel in het duister...") -ForegroundColor DarkRed
                    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor DarkRed
                    Show-Stats -C $C
                    $spelenActief = $false
                    continue
                } elseif ($resultaat -eq "gevlucht") {
                    Write-Host "  Je vlucht terug en bedenkt je strategie opnieuw..." -ForegroundColor Yellow
                    # Herstel 1 HP per gevlucht om niet vast te zitten
                    $C.HP = [Math]::Min($C.MaxHP, $C.HP + 2)
                    Pause-Game
                    # Zelfde kamer opnieuw
                    continue
                }
                Pause-Game
            }

            "buit" {
                $b = $kamer.Buit
                Write-Host ("  🎁  {0}" -f $b.Bericht) -ForegroundColor Green
                $C.Gold    += $b.Gold
                $C.Potions += $b.Potions

                # Optioneel wapen
                if ($kamer.BuitWapen) {
                    $bw = $kamer.BuitWapen
                    Write-Host ("  ⚔️  Je vindt ook: {0} ({1}d{2}+{3})" -f $bw.Name, $bw.Dice, $bw.DiceSides, $bw.Bonus) -ForegroundColor Yellow
                    $optie = (Read-Host "  Wil je dit wapen uitrusten? (ja/nee)").Trim().ToLower()
                    if ($optie -eq "ja") {
                        $C.Weapon = $bw
                        Write-Host "  ✅ Wapen uitgerust!" -ForegroundColor Green
                    }
                }
                Pause-Game
            }

            "winkel" {
                Visit-Shop -C $C
            }

            "rustplaats" {
                Write-Host "  💧 Magische Fontein: Je HP wordt volledig hersteld!" -ForegroundColor Cyan
                $C.HP = $C.MaxHP
                if ($C.SpellSlots -lt $klasseData[$C.Class].SpellSlots -and $C.Class -in @("Wizard","Cleric","Ranger")) {
                    $C.SpellSlots += 2
                    Write-Host "  ✨ +2 spreukplaatsen hersteld!" -ForegroundColor Magenta
                }
                Write-Host ""
                Show-Stats -C $C
                Pause-Game "Je ademde diep in. Druk op Enter voor de eindstrijd..."
            }

            "einde" {
                Clear-Host
                Write-Host ""
                Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
                Write-Host "  ║          🏆  OVERWINNING! GEWELDIG SPEL!  🏆     ║" -ForegroundColor Yellow
                Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow
                Write-Host $kamer.Verhaal -ForegroundColor White
                Write-Host ""
                Show-Stats -C $C
                $spelenActief = $false
                continue
            }
        }

        $kamerIndex++
    }

    Write-Host ""
    Write-Host "  ── Bedankt voor het spelen van PowerShell Dungeons! ──" -ForegroundColor Magenta
    Write-Host ""
    Start-Sleep -Seconds 4
}

# ══════════════════════════════════════════════════════════════════════════════
#  STARTPUNT
# ══════════════════════════════════════════════════════════════════════════════

$mijnKarakter = New-Character
Start-Adventure -C $mijnKarakter

# ──────────────────────────────────────────────────────────────────────────────
#  Na het spel keert het script automatisch terug naar het actieve menu.
# ──────────────────────────────────────────────────────────────────────────────
