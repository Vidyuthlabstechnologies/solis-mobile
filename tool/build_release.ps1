# Release build for SOLIS (Android APK + App Bundle), hardened.
#
#   pwsh -File tool\build_release.ps1            # APK + AAB
#   pwsh -File tool\build_release.ps1 -SkipAab   # APK only
#
# What it does
# 1. Reads SOLIS_APP_TOKEN (and SOLIS_GCP_PROJECT_NUMBER, if present) from
#    secrets\keys.local.json. The values are never printed and never put on a
#    command line: they go into a temporary --dart-define-from-file JSON on
#    D:\temp that is deleted afterwards.
# 2. Builds with --obfuscate --split-debug-info=D:\SOLIS-symbols\<version>, so
#    Dart symbols are stripped from the app and kept only on this machine (keep
#    that folder: `flutter symbolize` needs it to read crash stack traces).
# 3. Verifies the signatures: apksigner for the APK (v2/v3 scheme, signer
#    certificate SHA-256), jarsigner for the AAB, and refuses a debug-signed
#    release.
# 4. Copies the outputs to D:\Downloads and C:\Users\varsh\Downloads with
#    their SHA-256.
# TEMP/TMP point at D:\temp for the whole build (C: is nearly full).
param(
  [switch]$SkipAab,
  [string]$SymbolsRoot = 'D:\SOLIS-symbols',
  [string[]]$CopyTo = @('D:\Downloads', 'C:\Users\varsh\Downloads')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$flutter = 'C:\tools\flutter\bin\flutter.bat'
$env:JAVA_HOME = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.8.9-hotspot'
$env:TEMP = 'D:\temp'; $env:TMP = 'D:\temp'
New-Item -ItemType Directory -Force D:\temp | Out-Null

function Step($m) { Write-Host "== $m" }

# ---- version ----
$versionLine = (Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$version = $versionLine.Split('+')[0]
$symbols = Join-Path $SymbolsRoot $version
New-Item -ItemType Directory -Force $symbols | Out-Null
Step "SOLIS $versionLine, symbols in $symbols"

# ---- secrets -> temporary define file (never printed) ----
$keysPath = Join-Path $root 'secrets\keys.local.json'
if (-not (Test-Path $keysPath)) { throw "Missing $keysPath (run tool\keyvault first)" }
$vals = (Get-Content $keysPath -Raw | ConvertFrom-Json).values
if (-not $vals.SOLIS_APP_TOKEN) { throw 'SOLIS_APP_TOKEN is not set in keys.local.json' }
$defines = @{ SOLIS_APP_TOKEN = [string]$vals.SOLIS_APP_TOKEN }
if ($vals.PSObject.Properties.Name -contains 'SOLIS_GCP_PROJECT_NUMBER' -and $vals.SOLIS_GCP_PROJECT_NUMBER) {
  $defines.SOLIS_GCP_PROJECT_NUMBER = [string]$vals.SOLIS_GCP_PROJECT_NUMBER
  Step 'Play Integrity: on (cloud project number set)'
} else {
  Step 'Play Integrity: off (no SOLIS_GCP_PROJECT_NUMBER in keys.local.json)'
}
$defineFile = Join-Path 'D:\temp' ("solis-defines-" + [guid]::NewGuid().ToString('N') + '.json')
# UTF-8 without BOM in both Windows PowerShell 5.1 and pwsh 7 (5.1 has no utf8NoBOM).
[System.IO.File]::WriteAllText($defineFile, ($defines | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))

# ---- signing config present? ----
$keyProps = Join-Path $root 'android\key.properties'
if (-not (Test-Path $keyProps)) { throw 'android\key.properties is missing: a release would be debug-signed' }

$common = @('--release', '--obfuscate', "--split-debug-info=$symbols", "--dart-define-from-file=$defineFile")
Push-Location $root
try {
  Step 'flutter build apk'
  & $flutter build apk @common
  if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed ($LASTEXITCODE)" }
  if (-not $SkipAab) {
    Step 'flutter build appbundle'
    & $flutter build appbundle @common
    if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed ($LASTEXITCODE)" }
  }
} finally {
  Pop-Location
  Remove-Item $defineFile -Force -ErrorAction SilentlyContinue
}

$apk = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
$aab = Join-Path $root 'build\app\outputs\bundle\release\app-release.aab'

# ---- verify signatures ----
$sdk = ((Get-Content (Join-Path $root 'android\local.properties')) -match '^sdk\.dir=' -replace '^sdk\.dir=', '' -replace '\\\\', '\') | Select-Object -First 1
$apksigner = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory | Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -Descending |
  ForEach-Object { Join-Path $_.FullName 'apksigner.bat' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $apksigner) { throw "apksigner not found under $sdk\build-tools" }

Step 'apksigner verify (APK)'
$out = & $apksigner verify --verbose --print-certs $apk 2>&1
if ($LASTEXITCODE -ne 0) { $out | Write-Host; throw 'APK signature verification failed' }
$out | Where-Object { $_ -match 'Verified using v[0-9] scheme|Signer #1 certificate (DN|SHA-256)|Number of signers' } | ForEach-Object { Write-Host "   $_" }
if ($out -match 'CN=Android Debug') { throw 'APK is signed with the debug key' }
if (-not ($out -match 'Verified using v2 scheme \(APK Signature Scheme v2\): true')) { throw 'APK lacks a v2 signature' }

if (-not $SkipAab) {
  Step 'jarsigner verify (AAB)'
  $jarsigner = Join-Path $env:JAVA_HOME 'bin\jarsigner.exe'
  $jout = & $jarsigner -verify -certs $aab 2>&1
  if (-not ($jout -match 'jar verified')) { $jout | Select-Object -Last 5 | Write-Host; throw 'AAB signature verification failed' }
  if ($jout -match 'CN=Android Debug') { throw 'AAB is signed with the debug key' }
  Write-Host '   jar verified'
}

# ---- copy outputs ----
$outputs = @(@{ src = $apk; name = "solis-$version.apk" })
if (-not $SkipAab) { $outputs += @{ src = $aab; name = "solis-$version.aab" } }
foreach ($o in $outputs) {
  $h = (Get-FileHash $o.src -Algorithm SHA256).Hash.ToLower()
  $mb = [math]::Round((Get-Item $o.src).Length / 1MB, 1)
  foreach ($d in $CopyTo) {
    New-Item -ItemType Directory -Force $d | Out-Null
    Copy-Item $o.src (Join-Path $d $o.name) -Force
  }
  Step "$($o.name)  $mb MB  sha256 $h"
}
Step "Done. Copied to: $($CopyTo -join ', '). Keep $symbols for crash symbolication."
