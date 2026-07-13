<#
.SYNOPSIS
    Build static Qt on Windows using MSVC (vcpkg-style: per-module CMake builds).

.DESCRIPTION
    Each submodule is downloaded, configured, built, and installed independently
    via CMake (not via the top-level configure wrapper).

    Required environment variables (set by scripts/read-config.py):
      QT_VERSION                    Qt version (e.g. 6.10.2)
      SUBMODULE_URL_TEMPLATE        URL template with {submodule} placeholder
      SUBMODULES                    Comma-separated list (in dependency order)
      CMAKE_OPTIONS_COMMON          CMake options for ALL modules
      CMAKE_OPTIONS_QTBASE          Extra CMake options for qtbase only
      CMAKE_OPTIONS_QTBASE_WINDOWS  Windows-specific qtbase options
      STRIP_DEBUG_SYMBOLS           Strip debug symbols (true/false)
      PARALLEL_JOBS                 Parallel job count (0 = auto)
      PACKAGE_NAME_TEMPLATE         Artifact package name template

    Assumes cmake, ninja, python, perl are in PATH (default on GitHub runners).

.PARAMETER WorkDir
    Build working root. Defaults to $env:RUNNER_WORKSPACE.

.PARAMETER InstallPrefix
    Qt install prefix. Defaults to $WorkDir\qt-install.
#>

[CmdletBinding()]
param(
    [string]$WorkDir = $(if ($env:RUNNER_WORKSPACE) { $env:RUNNER_WORKSPACE } else { Join-Path $env:TEMP "qt-build" }),
    [string]$InstallPrefix
)

$ErrorActionPreference = "Stop"

# === Helper functions =========================================================
function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

# === Validate environment variables ============================================
$requiredVars = @(
    "QT_VERSION", "SUBMODULE_URL_TEMPLATE", "SUBMODULES", "CMAKE_OPTIONS_COMMON"
)
foreach ($v in $requiredVars) {
    if (-not (Get-Item -Path "env:$v" -ErrorAction SilentlyContinue)) {
        throw "Missing required env var: $v (run scripts/read-config.py first)"
    }
}

$qtVersion       = $env:QT_VERSION
$urlTemplate     = $env:SUBMODULE_URL_TEMPLATE
$moduleList      = ($env:SUBMODULES -split "," | Where-Object { $_ })
$commonOpts      = $env:CMAKE_OPTIONS_COMMON
$qtbaseOpts      = $env:CMAKE_OPTIONS_QTBASE
$qtbasePlatform  = $env:CMAKE_OPTIONS_QTBASE_WINDOWS
$stripDebug      = ($env:STRIP_DEBUG_SYMBOLS -eq "true")
$parallelJobs    = [int]($env:PARALLEL_JOBS)
if ($parallelJobs -le 0) { $parallelJobs = $env:NUMBER_OF_PROCESSORS }

if (-not $InstallPrefix) {
    $InstallPrefix = Join-Path $WorkDir "qt-install"
}

# Package name
$packageName = $env:PACKAGE_NAME_TEMPLATE
if (-not $packageName) { $packageName = "qt-{version}-static-{platform}" }
$packageName = $packageName -replace "{version}", $qtVersion -replace "{platform}", "windows"

# === Directory layout =========================================================
$installDir = $InstallPrefix
$artifactDir = Join-Path $WorkDir "artifacts"
foreach ($d in @($WorkDir, $installDir, $artifactDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Step "Qt static build parameters (Windows / MSVC)"
Write-Host "Qt version        : $qtVersion"
Write-Host "Submodules        : $($moduleList -join ', ')"
Write-Host "Common CMake opts : $commonOpts"
Write-Host "QtBase CMake opts : $qtbaseOpts"
Write-Host "QtBase platform   : $qtbasePlatform"
Write-Host "Parallel jobs     : $parallelJobs"
Write-Host "Strip debug syms  : $stripDebug"
Write-Host "Work directory    : $WorkDir"
Write-Host "Install prefix    : $installDir"
Write-Host "Package name      : $packageName"

# === Step 0: Set up MSVC dev environment =======================================
Write-Step "Step 0: Set up MSVC dev environment"

$vswhereExe = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhereExe)) { throw "vswhere.exe not found at: $vswhereExe" }
$vsInstallPath = & $vswhereExe -latest -property installationPath
if (-not $vsInstallPath) { throw "Visual Studio installation not found" }
$vcvarsBat = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvarsBat)) { throw "vcvars64.bat not found at: $vcvarsBat" }

Write-Host "Visual Studio path: $vsInstallPath"
Write-Host "Sourcing vcvars64.bat ..."
$envOutput = & cmd /c "`"$vcvarsBat`" && set"
if ($LASTEXITCODE -ne 0) { throw "vcvars64.bat failed with exit code $LASTEXITCODE" }
foreach ($line in $envOutput) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Path "env:$($matches[1])" -Value $matches[2]
    }
}
$clPath = (Get-Command cl.exe -ErrorAction SilentlyContinue)
if (-not $clPath) { throw "cl.exe not found in PATH after vcvars64.bat" }
Write-Host "cl.exe path       : $($clPath.Source)"

# Verify build tools
foreach ($tool in @("cmake", "ninja", "python", "perl")) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Required tool not in PATH: $tool" }
    Write-Host ("{0,-10}: {1}" -f $tool, $cmd.Source)
}

# === Build each submodule =====================================================
function Build-Submodule([string]$module) {
    Write-Step "Building: $module"

    $srcDir = Join-Path $WorkDir "${module}-src"
    $buildDir = Join-Path $WorkDir "${module}-build"
    $archivePath = Join-Path $WorkDir "${module}.tar.xz"

    # --- Download ---
    $downloadUrl = $urlTemplate -replace '\{submodule\}', $module
    if (Test-Path (Join-Path $srcDir "CMakeLists.txt")) {
        Write-Host "Source already exists, skipping download: $srcDir"
    }
    else {
        if (-not (Test-Path $archivePath)) {
            Write-Host "Downloading: $downloadUrl"
            try {
                Import-Module BitsTransfer -ErrorAction Stop
                Start-BitsTransfer -Source $downloadUrl -Destination $archivePath -DisplayName "Qt $module"
            }
            catch {
                Write-Host "BITS unavailable, using Invoke-WebRequest"
                Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
            }
        }
        else {
            Write-Host "Archive already exists: $archivePath"
        }

        # Extract with 7z (much faster than Expand-Archive)
        $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
        if (-not $sevenZip) { $sevenZip = "C:\Program Files\7-Zip\7z.exe" }
        if (-not (Test-Path $sevenZip)) { throw "7z not found" }

        # tar.xz: two passes (xz -> tar)
        $extractTmp = Join-Path $WorkDir "${module}-extract-tmp"
        if (Test-Path $extractTmp) { Remove-Item $extractTmp -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $extractTmp | Out-Null

        & $sevenZip x $archivePath "-o$WorkDir" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z xz extraction failed for $module" }
        $tarPath = Join-Path $WorkDir "${module}.tar"
        & $sevenZip x $tarPath "-o$extractTmp" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z tar extraction failed for $module" }
        Remove-Item $tarPath -Force

        # Move inner directory contents to srcDir
        $inner = Get-ChildItem -Path $extractTmp -Directory | Select-Object -First 1
        if ($inner) {
            Get-ChildItem -Path $inner.FullName -Force | ForEach-Object {
                Move-Item -Path $_.FullName -Destination $srcDir -Force
            }
        }
        Remove-Item $extractTmp -Recurse -Force
    }

    if (-not (Test-Path (Join-Path $srcDir "CMakeLists.txt"))) {
        throw "CMakeLists.txt not found in $srcDir"
    }

    # --- CMake configure ---
    $cmakeArgs = @("-S", $srcDir, "-B", $buildDir, "-G", "Ninja")
    $cmakeArgs += @("-DCMAKE_INSTALL_PREFIX=$installDir")

    # Modules after qtbase need to find the installed qtbase
    if ($module -ne "qtbase") {
        $cmakeArgs += @("-DCMAKE_PREFIX_PATH=$installDir")
    }

    # Common options
    if ($commonOpts) {
        $cmakeArgs += ($commonOpts -split ' ' | Where-Object { $_ })
    }

    # qtbase-specific options
    if ($module -eq "qtbase") {
        if ($qtbaseOpts) {
            $cmakeArgs += ($qtbaseOpts -split ' ' | Where-Object { $_ })
        }
        if ($qtbasePlatform) {
            $cmakeArgs += ($qtbasePlatform -split ' ' | Where-Object { $_ })
        }
    }

    Write-Host "CMake configure options:"
    foreach ($a in $cmakeArgs) { Write-Host "  $a" }

    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed for $module (exit $LASTEXITCODE)" }

    # --- Build ---
    Write-Host "Building $module (parallel: $parallelJobs) ..."
    & cmake --build $buildDir --parallel $parallelJobs
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed for $module (exit $LASTEXITCODE)" }

    # --- Install ---
    Write-Host "Installing $module to $installDir ..."
    & cmake --install $buildDir
    if ($LASTEXITCODE -ne 0) { throw "cmake install failed for $module (exit $LASTEXITCODE)" }

    Write-Host "Done: $module"
}

# Build all submodules in order
$totalModules = $moduleList.Count
$current = 0
foreach ($module in $moduleList) {
    $current++
    Write-Step "Module ${current}/${totalModules}: $module"
    Build-Submodule $module
}

# === Write build info ==========================================================
Write-Step "Write Qt build info"
$qtConf = @{
    version  = $qtVersion
    prefix   = $installDir
    host     = "windows-x86_64"
    static   = $true
    modules  = $moduleList
    compiler = "msvc"
}
$qtConfPath = Join-Path $installDir "qt-static-build-info.json"
$qtConf | ConvertTo-Json -Depth 4 | Out-File -FilePath $qtConfPath -Encoding utf8
Write-Host "Build info written to: $qtConfPath"

# === Package artifact ==========================================================
Write-Step "Package artifact"
$archivePath = Join-Path $artifactDir "$packageName.zip"
if (Test-Path $archivePath) { Remove-Item $archivePath -Force }

Write-Host "Compressing $installDir -> $archivePath"
$sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
if (-not $sevenZip) { $sevenZip = "C:\Program Files\7-Zip\7z.exe" }
if (Test-Path $sevenZip) {
    & $sevenZip a -tzip -mx=7 $archivePath "$installDir\*" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z archive failed (exit $LASTEXITCODE)" }
}
else {
    Compress-Archive -Path "$installDir\*" -DestinationPath $archivePath -CompressionLevel Optimal
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Build succeeded" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Artifact path: $archivePath"
Write-Host "Install prefix: $installDir"

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "artifact_path=$archivePath"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "install_prefix=$installDir"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "package_name=$packageName"
}
