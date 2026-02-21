[CmdletBinding()]
param(
    [string]$FlutterPath = "",
    [string]$VcpkgRoot = "",
    [string]$ToolsRoot = "",
    [switch]$SkipPortablePack,
    [switch]$NoHwcodec,
    [switch]$InstallMissingVcpkgDeps,
    [switch]$SkipFlutterDoctor,
    [switch]$AllowNonMSVCToolchain,
    [switch]$AutoSetup,
    [switch]$AutoSetupAllTools,
    [switch]$InstallVisualCpp,
    [switch]$VcpkgDebug
)

$ErrorActionPreference = "Stop"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Resolve-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }
    return $cmd.Source
}

function Resolve-LibclangDirectory {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LIBCLANG_PATH)) {
        $candidates += $env:LIBCLANG_PATH
    }
    $candidates += @(
        "C:\Program Files\LLVM\bin",
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Tools\Llvm\x64\bin",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\x64\bin",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\Llvm\x64\bin"
    )
    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path $candidate)) {
            continue
        }
        if ((Get-Item $candidate).PSIsContainer) {
            $libclangDll = Join-Path $candidate "libclang.dll"
            $clangDll = Join-Path $candidate "clang.dll"
            if ((Test-Path $libclangDll) -or (Test-Path $clangDll)) {
                return (Resolve-Path $candidate).Path
            }
        } else {
            $leaf = Split-Path -Leaf $candidate
            if ($leaf -in @("libclang.dll", "clang.dll")) {
                return (Resolve-Path (Split-Path -Parent $candidate)).Path
            }
        }
    }
    return $null
}

function Invoke-External([string]$Exe, [string[]]$CmdArgs) {
    & $Exe @CmdArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "Command failed ($LASTEXITCODE): $Exe $($CmdArgs -join ' ')"
    }
}

function Prepare-FlutterProject([string]$FlutterProjectDir, [string]$FlutterExePath) {
    if (-not (Test-Path $FlutterProjectDir)) {
        Fail "Flutter project directory not found: $FlutterProjectDir"
    }

    $runningFlutter = Get-Process -Name "flutter", "dart" -ErrorAction SilentlyContinue
    if ($runningFlutter) {
        $procList = ($runningFlutter | Select-Object -ExpandProperty Id) -join ", "
        Write-Warning "Detected running flutter/dart process(es): $procList. They may lock Flutter metadata files."
    }

    $probeFile = Join-Path $FlutterProjectDir ".build-windows-write-probe"
    try {
        Set-Content -LiteralPath $probeFile -Value "ok" -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop
    } catch {
        Fail "Flutter project is not writable: $FlutterProjectDir. $($_.Exception.Message)"
    }

    foreach ($name in @(".flutter-plugins", ".flutter-plugins-dependencies")) {
        $path = Join-Path $FlutterProjectDir $name
        if (Test-Path -LiteralPath $path) {
            try {
                attrib -R $path 2>$null | Out-Null
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                Write-Host "Removed stale Flutter metadata file: $name"
            } catch {
                Write-Warning "Could not remove $path. Build may fail if the file is locked. $($_.Exception.Message)"
            }
        }
    }

    Push-Location $FlutterProjectDir
    try {
        Write-Host "Running flutter pub get ..."
        Invoke-External $FlutterExePath @("pub", "get")
    } finally {
        Pop-Location
    }
}

function Test-SymlinkSupport([string]$Dir) {
    $target = Join-Path $Dir "pubspec.yaml"
    if (-not (Test-Path -LiteralPath $target)) {
        return $false
    }
    $link = Join-Path $Dir ".symlink-perm-check"
    try {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Show-VcpkgFfmpegLogTail([string]$VcpkgRootPath, [int]$TailLines = 60) {
    $ffmpegTree = Join-Path $VcpkgRootPath "buildtrees\ffmpeg"
    if (-not (Test-Path $ffmpegTree)) {
        Write-Warning "ffmpeg buildtree not found at $ffmpegTree"
        return
    }
    $logs = Get-ChildItem -Path $ffmpegTree -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 3
    if (-not $logs) {
        Write-Warning "No ffmpeg logs found in $ffmpegTree"
        return
    }
    Write-Host "Latest ffmpeg logs:"
    foreach ($log in $logs) {
        Write-Host "---- $($log.Name) [$($log.LastWriteTime)] ----"
        Get-Content -Path $log.FullName -Tail $TailLines -ErrorAction SilentlyContinue
    }
}

function Invoke-VcpkgInstall([string]$VcpkgExePath, [string[]]$Packages, [string]$VcpkgRootPath, [bool]$EnableDebug) {
    $installArgs = @("install", "--classic")
    if ($EnableDebug) {
        $installArgs += "--debug"
    }
    $installArgs += $Packages

    Write-Host "Running: $VcpkgExePath $($installArgs -join ' ')"
    & $VcpkgExePath @installArgs
    if ($LASTEXITCODE -ne 0) {
        Show-VcpkgFfmpegLogTail -VcpkgRootPath $VcpkgRootPath -TailLines 80
        Fail "Command failed ($LASTEXITCODE): $VcpkgExePath $($installArgs -join ' ')"
    }
}

function Import-CmdEnvironmentFromBatch([string]$BatchFile, [string]$BatchArgs = "") {
    if (-not (Test-Path $BatchFile)) {
        return $false
    }
    $escapedBatchFile = $BatchFile.Replace('"', '""')
    $cmdString = if ($BatchArgs) {
        "call ""$escapedBatchFile"" $BatchArgs >nul && set"
    } else {
        "call ""$escapedBatchFile"" >nul && set"
    }
    $envOutput = cmd.exe /s /c $cmdString
    if ($LASTEXITCODE -ne 0 -or -not $envOutput) {
        return $false
    }
    foreach ($line in $envOutput) {
        $idx = $line.IndexOf("=")
        if ($idx -gt 0) {
            $name = $line.Substring(0, $idx)
            $value = $line.Substring($idx + 1)
            Set-Item -Path "Env:$name" -Value $value
        }
    }
    return $true
}

function Try-LoadVisualCppEnvironment {
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        return $false
    }
    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $installationPath) {
        return $false
    }
    $installationPath = $installationPath.Trim()
    if (-not $installationPath) {
        return $false
    }
    $vcvars64 = Join-Path $installationPath "VC\Auxiliary\Build\vcvars64.bat"
    if (Import-CmdEnvironmentFromBatch $vcvars64) {
        return $true
    }
    $vsDevCmd = Join-Path $installationPath "Common7\Tools\VsDevCmd.bat"
    if (Import-CmdEnvironmentFromBatch $vsDevCmd "-arch=x64") {
        return $true
    }
    return $false
}

function Refresh-Tools {
    return @{
        python = Resolve-Tool "python"
        cargo = Resolve-Tool "cargo"
        rustup = Resolve-Tool "rustup"
        flutter = Resolve-Tool "flutter"
    }
}

function Get-VcpkgCandidates {
    $candidates = @()
    if ($ToolsRoot) {
        $candidates += (Join-Path $ToolsRoot "vcpkg")
    } elseif ($AutoSetup -and $env:USERPROFILE) {
        $candidates += (Join-Path (Join-Path $env:USERPROFILE "dev\mizemoon-tools") "vcpkg")
    }
    $candidates += @(
        (Join-Path $repoRoot ".windows-tools\vcpkg"),
        (Join-Path $repoRoot "vcpkg"),
        (Join-Path $env:USERPROFILE "vcpkg"),
        "C:\vcpkg",
        "D:\vcpkg",
        "C:\src\vcpkg",
        "C:\tools\vcpkg"
    )
    return $candidates | Where-Object { $_ } | Select-Object -Unique
}

function Invoke-AutoSetupIfNeeded([string]$Reason) {
    if (-not $AutoSetup) {
        return
    }
    if ($script:autoSetupDone) {
        return
    }
    $setupScript = Join-Path $repoRoot "setup-windows-tools.ps1"
    if (-not (Test-Path $setupScript)) {
        Fail "Auto setup requested, but setup script not found: $setupScript"
    }

    $setupParams = [ordered]@{}
    if ($VcpkgRoot) {
        $setupParams["VcpkgRoot"] = $VcpkgRoot
    }
    if ($ToolsRoot) {
        $setupParams["ToolsRoot"] = $ToolsRoot
    }
    $setupParams["InstallVcpkgDeps"] = $true
    if ($InstallVisualCpp) {
        $setupParams["InstallVisualCpp"] = $true
    }
    if ($SkipFlutterDoctor) {
        $setupParams["SkipFlutterDoctor"] = $true
    }
    if ($VcpkgDebug) {
        $setupParams["VcpkgDebug"] = $true
    }
    if (-not $AutoSetupAllTools) {
        $setupParams["SkipRustSetup"] = $true
        $setupParams["SkipFlutterSetup"] = $true
        $setupParams["SkipLibclangSetup"] = $true
    }

    $setupArgsForDisplay = @()
    foreach ($name in $setupParams.Keys) {
        $value = $setupParams[$name]
        if ($value -is [bool]) {
            if ($value) {
                $setupArgsForDisplay += "-$name"
            }
        } else {
            $setupArgsForDisplay += @("-$name", "$value")
        }
    }

    Write-Host "Auto setup triggered: $Reason"
    Write-Host "Running setup script: $setupScript $($setupArgsForDisplay -join ' ')"
    & $setupScript @setupParams
    if ($LASTEXITCODE -ne 0) {
        Fail "Auto setup failed ($LASTEXITCODE)."
    }
    $script:autoSetupDone = $true
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot
$script:autoSetupDone = $false

if ($env:OS -ne "Windows_NT") {
    Fail "This script must run on Windows."
}

if (-not (Test-Path (Join-Path $repoRoot "build.py"))) {
    Fail "build.py not found. Run this script from the repository root."
}

if ($FlutterPath) {
    $resolvedFlutter = Resolve-Path $FlutterPath -ErrorAction SilentlyContinue
    if ($null -eq $resolvedFlutter) {
        Fail "FlutterPath does not exist: $FlutterPath"
    }
    if ((Get-Item $resolvedFlutter).PSIsContainer) {
        if (-not (Test-Path (Join-Path $resolvedFlutter "flutter.bat"))) {
            Fail "FlutterPath folder must contain flutter.bat: $resolvedFlutter"
        }
        $env:PATH = "$resolvedFlutter;$env:PATH"
    } else {
        if ((Split-Path -Leaf $resolvedFlutter) -ne "flutter.bat") {
            Fail "FlutterPath file must be flutter.bat: $resolvedFlutter"
        }
        $env:PATH = "$(Split-Path -Parent $resolvedFlutter);$env:PATH"
    }
}

if ($VcpkgRoot) {
    $resolvedVcpkg = Resolve-Path $VcpkgRoot -ErrorAction SilentlyContinue
    if ($null -ne $resolvedVcpkg) {
        $env:VCPKG_ROOT = $resolvedVcpkg.Path
    } else {
        Write-Warning "VcpkgRoot does not exist: $VcpkgRoot"
    }
}

$tools = Refresh-Tools
if (-not $tools.python) { Fail "python not found in PATH." }

$missingToolNames = @()
if (-not $tools.cargo) { $missingToolNames += "cargo" }
if (-not $tools.rustup) { $missingToolNames += "rustup" }
if (-not $tools.flutter) { $missingToolNames += "flutter" }

if ($missingToolNames.Count -gt 0) {
    if ($AutoSetup -and $AutoSetupAllTools) {
        Invoke-AutoSetupIfNeeded ("missing tools: " + ($missingToolNames -join ", "))
        $tools = Refresh-Tools
        $missingToolNames = @()
        if (-not $tools.cargo) { $missingToolNames += "cargo" }
        if (-not $tools.rustup) { $missingToolNames += "rustup" }
        if (-not $tools.flutter) { $missingToolNames += "flutter" }
    }
}

if ($missingToolNames.Count -gt 0) {
    if ($AutoSetup -and -not $AutoSetupAllTools) {
        Fail "Missing tools in PATH: $($missingToolNames -join ', '). -AutoSetup currently installs project deps only (vcpkg). Install tools manually or run with -AutoSetupAllTools."
    }
    Fail "Missing tools in PATH: $($missingToolNames -join ', '). Run setup-windows-tools.ps1 or use -AutoSetup -AutoSetupAllTools."
}

$pythonExe = $tools.python
$cargoExe = $tools.cargo
$rustupExe = $tools.rustup
$flutterExe = $tools.flutter

if (-not $env:VCPKG_ROOT) {
    $vcpkgCandidates = Get-VcpkgCandidates
    foreach ($candidate in $vcpkgCandidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate "vcpkg.exe"))) {
            $env:VCPKG_ROOT = $candidate
            Write-Host "Detected VCPKG_ROOT: $env:VCPKG_ROOT"
            break
        }
    }
}

if (-not $env:VCPKG_ROOT) {
    Invoke-AutoSetupIfNeeded "VCPKG_ROOT is missing"
    if (-not $env:VCPKG_ROOT) {
        $vcpkgCandidates = Get-VcpkgCandidates
        foreach ($candidate in $vcpkgCandidates) {
            if ($candidate -and (Test-Path (Join-Path $candidate "vcpkg.exe"))) {
                $env:VCPKG_ROOT = $candidate
                Write-Host "Detected VCPKG_ROOT: $env:VCPKG_ROOT"
                break
            }
        }
    }
}

if (-not $env:VCPKG_ROOT) {
    Fail "VCPKG_ROOT is not set and vcpkg.exe was not found. Run setup-windows-tools.ps1 or use -AutoSetup."
}

$vcpkgExe = Join-Path $env:VCPKG_ROOT "vcpkg.exe"
if (-not (Test-Path $vcpkgExe)) {
    Invoke-AutoSetupIfNeeded "vcpkg.exe missing at $vcpkgExe"
    if (-not (Test-Path $vcpkgExe)) {
        Fail "vcpkg.exe not found at $vcpkgExe"
    }
}
$vcpkgRootResolved = Split-Path -Parent $vcpkgExe

$toolchain = (& $rustupExe show active-toolchain) 2>$null
if (-not $AllowNonMSVCToolchain -and ($toolchain -notmatch "x86_64-pc-windows-msvc")) {
    Fail "Active rust toolchain is '$toolchain'. Run: rustup default stable-x86_64-pc-windows-msvc"
}

$installedTargets = (& $rustupExe target list --installed) 2>$null
if ($installedTargets -notcontains "x86_64-pc-windows-msvc") {
    Write-Host "Adding Rust target x86_64-pc-windows-msvc ..."
    Invoke-External $rustupExe @("target", "add", "x86_64-pc-windows-msvc")
}

function Get-VcpkgListText([string]$VcpkgExePath) {
    $lines = (& $VcpkgExePath list --classic) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $lines) {
        $lines = (& $VcpkgExePath list) 2>$null
    }
    if (-not $lines) {
        return ""
    }
    return ($lines | Out-String)
}

function Parse-VcpkgPackageSpec([string]$PackageSpec) {
    $parts = $PackageSpec.Split(":", 2)
    if ($parts.Count -ne 2) {
        return $null
    }
    $namePart = $parts[0].Trim()
    $triplet = $parts[1].Trim()
    if ([string]::IsNullOrWhiteSpace($namePart) -or [string]::IsNullOrWhiteSpace($triplet)) {
        return $null
    }
    $name = $namePart
    $features = @()
    if ($namePart -match "^(?<name>[^\[]+)\[(?<features>[^\]]+)\]$") {
        $name = $Matches["name"].Trim()
        $features = $Matches["features"].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    return @{
        Name = $name
        Triplet = $triplet
        Features = $features
    }
}

function Test-VcpkgPackageInstalled([string]$PackageSpec, [string]$VcpkgRootPath, [string]$VcpkgListText) {
    $spec = Parse-VcpkgPackageSpec $PackageSpec
    if ($null -eq $spec) {
        return $false
    }

    $name = $spec.Name
    $triplet = $spec.Triplet
    $requiredFeatures = @($spec.Features)

    # Fast path for packages without feature requirements.
    $shareCopyright = Join-Path $VcpkgRootPath ("installed\" + $triplet + "\share\" + $name + "\copyright")
    if ((Test-Path $shareCopyright) -and $requiredFeatures.Count -eq 0) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($VcpkgListText)) {
        return (Test-Path $shareCopyright) -and $requiredFeatures.Count -eq 0
    }

    $pattern = "(?m)^" + [Regex]::Escape($name) + "(?:\[(?<features>[^\]]+)\])?:" + [Regex]::Escape($triplet) + "\s"
    $match = [Regex]::Match($VcpkgListText, $pattern)
    if (-not $match.Success) {
        return $false
    }
    if ($requiredFeatures.Count -eq 0) {
        return $true
    }

    $installedFeaturesText = $match.Groups["features"].Value
    if ([string]::IsNullOrWhiteSpace($installedFeaturesText)) {
        return $false
    }
    $installedFeatures = $installedFeaturesText.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    foreach ($feature in $requiredFeatures) {
        if ($installedFeatures -notcontains $feature) {
            return $false
        }
    }
    return $true
}

$requiredVcpkg = @(
    "ffmpeg[amf,nvcodec,qsv]:x64-windows-static",
    "mfx-dispatch:x64-windows-static",
    "libvpx:x64-windows-static",
    "libyuv:x64-windows-static",
    "opus:x64-windows-static",
    "aom:x64-windows-static"
)

$vcpkgListText = Get-VcpkgListText $vcpkgExe
$missingVcpkg = @()
foreach ($pkg in $requiredVcpkg) {
    if (-not (Test-VcpkgPackageInstalled $pkg $env:VCPKG_ROOT $vcpkgListText)) {
        $missingVcpkg += $pkg
    }
}

if ($missingVcpkg.Count -gt 0) {
    if ($InstallMissingVcpkgDeps) {
        Write-Host "Installing missing vcpkg deps: $($missingVcpkg -join ', ')"
        Invoke-VcpkgInstall -VcpkgExePath $vcpkgExe -Packages $missingVcpkg -VcpkgRootPath $env:VCPKG_ROOT -EnableDebug $VcpkgDebug
    } elseif ($AutoSetup) {
        Invoke-AutoSetupIfNeeded ("missing vcpkg deps: " + ($missingVcpkg -join ", "))
        $vcpkgListText = Get-VcpkgListText $vcpkgExe
        $missingVcpkg = @()
        foreach ($pkg in $requiredVcpkg) {
            if (-not (Test-VcpkgPackageInstalled $pkg $env:VCPKG_ROOT $vcpkgListText)) {
                $missingVcpkg += $pkg
            }
        }
        if ($missingVcpkg.Count -gt 0) {
            Fail "Missing vcpkg deps after auto setup: $($missingVcpkg -join ', ')"
        }
    } else {
        Fail "Missing vcpkg deps: $($missingVcpkg -join ', '). Run: `"$vcpkgExe`" install --classic $($missingVcpkg -join ' ')"
    }
}

$clExe = Resolve-Tool "cl"
if (-not $clExe) {
    if (Try-LoadVisualCppEnvironment) {
        # vcvars can overwrite VCPKG_ROOT (often to VS-internal vcpkg path). Restore project-selected vcpkg.
        if ($env:VCPKG_ROOT -ne $vcpkgRootResolved) {
            Write-Host "Restoring VCPKG_ROOT to: $vcpkgRootResolved"
            $env:VCPKG_ROOT = $vcpkgRootResolved
        }
        $clExe = Resolve-Tool "cl"
    }
}
if (-not $clExe) {
    if ($AutoSetup -and $InstallVisualCpp) {
        Invoke-AutoSetupIfNeeded "cl.exe missing"
        $clExe = Resolve-Tool "cl"
    }
}
if (-not $clExe) {
    Write-Warning "cl.exe not found in PATH. Build can fail without Visual Studio C++ tools. Use 'Developer PowerShell for VS 2022'."
}

$libclangDir = Resolve-LibclangDirectory
if (-not $NoHwcodec) {
    if (-not $libclangDir -and $AutoSetup -and $AutoSetupAllTools) {
        Invoke-AutoSetupIfNeeded "libclang missing"
        $libclangDir = Resolve-LibclangDirectory
    }
    if (-not $libclangDir) {
        if ($AutoSetup -and -not $AutoSetupAllTools) {
            Fail "libclang is missing (required by hwcodec/bindgen). Install LLVM and set LIBCLANG_PATH, or run with -AutoSetupAllTools."
        }
        Fail "libclang is missing (required by hwcodec/bindgen). Install LLVM (winget id: LLVM.LLVM) and set LIBCLANG_PATH to the folder containing libclang.dll."
    }
    $env:LIBCLANG_PATH = $libclangDir
    Write-Host "Using LIBCLANG_PATH: $libclangDir"
}

Write-Host "Enabling Flutter Windows desktop ..."
Invoke-External $flutterExe @("config", "--enable-windows-desktop")

if (-not $SkipFlutterDoctor) {
    Write-Host "Running flutter doctor ..."
    Invoke-External $flutterExe @("doctor", "-v")
}

$flutterProjectDir = Join-Path $repoRoot "flutter"
if (-not (Test-SymlinkSupport $flutterProjectDir)) {
    Fail "Flutter plugin builds on Windows require symlink support. Enable Developer Mode (run: start ms-settings:developers) or run this shell as Administrator, then retry."
}
Prepare-FlutterProject -FlutterProjectDir $flutterProjectDir -FlutterExePath $flutterExe

$buildArgs = @("build.py", "--flutter")
if (-not $NoHwcodec) {
    $buildArgs += "--hwcodec"
}
if ($SkipPortablePack) {
    $buildArgs += "--skip-portable-pack"
}

Write-Host "Running: python $($buildArgs -join ' ')"
Invoke-External $pythonExe $buildArgs

$mainExe = Join-Path $repoRoot "flutter\build\windows\x64\runner\Release\mizemoon.exe"
if (Test-Path $mainExe) {
    Write-Host "Main exe: $mainExe"
} else {
    Write-Warning "Main exe not found at expected path: $mainExe"
}

if (-not $SkipPortablePack) {
    $installer = Get-ChildItem -Path $repoRoot -Filter "mizemoon-*-install.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($installer) {
        Write-Host "Installer: $($installer.FullName)"
    } else {
        Write-Warning "Installer was not found in repo root."
    }
}
