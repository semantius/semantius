# Install script for the pg_semantius CLI (Windows)
# Usage: irm https://raw.githubusercontent.com/semantius/semantius/main/install.ps1 | iex
#
# To install a specific release, download the script and pass -Version:
#   irm https://raw.githubusercontent.com/semantius/semantius/main/install.ps1 -OutFile install.ps1
#   ./install.ps1 -Version 0.5.0

param(
    # Shared with semantius.exe from the semantius-cli repo on purpose: users
    # who already have that installed keep one PATH entry instead of two.
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Semantius",
    [string]$Version = ""
)

$ErrorActionPreference = 'Stop'

# Colors via Write-Host
function Write-Green  { param($msg) Write-Host $msg -ForegroundColor Green }
function Write-Yellow { param($msg) Write-Host $msg -ForegroundColor Yellow }
function Write-Blue   { param($msg) Write-Host $msg -ForegroundColor Cyan }
function Write-Red    { param($msg) Write-Host $msg -ForegroundColor Red }

# Detect architecture
$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
switch ($arch) {
    'X64'   { $binary = 'pg_semantius-windows-x64.exe' }
    'Arm64' { $binary = 'pg_semantius-windows-arm64.exe' }
    default {
        Write-Red "Unsupported architecture: $arch"
        exit 1
    }
}

$githubRepo = 'semantius/semantius'

# A named version comes from its own tag; without one, from the moving `latest`
# pointer. A draft release never moves `latest`, which is what keeps the
# previous release installable while a new one is still uploading.
if ($Version) {
    $releasePath = "releases/download/v$($Version.TrimStart('v'))"
} else {
    $releasePath = 'releases/latest/download'
}

$downloadUrl = "https://github.com/$githubRepo/$releasePath/$binary"
$checksumUrl = "https://github.com/$githubRepo/$releasePath/checksums.txt"
$destExe     = Join-Path $InstallDir 'pg_semantius.exe'

# Print banner
Write-Host ""
Write-Host "Installing pg_semantius" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host ""
Write-Host "  Platform  : Windows/$arch"
Write-Host "  Binary    : $binary"
Write-Host "  Location  : $destExe"
Write-Host ""

# Check for existing installation
if (Get-Command 'pg_semantius' -ErrorAction SilentlyContinue) {
    $existingVersion = & pg_semantius --version 2>$null
    Write-Yellow "Note: Updating existing installation ($existingVersion)"
    Write-Host ""
}

# Create install directory if needed
if (-not (Test-Path $InstallDir)) {
    Write-Blue "Creating $InstallDir..."
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# Download binary
Write-Blue "Downloading $binary..."
$tmpFile = [System.IO.Path]::GetTempFileName()
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpFile -UseBasicParsing
} catch {
    Write-Red "Failed to download binary. Check if releases exist at:"
    Write-Host "  https://github.com/$githubRepo/releases"
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    exit 1
}

# Verify checksum (if available)
$tmpChecksum = [System.IO.Path]::GetTempFileName()
try {
    Invoke-WebRequest -Uri $checksumUrl -OutFile $tmpChecksum -UseBasicParsing -ErrorAction SilentlyContinue
    $checksumContent = Get-Content $tmpChecksum -ErrorAction SilentlyContinue
    if ($checksumContent) {
        # Matched on the whole field, not with -match: the name is compared
        # against column two so a longer asset name that merely contains this
        # one can never supply the hash.
        $expectedHash = $null
        foreach ($line in $checksumContent) {
            $fields = $line -split '\s+' | Where-Object { $_ }
            if ($fields.Count -ge 2 -and $fields[1].TrimStart('*') -eq $binary) {
                $expectedHash = $fields[0].ToUpper()
                break
            }
        }
        if ($expectedHash) {
            Write-Blue "Verifying checksum..."
            $actualHash = (Get-FileHash $tmpFile -Algorithm SHA256).Hash.ToUpper()
            if ($expectedHash -ne $actualHash) {
                Write-Red "Checksum verification failed!"
                Write-Host "Expected: $expectedHash"
                Write-Host "Actual  : $actualHash"
                Remove-Item $tmpFile -ErrorAction SilentlyContinue
                Remove-Item $tmpChecksum -ErrorAction SilentlyContinue
                exit 1
            }
            Write-Green "Checksum verified"
        }
    }
} catch {
    Write-Yellow "Warning: Could not verify checksum"
} finally {
    Remove-Item $tmpChecksum -ErrorAction SilentlyContinue
}

# Install
Write-Blue "Installing..."
Move-Item -Path $tmpFile -Destination $destExe -Force

Write-Host ""
Write-Green "pg_semantius installed successfully!"
Write-Host ""

# Add to PATH for current user if not already present
$userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath -notlike "*$InstallDir*") {
    Write-Yellow "Adding $InstallDir to your PATH..."
    [System.Environment]::SetEnvironmentVariable(
        'PATH',
        "$userPath;$InstallDir",
        'User'
    )
    Write-Green "PATH updated. Restart your terminal (or open a new one) to use pg_semantius."
} else {
    # Already in PATH - show installed version
    if (Test-Path $destExe) {
        & $destExe --version
    }
}

Write-Host ""
Write-Host "Get started:"
Write-Host "  pg_semantius --help"
Write-Host "  pg_semantius migrate --apps _core --database-url postgresql://user:pass@host:5432/db"
Write-Host ""
