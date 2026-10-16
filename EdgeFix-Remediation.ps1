<#
    EdgeFix - Remediation
    Intune Remediations: run with "Run this script using the logged-on credentials" = Yes

    1. Closes Microsoft Edge in the logged-on user's session
    2. Renames %LOCALAPPDATA%\Microsoft\Edge\User Data to "User Data OLD"
       (an existing "User Data OLD" is kept and renamed with a timestamp)
    3. Sets HKCU\Software\ME\EdgeFix = 1 (DWORD)

    The registry value is only written once the folder has been renamed (or does not exist),
    so a failed rename is retried on the next run.
#>

$EdgePath  = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge'
$UserData  = Join-Path $EdgePath 'User Data'
$NewName   = 'User Data OLD'
$OldPath   = Join-Path $EdgePath $NewName
$RegPath   = 'HKCU:\Software\ME'
$ValueName = 'EdgeFix'

# As SYSTEM, $env:LOCALAPPDATA and HKCU point to the system profile, not the user
if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
    Write-Output "Running as SYSTEM. Set 'Run this script using the logged-on credentials' to Yes."
    exit 1
}

function Stop-Edge {
    # Only this session's Edge, other users on the same device are left alone
    $sessionId = (Get-Process -Id $PID).SessionId
    $edge = Get-Process -Name msedge -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId }

    if ($edge) {
        $edge | Stop-Process -Force -ErrorAction SilentlyContinue
        $edge | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
    }
}

try {
    if (Test-Path -LiteralPath $UserData) {
        Stop-Edge

        if (Test-Path -LiteralPath $OldPath) {
            $backupName = "$NewName $(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Rename-Item -LiteralPath $OldPath -NewName $backupName -ErrorAction Stop
            Write-Output "Existing '$NewName' renamed to '$backupName'"
        }

        # Edge can take a moment to release its file handles
        $renamed = $false
        for ($attempt = 1; $attempt -le 10 -and -not $renamed; $attempt++) {
            try {
                Rename-Item -LiteralPath $UserData -NewName $NewName -ErrorAction Stop
                $renamed = $true
            }
            catch {
                $lastError = $_.Exception.Message
                Start-Sleep -Seconds 3
                Stop-Edge
            }
        }

        if (-not $renamed) {
            throw "Could not rename '$UserData': $lastError"
        }

        Write-Output "Renamed '$UserData' to '$NewName'"
    }
    else {
        Write-Output "'$UserData' not found, nothing to rename"
    }

    if (-not (Test-Path -Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    New-ItemProperty -Path $RegPath -Name $ValueName -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Output "Set $RegPath\$ValueName = 1"

    exit 0
}
catch {
    Write-Output "EdgeFix failed: $($_.Exception.Message)"
    exit 1
}
