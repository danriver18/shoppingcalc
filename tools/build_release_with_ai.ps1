param(
  [string]$OutputPath = "releases\shoppingcalc-ai-release.apk"
)

$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $projectRoot

$apiKey = [Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "Process")
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  $apiKey = [Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "User")
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
  $secureKey = Read-Host "OPENAI_API_KEY" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
  try {
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
  throw "OPENAI_API_KEY is required to build the APK with AI price detection."
}

flutter build apk --release "--dart-define=OPENAI_API_KEY=$apiKey"

$sourceApk = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-release.apk"
$targetApk = Join-Path $projectRoot $OutputPath
$targetDir = Split-Path $targetApk -Parent
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
Copy-Item -Path $sourceApk -Destination $targetApk -Force

Write-Host "APK with AI price detection: $targetApk"
