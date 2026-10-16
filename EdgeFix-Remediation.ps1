<#
    EdgeFix - Remediation
    Intune Remediations: run with "Run this script using the logged-on credentials" = Yes

    1. Closes Microsoft Edge in the logged-on user's session
    2. Deletes %LOCALAPPDATA%\Microsoft\Edge\User Data, Edge creates a new one on next start
    3. Sets HKCU\Software\ME\EdgeFix = 1 (DWORD)

    The registry value is only written once the folder is gone, so a failed delete
    is retried on the next run.
#>

$UserData  = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
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

        # Edge can take a moment to release its file handles
        for ($attempt = 1; $attempt -le 10 -and (Test-Path -LiteralPath $UserData); $attempt++) {
            try {
                Remove-Item -LiteralPath $UserData -Recurse -Force -ErrorAction Stop
            }
            catch {
                $lastError = $_.Exception.Message
                Start-Sleep -Seconds 3
                Stop-Edge
            }
        }

        if (Test-Path -LiteralPath $UserData) {
            throw "Could not delete '$UserData': $lastError"
        }

        Write-Output "Deleted '$UserData'"
    }
    else {
        Write-Output "'$UserData' not found, nothing to delete"
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
