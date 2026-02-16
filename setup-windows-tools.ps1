[CmdletBinding()]
param(
    [string]$ToolsRoot = "",
    [string]$VcpkgRoot = "",
    [string]$FlutterRoot = "",
    [switch]$InstallVcpkgDeps,
    [switch]$InstallVisualCpp,
    [switch]$SkipFlutterDoctor,
    [switch]$PersistUserPath
)

$ErrorActionPreference = "Stop"
$customToolsRoot = $PSBoundParameters.ContainsKey("ToolsRoot") -and (-not [string]::IsNullOrWhiteSpace($ToolsRoot))
$customFlutterRoot = $PSBoundParameters.ContainsKey("FlutterRoot") -and (-not [string]::IsNullOrWhiteSpace($FlutterRoot))
$customVcpkgRoot = $PSBoundParameters.ContainsKey("VcpkgRoot") -and (-not [string]::IsNullOrWhiteSpace($VcpkgRoot))

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

function Invoke-External([string]$Exe, [string[]]$CmdArgs) {
    & $Exe @CmdArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "Command failed ($LASTEXITCODE): $Exe $($CmdArgs -join ' ')"
    }
}

function Try-Invoke-External([string]$Exe, [string[]]$CmdArgs) {
    & $Exe @CmdArgs
    return ($LASTEXITCODE -eq 0)
}

function Add-PathSession([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) {
        return
    }
    if (-not (Test-Path $Dir)) {
        return
    }
    $parts = $env:PATH -split ";"
    if ($parts -notcontains $Dir) {
        $env:PATH = "$Dir;$env:PATH"
    }
}

function Add-PathUser([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) {
        return
    }
    if (-not (Test-Path $Dir)) {
        return
    }
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) {
        $parts = $userPath -split ";"
    }
    if ($parts -notcontains $Dir) {
        $newPath = if ($userPath) { "$userPath;$Dir" } else { $Dir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "Updated user PATH with: $Dir"
    }
}

function Get-WingetIfAny {
    return Resolve-Tool "winget"
}

function Normalize-DirectoryPath([string]$InputPath, [string]$FallbackPath) {
    $raw = if ($null -eq $InputPath) { "" } else { $InputPath.Trim() }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = $FallbackPath
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ""
    }
    try {
        return [System.IO.Path]::GetFullPath($raw)
    } catch {
        return $raw
    }
}

function Ensure-Directory([string]$PathValue, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        Fail "$Label path is empty."
    }
    try {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
    } catch {
        Fail "Cannot create $Label directory '$PathValue': $($_.Exception.Message)"
    }
}

function Try-EnsureDirectory([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }
    try {
        New-Item -ItemType Directory -Path $PathValue -Force | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Ensure-Git([string]$WingetExe) {
    $git = Resolve-Tool "git"
    if ($git) {
        return $git
    }
    $commonGitCmd = "C:\Program Files\Git\cmd"
    if (Test-Path (Join-Path $commonGitCmd "git.exe")) {
        Add-PathSession $commonGitCmd
        if ($PersistUserPath) {
            Add-PathUser $commonGitCmd
        }
        $git = Resolve-Tool "git"
        if ($git) {
            return $git
        }
    }
    if (-not $WingetExe) {
        Fail "Git was not found in PATH and winget is unavailable. Install Git manually, then rerun."
    }
    Write-Host "Installing Git via winget ..."
    Invoke-External $WingetExe @(
        "install",
        "--id", "Git.Git",
        "-e",
        "--source", "winget",
        "--accept-source-agreements",
        "--accept-package-agreements"
    )
    if (Test-Path (Join-Path $commonGitCmd "git.exe")) {
        Add-PathSession $commonGitCmd
        if ($PersistUserPath) {
            Add-PathUser $commonGitCmd
        }
    }
    $git = Resolve-Tool "git"
    if (-not $git) {
        Fail "Git installation completed, but git is still not in PATH. Open a new shell and rerun."
    }
    return $git
}

if ($env:OS -ne "Windows_NT") {
    Fail "This script must run on Windows."
}

$defaultToolsRoot = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    Join-Path $env:USERPROFILE "dev\mizemoon-tools"
} else {
    Join-Path $PSScriptRoot ".windows-tools"
}

$ToolsRoot = Normalize-DirectoryPath $ToolsRoot $defaultToolsRoot
$FlutterRoot = Normalize-DirectoryPath $FlutterRoot (Join-Path $ToolsRoot "flutter")
$VcpkgRoot = Normalize-DirectoryPath $VcpkgRoot (Join-Path $ToolsRoot "vcpkg")

if (-not (Try-EnsureDirectory $ToolsRoot)) {
    $fallbackToolsRoot = Normalize-DirectoryPath (Join-Path $PSScriptRoot ".windows-tools") ""
    Write-Warning "Cannot create ToolsRoot '$ToolsRoot'. Falling back to '$fallbackToolsRoot'."
    $ToolsRoot = $fallbackToolsRoot
    if (-not $customFlutterRoot) {
        $FlutterRoot = Normalize-DirectoryPath "" (Join-Path $ToolsRoot "flutter")
    }
    if (-not $customVcpkgRoot) {
        $VcpkgRoot = Normalize-DirectoryPath "" (Join-Path $ToolsRoot "vcpkg")
    }
}
Ensure-Directory $ToolsRoot "ToolsRoot"
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    Add-PathSession (Join-Path $env:USERPROFILE ".cargo\bin")
}

$wingetExe = Get-WingetIfAny
if (-not $wingetExe) {
    Write-Warning "winget not found. Script will use fallback methods where possible."
}
$gitExe = Ensure-Git $wingetExe

Write-Host "Checking Rust toolchain ..."
$rustupExe = Resolve-Tool "rustup"
$cargoExe = Resolve-Tool "cargo"
if (-not $rustupExe -or -not $cargoExe) {
    $rustInstalled = $false
    if ($wingetExe) {
        Write-Host "Installing Rustup via winget ..."
        $rustInstalled = Try-Invoke-External $wingetExe @(
            "install",
            "--id", "Rustlang.Rustup",
            "-e",
            "--source", "winget",
            "--accept-source-agreements",
            "--accept-package-agreements"
        )
        if (-not $rustInstalled) {
            Write-Warning "winget Rustup install failed. Falling back to official installer."
        }
    }
    if (-not $rustInstalled) {
        Write-Host "Installing Rustup via official installer ..."
        $tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $rustupInstaller = Join-Path $tempRoot "rustup-init.exe"
        Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupInstaller
        Invoke-External $rustupInstaller @("-y", "--default-toolchain", "stable-x86_64-pc-windows-msvc")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Add-PathSession (Join-Path $env:USERPROFILE ".cargo\bin")
        if ($PersistUserPath) {
            Add-PathUser (Join-Path $env:USERPROFILE ".cargo\bin")
        }
    }
    $rustupExe = Resolve-Tool "rustup"
    $cargoExe = Resolve-Tool "cargo"
}
if (-not $rustupExe -or -not $cargoExe) {
    Fail "Rust tools are still missing from PATH. Open a new shell and rerun."
}

Write-Host "Setting Rust MSVC toolchain ..."
$activeToolchain = (& $rustupExe show active-toolchain) 2>$null
if ($activeToolchain -notmatch "stable-x86_64-pc-windows-msvc") {
    Invoke-External $rustupExe @("default", "stable-x86_64-pc-windows-msvc")
} else {
    Write-Host "Rust default toolchain already stable-x86_64-pc-windows-msvc"
}
$installedTargets = (& $rustupExe target list --installed) 2>$null
if ($installedTargets -notcontains "x86_64-pc-windows-msvc") {
    Invoke-External $rustupExe @("target", "add", "x86_64-pc-windows-msvc")
} else {
    Write-Host "Rust target x86_64-pc-windows-msvc already installed"
}

Write-Host "Checking Flutter ..."
$flutterExe = Resolve-Tool "flutter"
if (-not $flutterExe) {
    $flutterBat = Join-Path $FlutterRoot "bin\flutter.bat"
    if (-not (Test-Path $flutterBat)) {
        if (Test-Path $FlutterRoot) {
            $hasContent = (Get-ChildItem -Path $FlutterRoot -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
            if ($hasContent) {
                Fail "FlutterRoot exists but is not a Flutter checkout: $FlutterRoot"
            }
        } else {
            $flutterParent = Split-Path -Parent $FlutterRoot
            if ([string]::IsNullOrWhiteSpace($flutterParent)) {
                $flutterParent = $ToolsRoot
            }
            Ensure-Directory $flutterParent "FlutterRoot parent"
        }
        Write-Host "Cloning Flutter stable into $FlutterRoot ..."
        Invoke-External $gitExe @("clone", "--depth", "1", "-b", "stable", "https://github.com/flutter/flutter.git", $FlutterRoot)
    }
    Add-PathSession (Join-Path $FlutterRoot "bin")
    if ($PersistUserPath) {
        Add-PathUser (Join-Path $FlutterRoot "bin")
    }
    $flutterExe = Resolve-Tool "flutter"
}
if (-not $flutterExe) {
    Fail "Flutter is still missing from PATH. Open a new shell and rerun."
}

Write-Host "Enabling Flutter Windows desktop ..."
Invoke-External $flutterExe @("config", "--enable-windows-desktop")
if (-not $SkipFlutterDoctor) {
    Write-Host "Running flutter doctor ..."
    Invoke-External $flutterExe @("doctor", "-v")
}

if ($InstallVisualCpp) {
    $clExe = Resolve-Tool "cl"
    if (-not $clExe) {
        if (-not $wingetExe) {
            Fail "InstallVisualCpp was requested, but winget is unavailable. Install Visual Studio Build Tools manually."
        }
        Write-Host "Installing Visual Studio 2022 Build Tools (C++) ..."
        Invoke-External $wingetExe @(
            "install",
            "--id", "Microsoft.VisualStudio.2022.BuildTools",
            "-e",
            "--source", "winget",
            "--accept-source-agreements",
            "--accept-package-agreements",
            "--override", "--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        )
        Write-Host "Visual C++ Build Tools installed. You may need a new shell for cl.exe in PATH."
    } else {
        Write-Host "Visual C++ tools already available: $clExe"
    }
}

$vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
if (-not (Test-Path $vcpkgExe)) {
    if (Test-Path $VcpkgRoot) {
        $hasContent = (Get-ChildItem -Path $VcpkgRoot -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
        if ($hasContent) {
            Fail "VcpkgRoot exists but vcpkg.exe was not found: $VcpkgRoot"
        }
    } else {
        $vcpkgParent = Split-Path -Parent $VcpkgRoot
        if ([string]::IsNullOrWhiteSpace($vcpkgParent)) {
            $vcpkgParent = $ToolsRoot
        }
        Ensure-Directory $vcpkgParent "VcpkgRoot parent"
    }
    Write-Host "Cloning vcpkg into $VcpkgRoot ..."
    Invoke-External $gitExe @("clone", "https://github.com/microsoft/vcpkg", $VcpkgRoot)
    Write-Host "Bootstrapping vcpkg ..."
    Invoke-External (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") @()
}

$env:VCPKG_ROOT = $VcpkgRoot
[Environment]::SetEnvironmentVariable("VCPKG_ROOT", $VcpkgRoot, "User")
Write-Host "Set VCPKG_ROOT=$VcpkgRoot (User + current session)"

if ($InstallVcpkgDeps) {
    Write-Host "Installing required vcpkg dependencies ..."
    Invoke-External $vcpkgExe @(
        "install",
        "libvpx:x64-windows-static",
        "libyuv:x64-windows-static",
        "opus:x64-windows-static",
        "aom:x64-windows-static"
    )
}

Write-Host ""
Write-Host "Setup completed."
Write-Host "ToolsRoot: $ToolsRoot"
Write-Host "FlutterRoot: $FlutterRoot"
Write-Host "VcpkgRoot: $VcpkgRoot"
Write-Host ""
Write-Host "Next step:"
Write-Host ".\build-windows.ps1 -AutoSetup -VcpkgRoot $VcpkgRoot -InstallMissingVcpkgDeps"
