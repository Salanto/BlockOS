# Run the BlockOS test suite in CraftOS-PC on Windows.
#
#   tools\test.ps1 [-ComputerType advanced|basic]
#
# Set $env:CRAFTOS to the CraftOS-PC executable if it is not in the default place.
# This mirrors tools/craftos-run.sh; keep the two in sync.
param(
    [ValidateSet("advanced", "basic")]
    [string]$ComputerType = "advanced"
)
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$craftos = if ($env:CRAFTOS) { $env:CRAFTOS } else { "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe" }
if (-not (Test-Path $craftos)) {
    throw "CraftOS-PC not found at '$craftos'. Install it or set `$env:CRAFTOS."
}

$data = Join-Path ([System.IO.Path]::GetTempPath()) ("blockos-test-" + [guid]::NewGuid())
$computer = Join-Path $data "computer\0"
try {
    New-Item -ItemType Directory -Force (Join-Path $computer "repo") | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $data "computer\1") | Out-Null
    foreach ($dir in "packages", "installer", "tools", "tests") {
        Copy-Item -Recurse (Join-Path $repo $dir) (Join-Path $computer "repo")
    }
    Copy-Item (Join-Path $repo "tests\fixtures\peer_startup.lua") (Join-Path $data "computer\1\startup.lua")

    Set-Content (Join-Path $computer "harness-args") "/repo/tests/run.lua`n$ComputerType"
    Set-Content (Join-Path $computer "startup.lua") 'shell.run("/repo/tools/harness.lua")'

    & $craftos --headless --directory $data --id 0

    $report = Join-Path $computer "test-report.txt"
    if (Test-Path $report) { Get-Content $report }
    $result = Get-Content (Join-Path $computer "harness-result") -ErrorAction SilentlyContinue
    if ($result -ne "ok") {
        Write-Error "Tests FAILED ($result)"
        exit 1
    }
    Write-Output "OK"
}
finally {
    Remove-Item -Recurse -Force $data -ErrorAction SilentlyContinue
}
