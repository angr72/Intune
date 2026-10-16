<#
    EdgeFix - Detection
    Intune Remediations: run with "Run this script using the logged-on credentials" = Yes

    Exit 0 = nothing to do: EdgeFix is already 1, or Edge is not version 155.0.4283.60
    Exit 1 = Edge is 155.0.4283.60 and the fix is not applied, run the remediation script
#>

$TargetVersion = [version]'155.0.4283.60'
$RegPath       = 'HKCU:\Software\ME'
$ValueName     = 'EdgeFix'

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

# Edge Stable is installed per machine, normally under Program Files (x86)
$edgeExe = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $edgeExe) {
    Write-Output "Edge not found, EdgeFix not needed"
    exit 0
}

$info = (Get-Item -LiteralPath $edgeExe).VersionInfo
$edgeVersion = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)

if ($edgeVersion -ne $TargetVersion) {
    Write-Output "Edge is $edgeVersion, not $TargetVersion, EdgeFix not needed"
    exit 0
}

Write-Output "Edge is $edgeVersion and EdgeFix not applied ($RegPath\$ValueName = '$value')"
exit 1
