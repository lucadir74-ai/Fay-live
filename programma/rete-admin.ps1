# Fay Live - la parte della rete che serve i permessi di amministratore
#
# Imposta la presa di rete via cavo come PC CENTRALE o come POSTAZIONE. Su un PC preparato gira
# da una copia protetta (C:\ProgramData\FayLive), lanciata da un'attivita' pianificata, senza la
# finestra "Vuoi consentire...?". La preparazione vale finche' QUESTO file non cambia: per questo
# qui c'e' solo il minimo indispensabile, e tutto il resto (scelta del ruolo, messaggi, controlli
# del cavo, diagnosi) sta in rete.ps1, che si puo' aggiornare senza dover ripreparare i PC.
# Cambiare questo file solo quando serve davvero: dopo, su ogni PC va ripremuto P all'avvio.
param(
  [Parameter(Mandatory=$true)][ValidateSet('centrale','postazione')][string]$Azione,
  [switch]$Silenzioso,
  [switch]$Nascosto,          # lanciato da un'attivita' pianificata: niente finestre, niente attese di tasti
  [string]$Cartella = ''      # cartella di Fay Live quando lo script gira dalla copia protetta
)
$BASE = if ($Cartella) { $Cartella } else { $PSScriptRoot }
$env:PATH = "$BASE\node;" + $env:PATH
$ErrorActionPreference = 'Stop'
$IP_CENTRALE = '169.254.50.1'
$MASCHERA    = '255.255.0.0'
$PORTA       = 8787
$NOME_REGOLA = 'Fay Live - postazioni (porta 8787)'
$CARTELLA_POSTAZIONE = 'C:\FayLive-Postazione'
$UNICO = Test-Path (Join-Path $BASE 'Fay Live.bat')
$CARTELLA_ADMIN = Join-Path $env:ProgramData 'FayLive'

function Ok($t)         { Write-Host "  [OK] $t" -ForegroundColor Green }
function Info($t)       { Write-Host "  $t" }
function Attenzione($t) { Write-Host "  [!] $t" -ForegroundColor Yellow }
function Attendi-Tasto  { if ($Nascosto) { return }; Write-Host ""; Write-Host "  Premi un tasto per chiudere..."; [void][Console]::ReadKey($true) }
function Errore($t)     {
  if ($Nascosto) {   # nessuno vede la finestra: l'errore si lascia scritto e lo mostra chi ha lanciato l'attivita'
    try { Set-Content -Path (Join-Path $CARTELLA_ADMIN 'ultimo-errore.txt') -Value $t -Encoding UTF8 } catch { }
    exit 1
  }
  Write-Host ""; Write-Host "  [X] $t" -ForegroundColor Red; Attendi-Tasto; exit 1
}

# Solo prese di rete via cavo vere (niente WiFi, Bluetooth, schede virtuali)
function Schede-Cavo {
  @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.MediaType -eq '802.3' -and $_.NdisPhysicalMedium -notin 9,10 -and
    $_.InterfaceDescription -notmatch 'Bluetooth|Virtual|VPN|Hyper-V|VMware|VirtualBox|TAP|Wi-?Fi|Wireless'
  })
}

function Chiave-Scheda($scheda) {
  return "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($scheda.InterfaceGuid)"
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
    Copy-Item (Join-Path $BASE 'rete-admin.ps1') $CARTELLA_POSTAZIONE -Force
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

switch ($Azione) {
  'centrale'   { Configura-Centrale }
  'postazione' { Configura-Postazione }
}
