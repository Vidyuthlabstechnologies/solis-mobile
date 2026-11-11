# One-shot release for SOLIS, run from the repo root on your PC:
#
#   powershell -ExecutionPolicy Bypass -File tool\setup-release.ps1
#
# What it does, using the GitHub CLI (gh):
# 1. Installs gh with winget if it is missing, and signs you in if needed.
# 2. Reads android\key.properties and the upload keystore it points at, and
#    stores them as GitHub Actions secrets (ANDROID_KEYSTORE_BASE64,
#    ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD).
#    Values are never printed, and nothing is written to the repo.
# 3. Asks once for the Cloudflare API token and account ID (press Enter to
#    skip) and stores them, then deploys the website.
# 4. Runs the Release workflow (standalone build signed with your real key),
#    then the emulator smoke test on that exact APK.
# 5. Downloads the signed APK and the test screenshots to Desktop\SOLIS-release.
param(
  [string]$Repo = 'Vidyuthlabstechnologies/solis-mobile',
  [ValidateSet('standalone', 'play', 'both')][string]$Builds = 'standalone',
  [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SOLIS-release'),
  [switch]$SkipSecrets,
  [switch]$SkipSite
)
# Continue, so gh writing to stderr does not abort; failures throw explicitly.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Plain([Security.SecureString]$s) {
  $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}
function Set-Secret($name, $value) {
  if ([string]::IsNullOrEmpty($value)) { throw "No value for $name" }
  gh secret set $name -R $Repo -b $value
  if ($LASTEXITCODE -ne 0) { throw "gh secret set $name failed" }
  Write-Host "   set $name"
}
# Starts a workflow and returns the new run's ID.
function Start-Workflow($file, [string[]]$fields) {
  $before = (gh run list -R $Repo --workflow $file -L 1 --json databaseId -q '.[0].databaseId')
  $ghArgs = @('workflow', 'run', $file, '-R', $Repo, '--ref', 'main')
  foreach ($f in $fields) { $ghArgs += @('-f', $f) }
  & gh @ghArgs
  if ($LASTEXITCODE -ne 0) { throw "could not start $file" }
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep 3
    $id = (gh run list -R $Repo --workflow $file -L 1 --json databaseId -q '.[0].databaseId')
    if ($id -and $id -ne $before) { return $id }
  }
  throw "run of $file never appeared"
}
function Wait-Run($id, $what) {
  Write-Host "   https://github.com/$Repo/actions/runs/$id"
  gh run watch $id -R $Repo --exit-status --interval 20
  if ($LASTEXITCODE -ne 0) {
    gh run view $id -R $Repo --log-failed | Select-Object -Last 40
    throw "$what failed (run $id)"
  }
}

Step 'GitHub CLI'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { gh auth login -h github.com -w -s repo,workflow }
gh repo view $Repo --json name | Out-Null
if ($LASTEXITCODE -ne 0) { throw "This GitHub account cannot see $Repo" }

if (-not $SkipSecrets) {
  Step 'Signing key secrets'
  $propsFile = Join-Path $root 'android\key.properties'
  if (-not (Test-Path $propsFile)) { throw "Missing $propsFile" }
  $props = @{}
  foreach ($line in Get-Content $propsFile) {
    if ($line -match '^\s*([^#=\s]+)\s*=\s*(.*?)\s*$') { $props[$Matches[1]] = $Matches[2] }
  }
  $store = $props['storeFile']
  $candidates = @()
  if ($store) {
    $candidates += $store
    $candidates += (Join-Path $root "android\app\$store")
    $candidates += (Join-Path $root "android\$store")
  }
  $candidates += (Join-Path $root 'secrets\solis-upload.jks')
  $jks = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if (-not $jks) { throw "Keystore not found (storeFile=$store)" }
  Write-Host "   keystore: $jks"
  Set-Secret 'ANDROID_KEYSTORE_BASE64' ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $jks))))
  Set-Secret 'ANDROID_KEYSTORE_PASSWORD' $props['storePassword']
  Set-Secret 'ANDROID_KEY_ALIAS' $props['keyAlias']
  Set-Secret 'ANDROID_KEY_PASSWORD' $props['keyPassword']

  if (-not $SkipSite) {
    $have = (gh secret list -R $Repo --json name -q '.[].name') -split "`n"
    if ($have -notcontains 'CLOUDFLARE_API_TOKEN') {
      Step 'Cloudflare (website). Press Enter to skip.'
      $tok = Plain (Read-Host '   Cloudflare API token (Pages: Edit)' -AsSecureString)
      if ($tok) {
        Set-Secret 'CLOUDFLARE_API_TOKEN' $tok
        Set-Secret 'CLOUDFLARE_ACCOUNT_ID' (Read-Host '   Cloudflare account ID')
      } else { $SkipSite = $true }
    }
  }
}

$site = $null
if (-not $SkipSite) {
  Step 'Deploying the website'
  $site = Start-Workflow 'deploy-site.yml' @()
}

Step "Building the signed release ($Builds)"
$rel = Start-Workflow 'release.yml' @("builds=$Builds")
Wait-Run $rel 'Release build'

Step 'Testing the signed APK on an Android emulator'
$smoke = Start-Workflow 'smoke-test.yml' @('flavor=standalone', "release_run_id=$rel")
$smokeOk = $true
try { Wait-Run $smoke 'Smoke test' } catch { Write-Warning $_; $smokeOk = $false }

Step "Downloading to $OutDir"
New-Item -ItemType Directory -Force $OutDir | Out-Null
gh run download $rel -R $Repo -D (Join-Path $OutDir 'app')
gh run download $smoke -R $Repo -D (Join-Path $OutDir 'smoke-test')

if ($site) {
  Step 'Website'
  try { Wait-Run $site 'Website deploy'; Write-Host '   https://solis-health.pages.dev' } catch { Write-Warning $_ }
}

Get-ChildItem $OutDir -Recurse -Include *.apk, *.aab | ForEach-Object {
  Write-Host ("   {0}  SHA-256 {1}" -f $_.FullName, (Get-FileHash $_.FullName -Algorithm SHA256).Hash)
}
if ($smokeOk) { Write-Host "`nDone. Signed APK and screenshots are in $OutDir" -ForegroundColor Green }
else { Write-Host "`nAPK is built and signed, but the emulator test failed: see $OutDir\smoke-test" -ForegroundColor Yellow; exit 1 }
