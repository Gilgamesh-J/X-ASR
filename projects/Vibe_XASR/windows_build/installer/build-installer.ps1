# build-installer.ps1 - build the per-user MSI that bundles the default 960 ms model.
# Output: installer\VibeXASR-Setup.msi  (installs to %LOCALAPPDATA%\Programs\VibeXASR, no admin).
#
# Prerequisites (one-time):
#   dotnet tool install --global wix --version 5.0.2
#   wix extension add -g WixToolset.UI.wixext/5.0.2
# (WiX v6/v7 require a paid EULA; stay on the free v5.)
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\build-installer.ps1 -Version 1.1.2.0

param([string]$Rid = "win-x64", [string]$Version = "1.1.2.0")
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repo = Split-Path $here -Parent           # windows_build/

# --- resolve dotnet (prefer PATH; fall back to per-user ~/.dotnet) ---
$dotnet = "dotnet"
$hasSdk = $false
if (Get-Command dotnet -ErrorAction SilentlyContinue) { try { $hasSdk = [bool](& dotnet --list-sdks 2>$null) } catch {} }
if (-not $hasSdk) {
    $u = Join-Path $env:USERPROFILE ".dotnet\dotnet.exe"
    if (Test-Path $u) { $dotnet = $u; $env:DOTNET_ROOT = Split-Path $u; $env:DOTNET_MULTILEVEL_LOOKUP = "0" }
    else { throw "No .NET SDK found (see windows_build\README.md)." }
}

# --- resolve wix v5 ---
$wix = (Get-Command wix -ErrorAction SilentlyContinue).Source
if (-not $wix) { $wix = Join-Path $env:USERPROFILE ".dotnet\tools\wix.exe" }
if (-not (Test-Path $wix)) { throw "WiX not found. Run: dotnet tool install --global wix --version 5.0.2; wix extension add -g WixToolset.UI.wixext/5.0.2" }

# --- 1. publish the self-contained single-file app ---
Write-Host "Publishing $Rid..." -ForegroundColor Cyan
& $dotnet publish "$repo\src\VibeXASR.Windows\VibeXASR.Windows.csproj" `
    -c Release -r $Rid --self-contained `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -o "$repo\dist\$Rid"

# --- 2. stage payload (exe + WinSparkle.dll + default 960 ms model + v4 silero VAD) ---
$payload = Join-Path $here "payload"
$tier = Join-Path $payload "models\chunk-960ms-model"
New-Item -ItemType Directory -Force $tier | Out-Null
Copy-Item "$repo\dist\$Rid\VibeXASR.exe" (Join-Path $payload "VibeXASR.exe") -Force
# WinSparkle auto-update DLL - installs beside the exe; loaded from the app dir at runtime.
Copy-Item "$repo\third_party\winsparkle\WinSparkle.dll" (Join-Path $payload "WinSparkle.dll") -Force
# FireRedVAD shim (default VAD) + its model (onnx + CMVN), sourced from macos_build (committed there).
Copy-Item "$repo\third_party\firered\firered_vad.dll" (Join-Path $payload "firered_vad.dll") -Force
$frm = Join-Path $payload "models\firered"
New-Item -ItemType Directory -Force $frm | Out-Null
$frsrc = Join-Path (Split-Path $repo -Parent) "macos_build\models\firered"
foreach ($f in 'firered_vad.onnx','cmvn_means.bin','cmvn_istd.bin') { Copy-Item (Join-Path $frsrc $f) $frm -Force }

# Default tier from HuggingFace (only the files not already staged). ~615 MB.
$base = "https://huggingface.co/GilgameshWind/X-ASR-zh-en/resolve/main/deployment/models/chunk-960ms-model"
foreach ($f in 'encoder-960ms.onnx','decoder-960ms.onnx','joiner-960ms.onnx','tokens.txt') {
    $d = Join-Path $tier $f
    if (-not (Test-Path $d)) { Write-Host "  downloading $f ..."; Invoke-WebRequest "$base/$f" -OutFile $d -UseBasicParsing }
}
# v4 silero VAD - the version sherpa-onnx 1.10.x supports (v5 errors "Unsupported silero vad model").
$sv = Join-Path $payload "models\silero_vad.onnx"
if (-not (Test-Path $sv)) {
    Write-Host "  downloading silero_vad.onnx (v4) ..."
    Invoke-WebRequest "https://github.com/snakers4/silero-vad/raw/v4.0/files/silero_vad.onnx" -OutFile $sv -UseBasicParsing
}

# Dictionary resources: pinyin homophone table (committed in macos_build) + bpe.vocab for
# hotword tokenization, generated from the bundled tokens.txt.
Copy-Item (Join-Path (Split-Path $repo -Parent) "macos_build\native\app\Resources\pinyin.txt") (Join-Path $payload "models\pinyin.txt") -Force
& (Join-Path $here "make-bpe-vocab.ps1") -Tokens (Join-Path $tier "tokens.txt") -Out (Join-Path $payload "models\bpe.vocab")

# --- 3. build the MSI (Version flows into the WiX Package/@Version) ---
Write-Host "Building MSI v$Version ..." -ForegroundColor Cyan
Push-Location $here
try { & $wix build Product.wxs -ext WixToolset.UI.wixext -ext WixToolset.Util.wixext -d "Version=$Version" -o "VibeXASR-Setup.msi" }
finally { Pop-Location }
Write-Host "Done: $here\VibeXASR-Setup.msi" -ForegroundColor Green
