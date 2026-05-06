try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction Stop
    if ($feature.State -eq 'Enabled') {
        Write-Output 'Hyper-V is enabled'
        exit 0
    }
    else {
        Write-Output "Hyper-V state: $($feature.State)"
        exit 1
    }
}
catch {
    Write-Output $_.Exception.Message
    exit 1
}
