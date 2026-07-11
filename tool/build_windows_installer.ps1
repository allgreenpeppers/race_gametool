# Local one-command Windows installer build. Mirrors the CI workflow
# (.github/workflows/release.yml) so local and CI builds stay identical:
#   1. flutter build windows --release
#   2. dart run inno_bundle:build --no-app --release --no-installer  (generate .iss)
#   3. inject the .rgpack file association into the generated script
#   4. compile the script with the Inno Setup compiler (ISCC)
#
# Step 4 uses ISCC directly rather than `inno_bundle:build --release`, because
# the latter would regenerate the .iss and discard the injected association.
#
# Run from the repo root on Windows, with Flutter and Inno Setup installed:
#   powershell -ExecutionPolicy Bypass -File tool\build_windows_installer.ps1

param(
  # Inno Setup compiler. Leave empty to auto-locate, or pass a full path to
  # ISCC.exe.
  [string]$Iscc = ""
)

$ErrorActionPreference = "Stop"

# Locate the Inno Setup compiler: standard install locations, then PATH.
if (-not $Iscc) {
  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
  )
  $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($found) {
    $Iscc = $found
  } elseif (Get-Command iscc -ErrorAction SilentlyContinue) {
    $Iscc = "iscc"
  } else {
    throw "Inno Setup compiler (ISCC) not found. Install Inno Setup or pass -Iscc <path to ISCC.exe>."
  }
}

flutter build windows --release
dart run inno_bundle:build --no-app --release --no-installer
& "$PSScriptRoot\inject_rgpack_association.ps1"

$iss = "build\windows\x64\installer\Release\inno-script.iss"
& $Iscc $iss
Write-Host "Installer built from $iss"
