<#

.SYNOPSIS
PSAppDeployToolkit - Aktiverar Hyper-V-rollen på Windows 11 Pro/Enterprise/Education.

.DESCRIPTION
Bygger på PSAppDeployToolkit 4.1.8. Skriptet aktiverar (Install), avaktiverar
(Uninstall) eller reparerar (Repair) Windows-funktionen "Microsoft-Hyper-V-All"
inklusive hanteringsverktyg via DISM/Enable-WindowsOptionalFeature.

Hyper-V kräver omstart efter aktivering. Skriptet returnerar 3010 till Intune
så att Intune kan hantera omstartsupplevelsen.

.PARAMETER DeploymentType
Install / Uninstall / Repair.

.PARAMETER DeployMode
Interactive / NonInteractive / Silent.

.LINK
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType = 'Install',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode = 'Interactive',

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$AllowRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

$adtSession = @{
    AppVendor                   = 'Microsoft'
    AppName                     = 'Hyper-V'
    AppVersion                  = '1.0'
    AppArch                     = 'x64'
    AppLang                     = 'EN'
    AppRevision                 = '01'
    AppSuccessExitCodes         = @(0)
    AppRebootExitCodes          = @(1641, 3010)
    AppScriptVersion            = '1.0.0'
    AppScriptDate               = '2026-05-06'
    AppScriptAuthor             = 'Intune'
    InstallName                 = 'HyperV'
    InstallTitle                = 'Microsoft Hyper-V'
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptVersion      = '4.1.8'
    DeployAppScriptParameters   = $PSBoundParameters
}

function Install-ADTDeployment
{
    ##================================================
    ## MARK: Pre-Install
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    $edition = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
    if ($edition -match 'Home')
    {
        Write-ADTLogEntry -Message "Hyper-V stöds inte på Windows-utgåvan: $edition" -Severity 3
        Close-ADTSession -ExitCode 1641 -Force
    }

    $cpu = Get-CimInstance -ClassName Win32_Processor
    if (-not ($cpu.VirtualizationFirmwareEnabled -or $cpu.SecondLevelAddressTranslationExtensions))
    {
        Write-ADTLogEntry -Message 'Virtualisering är inte aktiverad i firmware/BIOS. Aktivera VT-x/AMD-V innan Hyper-V installeras.' -Severity 3
        Close-ADTSession -ExitCode 1
    }

    Show-ADTInstallationWelcome -CloseProcesses @(
        @{ Name = 'vmconnect'; Description = 'Hyper-V Virtual Machine Connection' }
        @{ Name = 'mmc';       Description = 'Microsoft Management Console' }
    ) -CloseProcessesCountdown 600 -PersistPrompt -DeferTimes 3

    Show-ADTInstallationProgress -StatusMessage 'Förbereder aktivering av Hyper-V...'

    ##================================================
    ## MARK: Install
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Show-ADTInstallationProgress -StatusMessage 'Aktiverar Microsoft-Hyper-V-All. Detta kan ta några minuter...'

    try
    {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -All -NoRestart -ErrorAction Stop
        Write-ADTLogEntry -Message "Hyper-V aktiverad. RestartNeeded=$($result.RestartNeeded)"
    }
    catch
    {
        Write-ADTLogEntry -Message "Aktivering av Hyper-V misslyckades: $($_.Exception.Message)" -Severity 3
        throw
    }

    ##================================================
    ## MARK: Post-Install
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    $state = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All'
    if ($state.State -notin @('Enabled', 'EnablePending'))
    {
        Write-ADTLogEntry -Message "Oväntat funktionsstatus efter aktivering: $($state.State)" -Severity 3
        Close-ADTSession -ExitCode 1
    }

    $adtSession.SetExitCode(3010)

    if ($DeployMode -eq 'Interactive')
    {
        Show-ADTInstallationRestartPrompt -CountdownSeconds 600 -CountdownNoHideSeconds 60
    }
}

function Uninstall-ADTDeployment
{
    ##================================================
    ## MARK: Pre-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    Show-ADTInstallationWelcome -CloseProcesses @(
        @{ Name = 'vmconnect'; Description = 'Hyper-V Virtual Machine Connection' }
        @{ Name = 'vmms';      Description = 'Hyper-V Virtual Machine Management Service' }
    ) -CloseProcessesCountdown 600 -PersistPrompt -DeferTimes 3

    Show-ADTInstallationProgress -StatusMessage 'Förbereder avaktivering av Hyper-V...'

    ##================================================
    ## MARK: Uninstall
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    try
    {
        $result = Disable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -NoRestart -ErrorAction Stop
        Write-ADTLogEntry -Message "Hyper-V avaktiverad. RestartNeeded=$($result.RestartNeeded)"
    }
    catch
    {
        Write-ADTLogEntry -Message "Avaktivering av Hyper-V misslyckades: $($_.Exception.Message)" -Severity 3
        throw
    }

    ##================================================
    ## MARK: Post-Uninstall
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    $adtSession.SetExitCode(3010)

    if ($DeployMode -eq 'Interactive')
    {
        Show-ADTInstallationRestartPrompt -CountdownSeconds 600 -CountdownNoHideSeconds 60
    }
}

function Repair-ADTDeployment
{
    ##================================================
    ## MARK: Pre-Repair
    ##================================================
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    Show-ADTInstallationProgress -StatusMessage 'Reparerar Hyper-V-funktioner...'

    ##================================================
    ## MARK: Repair
    ##================================================
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -All -NoRestart -ErrorAction Stop | Out-Null

    foreach ($svc in @('vmms', 'vmcompute', 'nvspwmi'))
    {
        if (Get-Service -Name $svc -ErrorAction SilentlyContinue)
        {
            Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        }
    }

    ##================================================
    ## MARK: Post-Repair
    ##================================================
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    $adtSession.SetExitCode(3010)
}


##================================================
## MARK: Initialization
##================================================

$adtModule = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"
if (-not (Test-Path -LiteralPath $adtModule -PathType Leaf))
{
    throw "PSAppDeployToolkit-modulen hittades inte i $adtModule. Lägg PSAppDeployToolkit 4.1.8 i mappen 'PSAppDeployToolkit'."
}

try
{
    Remove-Module -Name PSAppDeployToolkit* -Force -ErrorAction SilentlyContinue
    Import-Module -Name $adtModule -Force
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

try
{
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Open-ADTSession -SessionState $ExecutionContext.SessionState @adtSession @iadtParams -PassThru
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    Write-ADTLogEntry -Message ($mainErrorMessage = Resolve-ADTErrorRecord -ErrorRecord $_) -Severity 3
    Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop | Out-Null
    Close-ADTSession -ExitCode 60001
}
finally
{
    Remove-Module -Name PSAppDeployToolkit* -Force -ErrorAction SilentlyContinue
}
