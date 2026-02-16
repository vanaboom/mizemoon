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
    [switch]$InstallVisualCpp
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

function Invoke-External([string]$Exe, [string[]]$CmdArgs) {
    & $Exe @CmdArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "Command failed ($LASTEXITCODE): $Exe $($CmdArgs -join ' ')"
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

    $setupArgs = @()
    if ($VcpkgRoot) {
        $setupArgs += @("-VcpkgRoot", $VcpkgRoot)
    }
    if ($ToolsRoot) {
        $setupArgs += @("-ToolsRoot", $ToolsRoot)
    }
    $setupArgs += "-InstallVcpkgDeps"
    if ($InstallVisualCpp) {
        $setupArgs += "-InstallVisualCpp"
    }
    if ($SkipFlutterDoctor) {
        $setupArgs += "-SkipFlutterDoctor"
    }

    Write-Host "Auto setup triggered: $Reason"
    Write-Host "Running setup script: $setupScript $($setupArgs -join ' ')"
    & $setupScript @setupArgs
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
    Invoke-AutoSetupIfNeeded ("missing tools: " + ($missingToolNames -join ", "))
    $tools = Refresh-Tools
    $missingToolNames = @()
    if (-not $tools.cargo) { $missingToolNames += "cargo" }
    if (-not $tools.rustup) { $missingToolNames += "rustup" }
    if (-not $tools.flutter) { $missingToolNames += "flutter" }
}

if ($missingToolNames.Count -gt 0) {
    Fail "Missing tools in PATH: $($missingToolNames -join ', '). Run setup-windows-tools.ps1 or use -AutoSetup."
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

$toolchain = (& $rustupExe show active-toolchain) 2>$null
if (-not $AllowNonMSVCToolchain -and ($toolchain -notmatch "x86_64-pc-windows-msvc")) {
    Fail "Active rust toolchain is '$toolchain'. Run: rustup default stable-x86_64-pc-windows-msvc"
}

$installedTargets = (& $rustupExe target list --installed) 2>$null
if ($installedTargets -notcontains "x86_64-pc-windows-msvc") {
    Write-Host "Adding Rust target x86_64-pc-windows-msvc ..."
    Invoke-External $rustupExe @("target", "add", "x86_64-pc-windows-msvc")
}

$requiredVcpkg = @(
    "libvpx:x64-windows-static",
    "libyuv:x64-windows-static",
    "opus:x64-windows-static",
    "aom:x64-windows-static"
)

$vcpkgList = (& $vcpkgExe list) 2>$null
$missingVcpkg = @()
foreach ($pkg in $requiredVcpkg) {
    $pattern = "^" + [Regex]::Escape($pkg) + "\s"
    if (-not ($vcpkgList -match $pattern)) {
        $missingVcpkg += $pkg
    }
}

if ($missingVcpkg.Count -gt 0) {
    if ($InstallMissingVcpkgDeps) {
        Write-Host "Installing missing vcpkg deps: $($missingVcpkg -join ', ')"
        Invoke-External $vcpkgExe (@("install") + $missingVcpkg)
    } elseif ($AutoSetup) {
        Invoke-AutoSetupIfNeeded ("missing vcpkg deps: " + ($missingVcpkg -join ", "))
        $vcpkgList = (& $vcpkgExe list) 2>$null
        $missingVcpkg = @()
        foreach ($pkg in $requiredVcpkg) {
            $pattern = "^" + [Regex]::Escape($pkg) + "\s"
            if (-not ($vcpkgList -match $pattern)) {
                $missingVcpkg += $pkg
            }
        }
        if ($missingVcpkg.Count -gt 0) {
            Fail "Missing vcpkg deps after auto setup: $($missingVcpkg -join ', ')"
        }
    } else {
        Fail "Missing vcpkg deps: $($missingVcpkg -join ', '). Run: `"$vcpkgExe`" install $($missingVcpkg -join ' ')"
    }
}

$clExe = Resolve-Tool "cl"
if (-not $clExe) {
    if (Try-LoadVisualCppEnvironment) {
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

Write-Host "Enabling Flutter Windows desktop ..."
Invoke-External $flutterExe @("config", "--enable-windows-desktop")

if (-not $SkipFlutterDoctor) {
    Write-Host "Running flutter doctor ..."
    Invoke-External $flutterExe @("doctor", "-v")
}

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
