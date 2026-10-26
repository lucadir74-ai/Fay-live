# Fay Live - configurazione rete via cavo (PC centrale e postazioni)
param(
  [Parameter(Mandatory=$true)][ValidateSet('centrale','postazione','avvio','apri','apricentrale')][string]$Azione,
  [switch]$Silenzioso
)
$ErrorActionPreference = 'Stop'
$IP_CENTRALE = '169.254.50.1'
$MASCHERA    = '255.255.0.0'
$PORTA       = 8787
$URL         = "http://$($IP_CENTRALE):$PORTA/pc.html"
$NOME_REGOLA = 'Fay Live - postazioni (porta 8787)'
$CARTELLA_POSTAZIONE = 'C:\FayLive-Postazione'
# Chrome riservato a Fay Live: stampa diretta senza finestra di Windows
$PROFILO_CHROME = 'C:\FayLive-Chrome'
$NOME_STAMPANTE = 'DNP|DS620|DS-620|DS 620'

function Ok($t)         { Write-Host "  [OK] $t" -ForegroundColor Green }
function Info($t)       { Write-Host "  $t" }
function Attenzione($t) { Write-Host "  [!] $t" -ForegroundColor Yellow }
function Attendi-Tasto  { Write-Host ""; Write-Host "  Premi un tasto per chiudere..."; [void][Console]::ReadKey($true) }
function Errore($t)     { Write-Host ""; Write-Host "  [X] $t" -ForegroundColor Red; Attendi-Tasto; exit 1 }
function Chiedi-SN($t)  { while ($true) { $r = Read-Host "  $t (S/N)"; if ($r -match '^[sS]') { return $true }; if ($r -match '^[nN]') { return $false } } }

# Solo prese di rete via cavo vere (niente WiFi, Bluetooth, schede virtuali)
function Schede-Cavo {
  @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.MediaType -eq '802.3' -and $_.NdisPhysicalMedium -notin 9,10 -and
    $_.InterfaceDescription -notmatch 'Bluetooth|Virtual|VPN|Hyper-V|VMware|VirtualBox|TAP|Wi-?Fi|Wireless'
  })
}

function Ha-IpCentrale($scheda) {
  $a = @(Get-NetIPAddress -InterfaceIndex $scheda.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) +
       @(Get-NetIPAddress -InterfaceIndex $scheda.ifIndex -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
  return [bool]($a | Where-Object { $_.IPAddress -eq $IP_CENTRALE })
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

function Proteggi-Corrente($scheda) {
  try { Disable-NetAdapterPowerManagement -Name $scheda.Name -NoRestart -ErrorAction Stop | Out-Null } catch { }
}

# ---------------- PC CENTRALE ----------------
function Configura-Centrale {
  Info "Configuro questo portatile come PC CENTRALE..."
  Write-Host ""
  if (-not (Test-Path (Join-Path $PSScriptRoot 'avvia.bat'))) {
    Errore "Non trovo avvia.bat qui accanto. Copia questi file DENTRO la cartella FayCentrale e rilancia."
  }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Errore "Node.js non e' installato su questo portatile: senza Node il PC centrale non parte. Installalo da nodejs.org (versione LTS), riavvia il PC e rilancia."
  }
  $schede = Schede-Cavo
  if ($schede.Count -eq 0) { Errore "Nessuna presa di rete via cavo. Inserisci l'adattatore USB-Ethernet e rilancia." }
  $scheda = $null
  if ($schede.Count -eq 1) { $scheda = $schede[0] }
  else {
    $attive = @($schede | Where-Object Status -eq 'Up')
    if ($attive.Count -eq 1) { $scheda = $attive[0] }
    else { Errore "Trovo piu' prese di rete ($($schede.Name -join ', ')). Lascia collegato SOLO il cavo verso le postazioni e rilancia." }
  }

  # Indirizzo fisso del PC centrale sulla presa via cavo
  & netsh interface ipv4 set address "$($scheda.Name)" static $IP_CENTRALE $MASCHERA | Out-Null
  & netsh interface ipv4 set dnsservers "$($scheda.Name)" static none | Out-Null
  Start-Sleep -Seconds 2
  if (-not (Ha-IpCentrale $scheda)) { Errore "Windows non ha accettato l'indirizzo sulla presa '$($scheda.Name)'. Manda uno screenshot di questa finestra." }
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

  Collegamento-Desktop 'Fay Live - PC centrale' (Join-Path $PSScriptRoot 'Avvia Fay Live.bat') $PSScriptRoot
  Ok "Icona 'Fay Live - PC centrale' creata sul desktop"
  # se prima era una postazione, la sua icona non deve restare (due icone = confusione)
  Togli-Collegamento 'Fay Live'

  Write-Host ""
  Ok "FATTO. Da ora avvia sempre Fay Live dall'icona sul desktop."
  if (-not $Silenzioso) { Attendi-Tasto }
}

# ---------------- POSTAZIONE ----------------
function Configura-Postazione {
  Info "Configuro questo portatile come POSTAZIONE..."
  Write-Host ""
  $schede = Schede-Cavo
  if ($schede.Count -eq 0) { Errore "Nessuna presa di rete via cavo. Inserisci l'adattatore USB-Ethernet e rilancia." }
  foreach ($s in $schede) {
    & netsh interface ipv4 set address "$($s.Name)" dhcp | Out-Null
    & netsh interface ipv4 set dnsservers "$($s.Name)" dhcp | Out-Null
    Proteggi-Corrente $s
  }
  Ok "Presa di rete in automatico (l'indirizzo se lo prende da sola)"

  New-Item -ItemType Directory -Force -Path $CARTELLA_POSTAZIONE | Out-Null
  Copy-Item (Join-Path $PSScriptRoot 'rete.ps1') $CARTELLA_POSTAZIONE -Force
  Copy-Item (Join-Path $PSScriptRoot 'Apri Fay Live.bat') $CARTELLA_POSTAZIONE -Force
  Get-ChildItem $CARTELLA_POSTAZIONE | Unblock-File -ErrorAction SilentlyContinue
  Collegamento-Desktop 'Fay Live' (Join-Path $CARTELLA_POSTAZIONE 'Apri Fay Live.bat') $CARTELLA_POSTAZIONE
  Ok "Icona 'Fay Live' creata sul desktop"

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
    Attenzione "Gli originali delle piscine importati quando era PC centrale restano su questo portatile (cartella FayCentrale\dati): NON cancellare la cartella FayCentrale."
  }

  & powercfg /change standby-timeout-ac 0 | Out-Null
  Ok "Sospensione disattivata quando e' in carica"
  Write-Host ""
  Ok "FATTO. In servizio basta collegare il cavo e aprire l'icona 'Fay Live'."
  Attendi-Tasto
}

# ---------------- AVVIO SUL PC CENTRALE ----------------
function Controllo-Avvio {
  Write-Host ""
  Info "Controllo la presa di rete per le postazioni..."
  $schede = Schede-Cavo
  if ($schede.Count -eq 0) {
    Attenzione "Adattatore di rete NON inserito: le postazioni via cavo non potranno collegarsi."
    if (-not (Chiedi-SN "Avvio Fay Live lo stesso?")) { exit 1 }
    if (-not (Controlla-Stampante)) { exit 1 }
    exit 0
  }
  $pronta = @($schede | Where-Object { Ha-IpCentrale $_ })
  if ($pronta.Count -eq 0) {
    Info "Adattatore nuovo o diverso: lo imposto ora. Windows chiedera' il permesso, rispondi Si'."
    try {
      Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Azione centrale -Silenzioso"
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
  if (-not (Controlla-Stampante)) { exit 1 }
  if ($pronta[0].Status -ne 'Up') {
    Attenzione "Cavo non collegato (o switch spento). Puoi collegarlo anche dopo: le postazioni si agganciano da sole."
  } else {
    Ok "Rete per le postazioni pronta"
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

function Apri-Postazione {
  Write-Host ""
  Write-Host "  FAY LIVE - collegamento al PC centrale" -ForegroundColor Cyan
  Write-Host ""
  $limite = (Get-Date).AddSeconds(90)
  $ultimo = ''
  while ($true) {
    $schede = Schede-Cavo
    $attive = @($schede | Where-Object Status -eq 'Up')
    if ($schede.Count -eq 0)      { $stato = "Adattatore di rete non inserito: infilalo nella porta USB." }
    elseif ($attive.Count -eq 0)  { $stato = "Cavo non collegato (o switch spento): controlla il cavo." }
    else {
      $fisso = $attive | Where-Object { (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Disabled' }
      if ($fisso) { $stato = "Questa postazione non e' configurata: lancia 'Configura PC' e scegli 2 (postazione)." }
      elseif (Porta-Aperta) { Ok "PC centrale trovato"; if (-not (Controlla-Stampante)) { exit 1 }; Info "Apro Fay Live..."; Apri-Browser $URL; Start-Sleep -Seconds 2; exit 0 }
      else { $stato = "Cavo collegato. Aspetto il PC centrale: deve essere acceso con Fay Live avviato..." }
    }
    if ($stato -ne $ultimo) { Info $stato; $ultimo = $stato }
    if ((Get-Date) -gt $limite) {
      Write-Host ""
      Attenzione "Non riesco a collegarmi al PC centrale."
      Info "Controlla: 1) cavi infilati bene  2) switch acceso  3) sul PC centrale la finestra nera di Fay Live aperta."
      if (Chiedi-SN "Riprovo?") { $limite = (Get-Date).AddSeconds(90); $ultimo = ''; continue }
      exit 1
    }
    Start-Sleep -Seconds 2
  }
}

switch ($Azione) {
  'centrale'   { Configura-Centrale }
  'postazione' { Configura-Postazione }
  'avvio'      { Controllo-Avvio }
  'apri'       { Apri-Postazione }
  'apricentrale' { Apri-Centrale }
}
