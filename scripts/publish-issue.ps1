<#
.SYNOPSIS
  Encrypt a new Field Notes issue with StaticCrypt and stage it in the repo.

.DESCRIPTION
  1. Encrypts the plain-text source with StaticCrypt (password is prompted
     interactively by StaticCrypt itself; this script never sees or stores it).
  2. Adds <meta name="robots" content="noindex, nofollow"> to the encrypted page.
  3. Copies ONLY the encrypted file to issues/<NN>-<slug>/index.html.
  4. Scans every file in the repo for fingerprint strings from the source.
  5. Reminds you to update README.md and index.html, then stops before commit.

  The plain-text source must live OUTSIDE this repo (e.g. ~/notes-private/).

.EXAMPLE
  ./scripts/publish-issue.ps1 -Number 2 -Slug "<SLUG>" `
    -Source "<PATH-TO-PRIVATE-NOTES>/index.html" `
    -Title "<ISSUE-TITLE>" `
    -Fingerprints "<UNIQUE-PHRASE-1>","<UNIQUE-PHRASE-2>","<UNIQUE-PHRASE-3>"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateRange(1, 99)][int]$Number,
  [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')][string]$Slug,
  [Parameter(Mandatory)][string]$Source,
  [Parameter(Mandatory)][string]$Title,
  # Distinctive strings that appear in the plain text but must never appear in the repo.
  [Parameter(Mandatory)][string[]]$Fingerprints
)

$ErrorActionPreference = 'Stop'
$StaticCrypt = 'staticrypt@3.5.4'   # npm package is "staticrypt" (one c)
$MitRed      = '#A31F34'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$NN       = '{0:D2}' -f $Number
$IssueDir = Join-Path $RepoRoot "issues/$NN-$Slug"
$Dest     = Join-Path $IssueDir 'index.html'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "STOP: $msg" -ForegroundColor Red; exit 1 }

# --- 0. Pre-flight --------------------------------------------------------
Step 'Pre-flight checks'
if (-not (Test-Path $Source -PathType Leaf)) { Fail "Source not found: $Source" }
$SourceFull = (Resolve-Path $Source).Path
$SourceDir  = Split-Path $SourceFull -Parent
$SourceName = Split-Path $SourceFull -Leaf

$sep = [IO.Path]::DirectorySeparatorChar
if ($SourceFull.StartsWith($RepoRoot + $sep, [StringComparison]::OrdinalIgnoreCase)) {
  Fail "Source is inside the repo. Keep plain text outside (e.g. ~/notes-private/)."
}
foreach ($f in $Fingerprints) {
  if (-not (Select-String -Path $SourceFull -SimpleMatch -Pattern $f -Quiet)) {
    Fail "Fingerprint '$f' is not in the source, so the scan would prove nothing. Pick strings that are."
  }
}
if (Test-Path $Dest) { Fail "$Dest already exists. Remove it first if you mean to re-publish." }
foreach ($cmd in 'npx', 'git') {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Fail "$cmd not found on PATH" }
}
Write-Host "Source : $SourceFull"
Write-Host "Target : $Dest"

# --- 1. Encrypt (StaticCrypt prompts for the password) --------------------
Step "Encrypting with $StaticCrypt — enter the password when prompted"
$OutDir = Join-Path $SourceDir 'encrypted'
Push-Location $SourceDir
try {
  & npx -y $StaticCrypt $SourceName -d encrypted --short `
    --template-title "Field Notes · Issue $NN" `
    --template-instructions "$Title — personal notes, unofficial. Ask Allen for the password." `
    --template-color-primary $MitRed `
    --template-color-secondary '#F5F5F5' `
    --template-button 'Open' `
    --template-placeholder 'Password'
  if ($LASTEXITCODE -ne 0) { Fail "StaticCrypt exited with code $LASTEXITCODE" }
} finally { Pop-Location }

$Encrypted = Join-Path $OutDir $SourceName
if (-not (Test-Path $Encrypted)) { Fail "Encrypted output missing: $Encrypted" }
if (-not (Select-String -Path $Encrypted -SimpleMatch -Pattern 'staticrypt' -Quiet)) {
  Fail "Output does not look like a StaticCrypt page."
}

# --- 2. Add noindex -------------------------------------------------------
Step 'Adding robots noindex meta'
$html = [IO.File]::ReadAllText($Encrypted)
if ($html -notmatch '<meta\s+name="robots"') {
  $html = ([regex]'<head>').Replace($html, "<head>`n    <meta name=`"robots`" content=`"noindex, nofollow`">", 1)
  [IO.File]::WriteAllText($Encrypted, $html, [Text.UTF8Encoding]::new($false))
}
if (-not (Select-String -Path $Encrypted -SimpleMatch -Pattern 'content="noindex, nofollow"' -Quiet)) {
  Fail 'noindex meta not present after injection'
}

# --- 3. Copy only the encrypted file -------------------------------------
Step 'Copying encrypted file into the repo'
New-Item -ItemType Directory -Force -Path $IssueDir | Out-Null
Copy-Item $Encrypted $Dest
if (-not (Test-Path $Dest)) { Fail 'Copy failed' }

# --- 4. Fingerprint scan over every file in the repo ---------------------
Step 'Scanning repo for plain-text fingerprints'
$files = Get-ChildItem -Path $RepoRoot -Recurse -File -Force |
  Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
$hits = $files | Select-String -SimpleMatch -Pattern $Fingerprints
if ($hits) {
  $hits | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" -ForegroundColor Red }
  Remove-Item $Dest
  Fail 'Fingerprint found in repo. Encrypted copy removed. Do NOT commit.'
}
Write-Host 'Scan clean: 0 hits.' -ForegroundColor Green

# --- 5. Hand back to you --------------------------------------------------
Step 'Next steps (manual)'
Write-Host @"
  1. Add Issue $NN to the table in README.md (and bump the issues badge).
  2. Add a card at the top of <ol class="issues"> in index.html, and update the count.
  3. Re-run the scan after editing, then review:
       git -C "$RepoRoot" status
       git -C "$RepoRoot" diff
  4. When you're happy:
       git -C "$RepoRoot" add -A
       git -C "$RepoRoot" commit -m "Add Issue $NN: $Title"
       git -C "$RepoRoot" push
  The plain-text source and $OutDir stay in $SourceDir — never copy them here.
"@
git -C $RepoRoot status --short
