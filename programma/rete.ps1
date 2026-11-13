# Fay Live - configurazione rete via cavo (PC centrale e postazioni)
param(
  [Parameter(Mandatory=$true)][ValidateSet('centrale','postazione','avvio','apri','apricentrale','scelta','prepara','diagnosi')][string]$Azione,
  [switch]$Silenzioso,
  [switch]$Nascosto,          # lanciato da un'attivita' pianificata: niente finestre, niente attese di tasti
  [string]$Cartella = ''      # cartella di Fay Live quando lo script gira dalla copia protetta
)
# $BASE = la cartella di Fay Live (quella con "Fay Live.bat"), anche quando lo script gira da un'altra parte
$BASE = if ($Cartella) { $Cartella } else { $PSScriptRoot }
$env:PATH = "$BASE\node;" + $env:PATH
$ErrorActionPreference = 'Stop'
$IP_CENTRALE = '169.254.50.1'
$MASCHERA    = '255.255.0.0'
$PORTA       = 8787
$URL         = "http://$($IP_CENTRALE):$PORTA/pc.html"
$NOME_REGOLA = 'Fay Live - postazioni (porta 8787)'
$CARTELLA_POSTAZIONE = 'C:\FayLive-Postazione'
# cartella unica: ogni portatile ha tutto e sceglie il ruolo a ogni avvio (niente icone separate)
$UNICO = Test-Path (Join-Path $BASE 'Fay Live.bat')
# Chrome riservato a Fay Live: stampa diretta senza finestra di Windows
$PROFILO_CHROME = 'C:\FayLive-Chrome'
$NOME_STAMPANTE = 'DNP|DS620|DS-620|DS 620'
# senza cavo verso il centrale, con internet, la postazione puo' lavorare sulla versione online
$URL_ONLINE = 'https://fay-live.vercel.app/pc.html'

function Ok($t)         { Write-Host "  [OK] $t" -ForegroundColor Green }
function Info($t)       { Write-Host "  $t" }
function Attenzione($t) { Write-Host "  [!] $t" -ForegroundColor Yellow }
# PREPARAZIONE DEL PC (una volta sola): copia protetta dello script + due attivita' pianificate
# che cambiano la rete con i permessi di amministratore SENZA la finestra "Vuoi consentire...?".
$CARTELLA_ADMIN = Join-Path $env:ProgramData 'FayLive'
$ATTIVITA = @{ centrale = 'FayLive-Centrale'; postazione = 'FayLive-Postazione' }
$NOME_REGOLA_NODE = 'Fay Live - programma del PC centrale'

function Attendi-Tasto  { if ($Nascosto) { return }; Write-Host ""; Write-Host "  Premi un tasto per chiudere..."; [void][Console]::ReadKey($true) }
function Errore($t)     {
  if ($Nascosto) {   # nessuno vede la finestra: l'errore si lascia scritto e lo mostra chi ha lanciato l'attivita'
    try { Set-Content -Path (Join-Path $CARTELLA_ADMIN 'ultimo-errore.txt') -Value $t -Encoding UTF8 } catch { }
    exit 1
  }
  Write-Host ""; Write-Host "  [X] $t" -ForegroundColor Red; Attendi-Tasto; exit 1
}

# Il PC e' stato preparato, per QUESTA cartella e con QUESTA versione dello script?
function Preparato {
  try {
    $copia = Join-Path $CARTELLA_ADMIN 'rete.ps1'
    if (-not (Test-Path $copia)) { return $false }
    if ((Get-FileHash $copia).Hash -ne (Get-FileHash (Join-Path $BASE 'rete.ps1')).Hash) { return $false }
    $dove = Get-Content (Join-Path $CARTELLA_ADMIN 'cartella.txt') -ErrorAction Stop | Select-Object -First 1
    if ($dove -ne $BASE) { return $false }
    foreach ($n in $ATTIVITA.Values) { if (-not (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue)) { return $false } }
    return $true
  } catch { return $false }
}

# Esegue "-Azione centrale" o "-Azione postazione" con i permessi di amministratore.
# PC preparato: parte l'attivita' pianificata, in silenzio. Altrimenti (o se l'attivita' non parte):
# come prima, con la finestra di Windows che chiede il permesso. Se il permesso viene negato, errore.
function Esegui-ComeAdmin($ruolo) {
  if (Preparato) {
    try {
      $inizio = Get-Date
      Start-ScheduledTask -TaskName $ATTIVITA[$ruolo] -ErrorAction Stop
      Start-Sleep -Milliseconds 800
      for ($i = 0; $i -lt 90; $i++) {
        if ((Get-ScheduledTask -TaskName $ATTIVITA[$ruolo]).State -ne 'Running') { break }
        Start-Sleep -Milliseconds 700
      }
      $err = Join-Path $CARTELLA_ADMIN 'ultimo-errore.txt'
      if ((Test-Path $err) -and ((Get-Item $err).LastWriteTime -ge $inizio)) { Attenzione ((Get-Content $err -Raw).Trim()) }
      return
    } catch { }   # attivita' non avviabile: si ripiega sulla richiesta di permesso
  }
  Info "Windows chiedera' il permesso: rispondi Si'."
  Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Azione $ruolo -Silenzioso"
}

# Stato del cavo in parole: velocita' del collegamento e indirizzo della scheda
function Stato-Cavo($scheda) {
  $vel = ''
  try { if ($scheda.LinkSpeed) { $vel = " a $($scheda.LinkSpeed)" } } catch { }
  $ip = $null
  try { $ip = @(Get-NetIPAddress -InterfaceIndex $scheda.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.AddressState -eq 'Preferred' })[0].IPAddress } catch { }
  return @{ Velocita = $vel; Ip = $ip }
}

# Windows puo' "addormentare" la scheda di rete per risparmiare corrente: e' il motivo tipico per cui
# il cavo "va staccato e riattaccato". $true = il risparmio e' ancora attivo su questa scheda.
function Risparmio-Attivo($scheda) {
  if (@(Risparmi-Scheda $scheda).Count -gt 0) { return $true }
  try {
    $p = Get-NetAdapterPowerManagement -Name $scheda.Name -ErrorAction Stop
    return ($p.AllowComputerToTurnOffDevice -eq 'Enabled')
  } catch { return $false }
}

# ---------------- DIAGNOSI DEL CAVO ----------------
# Quando il cavo "va staccato e riattaccato": lanciare "Diagnosi cavo.bat" SU QUEL PORTATILE, subito
# dopo che e' successo. Scrive sul desktop un file di testo con tutto quello che serve per capire
# la causa (scheda, risparmi di corrente, indirizzi, e la cronologia di Windows delle ultime 24 ore:
# collegamenti caduti, sospensioni del PC, adattatore USB sparito). Non cambia nessuna impostazione.
function Diagnosi-Cavo {
  $r = New-Object System.Collections.Generic.List[string]
  $r.Add("FAY LIVE - diagnosi del cavo - $env:COMPUTERNAME - $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
  $r.Add("Cartella: $BASE   PC preparato: $(Preparato)")
  $r.Add("Alimentazione: " + $(try { if ((Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1).BatteryStatus -eq 2) { 'in carica' } else { 'A BATTERIA' } } catch { 'n.d.' }))
  $r.Add(""); $r.Add("== SCHEDE DI RETE VIA CAVO ==")
  $schede = @(Schede-Cavo)
  if ($schede.Count -eq 0) { $r.Add("NESSUNA: Windows non vede nessun adattatore di rete via cavo in questo momento.") }
  $servizi = @()
  foreach ($s in $schede) {
    $r.Add("- $($s.Name) | $($s.InterfaceDescription) | stato $($s.Status) | velocita' $($s.LinkSpeed) | driver $($s.DriverProvider) $($s.DriverVersion) del $($s.DriverDate)")
    try { $svc = (Get-CimInstance Win32_NetworkAdapter -Filter "InterfaceIndex=$($s.ifIndex)" -ErrorAction Stop).ServiceName; if ($svc) { $servizi += $svc; $r.Add("  servizio del driver: $svc") } } catch { }
    try { Get-NetIPAddress -InterfaceIndex $s.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $r.Add("  indirizzo $($_.IPAddress)/$($_.PrefixLength) ($($_.PrefixOrigin), $($_.AddressState))") } } catch { }
    try { $r.Add("  DHCP: " + (Get-NetIPInterface -InterfaceIndex $s.ifIndex -AddressFamily IPv4 -ErrorAction Stop).Dhcp) } catch { }
    try { $p = Get-NetAdapterPowerManagement -Name $s.Name -ErrorAction Stop; $r.Add("  Windows puo' spegnere la scheda per risparmiare: $($p.AllowComputerToTurnOffDevice)") } catch { $r.Add("  risparmio di Windows: non leggibile") }
    try {
      Get-NetAdapterAdvancedProperty -Name $s.Name -ErrorAction Stop | ForEach-Object {
        $segno = if ($_.RegistryKeyword -match $RISPARMI_SCHEDA -and "$($_.RegistryValue)" -ne '0') { '  <== RISPARMIO ACCESO' } else { '' }
        $r.Add("  [$($_.RegistryKeyword)] $($_.DisplayName) = $($_.DisplayValue)$segno")
      }
    } catch { $r.Add("  proprieta' avanzate: non leggibili") }
  }
  $r.Add(""); $r.Add("== PC CENTRALE ==")
  $r.Add("Risponde su ${IP_CENTRALE}:$PORTA adesso: $(Porta-Aperta)")
  $r.Add(""); $r.Add("== SOSPENSIONE ==")
  try { (& powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE) | Where-Object { $_ -match 'Indice|Index' } | ForEach-Object { $r.Add("  sospensione dopo (secondi, esadecimale): $($_.Trim())") } } catch { }
  try { (& powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION) | Where-Object { $_ -match 'Indice|Index' } | ForEach-Object { $r.Add("  chiusura coperchio (0 = non fa niente): $($_.Trim())") } } catch { }
  $r.Add(""); $r.Add("== CRONOLOGIA DI WINDOWS, ULTIME 24 ORE (dal piu' recente) ==")
  try {
    $da = (Get-Date).AddHours(-24)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $da } -ErrorAction SilentlyContinue | Where-Object {
      ($servizi -contains $_.ProviderName) -or
      ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -in 42,107,506,507) -or
      ($_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter') -or
      ($_.ProviderName -in 'Microsoft-Windows-Dhcp-Client','Tcpip','Microsoft-Windows-NDIS') -or
      ($_.ProviderName -eq 'Microsoft-Windows-Kernel-PnP' -and $_.Message -match 'USB')
    } | Select-Object -First 150)
    if ($ev.Count -eq 0) { $r.Add("  (nessun evento di rete, sospensione o USB registrato)") }
    foreach ($e in $ev) {
      $m = (($e.Message -split "`r?`n")[0]); if ($m.Length -gt 170) { $m = $m.Substring(0, 170) }
      $r.Add("  $($e.TimeCreated.ToString('dd/MM HH:mm:ss'))  $($e.ProviderName) #$($e.Id)  $m")
    }
  } catch { $r.Add("  cronologia non leggibile: $($_.Exception.Message)") }
  $file = Join-Path ([Environment]::GetFolderPath('Desktop')) ("FayLive-diagnosi-cavo-$env:COMPUTERNAME-" + (Get-Date -Format 'ddMM-HHmm') + ".txt")
  try { Set-Content -Path $file -Value $r -Encoding UTF8 } catch { $file = Join-Path $env:TEMP 'FayLive-diagnosi-cavo.txt'; Set-Content -Path $file -Value $r -Encoding UTF8 }
  Write-Host ""
  Ok "Diagnosi scritta sul desktop: $(Split-Path $file -Leaf)"
  Info "Manda quel file a chi segue Fay Live. Si apre adesso nel Blocco note."
  try { Start-Process notepad.exe $file } catch { }
  Start-Sleep -Seconds 3
}
function Chiedi-SN($t)  { while ($true) { $r = Read-Host "  $t (S/N)"; if ($r -match '^[sS]') { return $true }; if ($r -match '^[nN]') { return $false } } }

# Solo prese di rete via cavo vere (niente WiFi, Bluetooth, schede virtuali)
function Schede-Cavo {
  @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.MediaType -eq '802.3' -and $_.NdisPhysicalMedium -notin 9,10 -and
    $_.InterfaceDescription -notmatch 'Bluetooth|Virtual|VPN|Hyper-V|VMware|VirtualBox|TAP|Wi-?Fi|Wireless'
  })
}

function Ha-IpCentrale($scheda) {
  # 1) come lo vede Windows (indirizzi attivi e salvati)
  try {
    $a = @(Get-NetIPAddress -InterfaceIndex $scheda.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) +
         @(Get-NetIPAddress -InterfaceIndex $scheda.ifIndex -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    if ($a | Where-Object { $_.IPAddress -eq $IP_CENTRALE }) { return $true }
  } catch { }
  # 2) riserva: l'impostazione salvata nel registro della scheda (vale anche a cavo staccato)
  try {
    $ip = (Get-ItemProperty -Path (Chiave-Scheda $scheda) -Name IPAddress -ErrorAction Stop).IPAddress
    if (@($ip) -contains $IP_CENTRALE) { return $true }
  } catch { }
  return $false
}

function Chiave-Scheda($scheda) {
  return "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($scheda.InterfaceGuid)"
}

function Diagnosi-Scheda($scheda) {
  $righe = @("Scheda: $($scheda.Name) / $($scheda.InterfaceDescription) / indice $($scheda.ifIndex) / stato $($scheda.Status)")
  try {
    $ip = @(Get-NetIPAddress -InterfaceIndex $scheda.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) +
          @(Get-NetIPAddress -InterfaceIndex $scheda.ifIndex -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    $righe += "Indirizzi visti: " + (($ip | ForEach-Object { "$($_.IPAddress) ($($_.PolicyStore), $($_.AddressState))" }) -join '; ')
  } catch { $righe += "Lettura indirizzi: ERRORE $($_.Exception.Message)" }
  try {
    $r = Get-ItemProperty -Path (Chiave-Scheda $scheda) -ErrorAction Stop
    $righe += "Registro: DHCP=$($r.EnableDHCP) IP=$(@($r.IPAddress) -join ',')"
  } catch { $righe += "Registro: non letto ($($_.Exception.Message))" }
  return ($righe -join "`n      ")
}

function Collegamento-Desktop($nome, $destinazione, $cartella) {
  $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $desktop "$nome.lnk"))
  $lnk.TargetPath = $destinazione
  $lnk.WorkingDirectory = $cartella
  $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
  $lnk.Save()
}

# Toglie un'icona di Fay Live dal desktop (serve quando un portatile cambia ruolo)
function Togli-Collegamento($nome) {
  foreach ($d in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))) {
    $f = Join-Path $d "$nome.lnk"
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
  }
}

# Risparmi di corrente DELLA SCHEDA (non di Windows): "Energy Efficient Ethernet", "Green Ethernet",
# sospensione selettiva USB, riduzione di velocita'... Sugli adattatori USB-Ethernet sono il motivo
# piu' comune per cui il collegamento cade e torna solo staccando e riattaccando il cavo.
$RISPARMI_SCHEDA = 'EEE|GreenEthernet|SelectiveSuspend|PowerSav|AutoDisableGigabit|GigaLite|ULPMode|DeviceSleepOnDisconnect|ReduceSpeedOnPowerDown'
function Risparmi-Scheda($scheda) {   # le voci di risparmio ancora accese su questa scheda
  try {
    return @(Get-NetAdapterAdvancedProperty -Name $scheda.Name -ErrorAction Stop |
      Where-Object { $_.RegistryKeyword -match $RISPARMI_SCHEDA -and "$($_.RegistryValue)" -ne '0' })
  } catch { return @() }
}
function Proteggi-Corrente($scheda) {
  try { Disable-NetAdapterPowerManagement -Name $scheda.Name -NoRestart -ErrorAction Stop | Out-Null } catch { }
  $cambiato = $false
  foreach ($v in (Risparmi-Scheda $scheda)) {
    try { Set-NetAdapterAdvancedProperty -Name $scheda.Name -RegistryKeyword $v.RegistryKeyword -RegistryValue 0 -NoRestart -ErrorAction Stop; $cambiato = $true } catch { }
  }
  # le nuove impostazioni valgono dopo un riavvio della scheda (qualche secondo senza rete)
  if ($cambiato) { try { Restart-NetAdapter -Name $scheda.Name -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 4 } catch { } }
}

# ---------------- PC CENTRALE ----------------
function Configura-Centrale {
  Info "Configuro questo portatile come PC CENTRALE..."
  Write-Host ""
  if (-not (Test-Path (Join-Path $BASE '_motore.bat'))) {
    Errore "Non trovo _motore.bat qui accanto. Copia questi file DENTRO la cartella FayCentrale e rilancia."
  }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Errore "Node.js non e' installato su questo portatile: senza Node il PC centrale non parte. Installalo da nodejs.org (versione LTS), riavvia il PC e rilancia."
  }
  $schede = @(Schede-Cavo)
  if ($schede.Count -eq 0) { Errore "Nessuna presa di rete via cavo. Inserisci l'adattatore USB-Ethernet e rilancia." }
  $scheda = $null
  if ($schede.Count -eq 1) { $scheda = $schede[0] }
  else {
    $attive = @($schede | Where-Object Status -eq 'Up')
    if ($attive.Count -eq 1) { $scheda = $attive[0] }
    else { Errore "Trovo piu' prese di rete ($($schede.Name -join ', ')). Lascia collegato SOLO il cavo verso le postazioni e rilancia." }
  }

  # Indirizzo fisso del PC centrale sulla presa via cavo
  $rispostaWin = & netsh interface ipv4 set address "$($scheda.Name)" static $IP_CENTRALE $MASCHERA
  & netsh interface ipv4 set dnsservers "$($scheda.Name)" static none | Out-Null
  # Windows a volte impiega qualche secondo: riprovo il controllo fino a 15 secondi
  $accettato = $false
  for ($i = 0; $i -lt 15 -and -not $accettato; $i++) { Start-Sleep -Seconds 1; $accettato = Ha-IpCentrale $scheda }
  if (-not $accettato) {
    $testo = (($rispostaWin | Out-String).Trim())
    if (-not $testo) { $testo = '(nessun messaggio)' }
    Errore "Windows non ha accettato l'indirizzo sulla presa '$($scheda.Name)'. Risposta di Windows: $testo.`n      $(Diagnosi-Scheda $scheda)`n  Manda uno screenshot di questa finestra."
  }
  Ok "Presa di rete '$($scheda.Name)' impostata come PC centrale"

  # Le altre prese via cavo (se ce ne sono) non devono avere lo stesso indirizzo
  foreach ($s in $schede) {
    if ($s.ifIndex -ne $scheda.ifIndex -and (Ha-IpCentrale $s)) {
      & netsh interface ipv4 set address "$($s.Name)" dhcp | Out-Null
    }
  }
  Proteggi-Corrente $scheda

  # Firewall: apre Fay Live solo ai PC collegati direttamente, con rete pubblica o privata
  Get-NetFirewallRule -DisplayName $NOME_REGOLA -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $NOME_REGOLA -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $PORTA -Profile Any -RemoteAddress LocalSubnet | Out-Null
  try {
    Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
      Where-Object { $_.Program -like '*\node.exe' } | Get-NetFirewallRule |
      Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' -and $_.Enabled -eq 'True' } |
      Disable-NetFirewallRule
  } catch { }
  Ok "Firewall pronto per le postazioni"

  # Il PC centrale non deve mai addormentarsi durante il servizio
  & powercfg /change standby-timeout-ac 0 | Out-Null
  & powercfg /change standby-timeout-dc 0 | Out-Null
  & powercfg /change hibernate-timeout-ac 0 | Out-Null
  & powercfg /change hibernate-timeout-dc 0 | Out-Null
  & powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
  & powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
  & powercfg /setactive SCHEME_CURRENT | Out-Null
  Ok "Sospensione disattivata (anche chiudendo il coperchio)"

  if (-not $UNICO) { Collegamento-Desktop 'Fay Live - PC centrale' (Join-Path $BASE 'Avvia Fay Live.bat') $BASE }
  if (-not $UNICO) { Ok "Icona 'Fay Live - PC centrale' creata sul desktop" }
  # se prima era una postazione, la sua icona non deve restare (due icone = confusione)
  if (-not $UNICO) { Togli-Collegamento 'Fay Live' }

  Write-Host ""
  Ok "FATTO. Da ora avvia sempre Fay Live dall'icona sul desktop."
  if (-not $Silenzioso) { Attendi-Tasto }
}

# ---------------- POSTAZIONE ----------------
function Configura-Postazione {
  Info "Configuro questo portatile come POSTAZIONE..."
  Write-Host ""
  $schede = @(Schede-Cavo)
  if ($schede.Count -eq 0) { Errore "Nessuna presa di rete via cavo. Inserisci l'adattatore USB-Ethernet e rilancia." }
  foreach ($s in $schede) {
    & netsh interface ipv4 set address "$($s.Name)" dhcp | Out-Null
    & netsh interface ipv4 set dnsservers "$($s.Name)" dhcp | Out-Null
    Proteggi-Corrente $s
  }
  Ok "Presa di rete in automatico (l'indirizzo se lo prende da sola)"

  if (-not $UNICO) { New-Item -ItemType Directory -Force -Path $CARTELLA_POSTAZIONE | Out-Null }
  if (-not $UNICO -and ((Resolve-Path $BASE).Path.TrimEnd('\') -ne (Resolve-Path $CARTELLA_POSTAZIONE).Path.TrimEnd('\'))) {
    Copy-Item (Join-Path $BASE 'rete.ps1') $CARTELLA_POSTAZIONE -Force
    Copy-Item (Join-Path $BASE 'Apri Fay Live.bat') $CARTELLA_POSTAZIONE -Force
  }
  if (-not $UNICO) { Get-ChildItem $CARTELLA_POSTAZIONE | Unblock-File -ErrorAction SilentlyContinue }
  if (-not $UNICO) { Collegamento-Desktop 'Fay Live' (Join-Path $CARTELLA_POSTAZIONE 'Apri Fay Live.bat') $CARTELLA_POSTAZIONE }
  if (-not $UNICO) { Ok "Icona 'Fay Live' creata sul desktop" }

  # Se prima era il PC centrale: via la sua icona, la porta aperta e le regole "da servizio",
  # cosi' nessuno puo' avviare per sbaglio un secondo PC centrale.
  $eraCentrale = $false
  foreach ($d in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))) {
    if (Test-Path (Join-Path $d 'Fay Live - PC centrale.lnk')) { $eraCentrale = $true }
  }
  if (Get-NetFirewallRule -DisplayName $NOME_REGOLA -ErrorAction SilentlyContinue) { $eraCentrale = $true }
  if ($eraCentrale) {
    Togli-Collegamento 'Fay Live - PC centrale'
    Get-NetFirewallRule -DisplayName $NOME_REGOLA -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    & powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null
    & powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 1 | Out-Null
    & powercfg /change standby-timeout-dc 15 | Out-Null
    & powercfg /setactive SCHEME_CURRENT | Out-Null
    Ok "Tolte le impostazioni da PC centrale (icona, porta, coperchio)"
    Attenzione "Gli originali delle piscine importati quando era PC centrale restano su questo portatile (cartelle dati e Archivio di Fay Live): NON cancellarle."
  }

  & powercfg /change standby-timeout-ac 0 | Out-Null
  Ok "Sospensione disattivata quando e' in carica"
  Write-Host ""
  Ok "FATTO. In servizio basta collegare il cavo e aprire l'icona 'Fay Live'."
  if (-not $Silenzioso) { Attendi-Tasto }
}

# ---------------- AVVIO SUL PC CENTRALE ----------------
function Controllo-Avvio {
  Write-Host ""
  Info "Controllo la presa di rete per le postazioni..."
  if (Porta-Aperta) {
    Write-Host ""
    Write-Host "  [X] Sul cavo c'e' gia' un PC centrale acceso con Fay Live." -ForegroundColor Red
    if (@(Schede-Cavo | Where-Object { Ha-IpCentrale $_ }).Count -gt 0) { Info "E' questo stesso PC: Fay Live e' gia' aperto. Cerca la finestra nera o il browser gia' aperti." }
    else { Info "Ce ne puo' essere uno solo: su questo portatile apri invece l'icona 'Fay Live' (postazione)." }
    Attendi-Tasto; exit 1
  }
  $schede = @(Schede-Cavo)
  if ($schede.Count -eq 0) {
    Attenzione "Adattatore di rete NON inserito: le postazioni via cavo non potranno collegarsi."
    if (-not (Chiedi-SN "Avvio Fay Live lo stesso?")) { exit 1 }
    if (-not (Controlla-Stampante)) { exit 1 }
    exit 0
  }
  $pronta = @($schede | Where-Object { Ha-IpCentrale $_ })
  if ($pronta.Count -eq 0) {
    Info "Imposto la presa di rete di questo portatile come PC centrale..."
    try {
      Esegui-ComeAdmin 'centrale'
    } catch {
      Attenzione "Permesso negato: le postazioni via cavo non potranno collegarsi."
      if (-not (Chiedi-SN "Avvio Fay Live lo stesso?")) { exit 1 }
      exit 0
    }
    $pronta = @(Schede-Cavo | Where-Object { Ha-IpCentrale $_ })
    if ($pronta.Count -eq 0) {
      Attenzione "Impostazione non riuscita: le postazioni via cavo non potranno collegarsi."
      if (-not (Chiedi-SN "Avvio Fay Live lo stesso?")) { exit 1 }
      exit 0
    }
  }
  # la scheda non deve "addormentarsi" a meta' servizio (su un PC preparato si sistema da solo, in silenzio)
  if ((Risparmio-Attivo $pronta[0]) -and (Preparato)) { try { Esegui-ComeAdmin 'centrale' } catch { } }
  if (-not (Controlla-Stampante)) { exit 1 }
  $viva = @(Schede-Cavo | Where-Object { Ha-IpCentrale $_ })
  if ($viva.Count -eq 0 -or $viva[0].Status -ne 'Up') {
    Attenzione "CAVO NON COLLEGATO (o switch spento, o cavo entrato male): infilalo fino al clic."
    Info "Puoi collegarlo anche dopo: le postazioni si agganciano da sole, e in Fay Live la spia"
    Info "in basso dice quante postazioni sono collegate."
  } else {
    $c = Stato-Cavo $viva[0]
    Ok "Cavo collegato$($c.Velocita): rete per le postazioni pronta"
  }
  exit 0
}

# ---------------- APERTURA SULLA POSTAZIONE ----------------
function Porta-Aperta {
  $c = New-Object System.Net.Sockets.TcpClient
  try {
    $r = $c.BeginConnect($IP_CENTRALE, $PORTA, $null, $null)
    if ($r.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) { return $true }
    return $false
  } catch { return $false } finally { $c.Close() }
}

function Trova-Chrome {
  @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

# La stampa parte senza conferma sulla stampante PREDEFINITA: deve essere la DNP
function Controlla-Stampante {
  $pred = $null
  try { $pred = Get-CimInstance Win32_Printer -Filter "Default=True" -ErrorAction Stop | Select-Object -First 1 } catch { }
  if ($pred -and $pred.Name -match $NOME_STAMPANTE) { Ok "Stampa diretta sulla $($pred.Name)"; return $true }
  Write-Host ""
  if ($pred) { Attenzione "La stampante predefinita e' '$($pred.Name)', NON la DNP: le foto andrebbero li' senza chiedere." }
  else       { Attenzione "Nessuna stampante predefinita: le foto non verrebbero stampate." }
  Info "Per sistemare: Impostazioni > Bluetooth e dispositivi > Stampanti e scanner > DNP > Imposta come predefinita"
  Info "(e prima togli la spunta a 'Consenti a Windows di gestire la stampante predefinita')."
  return (Chiedi-SN "Apro Fay Live lo stesso?")
}

function Apri-Browser($url) {
  $chrome = Trova-Chrome
  if (-not $chrome) { Attenzione "Chrome non trovato: apro il browser normale, con la finestra di stampa."; Start-Process $url; return }
  Start-Process $chrome -ArgumentList @("--user-data-dir=`"$PROFILO_CHROME`"", "--kiosk-printing", "--no-first-run", "--no-default-browser-check", $url)
}

function Apri-Centrale {
  # aspetta che il motore (finestra nera) sia pronto, poi apre la pagina
  $limite = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $limite) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $r = $c.BeginConnect('127.0.0.1', $PORTA, $null, $null); if ($r.AsyncWaitHandle.WaitOne(1000) -and $c.Connected) { $c.Close(); Apri-Browser "http://localhost:$PORTA/pc.html"; exit 0 } } catch { } finally { $c.Close() }
    Start-Sleep -Seconds 1
  }
  exit 1
}

function Internet-Ok {
  $c = New-Object System.Net.Sockets.TcpClient
  try { $r = $c.BeginConnect('fay-live.vercel.app', 443, $null, $null); return ($r.AsyncWaitHandle.WaitOne(4000) -and $c.Connected) }
  catch { return $false } finally { $c.Close() }
}

function Apri-Online {
  Write-Host ""
  if (-not (Internet-Ok)) { Attenzione "Non c'e' internet: la versione online non si puo' aprire."; return $false }
  if (-not (Controlla-Stampante)) { return $false }
  Info "Apro la versione online di Fay Live (lavora sul cloud)..."
  Apri-Browser $URL_ONLINE
  Start-Sleep -Seconds 2
  return $true
}

function Apri-Postazione {
  Write-Host ""
  Write-Host "  FAY LIVE - collegamento al PC centrale" -ForegroundColor Cyan
  Write-Host ""
  $limite = (Get-Date).AddSeconds(90)
  $ultimo = ''
  $giaSistemata = $false
  $risparmioVisto = $false
  while ($true) {
    $schede = @(Schede-Cavo)
    $attive = @($schede | Where-Object Status -eq 'Up')
    if ($schede.Count -eq 0)      { $stato = "Adattatore di rete non inserito: infilalo nella porta USB." }
    elseif ($attive.Count -eq 0)  { $stato = "Cavo non collegato (o switch spento): controlla il cavo." }
    else {
      $fisso = $attive | Where-Object { (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Disabled' }
      if ($fisso -and -not $giaSistemata) {
        $giaSistemata = $true
        Info "Questo portatile l'ultima volta faceva da PC centrale: lo rimetto come postazione."
        try {
          Esegui-ComeAdmin 'postazione'
          Ok "Fatto: ora e' una postazione"
        } catch { Attenzione "Permesso negato." }
        $ultimo = ''; continue
      }
      elseif ($fisso) { $stato = "Questa presa di rete e' ancora impostata come PC centrale: chiudi, riapri Fay Live, premi 2 e rispondi Si' alla richiesta di Windows." }
      elseif (-not $risparmioVisto -and (Risparmio-Attivo $attive[0]) -and (Preparato)) {
        # la scheda non deve "addormentarsi" a meta' servizio: su un PC preparato si sistema da solo
        $risparmioVisto = $true
        try { Esegui-ComeAdmin 'postazione' } catch { }
        $ultimo = ''; continue
      }
      elseif (Porta-Aperta) {
        $c = Stato-Cavo $attive[0]
        Ok "Cavo collegato$($c.Velocita): PC centrale trovato"
        if (-not (Controlla-Stampante)) { exit 1 }; Info "Apro Fay Live..."; Apri-Browser $URL; Start-Sleep -Seconds 2; exit 0
      }
      else {
        $c = Stato-Cavo $attive[0]
        if (-not $c.Ip) { $stato = "Cavo collegato$($c.Velocita). Windows sta preparando la rete: puo' servire fino a un minuto, non staccare..." }
        elseif ($c.Ip -notlike '169.254.*') { $stato = "Cavo collegato$($c.Velocita), ma questa presa ha preso l'indirizzo $($c.Ip) da un router: il cavo deve andare al PC centrale (o al suo switch), non al router di casa/ufficio." }
        else { $stato = "Cavo collegato$($c.Velocita) e rete pronta. Aspetto il PC centrale: deve essere acceso, con Fay Live avviato (premuto 1) e il suo cavo infilato bene..." }
      }
    }
    if ($stato -ne $ultimo) { Info $stato; Info "(Senza cavo? Premi O per aprire la versione online: serve internet)"; $ultimo = $stato }
    try {
      if ([Console]::KeyAvailable -and ([Console]::ReadKey($true).KeyChar -in 'o','O')) { if (Apri-Online) { exit 0 } }
    } catch { }
    if ((Get-Date) -gt $limite) {
      Write-Host ""
      Attenzione "Non riesco a collegarmi al PC centrale."
      Info "Controlla: 1) cavi infilati bene  2) switch acceso  3) sul PC centrale la finestra nera di Fay Live aperta."
      if (Chiedi-SN "Apro la versione online (serve internet)?") { if (Apri-Online) { exit 0 } }
      if (Chiedi-SN "Riprovo?") { $limite = (Get-Date).AddSeconds(90); $ultimo = ''; continue }
      exit 1
    }
    Start-Sleep -Seconds 2
  }
}

# ---------------- SCELTA DEL RUOLO (cartella unica) ----------------
# l'icona sul desktop si crea da sola; l'uscita dice a "Fay Live.bat" cosa lanciare (10 = centrale, 20 = postazione)
# L'icona punta a cmd.exe (che lancia "Fay Live.bat") e non direttamente al .bat: solo cosi' Windows
# permette "Aggiungi alla barra delle applicazioni". L'immagine e' faylive.ico (il logo Frame).
function Icona-Unica {
  $bat = Join-Path $BASE 'Fay Live.bat'
  $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $arg = "/c `"`"$bat`"`""
  $ico = Join-Path $BASE 'faylive.ico'
  $icona = if (Test-Path $ico) { "$ico,0" } else { "$env:SystemRoot\System32\shell32.dll,13" }
  $scrivi = {
    param($f)
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($f)
    if ($lnk.TargetPath -eq $cmd -and $lnk.Arguments -eq $arg -and $lnk.IconLocation -eq $icona) { return }
    $lnk.TargetPath = $cmd
    $lnk.Arguments = $arg
    $lnk.WorkingDirectory = $BASE
    $lnk.IconLocation = $icona
    $lnk.Description = 'Fay Live'
    $lnk.Save()
  }
  $cartelle = @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))
  $trovata = $false
  foreach ($d in $cartelle) {      # un'icona c'e' gia': si aggiorna quella (bersaglio e immagine), senza farne una seconda
    $f = Join-Path $d 'Fay Live.lnk'
    if (Test-Path $f) { $trovata = $true; try { & $scrivi $f } catch { } }
  }
  if ($trovata) { return }
  foreach ($d in $cartelle) {
    try { & $scrivi (Join-Path $d 'Fay Live.lnk'); return } catch { }
  }
}

function Scelta-Ruolo {
  Icona-Unica
  Write-Host ""
  Write-Host "  FAY LIVE" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  1 = PC CENTRALE   (questo portatile raccoglie le foto)"
  Write-Host "  2 = POSTAZIONE    (si collega al PC centrale, vede e stampa)"
  Write-Host ""
  Write-Host "  Premi 1 oppure 2 (Esc per uscire)"
  $prep = Preparato
  if (-not $prep) {
    Write-Host ""
    Write-Host "  (Questo PC non e' ancora preparato: premi P per prepararlo una volta sola," -ForegroundColor DarkGray
    Write-Host "   cosi' Fay Live non chiedera' piu' permessi a Windows. Funziona anche senza.)" -ForegroundColor DarkGray
  }
  while ($true) {
    $k = [Console]::ReadKey($true)
    if ($k.KeyChar -eq '1') { exit 10 }
    if ($k.KeyChar -eq '2') { exit 20 }
    if ($k.Key -eq 'Escape') { exit 1 }
    if (-not $prep -and $k.KeyChar -in 'p','P') {
      Info "Preparo il PC: Windows chiede il permesso UNA volta, rispondi Si'."
      try { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Azione prepara" } catch { Attenzione "Permesso negato: resta tutto come prima." }
      $prep = Preparato
      if ($prep) { Ok "PC preparato." }
      Write-Host ""
      Write-Host "  Premi 1 oppure 2 (Esc per uscire)"
    }
  }
}

# ---------------- PREPARAZIONE DEL PC (una volta sola, da amministratore) ----------------
# Fa in un colpo tutto quello che altrimenti Windows chiederebbe poco alla volta, cosi' chi usa
# Fay Live in servizio deve solo aprire l'icona e premere 1 o 2:
#  - toglie il blocco "file scaricato da internet" ai file della cartella;
#  - apre il firewall al programma del PC centrale (niente finestra "Consenti accesso");
#  - spegne i risparmi di corrente che addormentano la scheda di rete e le porte USB;
#  - mette la DNP come stampante predefinita, se c'e';
#  - registra due attivita' pianificate che cambiano la rete (centrale/postazione) con i
#    permessi di amministratore SENZA la finestra "Vuoi consentire...?".
function Prepara-PC {
  Write-Host ""
  Write-Host "  FAY LIVE - preparazione di questo PC (si fa una volta sola)" -ForegroundColor Cyan
  Write-Host ""
  $io = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $io.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Errore "La preparazione va fatta da amministratore: apri 'Prepara questo PC.bat' e rispondi Si' alla richiesta di Windows."
  }
  if (-not (Test-Path (Join-Path $BASE 'Fay Live.bat'))) { Errore "Non trovo 'Fay Live.bat' in $BASE." }

  try { Get-ChildItem -Path $BASE -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue } catch { }
  Ok "File di Fay Live sbloccati"

  # firewall: il programma del PC centrale puo' ricevere dalle postazioni collegate direttamente
  try {
    Get-NetFirewallRule -DisplayName $NOME_REGOLA_NODE -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $NOME_REGOLA_NODE -Direction Inbound -Action Allow -Protocol TCP `
      -Program (Join-Path $BASE 'node\node.exe') -Profile Any -RemoteAddress LocalSubnet | Out-Null
    Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
      Where-Object { $_.Program -like '*\node.exe' } | Get-NetFirewallRule |
      Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' -and $_.Enabled -eq 'True' } |
      Disable-NetFirewallRule
    Ok "Firewall pronto (nessuna finestra 'Consenti accesso' al primo avvio)"
  } catch { Attenzione "Firewall non impostato: $($_.Exception.Message)" }

  # corrente: niente sospensione in carica, niente scheda di rete o porta USB che si addormenta
  & powercfg /change standby-timeout-ac 0 | Out-Null
  & powercfg /change standby-timeout-dc 0 | Out-Null     # nemmeno a batteria: al risveglio l'adattatore USB spesso non riparte
  & powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
  & powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
  & powercfg /setactive SCHEME_CURRENT | Out-Null
  $schede = @(Schede-Cavo)
  foreach ($s in $schede) { Proteggi-Corrente $s }
  if ($schede.Count) { Ok "Risparmio di corrente spento sulla scheda di rete ($($schede.Name -join ', ')) e sulle porte USB" }
  else { Attenzione "Adattatore di rete non inserito adesso: il suo risparmio di corrente verra' spento al primo avvio con il cavo." }

  # stampante: la DNP come predefinita, e Windows non la cambia piu' da solo
  try {
    $dnp = @(Get-CimInstance Win32_Printer -ErrorAction Stop | Where-Object { $_.Name -match $NOME_STAMPANTE })
    if ($dnp.Count -eq 1) {
      New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -Value 1 -PropertyType DWord -Force | Out-Null
      Invoke-CimMethod -InputObject $dnp[0] -MethodName SetDefaultPrinter | Out-Null
      Ok "Stampante predefinita: $($dnp[0].Name)"
    } elseif ($dnp.Count -eq 0) { Attenzione "Stampante DNP non installata su questo PC: installala e impostala come predefinita." }
    else { Attenzione "Trovate piu' stampanti DNP ($($dnp.Name -join ', ')): scegli tu quella predefinita dalle Impostazioni." }
  } catch { Attenzione "Stampante non controllata: $($_.Exception.Message)" }

  # copia protetta dello script (solo gli amministratori possono cambiarla) + attivita' pianificate
  try {
    New-Item -ItemType Directory -Force -Path $CARTELLA_ADMIN | Out-Null
    $copia = Join-Path $CARTELLA_ADMIN 'rete.ps1'
    Copy-Item (Join-Path $BASE 'rete.ps1') $copia -Force
    Set-Content -Path (Join-Path $CARTELLA_ADMIN 'cartella.txt') -Value $BASE -Encoding UTF8
    Remove-Item (Join-Path $CARTELLA_ADMIN 'ultimo-errore.txt') -Force -ErrorAction SilentlyContinue
    & icacls $CARTELLA_ADMIN /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    foreach ($ruolo in $ATTIVITA.Keys) {
      $az  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$copia`" -Azione $ruolo -Silenzioso -Nascosto -Cartella `"$BASE`""
      $chi = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest
      $imp = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
      Register-ScheduledTask -TaskName $ATTIVITA[$ruolo] -Action $az -Principal $chi -Settings $imp -Force `
        -Description 'Fay Live: imposta la presa di rete via cavo per il ruolo scelto' | Out-Null
    }
    Ok "Cambio di ruolo (centrale / postazione) senza piu' richieste di permesso"
  } catch { Attenzione "Attivita' non registrate ($($_.Exception.Message)): Fay Live funziona lo stesso, ma chiedera' il permesso come prima." }

  Icona-Unica
  Write-Host ""
  if (Preparato) { Ok "FATTO. Da ora basta aprire l'icona 'Fay Live' e premere 1 oppure 2." }
  else { Attenzione "Preparazione incompleta: Fay Live funziona lo stesso, chiedendo i permessi come prima." }
  Attenzione "Se sposti o aggiorni la cartella di Fay Live, rifai la preparazione (basta premere P all'avvio)."
  Attendi-Tasto
}

switch ($Azione) {
  'scelta'     { Scelta-Ruolo }
  'prepara'    { Prepara-PC }
  'diagnosi'   { Diagnosi-Cavo }
  'centrale'   { Configura-Centrale }
  'postazione' { Configura-Postazione }
  'avvio'      { Controllo-Avvio }
  'apri'       { Apri-Postazione }
  'apricentrale' { Apri-Centrale }
}
