# Fay Live - aggiornamento automatico del programma
#
# Parte da solo a ogni avvio di "Fay Live.bat", prima della scelta 1/2. Cerca una versione piu'
# nuova del programma (server.mjs, rete.ps1, file .bat, librerie...):
#   1) sul PC centrale, se e' acceso sul cavo (le postazioni di solito non hanno internet);
#   2) sul sito di Fay Live, se c'e' internet.
# Se la trova scarica i file cambiati, li CONTROLLA tutti (impronta SHA-256 e, per i programmi,
# che siano scritti bene), mette da parte quelli vecchi nella cartella "riserva" e solo alla fine
# li sostituisce. Se qualcosa va storto non cambia niente e Fay Live parte come prima.
# Non tocca MAI la cartella dati, l'Archivio, Node.js e "Fay Live.bat".
#
# "-Ripristina" (da "Torna alla versione di prima.bat"): rimette i file della riserva e salta
# quella versione finche' non ne esce una piu' nuova.
param([switch]$Ripristina)

$ErrorActionPreference = 'Stop'
$BASE      = $PSScriptRoot
$VERSIONE  = Join-Path $BASE 'versione.json'
$RISERVA   = Join-Path $BASE 'riserva'
$SALTATA   = Join-Path $BASE 'versione-saltata.txt'
$TEMP_AGG  = Join-Path $BASE '_aggiornamento'
$CENTRALE  = if ($env:FAY_CENTRALE) { $env:FAY_CENTRALE } else { '169.254.50.1:8787' }
$SITO      = if ($env:FAY_SITO_PROGRAMMA) { $env:FAY_SITO_PROGRAMMA } else { 'https://fay-live.vercel.app/programma' }
# file che non si aggiornano mai da soli: "Fay Live.bat" e' quello che sta girando in questo momento
$INTOCCABILI = '^(fay live\.bat|torna alla versione di prima\.bat|dati[\\/].*|archivio[\\/].*|node[\\/].*|riserva[\\/].*|_aggiornamento[\\/].*|versione\.json)$'

function Ok($t)         { Write-Host "  [OK] $t" -ForegroundColor Green }
function Info($t)       { Write-Host "  $t" }
function Attenzione($t) { Write-Host "  [!] $t" -ForegroundColor Yellow }

function Leggi-Json($f) {
  if (-not (Test-Path $f)) { return $null }
  try { return ([IO.File]::ReadAllText($f) -replace "^$([char]0xFEFF)", '') | ConvertFrom-Json } catch { return $null }
}
function Numero-Versione($j) { try { if ($j -and $j.versione) { return [long]$j.versione } } catch { }; return [long]0 }
function Impronta($f) { if (Test-Path $f) { return (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower() }; return '' }
function Nome-Valido($n) {
  # solo nomi semplici dentro la cartella: niente "..", niente percorsi assoluti
  return ($n -match '^[A-Za-z0-9_][A-Za-z0-9 _.\-]*(/[A-Za-z0-9_][A-Za-z0-9 _.\-]*)?$') -and ($n -notmatch '\.\.') -and ($n -notmatch $INTOCCABILI)
}
function Percorso($cartella, $nome) { return Join-Path $cartella ($nome -replace '/', '\') }

function Porta-Aperta($indirizzo, $ms) {
  $h, $p = $indirizzo -split ':'
  $c = New-Object System.Net.Sockets.TcpClient
  try { $r = $c.BeginConnect($h, [int]$p, $null, $null); return ($r.AsyncWaitHandle.WaitOne($ms) -and $c.Connected) }
  catch { return $false } finally { $c.Close() }
}
function Scarica($url, $file) {
  $sep = if ($url -match '\?') { '&' } else { '?' }
  Invoke-WebRequest -UseBasicParsing -Uri "$url$($sep)nc=$([DateTime]::Now.Ticks)" -OutFile $file -TimeoutSec 60 | Out-Null
}

# Il file scaricato e' scritto bene? (un programma rotto non deve mai sostituire quello buono)
function Controlla-File($f) {
  $est = [IO.Path]::GetExtension($f).ToLower()
  if ($est -eq '.ps1') {
    $err = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$err)
    if ($err -and $err.Count) { throw "rete o script non valido ($($err[0].Message))" }
  } elseif ($est -eq '.mjs') {
    $node = Join-Path $BASE 'node\node.exe'
    if (-not (Test-Path $node)) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
    if ($node) {
      $vecchia = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      $out = & $node --check $f 2>&1; $codice = $LASTEXITCODE
      $ErrorActionPreference = $vecchia
      if ($codice -ne 0) {
        $riga = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match 'Error' }) | Select-Object -First 1
        throw "programma del centrale scritto male: $riga"
      }
    }
  } elseif ($est -eq '.json') {
    try { [void](([IO.File]::ReadAllText($f) -replace "^$([char]0xFEFF)", '') | ConvertFrom-Json) } catch { throw "file di impostazioni non valido" }
  }
}

# ---------------- TORNA ALLA VERSIONE DI PRIMA ----------------
if ($Ripristina) {
  $prima = Leggi-Json (Join-Path $RISERVA 'versione.json')
  if (-not (Test-Path $RISERVA) -or -not $prima) { Attenzione "Non c'e' una versione di prima da rimettere."; exit 1 }
  $ora = Leggi-Json $VERSIONE
  Get-ChildItem $RISERVA -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($RISERVA.Length + 1)
    $dest = Join-Path $BASE $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item $_.FullName $dest -Force
  }
  # la versione appena tolta non deve tornare al prossimo avvio: si aspetta la prossima correzione
  if ($ora) { Set-Content -Path $SALTATA -Value (Numero-Versione $ora) -Encoding ASCII }
  Ok "Rimessa la versione di prima ($($prima.data)). La prossima versione nuova arrivera' da sola."
  exit 0
}

# ---------------- CONTROLLO DEGLI AGGIORNAMENTI ----------------
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $ProgressPreference = 'SilentlyContinue'
  $qui = Leggi-Json $VERSIONE
  $nQui = Numero-Versione $qui
  $nSaltata = [long]0; try { if (Test-Path $SALTATA) { $nSaltata = [long]((Get-Content $SALTATA | Select-Object -First 1).Trim()) } } catch { }

  if (Test-Path $TEMP_AGG) { Remove-Item $TEMP_AGG -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $TEMP_AGG | Out-Null

  # dove cercare: prima il PC centrale (via cavo), poi il sito
  $fonti = @()
  if (Porta-Aperta $CENTRALE 1500) { $fonti += @{ Nome = 'PC centrale'; Url = "http://$CENTRALE/programma" } }
  if ($SITO -ne 'no') {
    $uriSito = [Uri]$SITO
    if (Porta-Aperta "$($uriSito.Host):$($uriSito.Port)" 3000) { $fonti += @{ Nome = 'sito'; Url = $SITO } }
  }
  $migliore = $null; $nMigliore = $nQui
  foreach ($f in $fonti) {
    try {
      $file = Join-Path $TEMP_AGG "versione-$($f.Nome -replace ' ', '').json"
      Scarica "$($f.Url)/versione.json" $file
      $j = Leggi-Json $file
      $n = Numero-Versione $j
      if ($j -and $j.file -and $n -gt $nMigliore -and $n -gt $nSaltata) { $migliore = $f; $migliore.Json = $j; $migliore.FileJson = $file; $nMigliore = $n }
    } catch { }
  }
  if (-not $migliore) { Remove-Item $TEMP_AGG -Recurse -Force -ErrorAction SilentlyContinue; exit 0 }

  $nuova = $migliore.Json
  Write-Host ""
  Info "C'e' una versione nuova di Fay Live ($($nuova.data)): la scarico dal $($migliore.Nome)..."

  # 1) scarica e controlla i file cambiati (tutto in una cartella a parte: qui non si tocca niente)
  $cambiati = @()
  foreach ($p in $nuova.file.PSObject.Properties) {
    $nome = $p.Name; $impronta = "$($p.Value)".ToLower()
    if (-not (Nome-Valido $nome)) { throw "nome di file non accettato: $nome" }
    if ((Impronta (Percorso $BASE $nome)) -eq $impronta) { continue }
    $dest = Percorso $TEMP_AGG $nome
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    $url = "$($migliore.Url)/" + ((($nome -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    Scarica $url $dest
    if ((Impronta $dest) -ne $impronta) { throw "il file $nome non e' arrivato intero" }
    Controlla-File $dest
    $cambiati += $nome
  }

  # 2) mette da parte la versione di adesso (per "Torna alla versione di prima")
  if ($cambiati.Count) {
    if (Test-Path $RISERVA) { Remove-Item $RISERVA -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $RISERVA | Out-Null
    foreach ($nome in $cambiati) {
      $att = Percorso $BASE $nome
      if (Test-Path $att) {
        $r = Percorso $RISERVA $nome
        New-Item -ItemType Directory -Force -Path (Split-Path $r) | Out-Null
        Copy-Item $att $r -Force
      }
    }
    if (Test-Path $VERSIONE) { Copy-Item $VERSIONE (Join-Path $RISERVA 'versione.json') -Force }
    else { Set-Content -Path (Join-Path $RISERVA 'versione.json') -Value '{"versione":0,"data":"prima degli aggiornamenti automatici","file":{}}' -Encoding ASCII }
  }

  # 3) sostituisce i file, e per ultimo il numero di versione
  foreach ($nome in $cambiati) {
    $dest = Percorso $BASE $nome
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item (Percorso $TEMP_AGG $nome) $dest -Force
    try { Unblock-File $dest -ErrorAction SilentlyContinue } catch { }
  }
  Copy-Item $migliore.FileJson $VERSIONE -Force
  Remove-Item $TEMP_AGG -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $SALTATA -Force -ErrorAction SilentlyContinue

  if ($cambiati.Count) { Ok "Fay Live aggiornato ($($nuova.data)): $($cambiati -join ', ')" }
  else { Ok "Fay Live e' gia' alla versione $($nuova.data)" }
  if ($nuova.note) { Info "Novita': $($nuova.note)" }
  if ($cambiati -contains 'rete.ps1' -and (Test-Path (Join-Path $env:ProgramData 'FayLive\rete.ps1'))) {
    Info "(E' cambiata la parte della rete: alla scelta 1/2 premi P per ripreparare il PC, una volta sola."
    Info " Senza, funziona lo stesso: Windows chiede il permesso quando cambi ruolo.)"
  }
  exit 0
} catch {
  Attenzione "Aggiornamento non riuscito ($($_.Exception.Message)): Fay Live parte con la versione che c'era."
  try { Remove-Item $TEMP_AGG -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  Start-Sleep -Seconds 3
  exit 0
}
