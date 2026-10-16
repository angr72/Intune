<#
    EdgeFix - Detection
    Intune Remediations: run with "Run this script using the logged-on credentials" = Yes

    Exit 0 = HKCU\Software\ME\EdgeFix is 1, the fix is already applied
    Exit 1 = the fix is not applied, run the remediation script
#>

$RegPath   = 'HKCU:\Software\ME'
$ValueName = 'EdgeFix'

try {
    $value = Get-ItemPropertyValue -Path $RegPath -Name $ValueName -ErrorAction Stop
}
catch {
    $value = $null
}

if ($value -eq 1) {
    Write-Output "EdgeFix already applied ($RegPath\$ValueName = 1)"
    exit 0
}

Write-Output "EdgeFix not applied ($RegPath\$ValueName = '$value')"
exit 1
