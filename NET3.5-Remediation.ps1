try  {
 
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3
    Write-Output 'NetFx3 will be Enabled'
    exit 0
}
catch {
 
    $errMsg = $_.Exception.Message
    Write-host $errMsg
    exit 1
}