# build-firered.ps1 — compile the FireRedVAD shim (firered_vad.cc + knf + kissfft) into
# firered_vad.dll (x64) with portable mingw-w64, linking onnxruntime's C API.
# Self-contained DLL (static libstdc++/libgcc/winpthread); only external dep is onnxruntime.dll.
# Output: third_party/firered/firered_vad.dll
$fr   = $PSScriptRoot
$gcc  = "$env:USERPROFILE\mingw64\bin\gcc.exe"
$gpp  = "$env:USERPROFILE\mingw64\bin\g++.exe"
$inc  = Join-Path $fr "inc"
$build= Join-Path $fr "build"
New-Item -ItemType Directory -Force $build | Out-Null

# Regenerate the onnxruntime import lib (only OrtGetApiBase is needed) from sherpa-onnx's bundled
# onnxruntime.dll, so this build dir is fully reproducible from a clean checkout.
if (-not (Test-Path "$build\libonnxruntime.a")) {
  $ort = "$env:USERPROFILE\.nuget\packages\org.k2fsa.sherpa.onnx.runtime.win-x64\1.10.32\runtimes\win-x64\native\onnxruntime.dll"
  Copy-Item $ort "$build\onnxruntime.dll" -Force
  Push-Location $build
  & "$env:USERPROFILE\mingw64\bin\gendef.exe" onnxruntime.dll | Out-Null
  & "$env:USERPROFILE\mingw64\bin\dlltool.exe" -d onnxruntime.def -D onnxruntime.dll -l libonnxruntime.a | Out-Null
  Pop-Location
}

$objs = @(); $ok = $true

# kissfft (.c) compiled as C — kissfft uses implicit void* casts that are illegal in C++.
foreach ($c in Get-ChildItem "$fr\src\*.c") {
  $o = Join-Path $build ($c.BaseName + ".o")
  & $gcc -c -O2 -DNDEBUG "-I$inc" $c.FullName -o $o
  if ($LASTEXITCODE -ne 0) { Write-Output "C-FAIL: $($c.Name)"; $ok = $false } else { $objs += $o }
}
# shim + knf (.cc) as C++17.
foreach ($cc in Get-ChildItem "$fr\src\*.cc") {
  $o = Join-Path $build ($cc.BaseName + ".o")
  # -include sal.h: onnxruntime_c_api.h uses MSVC SAL annotations gated on _WIN32; mingw is
  # _WIN32 but doesn't auto-include sal.h, so force it (mingw-w64 ships a complete sal.h).
  & $gpp -c -O2 -std=c++17 -DNDEBUG -include sal.h "-I$inc" $cc.FullName -o $o
  if ($LASTEXITCODE -ne 0) { Write-Output "CXX-FAIL: $($cc.Name)"; $ok = $false } else { $objs += $o }
}
if ($ok) {
  & $gpp -shared -static -static-libgcc -static-libstdc++ $objs -o "$fr\firered_vad.dll" "-L$build" -lonnxruntime
  Write-Output ("LINK_EXIT=" + $LASTEXITCODE + "  dll=" + (Test-Path "$fr\firered_vad.dll"))
} else {
  Write-Output "COMPILE FAILED — see errors above"
}
