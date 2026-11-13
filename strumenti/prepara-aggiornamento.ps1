# Fay Live - prepara un aggiornamento da pubblicare sul sito
#
# Copia i file del programma dalla cartella di Fay Live di questo PC (FayLive-Unico) nella
# cartella "programma" del sito, con l'elenco delle impronte (versione.json). Dopo basta
# pubblicare il sito con GitHub Desktop (Commit + Push): ogni portatile si aggiorna da solo
# al primo avvio con internet, e le postazioni prendono i file dal PC centrale.
#
# Uso:  powershell -ExecutionPolicy Bypass -File strumenti\prepara-aggiornamento.ps1 -Note "cosa cambia"
param(
  [string]$Sorgente = 'C:\Users\ASUS\FayLive-Unico',
  [string]$Note = '',
  [string]$Destinazione = ''     # solo per le prove: di solito la cartella "programma" del sito
)
$ErrorActionPreference = 'Stop'
$REPO = Split-Path $PSScriptRoot
$DEST = if ($Destinazione) { $Destinazione } else { Join-Path $REPO 'programma' }

# i file che si aggiornano da soli (NON: Fay Live.bat, dati, Archivio, node, pc.html e report.html,
# che il centrale riscarica gia' per conto suo)
$elenco = @('server.mjs', 'rete.ps1', 'aggiorna.ps1', '_avvio.bat', '_motore.bat', 'Cloud.bat',
  'Diagnosi cavo.bat', 'Prepara questo PC.bat', 'LEGGIMI.txt', 'faylive.ico', 'pagine/foto-cloud.html')
$elenco += @(Get-ChildItem (Join-Path $Sorgente 'lib') -File | ForEach-Object { "lib/$($_.Name)" })

# controlli prima di pubblicare: un programma rotto non deve arrivare sui portatili
$node = Join-Path $Sorgente 'node\node.exe'
if (-not (Test-Path $node)) { $node = (Get-Command node).Source }
& $node --check (Join-Path $Sorgente 'server.mjs'); if ($LASTEXITCODE -ne 0) { throw "server.mjs ha un errore: non pubblico" }
foreach ($ps in 'rete.ps1', 'aggiorna.ps1') {
  $err = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Sorgente $ps), [ref]$null, [ref]$err)
  if ($err -and $err.Count) { throw "$ps ha un errore: $($err[0].Message)" }
}

if (Test-Path $DEST) { Get-ChildItem $DEST -Force | Where-Object Name -ne '.gitattributes' | Remove-Item -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DEST | Out-Null
# i file vanno sul sito byte per byte (senza conversioni degli a capo), se no le impronte non tornano
[IO.File]::WriteAllText((Join-Path $DEST '.gitattributes'), "* -text`n")

$impronte = [ordered]@{}
foreach ($nome in $elenco) {
  $da = Join-Path $Sorgente ($nome -replace '/', '\')
  if (-not (Test-Path $da)) { throw "manca $nome in $Sorgente" }
  $a = Join-Path $DEST ($nome -replace '/', '\')
  New-Item -ItemType Directory -Force -Path (Split-Path $a) | Out-Null
  Copy-Item $da $a -Force
  $impronte[$nome] = (Get-FileHash -Algorithm SHA256 $a).Hash.ToLower()
}

# numero di versione: AAAAMMGG + progressivo del giorno (2026111301, 2026111302...)
$oggi = [long](Get-Date -Format 'yyyyMMdd') * 100
$prima = [long]0
try { $prima = [long](([IO.File]::ReadAllText((Join-Path $Sorgente 'versione.json')) | ConvertFrom-Json).versione) } catch { }
$numero = [Math]::Max($oggi + 1, $prima + 1)
$mesi = 'gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic'
$d = Get-Date
$data = "$($d.Day) $($mesi[$d.Month - 1]) $($d.Year) n.$($numero % 100)"

$json = [ordered]@{ versione = $numero; data = $data; note = $Note; file = $impronte } | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $DEST 'versione.json'), $json, (New-Object Text.UTF8Encoding $false))
# anche la cartella di questo PC e' gia' a questa versione
[IO.File]::WriteAllText((Join-Path $Sorgente 'versione.json'), $json, (New-Object Text.UTF8Encoding $false))

Write-Host ""
Write-Host "  [OK] Aggiornamento pronto: versione $numero ($data), $($impronte.Count) file in $DEST" -ForegroundColor Green
Write-Host "  Ora apri GitHub Desktop: Commit, poi Push. Dopo un minuto e' sul sito."
