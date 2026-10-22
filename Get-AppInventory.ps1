<#
.SYNOPSIS
    Exports the Intune app inventory (Discovered apps) for all devices and optionally
    finds which devices and users have a specific app version.

.DESCRIPTION
    Runs the Intune "AppInvRawData" report export through Microsoft Graph. This is the same
    data as Apps > Monitor > Discovered apps > Export: one row per app per device, including
    the device name and user, so a single export covers every device in the tenant.

    The full inventory is always saved to CSV. When -AppName is given, the script also:
      - prints every version of that app found and how many devices have each one
      - lists the devices that have the requested -Version (or any version if omitted),
        enriched with UPN, serial number and last check-in from the managed device record
      - saves those matches to a second CSV

    Requirements:
      - Microsoft.Graph.Authentication module (Install-Module Microsoft.Graph.Authentication)
      - Graph permission DeviceManagementManagedDevices.ReadWrite.All. Graph lists a ReadWrite
        permission as the minimum for creating a report export job; the script changes nothing.
      - An Intune role that can read devices and apps, such as Read Only Operator

.PARAMETER AppName
    App display name to search for. Matched with -like and wrapped in * unless it already
    contains wildcards, so 'SidekickPC' also matches 'SidekickPC (x64)'.

.PARAMETER Version
    Version to search for. Trailing ".0" parts are ignored, so 3.17.3 matches 3.17.3.0.
    Compared against both ApplicationVersion and ApplicationShortVersion.

.PARAMETER OutputFolder
    Folder for the CSV files. Defaults to the current folder.

.PARAMETER TenantId
    Tenant to sign in to. Optional.

.EXAMPLE
    .\Get-AppInventory.ps1
    Exports the full app inventory for all devices to CSV.

.EXAMPLE
    .\Get-AppInventory.ps1 -AppName 'SidekickPC' -Version '3.17.3'
    Exports the inventory and lists the devices and users that have SidekickPC 3.17.3.

.EXAMPLE
    .\Get-AppInventory.ps1 -AppName 'SidekickPC'
    Lists every SidekickPC version in the tenant and every device that has it.
#>
[CmdletBinding()]
param(
    [string]$AppName,
    [string]$Version,
    [string]$OutputFolder = (Get-Location).Path,
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest downloads very slowly in Windows PowerShell 5.1 when the progress bar is shown
$ProgressPreference = 'SilentlyContinue'

$graphUri = 'https://graph.microsoft.com/v1.0/deviceManagement'

function ConvertTo-NormalizedVersion {
    param([string]$Value)

    # Strip trailing .0 parts so 3.17.3, 3.17.3.0 and 3.17.3.00 compare equal
    $normalized = "$Value".Trim()
    while ($normalized -match '^(.+)\.0+$') {
        $normalized = $Matches[1]
    }
    return $normalized
}

if ($Version -and -not $AppName) {
    throw 'Use -Version together with -AppName.'
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication module not found. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}

if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$connectParams = @{
    Scopes    = 'DeviceManagementManagedDevices.ReadWrite.All'
    NoWelcome = $true
}
if ($TenantId) {
    $connectParams.TenantId = $TenantId
}
Connect-MgGraph @connectParams

# 1. Request the Discovered apps raw data export for all devices
$exportBody = @{
    reportName       = 'AppInvRawData'
    format           = 'csv'
    localizationType = 'ReplaceLocalizableValues'
    select           = @(
        'ApplicationName'
        'ApplicationPublisher'
        'ApplicationVersion'
        'ApplicationShortVersion'
        'Platform'
        'DeviceId'
        'DeviceName'
        'OSDescription'
        'OSVersion'
        'UserId'
        'UserName'
        'EmailAddress'
    )
} | ConvertTo-Json

Write-Host 'Requesting Discovered apps export (AppInvRawData)...'
$job = Invoke-MgGraphRequest -Method POST -Uri "$graphUri/reports/exportJobs" -Body $exportBody -ContentType 'application/json'

# 2. Poll until the export is ready
$deadline = (Get-Date).AddMinutes(15)
while ($job.status -ne 'completed') {
    if ($job.status -eq 'failed') {
        throw "Export job $($job.id) failed."
    }
    if ((Get-Date) -gt $deadline) {
        throw "Export job $($job.id) did not complete within 15 minutes. Last status: $($job.status)"
    }
    Start-Sleep -Seconds 5
    $job = Invoke-MgGraphRequest -Method GET -Uri "$graphUri/reports/exportJobs/$($job.id)"
    Write-Host "  Export status: $($job.status)"
}

# 3. Download and unpack the CSV. The URL is a pre-signed storage link, so no Graph token is needed
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tempFolder = Join-Path ([System.IO.Path]::GetTempPath()) "AppInvRawData-$timestamp"
New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null

try {
    $zipPath = Join-Path $tempFolder 'AppInvRawData.zip'
    Invoke-WebRequest -Uri $job.url -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $tempFolder -Force

    $csvFile = Get-ChildItem -Path $tempFolder -Filter '*.csv' | Select-Object -First 1
    if (-not $csvFile) {
        throw "The export archive did not contain a CSV file."
    }

    $inventoryPath = Join-Path $OutputFolder "AppInventory-AllDevices-$timestamp.csv"
    Copy-Item -Path $csvFile.FullName -Destination $inventoryPath
    $inventory = @(Import-Csv -Path $inventoryPath -Encoding UTF8)
}
finally {
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
}

$deviceCount = @($inventory.DeviceId | Sort-Object -Unique).Count
Write-Host "Inventory: $($inventory.Count) app rows across $deviceCount devices"
Write-Host "Saved to $inventoryPath"

if (-not $AppName) {
    return
}

# 4. Find the app and summarise the versions in use
$namePattern = if ($AppName -match '[\*\?\[]') { $AppName } else { "*$AppName*" }
$appRows = @($inventory | Where-Object { $_.ApplicationName -like $namePattern })

if ($appRows.Count -eq 0) {
    Write-Warning "No discovered app name matches '$namePattern'."
    return
}

Write-Host ''
Write-Host "Versions found for '$namePattern':"
$appRows |
    Group-Object -Property ApplicationName, ApplicationVersion |
    ForEach-Object {
        [pscustomobject]@{
            ApplicationName    = $_.Group[0].ApplicationName
            ApplicationVersion = $_.Group[0].ApplicationVersion
            Devices            = @($_.Group.DeviceId | Sort-Object -Unique).Count
        }
    } |
    Sort-Object -Property ApplicationName, ApplicationVersion |
    Format-Table -AutoSize |
    Out-String -Width 250 |
    Write-Host

$hits = $appRows
if ($Version) {
    $wantedVersion = ConvertTo-NormalizedVersion $Version
    $hits = @($appRows | Where-Object {
        (ConvertTo-NormalizedVersion $_.ApplicationVersion) -eq $wantedVersion -or
        (ConvertTo-NormalizedVersion $_.ApplicationShortVersion) -eq $wantedVersion
    })
}

$label = if ($Version) { "$AppName $Version" } else { $AppName }
if ($hits.Count -eq 0) {
    Write-Warning "No devices have $label. See the version list above for what is installed."
    return
}

# 5. Add UPN, serial number and last check-in from the managed device record
$deviceCache = @{}
$results = foreach ($row in $hits) {
    if (-not $deviceCache.ContainsKey($row.DeviceId)) {
        $deviceCache[$row.DeviceId] = $null
        try {
            $deviceCache[$row.DeviceId] = Invoke-MgGraphRequest -Method GET -Uri "$graphUri/managedDevices/$($row.DeviceId)?`$select=userPrincipalName,serialNumber,lastSyncDateTime"
        }
        catch {
            Write-Warning "Could not read managed device $($row.DeviceName) ($($row.DeviceId)): $($_.Exception.Message)"
        }
    }
    $device = $deviceCache[$row.DeviceId]

    [pscustomobject]@{
        DeviceName         = $row.DeviceName
        UserName           = $row.UserName
        UserPrincipalName  = $device.userPrincipalName
        EmailAddress       = $row.EmailAddress
        ApplicationName    = $row.ApplicationName
        ApplicationVersion = $row.ApplicationVersion
        Platform           = $row.Platform
        OSVersion          = $row.OSVersion
        SerialNumber       = $device.serialNumber
        LastSync           = $device.lastSyncDateTime
        DeviceId           = $row.DeviceId
    }
}
# Devices with a user first, devices without one (shared/kiosk) last
$results = @($results | Sort-Object -Property @{ Expression = { -not $_.UserName } }, UserName, DeviceName)

$userCount = @($results.UserName | Where-Object { $_ } | Sort-Object -Unique).Count
Write-Host "$($results.Count) device(s) have $label ($userCount user(s)):"
$results |
    Format-Table -Property DeviceName, UserName, UserPrincipalName, ApplicationVersion, Platform, LastSync -AutoSize |
    Out-String -Width 250 |
    Write-Host

$safeLabel = $label -replace '[^\w\.-]', '_'
$matchesPath = Join-Path $OutputFolder "AppSearch-$safeLabel-$timestamp.csv"
# Write a BOM so Excel shows non-ASCII names correctly (PowerShell 7's UTF8 has no BOM)
$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
$results | Export-Csv -Path $matchesPath -NoTypeInformation -Encoding $csvEncoding
Write-Host "Saved to $matchesPath"
