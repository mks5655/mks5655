$ErrorActionPreference = "Stop"

Write-Host "=================================================="
Write-Host "Start Windows Release Build Process"
Write-Host "=================================================="

$WORKSPACE_DIR = Get-Location
$RUN_ID = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { "1" }

Write-Host "Workspace: $WORKSPACE_DIR"
Write-Host "Run ID: $RUN_ID"

# 1. Enable Windows desktop support & clean extra assets
Write-Host "--------------------------------------------------"
Write-Host "Enabling Flutter Windows Desktop support..."
flutter config --enable-windows-desktop

Write-Host "Cleaning assets directory..."
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue pan_client/assets/mihomo/linux
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue pan_client/assets/mihomo/macos
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue pan_client/assets/mihomo/windows

# 2. Install dependencies
Write-Host "--------------------------------------------------"
Write-Host "Step 1: Fetching Flutter dependencies..."
Set-Location pan_client
flutter pub get
Set-Location $WORKSPACE_DIR

# 3. Build Windows Release
Write-Host "--------------------------------------------------"
Write-Host "Step 2: Building Windows Release App..."

New-Item -ItemType Directory -Force -Path "$WORKSPACE_DIR\output_windows" | Out-Null
New-Item -ItemType Directory -Force -Path "$WORKSPACE_DIR\vanguard_symbols" | Out-Null

Set-Location pan_client
flutter build windows --release -t lib/main.dart `
  --obfuscate `
  --split-debug-info="$WORKSPACE_DIR\vanguard_symbols"
Set-Location $WORKSPACE_DIR

# 4. Create ZIP archives
Write-Host "--------------------------------------------------"
Write-Host "Step 3: Compressing Release artifacts and symbols..."

$buildDir = "$WORKSPACE_DIR\pan_client\build\windows\x64\runner\Release"
$zipPath = "$WORKSPACE_DIR\output_windows\pan-client-windows-x64-v1.0.12.zip"

Compress-Archive -Path "$buildDir\*" -DestinationPath $zipPath -Force

$symbolsDir = "$WORKSPACE_DIR\vanguard_symbols"
$symbolsZip = "$WORKSPACE_DIR\output_windows\pan-client-windows-symbols-v1.0.12.zip"

Compress-Archive -Path "$symbolsDir\*" -DestinationPath $symbolsZip -Force

Write-Host "=================================================="
Write-Host "Build Windows Complete! Outputs saved in: output_windows\"
Get-ChildItem output_windows
Write-Host "=================================================="