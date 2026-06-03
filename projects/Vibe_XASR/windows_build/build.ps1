# build.ps1 — publish self-contained single-file binaries for win-x64 and win-arm64.
# Run ON WINDOWS in PowerShell from the windows_build/ directory:
#     powershell -ExecutionPolicy Bypass -File .\build.ps1
# Requires the .NET 8 SDK (https://dotnet.microsoft.com/download/dotnet/8.0).
#
# Output lands in dist/<rid>/.

param(
    [string]$Configuration = "Release",
    # Pass -Rids "win-x64" to build only one. Default builds both.
    [string[]]$Rids = @("win-x64", "win-arm64")
)

$ErrorActionPreference = "Stop"

$proj = "src/VibeXASR.Windows/VibeXASR.Windows.csproj"
$distRoot = Join-Path $PSScriptRoot "dist"

# Resolve a .NET SDK: prefer one on PATH; otherwise fall back to a per-user install
# (~/.dotnet via dotnet-install.ps1). On machines that have only the .NET *runtime*
# on PATH (no SDK), `dotnet --list-sdks` is empty, so we use the per-user dotnet.exe.
$dotnet = "dotnet"
$hasSdk = $false
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    try { $hasSdk = [bool](& dotnet --list-sdks 2>$null) } catch { $hasSdk = $false }
}
if (-not $hasSdk) {
    $userDotnet = Join-Path $env:USERPROFILE ".dotnet\dotnet.exe"
    if (Test-Path $userDotnet) {
        $dotnet = $userDotnet
        $env:DOTNET_ROOT = Split-Path $userDotnet
        $env:DOTNET_MULTILEVEL_LOOKUP = "0"
        Write-Host "Using per-user SDK: $dotnet" -ForegroundColor DarkGray
    } else {
        throw "No .NET SDK found. Install it (machine-wide from https://dotnet.microsoft.com/download/dotnet/8.0, or per-user: irm https://dot.net/v1/dotnet-install.ps1 | iex; then -Channel 8.0)."
    }
}

Write-Host "Restoring..." -ForegroundColor Cyan
& $dotnet restore $proj

foreach ($rid in $Rids) {
    $out = Join-Path $distRoot $rid
    Write-Host "Publishing $rid -> $out" -ForegroundColor Cyan

    # Notes:
    #  --self-contained: bundles the .NET runtime so end users need no SDK/runtime install.
    #  PublishSingleFile: one .exe. Native sherpa-onnx / ONNX Runtime DLLs are bundled and
    #    extracted at runtime (IncludeNativeLibrariesForSelfExtract).
    #  TODO(win): if startup extraction is slow, drop PublishSingleFile and ship a folder,
    #    or set <IncludeAllContentForSelfExtract>true</IncludeAllContentForSelfExtract>.
    & $dotnet publish $proj `
        -c $Configuration `
        -r $rid `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:EnableCompressionInSingleFile=true `
        -o $out
}

Write-Host "Done. Binaries in $distRoot" -ForegroundColor Green
