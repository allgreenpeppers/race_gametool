# Injects the .rgpack file association into the Inno Setup script that
# inno_bundle generates at build\windows\x64\installer\Release\inno-script.iss.
#
# inno_bundle has no file-association option, so this patch adds the [Registry]
# entries plus ChangesAssociations. Run it AFTER
#   dart run inno_bundle:build --no-app --release --no-installer
# and BEFORE the script is compiled. Idempotent.
param(
  [string]$IssPath = "build\windows\x64\installer\Release\inno-script.iss"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $IssPath)) {
  throw "Inno Setup script not found: $IssPath (generate it with 'dart run inno_bundle:build --no-app --release --no-installer' first)."
}

$content = Get-Content -Raw -Path $IssPath

# Ask the shell to refresh associations after install.
if ($content -notmatch "ChangesAssociations") {
  $content = $content -replace "(?m)^\[Setup\]\s*$", "[Setup]`r`nChangesAssociations=yes"
}

# Append the association. `{app}\race_gametool.exe` is the installed executable
# (BINARY_NAME in windows/CMakeLists.txt); the command passes the double-clicked
# path as %1, which the app opens via FileOpenService. With `admin: false` the
# install is per-user, so HKA resolves to HKCU (no elevation). uninsdeletekey /
# uninsdeletevalue remove the association on uninstall.
if ($content -notmatch "RaceGameTool\.rgpack") {
  $reg = @'

[Registry]
Root: HKA; Subkey: "Software\Classes\.rgpack"; ValueType: string; ValueName: ""; ValueData: "RaceGameTool.rgpack"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\RaceGameTool.rgpack"; ValueType: string; ValueName: ""; ValueData: "Race Game Pack"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\RaceGameTool.rgpack\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\race_gametool.exe,0"
Root: HKA; Subkey: "Software\Classes\RaceGameTool.rgpack\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\race_gametool.exe"" ""%1"""
'@
  $content = $content + $reg
}

Set-Content -Path $IssPath -Value $content -Encoding UTF8
Write-Host "Injected .rgpack association into $IssPath"
