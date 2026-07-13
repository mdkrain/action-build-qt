<#
.SYNOPSIS
    在 Windows 上使用 MSVC 构建静态 Qt（不使用 mingw）。

.DESCRIPTION
    本脚本假设以下环境变量已被 workflow 通过 scripts/read-config.py 设置：
      QT_VERSION                Qt 版本（例如 6.10.2）
      QT_SOURCE_URL             Qt 源码下载地址
      QT_SOURCE_SHA256          源码 SHA-256（可选，空则跳过校验）
      SUBMODULES                要构建的子模块，逗号分隔
      SKIP_MODULES              要跳过的子模块，逗号分隔
      CONFIGURE_OPTIONS_COMMON  通用 configure 参数（空格分隔）
      CONFIGURE_OPTIONS_WINDOWS Windows 专属 configure 参数
      CMAKE_EXTRA_ARGS_COMMON   通用 CMake 参数（空格分隔）
      CMAKE_EXTRA_ARGS_WINDOWS  Windows 专属 CMake 参数
      STRIP_DEBUG_SYMBOLS       是否 strip 调试符号（true/false）
      PARALLEL_JOBS             并行任务数（0=自动）
      PACKAGE_NAME_TEMPLATE     产物包命名模板

    同时假设以下工具已在 PATH 中：cmake, ninja, python, perl
    GitHub-hosted windows-latest runner 默认已安装。

.PARAMETER WorkDir
    构建工作根目录。默认为 $env:RUNNER_WORKSPACE（在 GitHub Actions 中存在），
    若不存在则使用 $env:TEMP\qt-build。

.PARAMETER InstallPrefix
    Qt 安装前缀。默认为 $WorkDir\qt-install。
#>

[CmdletBinding()]
param(
    [string]$WorkDir = $(if ($env:RUNNER_WORKSPACE) { $env:RUNNER_WORKSPACE } else { Join-Path $env:TEMP "qt-build" }),
    [string]$InstallPrefix
)

$ErrorActionPreference = "Stop"

# ── 辅助函数 ──────────────────────────────────────────────────────────────────
function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Invoke-Native {
    # 调用外部程序并在失败时抛出。比 cmd /c 更可靠地捕获错误。
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Args = @())
    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe' exited with code $LASTEXITCODE"
    }
}

# ── 校验环境变量 ───────────────────────────────────────────────────────────────
$requiredVars = @(
    "QT_VERSION", "QT_SOURCE_URL", "SUBMODULES",
    "CONFIGURE_OPTIONS_COMMON", "CONFIGURE_OPTIONS_WINDOWS"
)
foreach ($v in $requiredVars) {
    if (-not (Get-Item -Path "env:$v" -ErrorAction SilentlyContinue)) {
        throw "Missing required env var: $v (run scripts/read-config.py first)"
    }
}

$qtVersion = $env:QT_VERSION
$sourceUrl = $env:QT_SOURCE_URL
$sourceSha256 = $env:QT_SOURCE_SHA256
$submodules = ($env:SUBMODULES -split "," | Where-Object { $_ }) -join ","
$skipModules = ($env:SKIP_MODULES -split "," | Where-Object { $_ }) -join ","
$commonOpts = $env:CONFIGURE_OPTIONS_COMMON
$platformOpts = $env:CONFIGURE_OPTIONS_WINDOWS
$cmakeCommon = $env:CMAKE_EXTRA_ARGS_COMMON
$cmakePlatform = $env:CMAKE_EXTRA_ARGS_WINDOWS
$stripDebug = ($env:STRIP_DEBUG_SYMBOLS -eq "true")
$parallelJobs = [int]($env:PARALLEL_JOBS)
if ($parallelJobs -le 0) { $parallelJobs = $env:NUMBER_OF_PROCESSORS }

if (-not $InstallPrefix) {
    $InstallPrefix = Join-Path $WorkDir "qt-install"
}

# 包名（替换模板）
$packageName = $env:PACKAGE_NAME_TEMPLATE
if (-not $packageName) { $packageName = "qt-{version}-static-{platform}" }
$packageName = $packageName -replace "{version}", $qtVersion -replace "{platform}", "windows"

# ── 目录规划 ───────────────────────────────────────────────────────────────────
$srcDir = Join-Path $WorkDir "qt-src"
$buildDir = Join-Path $WorkDir "qt-build"
$installDir = $InstallPrefix
$artifactDir = Join-Path $WorkDir "artifacts"

foreach ($d in @($WorkDir, $srcDir, $buildDir, $installDir, $artifactDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Step "Qt 静态构建参数（Windows / MSVC）"
Write-Host "Qt 版本          : $qtVersion"
Write-Host "源码 URL         : $sourceUrl"
Write-Host "子模块           : $submodules"
Write-Host "跳过模块         : $skipModules"
Write-Host "通用 configure   : $commonOpts"
Write-Host "Windows configure: $platformOpts"
Write-Host "通用 CMake       : $cmakeCommon"
Write-Host "Windows CMake    : $cmakePlatform"
Write-Host "并行任务数       : $parallelJobs"
Write-Host "Strip 调试符号   : $stripDebug"
Write-Host "工作目录         : $WorkDir"
Write-Host "安装前缀         : $installDir"
Write-Host "产物包名         : $packageName"

# ── Step 1: 设置 MSVC 开发环境 ──────────────────────────────────────────────────
Write-Step "Step 1: 设置 MSVC 开发环境（不使用 mingw）"

# 通过 vswhere 找到最新 Visual Studio 安装路径，再调用 vcvars64.bat 设置环境。
$vswhereExe = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhereExe)) {
    throw "vswhere.exe not found at: $vswhereExe"
}
$vsInstallPath = & $vswhereExe -latest -property installationPath
if (-not $vsInstallPath) {
    throw "Visual Studio installation not found"
}
$vcvarsBat = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvarsBat)) {
    throw "vcvars64.bat not found at: $vcvarsBat"
}

Write-Host "Visual Studio path: $vsInstallPath"
Write-Host "vcvars64.bat path : $vcvarsBat"

# 调用 vcvars64.bat 并将其环境变量导入当前 PowerShell 进程。
# cmd /c "call vcvars64.bat && set" 会输出所有环境变量，我们解析后写入当前进程。
Write-Host "Sourcing vcvars64.bat ..."
$envOutput = & cmd /c "`"$vcvarsBat`" && set"
if ($LASTEXITCODE -ne 0) {
    throw "vcvars64.bat failed with exit code $LASTEXITCODE"
}
foreach ($line in $envOutput) {
    if ($line -match '^([^=]+)=(.*)$') {
        $name = $matches[1]
        $value = $matches[2]
        Set-Item -Path "env:$name" -Value $value
    }
}

# 验证 MSVC 工具链可用
$clPath = (Get-Command cl.exe -ErrorAction SilentlyContinue)
if (-not $clPath) {
    throw "cl.exe not found in PATH after vcvars64.bat"
}
Write-Host "cl.exe path      : $($clPath.Source)"
Write-Host "MSVC environment ready."

# ── Step 2: 验证工具链 ─────────────────────────────────────────────────────────
Write-Step "Step 2: 验证构建工具"
foreach ($tool in @("cmake", "ninja", "python", "perl")) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Required tool not in PATH: $tool"
    }
    Write-Host ("{0,-10}: {1}" -f $tool, $cmd.Source)
}

# ── Step 3: 下载 Qt 源码 ───────────────────────────────────────────────────────
Write-Step "Step 3: 下载 Qt 源码"
$archiveExt = if ($sourceUrl -match '\.zip$') { ".zip" } elseif ($sourceUrl -match '\.7z$') { ".7z" } else { ".tar.xz" }
$archivePath = Join-Path $WorkDir "qt-src$archiveExt"

if (Test-Path (Join-Path $srcDir "configure.bat")) {
    Write-Host "Qt 源码已存在，跳过下载: $srcDir"
}
else {
    if (Test-Path $archivePath) {
        Write-Host "归档已存在，跳过下载: $archivePath"
    }
    else {
        Write-Host "下载: $sourceUrl"
        # 使用 BITS 下载更稳定（支持断点）
        try {
            Import-Module BitsTransfer -ErrorAction Stop
            Start-BitsTransfer -Source $sourceUrl -Destination $archivePath -DisplayName "Qt source"
        }
        catch {
            Write-Host "BITS 不可用，回退到 Invoke-WebRequest"
            Invoke-WebRequest -Uri $sourceUrl -OutFile $archivePath -UseBasicParsing
        }
    }

    # SHA-256 校验
    if ($sourceSha256) {
        Write-Host "校验 SHA-256 ..."
        $hash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $sourceSha256.ToLower()) {
            throw "SHA-256 mismatch:`n  expected: $sourceSha256`n  actual:   $hash"
        }
        Write-Host "SHA-256 校验通过"
    }
    else {
        Write-Host "未提供 SHA-256，跳过校验"
    }

    # 解压到 srcDir
    Write-Host "解压到: $srcDir"
    # Qt 源码归档内含一层目录（qt-everywhere-src-<version>），先解压到临时目录再移动
    $extractTmp = Join-Path $WorkDir "qt-extract-tmp"
    if (Test-Path $extractTmp) { Remove-Item $extractTmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $extractTmp | Out-Null

    if ($archiveExt -eq ".zip") {
        Expand-Archive -Path $archivePath -DestinationPath $extractTmp -Force
    }
    else {
        # .tar.xz / .7z 都用 7z 解压（GitHub runner 自带）
        $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
        if (-not $sevenZip) {
            $sevenZip = (Get-Command "C:\Program Files\7-Zip\7z.exe" -ErrorAction SilentlyContinue).Source
        }
        if (-not $sevenZip) {
            throw "7z not found in PATH"
        }
        # tar.xz 需要先解压 xz，再解压 tar
        if ($archiveExt -eq ".tar.xz") {
            & $sevenZip x $archivePath "-o$WorkDir" -y | Out-Null
            $tarPath = Join-Path $WorkDir "qt-src.tar"
            & $sevenZip x $tarPath "-o$extractTmp" -y | Out-Null
            Remove-Item $tarPath -Force
        }
        else {
            & $sevenZip x $archivePath "-o$extractTmp" -y | Out-Null
        }
    }

    # 将内层目录移动到 $srcDir
    $inner = Get-ChildItem -Path $extractTmp -Directory | Select-Object -First 1
    if ($inner) {
        # 移动所有内容到 $srcDir
        Get-ChildItem -Path $inner.FullName -Force | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $srcDir -Force
        }
    }
    Remove-Item $extractTmp -Recurse -Force
}

# 验证源码
$configureBat = Join-Path $srcDir "configure.bat"
if (-not (Test-Path $configureBat)) {
    throw "configure.bat not found in source dir: $srcDir"
}

# ── Step 4: 配置 Qt ────────────────────────────────────────────────────────────
Write-Step "Step 4: 配置 Qt"

# 清理 build 目录确保干净环境
if (Test-Path (Join-Path $buildDir "CMakeCache.txt")) {
    Write-Host "清理旧的 CMakeCache.txt ..."
    Remove-Item (Join-Path $buildDir "CMakeCache.txt") -Force
}

Push-Location $buildDir
try {
    # 构造 configure 参数（不含 configure.bat 本身）
    $configureArgs = @()

    # 通用选项（按空格切分为独立参数）
    if ($commonOpts) {
        $configureArgs += ($commonOpts -split ' ' | Where-Object { $_ })
    }
    # 平台专属选项
    if ($platformOpts) {
        $configureArgs += ($platformOpts -split ' ' | Where-Object { $_ })
    }
    # 子模块
    if ($submodules) {
        $configureArgs += @("-submodules", $submodules)
    }
    # 跳过模块
    if ($skipModules) {
        $configureArgs += @("-skip", $skipModules)
    }
    # 安装前缀
    $configureArgs += @("-prefix", $installDir)

    # 透传 CMake 参数（通过 -- 分隔）
    $cmakeArgsStr = (@($cmakeCommon, $cmakePlatform) | Where-Object { $_ }) -join ' '
    if ($cmakeArgsStr) {
        $configureArgs += @("--")
        $configureArgs += ($cmakeArgsStr -split ' ' | Where-Object { $_ })
    }

    # 为含空格的参数添加引号（例如 -prefix C:\Program Files\...）
    $argString = ($configureArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { "$_" }
        }) -join ' '

    Write-Host "调用 configure.bat ..."
    Write-Host "参数: $argString"
    # 用 cmd /c 调用 .bat 以确保正确处理批处理语义
    & cmd /c "`"$configureBat`" $argString"
    if ($LASTEXITCODE -ne 0) {
        throw "configure.bat failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

# ── Step 5: 构建 Qt ────────────────────────────────────────────────────────────
Write-Step "Step 5: 构建 Qt（并行任务数: $parallelJobs）"
Push-Location $buildDir
try {
    & cmake --build . --parallel $parallelJobs
    if ($LASTEXITCODE -ne 0) {
        throw "cmake --build failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

# ── Step 6: 安装 Qt ────────────────────────────────────────────────────────────
Write-Step "Step 6: 安装 Qt 到 $installDir"
Push-Location $buildDir
try {
    & cmake --install .
    if ($LASTEXITCODE -ne 0) {
        throw "cmake --install failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

# ── Step 7: 写入环境信息（供下游项目使用）──────────────────────────────────────
Write-Step "Step 7: 写入 Qt 环境信息"
$qtConf = @{
    version  = $qtVersion
    prefix   = $installDir
    host     = "windows-x86_64"
    static   = $true
    modules  = ($submodules -split ",")
    skip     = ($skipModules -split "," | Where-Object { $_ })
    compiler = "msvc"
}
$qtConfPath = Join-Path $installDir "qt-static-build-info.json"
$qtConf | ConvertTo-Json -Depth 4 | Out-File -FilePath $qtConfPath -Encoding utf8
Write-Host "已写入构建信息: $qtConfPath"

# ── Step 8: 打包产物 ───────────────────────────────────────────────────────────
Write-Step "Step 8: 打包产物"
$archivePath = Join-Path $artifactDir "$packageName.zip"
if (Test-Path $archivePath) { Remove-Item $archivePath -Force }

Write-Host "压缩 $installDir → $archivePath"
# 使用 7z 压缩为 zip（比 Compress-Archive 更快且支持大文件）
$sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
if (-not $sevenZip) {
    $sevenZip = "C:\Program Files\7-Zip\7z.exe"
}
if (Test-Path $sevenZip) {
    & $sevenZip a -tzip -mx=7 $archivePath "$installDir\*" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "7z archive failed with exit code $LASTEXITCODE"
    }
}
else {
    # 回退到 PowerShell 内置
    Compress-Archive -Path "$installDir\*" -DestinationPath $archivePath -CompressionLevel Optimal
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  构建成功" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "产物路径: $archivePath"
Write-Host "安装前缀: $installDir"

# 输出产物路径到 GITHUB_OUTPUT（供 workflow 后续步骤使用）
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "artifact_path=$archivePath"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "install_prefix=$installDir"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "package_name=$packageName"
}
