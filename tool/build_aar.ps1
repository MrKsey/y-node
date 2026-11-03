# Builds the yggnode AAR that the Android app links against.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool/build_aar.ps1
#
# Optional switches:
#   -Emulator   also build x86_64, needed only to run the app in an emulator
#   -Clean      remove the previous output first
param(
    [switch]$Emulator,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$goBridge = Join-Path $repo 'go-bridge'
$libs = Join-Path $repo 'android\app\libs'
$output = Join-Path $libs 'yggnode.aar'

# The toolchain locations are not assumed: ANDROID_HOME/ANDROID_NDK_HOME win,
# then the SDK used by this workspace, then the default Windows install path.
$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (-not $sdk) { $sdk = 'D:\VCS\sstp\.tools\android-sdk' }
if (-not (Test-Path $sdk)) { throw "Android SDK not found. Set ANDROID_HOME." }

$ndk = $env:ANDROID_NDK_HOME
if (-not $ndk) {
    $ndkRoot = Join-Path $sdk 'ndk'
    if (Test-Path $ndkRoot) {
        $ndk = (Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    }
}
if (-not $ndk -or -not (Test-Path $ndk)) { throw "Android NDK not found. Set ANDROID_NDK_HOME." }

$jdk = $env:JAVA_HOME
if (-not $jdk) { $jdk = 'D:\VCS\sstp\.tools\jdk17' }
if (-not (Test-Path $jdk)) { throw "JDK 17 not found. Set JAVA_HOME." }

$gomobile = Join-Path $repo '.tools\bin\gomobile.exe'
if (-not (Test-Path $gomobile)) {
    Write-Host 'gomobile is missing, installing it into .tools\bin'
    $env:GOBIN = Join-Path $repo '.tools\bin'
    New-Item -ItemType Directory -Force -Path $env:GOBIN | Out-Null
    & go install golang.org/x/mobile/cmd/gomobile@latest
    if ($LASTEXITCODE -ne 0) { throw 'go install gomobile failed' }
}

$env:ANDROID_HOME = $sdk
$env:ANDROID_NDK_HOME = $ndk
$env:JAVA_HOME = $jdk
$env:GOBIN = Join-Path $repo '.tools\bin'
$env:Path = "$env:GOBIN;$jdk\bin;$env:Path"

Push-Location $goBridge
try {
    & $gomobile init
    if ($LASTEXITCODE -ne 0) { throw 'gomobile init failed' }

    if ($Clean -and (Test-Path $output)) { Remove-Item $output -Force }
    New-Item -ItemType Directory -Force -Path $libs | Out-Null

    $targets = 'android/arm,android/arm64'
    if ($Emulator) { $targets = "$targets,android/amd64" }

    Write-Host "Building yggnode.aar for $targets"
    # -checklinkname=0 is required: golang.org/x/net's Android dependency
    # wlynxg/anet reaches into net.zoneCache with go:linkname, which the Go 1.26
    # linker rejects by default.
    & $gomobile bind "-target=$targets" '-androidapi=26' '-ldflags=-checklinkname=0' "-o=$output" './yggnode'
    if ($LASTEXITCODE -ne 0) { throw 'gomobile bind failed' }
} finally {
    Pop-Location
}

$size = [math]::Round((Get-Item $output).Length / 1MB, 2)
Write-Host "yggnode.aar written to $output ($size MB)"
