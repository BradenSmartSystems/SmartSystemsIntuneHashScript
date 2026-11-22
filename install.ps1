#requires -Version 5.1
# Run from elevated Windows PowerShell at new/reset-PC OOBE.
[CmdletBinding()]
param([switch]$Preview, [switch]$NoRestart)
$ErrorActionPreference = 'Stop'
$tenantId = '82fcf08e-4874-4897-9b59-4ad8421cc6d8'
$graphRoot = 'https://graph.microsoft.com/beta'

function Select-OnboardingRole {
    Write-Host "`nSmart Systems - PC onboarding" -ForegroundColor Cyan
    Write-Host '  1. Employee PC'
    Write-Host '  2. Shared Jump PC (physical PC with TPM 2.0)'
    Write-Host '  0. Cancel'
    while ($true) {
        switch ((Read-Host 'Select 1, 2 or 0').Trim()) {
            '1' { return [pscustomobject]@{
                Role = 'Employee PC'; Tag = 'STD-LAPTOP'; Usage = 'singleUser'
                ProfileId = '6799c989-143d-43e4-b1c7-61df6f2c0667'
                GroupId = 'a862fc3d-3f9f-4202-bd3a-1d09d3c1e9cc'
            } }
            '2' { return [pscustomobject]@{
                Role = 'Shared Jump PC'; Tag = 'JUMP-PC'; Usage = 'shared'
                ProfileId = '24ebfcdf-3a75-4381-ab5f-4c7f35a101a3'
                GroupId = 'f5200c53-ec8e-479b-907f-0916e95b9095'
            } }
            '0' { return $null }
            default { Write-Host 'Enter 1, 2 or 0. Nothing has been changed.' -ForegroundColor Yellow }
        }
    }
}

function Wait-OnboardingState {
    param([string]$Message, [scriptblock]$Check, [int]$Minutes = 30)
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        $result = & $Check
        if ($result) { return $result }
        Write-Host "$Message (next check in 15 seconds)" -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    throw "Timed out: $Message. No restart requested. Check Intune before retrying."
}

$route = Select-OnboardingRole
if ($null -eq $route) { Write-Host 'Cancelled. Nothing has been changed.'; return }
if ($Preview) { $route; return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as administrator, or use Shift+F10 during Windows OOBE.'
}
$setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup'
if ($setup.OOBEInProgress -ne 1 -and $setup.SystemSetupInProgress -ne 1) {
    throw 'Use this on new or reset PCs at OOBE, not an existing deployed Windows installation.'
}
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
if ($edition -match '^Core') { throw 'Windows Home cannot Entra join. Install or upgrade to Windows Pro first.' }
if ($route.Usage -eq 'shared') {
    $tpm = Get-Tpm
    $tpmInfo = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -ClassName Win32_Tpm
    if (-not $tpm.TpmPresent -or -not $tpm.TpmReady -or $tpmInfo.SpecVersion -notmatch '^2\.0') {
        throw 'Jump PC self-deployment requires a ready TPM 2.0.'
    }
    Write-Host 'Autopilot will validate hardware TPM attestation. Virtual machines are not supported.' -ForegroundColor Yellow
}
Write-Host "`nSelected: $($route.Role) | tag: $($route.Tag)" -ForegroundColor Cyan
if ((Read-Host "Type $($route.Tag) to confirm, or Enter to cancel").Trim() -cne $route.Tag) {
    Write-Host 'Cancelled. Nothing has been changed.'; return
}

$hashFile = Join-Path $env:TEMP ('SmartSystems-Autopilot-' + [guid]::NewGuid() + '.csv')
$repositoryWasChanged = $false
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force
    Write-Host 'Installing prerequisites from PowerShell Gallery...' -ForegroundColor Cyan
    $originalRepositoryPolicy = (Get-PSRepository -Name PSGallery).InstallationPolicy
    if ($originalRepositoryPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        $repositoryWasChanged = $true
    }
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Script -Name Get-WindowsAutopilotInfo -RequiredVersion 3.9 -Repository PSGallery -Scope AllUsers -Force
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Install-Module Microsoft.Graph.Authentication -Repository PSGallery -Scope AllUsers -Force -AllowClobber
    }
    Import-Module Microsoft.Graph.Authentication
    # Use the official collector locally; authenticate the upload to the fixed tenant below.
    $collector = Get-InstalledScript -Name Get-WindowsAutopilotInfo -RequiredVersion 3.9
    & (Join-Path $collector.InstalledLocation 'Get-WindowsAutopilotInfo.ps1') -OutputFile $hashFile
    $hardware = @(Import-Csv -LiteralPath $hashFile)
    if ($hardware.Count -ne 1 -or -not $hardware[0].'Hardware Hash' -or -not $hardware[0].'Device Serial Number') {
        throw 'The collector did not return one complete hardware record.'
    }
    Write-Host 'Sign in with your authorized Intune administrator for hardware registration.' -ForegroundColor Cyan
    Write-Host 'Do not use intune.enroll for this upload: it is not an administrator.'
    Connect-MgGraph -TenantId $tenantId -ContextScope Process -UseDeviceCode -NoWelcome -Scopes @(
        'DeviceManagementServiceConfig.ReadWrite.All', 'Device.Read.All', 'GroupMember.Read.All'
    )
    if ((Get-MgContext).TenantId -ne $tenantId) { throw 'Connected to the wrong Microsoft tenant.' }
    $profile = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/deviceManagement/windowsAutopilotDeploymentProfiles/$($route.ProfileId)" -OutputType PSObject
    if ($profile.'@odata.type' -ne '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile' -or
        $profile.outOfBoxExperienceSetting.deviceUsageType -ne $route.Usage) {
        throw 'The configured profile does not match the selected route.'
    }
    Write-Host "Registering this PC as $($route.Role)..." -ForegroundColor Cyan
    $body = @{
        '@odata.type' = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
        serialNumber = $hardware[0].'Device Serial Number'
        hardwareIdentifier = $hardware[0].'Hardware Hash'
        groupTag = $route.Tag
    } | ConvertTo-Json
    $import = Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/deviceManagement/importedWindowsAutopilotDeviceIdentities" -Body $body -ContentType 'application/json' -OutputType PSObject
    if (-not $import.id) { throw 'Microsoft did not return an import ID.' }
    $completed = Wait-OnboardingState 'Waiting for hardware import' {
        $state = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($import.id)" -OutputType PSObject
        if ($state.state.deviceImportStatus -eq 'error') {
            throw "Import failed: $($state.state.deviceErrorCode) $($state.state.deviceErrorName). Review existing registrations in Intune before retrying."
        }
        if ($state.state.deviceImportStatus -eq 'complete' -and $state.state.deviceRegistrationId) { $state }
    }
    $autopilotId = $completed.state.deviceRegistrationId
    $assigned = Wait-OnboardingState 'Waiting for selected profile and policy group' {
        $device = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/deviceManagement/windowsAutopilotDeviceIdentities/$autopilotId`?`$expand=deploymentProfile" -OutputType PSObject
        if (-not $device.groupTag) { return }
        if ($device.groupTag -ne $route.Tag) { throw 'Device has a different tag. Review its existing registration in Intune.' }
        if ($device.deploymentProfileAssignmentStatus -ne 'assignedInSync' -or $device.deploymentProfile.id -ne $route.ProfileId) { return }
        if (-not $device.azureActiveDirectoryDeviceId) { return }
        $filter = [uri]::EscapeDataString("deviceId eq '$($device.azureActiveDirectoryDeviceId)'")
        $directoryDevices = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=$filter&`$select=id" -OutputType PSObject
        if (@($directoryDevices.value).Count -ne 1) { return }
        $objectId = $directoryDevices.value[0].id
        $memberships = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/devices/$objectId/checkMemberGroups" -Body (@{groupIds = @($route.GroupId)} | ConvertTo-Json) -ContentType 'application/json' -OutputType PSObject
        if ($memberships.value -contains $route.GroupId) { $device }
    }
    Write-Host "`nReady: $($route.Role)" -ForegroundColor Green
    Write-Host "Verified tag: $($route.Tag)"
    Write-Host "Verified profile: $($assigned.deploymentProfile.displayName)"
    Write-Host 'Verified policy group membership.'
    Write-Host 'After restart, continue Autopilot OOBE for Entra join and Intune enrollment.'
    if ($route.Usage -eq 'singleUser') {
        Write-Host 'The employee signs in with their own licensed work account.'
    } else {
        Write-Host 'Shared mode enrolls without a user. Technicians use their own accounts after setup.'
    }
    if (-not $NoRestart -and (Read-Host 'Type RESTART to restart into Autopilot, or Enter to restart later') -ceq 'RESTART') {
        shutdown.exe /r /t 15 /c 'Smart Systems Autopilot profile verified. Restarting into OOBE.'
        if ($LASTEXITCODE -ne 0) { throw 'Windows could not schedule the restart. Restart manually.' }
    } else { Write-Host 'No restart requested. Restart manually when ready.' }
} catch {
    Write-Host "`nOnboarding stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check Intune before retrying. No automatic retry or retagging is performed.' -ForegroundColor Yellow
    throw
} finally {
    if (Test-Path -LiteralPath $hashFile) { Remove-Item -LiteralPath $hashFile -Force }
    if ($repositoryWasChanged) {
        Set-PSRepository -Name PSGallery -InstallationPolicy $originalRepositoryPolicy -ErrorAction Continue
    }
}
