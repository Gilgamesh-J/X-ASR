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

# Default 960 ms tier — int8-quantized archive from the official CDN (R2), matching macOS build 202
# (~130 MB vs ~615 MB full precision). Extract, then strip macOS AppleDouble junk (._*, .DS_Store).
$needTier = -not (Test-Path (Join-Path $tier 'encoder-960ms.onnx'))
if ($needTier) {
    Write-Host "  downloading quantized chunk-960ms.tar.gz (CDN) ..."
    $arc = Join-Path $payload "chunk-960ms.tar.gz"
    Invoke-WebRequest "https://models.speech.wiki/asr/chunk-960ms.tar.gz" -OutFile $arc -UseBasicParsing
    tar -xzf $arc -C $tier
    Get-ChildItem $tier -Recurse -Force | Where-Object { $_.Name -like '._*' -or $_.Name -eq '.DS_Store' } | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item $arc -Force -ErrorAction SilentlyContinue
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
$msiOut = Join-Path $here "VibeXASR-Setup.msi"
Write-Host "Done: $msiOut" -ForegroundColor Green

# --- 4. mirror the MSI to Cloudflare R2 (CN-fast download), matching macOS package_release.sh ---
# Versioned name + a stable "latest" alias, like macOS app/VibeXASR-<VER>.dmg + app/VibeXASR.dmg.
# Skipped silently if the (gitignored) uploader / creds aren't present on this machine.
$disp   = ($Version -split '\.')[0..1] -join '.'                       # 2.0.0.1 -> 2.0
$scripts = Join-Path (Split-Path (Split-Path $repo -Parent) -Parent) "scripts"   # projects/scripts
$r2py   = Join-Path $scripts "r2_upload.py"
$r2env  = Join-Path $scripts ".env"
if ((Test-Path $r2py) -and (Test-Path $r2env)) {
    Write-Host "Uploading MSI to Cloudflare R2 ..." -ForegroundColor Cyan
    try {
        # Immutable, version-specific name — the appcast points HERE (CN-fast R2 download, skips GitHub).
        & python $r2py $msiOut "app/VibeXASR-$Version-windows-x64.msi" "application/x-msi" "public, max-age=31536000, immutable"
        & python $r2py $msiOut "app/VibeXASR-$disp.msi" "application/x-msi" "public, max-age=600"
        & python $r2py $msiOut "app/VibeXASR.msi"       "application/x-msi" "public, max-age=300"
    } catch { Write-Host "  R2 upload failed (non-fatal): $_" -ForegroundColor Yellow }
} else {
    Write-Host "R2 upload skipped (projects/scripts/.env not present)" -ForegroundColor DarkGray
}
