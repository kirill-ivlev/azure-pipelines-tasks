Trace-VstsEnteringInvocation $MyInvocation
Import-VstsLocStrings "$PSScriptRoot\Task.json"

try {

    $ServiceName = Get-VstsInput -Name ServiceName -Require
    $ResourceGroupName = Get-VstsInput -Name ResourceGroupName -Require
    $ServiceLocation = Get-VstsInput -Name ServiceLocation -Require
    $CsCfg = Get-VstsInput -Name CsCfg -Require
    $CsDef = Get-VstsInput -Name CsDef -Require
    $CsPkg = Get-VstsInput -Name CsPkg -Require
    $StorageAccount = Get-VstsInput -Name ARMStorageAccount -Require
    $KeyVault = Get-VstsInput -Name KeyVault
    $DeploymentLabel = Get-VstsInput -Name DeploymentLabel
    $AppendDateTimeToLabel = Get-VstsInput -Name AppendDateTimeToLabel -Require -AsBool
    $UpgradeMode = Get-VstsInput -Name UpgradeMode
    $AllowUpgrade = Get-VstsInput -Name AllowUpgrade -Require -AsBool
    $VerifyRoleInstanceStatus = Get-VstsInput -Name VerifyRoleInstanceStatus -AsBool
    $DiagnosticStorageAccountKeys = Get-VstsInput -Name DiagnosticStorageAccountKeys
    $ARMConnectedServiceName = Get-VstsInput -Name ARMConnectedServiceName -Require
    $endpoint = Get-VstsEndpoint -Name $ARMConnectedServiceName -Require

    # Initialize helpers
    Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
    . $PSScriptRoot/Utility.ps1

    Update-PSModulePathForHostedAgent

    $troubleshoot = "https://aka.ms/azurepowershelltroubleshooting"
    try {
        # Initialize Azure.
        Initialize-AzModule -Endpoint $endpoint
        Write-Host "## Az module initialization Complete"
        $success = $true
    }
    finally {
        if (!$success) {
            Write-VstsTaskError "Initializing Az module failed: For troubleshooting, refer: $troubleshoot"
        }
    }

    $storageAccountKeysMap = Parse-StorageKeys -StorageAccountKeys $DiagnosticStorageAccountKeys

    Write-Host "Finding $CsCfg"
    $serviceConfigFile = Find-VstsFiles -LegacyPattern "$CsCfg"
    Write-Host "serviceConfigFile= $serviceConfigFile"
    $serviceConfigFile = Get-SingleFile $serviceConfigFile $CsCfg

    Write-Host "Find-VstsFiles -LegacyPattern $CsPkg"
    $servicePackageFile = Find-VstsFiles -LegacyPattern "$CsPkg"
    Write-Host "servicePackageFile= $servicePackageFile"
    $servicePackageFile = Get-SingleFile $servicePackageFile $CsPkg

    $label = $DeploymentLabel
    if ($label -and $AppendDateTimeToLabel) {
        $label += " "
        $label += [datetime]::now
    }
    $tag=@{}
    if ($label) {
        $tag["Label"] = $label
    }

    $diagnosticExtensions = Get-DiagnosticsExtensions $ServiceName $StorageAccount $serviceConfigFile $storageAccountKeysMap

    Write-Host "##[command]Get-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue -ErrorVariable azureServiceError"
    $azureService = Get-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue -ErrorVariable azureServiceError
    if ($azureServiceError) {
       $azureServiceError | ForEach-Object { Write-Verbose $_.Exception.ToString() }
    }

    if (!$azureService) {
        Create-AzureCloudService $ServiceName $ResourceGroupName $ServiceLocation $CsCfg $CsDef $CsPkg $StorageAccount $KeyVault $tag $diagnosticExtensions $UpgradeMode
    }
    elseif ($AllowUpgrade -eq $false) {
        #Remove and then Re-create
        Write-Host "##[command]Remove-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName"
        Remove-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName
        Create-AzureCloudService $ServiceName $ResourceGroupName $ServiceLocation $CsCfg $CsDef $CsPkg $StorageAccount $KeyVault $tag $diagnosticExtensions $UpgradeMode
    }
    else {
        $tagChanged = $azureService.Tag.Keys.Count -ne $tag.Keys.Count
        if (!$tagChanged -and ($tag.Keys.Coun -gt 0)) {
            foreach ($key in $tag.Keys) {
                if ($tag[$key] -ne $azureService.Tag[$key]) {
                    $tagChanged = $true
                    break
                }
            }
        }
        if (!$UpgradeMode) {
            $UpgradeMode = "Auto"
        }
        $upgradeModeChanged = $azureService.UpgradeMode -ne $UpgradeMode
        if ($tagChanged -or $upgradeModeChanged) {
            if ($tagChanged) {
                Write-Host "Updating a tag"
                $azureService.Tag = $tag
            }
            if ($upgradeModeChanged) {
                Write-Host "Updating upgrade mode"
                $azureService.UpgradeMode = $UpgradeMode
            }
            Write-Host "##[command]Update-AzCloudService"
            $azureService | Update-AzCloudService
        }
    }

    if ($VerifyRoleInstanceStatus -eq $true) {
        Validate-AzureCloudServiceStatus -CloudServiceName $ServiceName
    }
} finally {
	Trace-VstsLeavingInvocation $MyInvocation
}

