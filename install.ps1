#requires -Version 5.1
# Run from elevated Windows PowerShell, at OOBE or on an existing PC.
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

function Test-OnboardingOobe {
    param($SetupState)
    return ($SetupState.OOBEInProgress -eq 1 -or $SetupState.SystemSetupInProgress -eq 1)
}

function ConvertFrom-JoinStatus {
    param([string[]]$Lines)
    $state = @{}
    foreach ($line in $Lines) {
        if ($line -match '^\s*(AzureAdJoined|DomainJoined|WorkplaceJoined|TenantId|DeviceId)\s*:\s*(.*?)\s*$') {
            $state[$Matches[1]] = $Matches[2]
        }
    }
    if (-not $state.ContainsKey('AzureAdJoined') -or -not $state.ContainsKey('DomainJoined')) {
        throw 'Could not read the Windows join state. Stop and inspect dsregcmd /status.'
    }
    return $state
}

function Get-LocalJoinState {
    $lines = & dsregcmd.exe /status
    if ($LASTEXITCODE -ne 0) { throw 'Windows could not report its join state.' }
    return ConvertFrom-JoinStatus $lines
}

function Assert-ExistingJoinTenant {
    param($JoinState, [string]$ExpectedTenant)
    if ($JoinState.DomainJoined -eq 'YES') {
        throw 'This PC is joined to local Active Directory. It needs a planned domain migration; this script will not disconnect it.'
    }
    if ($JoinState.AzureAdJoined -eq 'YES' -and $JoinState.TenantId -ne $ExpectedTenant) {
        throw 'This PC is joined to another Entra tenant. This script will not disconnect it.'
    }
}

function Get-ExistingRoleMarker {
    param($SelectedRoute, $DirectoryDevice)
    $marker = if ($SelectedRoute.Usage -eq 'shared') { 'SS-JUMP-PC' } else { 'SS-EMPLOYEE-PC' }
    $existingMarker = $DirectoryDevice.extensionAttributes.extensionAttribute15
    if ($existingMarker -and $existingMarker -ne $marker) {
        throw 'Device extensionAttribute15 already has another value. Review its existing classification before changing it.'
    }
    $oppositeTag = if ($SelectedRoute.Usage -eq 'shared') { '[OrderID]:STD-LAPTOP' } else { '[OrderID]:JUMP-PC' }
    if ($DirectoryDevice.physicalIds -contains $oppositeTag) {
        throw 'This PC has a conflicting Autopilot tag. Review its intended role in Intune before changing it.'
    }
    return $marker
}

function Enroll-ExistingInstallation {
    param($SelectedRoute, [string]$ExpectedTenant)
    $join = Get-LocalJoinState
    Assert-ExistingJoinTenant $join $ExpectedTenant
    $wasJoined = $join.AzureAdJoined -eq 'YES'
    if ($join.AzureAdJoined -ne 'YES') {
        Write-Host "`nKeep Datto Web Remote available. Confirm a working LOCAL administrator and its password." -ForegroundColor Yellow
        Write-Host 'Joining creates separate work-account profiles; it does not migrate the existing local profile.'
        if ((Read-Host 'Type READY after testing local administrator and remote recovery access, or Enter to cancel') -cne 'READY') { return }
        Write-Host 'In Settings: Accounts > Access work or school > Connect.' -ForegroundColor Cyan
        Write-Host 'BEFORE entering an email, select Join this device to Microsoft Entra ID under Alternate actions.' -ForegroundColor Yellow
        if ($SelectedRoute.Usage -eq 'shared') {
            Write-Host 'Join with intune.enroll@cosmartsystems.com (configured as Device Enrollment Manager).'
        } else { Write-Host 'Join with the employee work account, licensed for Intune and included in automatic enrollment.' }
        if ($join.WorkplaceJoined -eq 'YES') {
            Write-Host 'A work registration exists. If Windows reports already enrolled, its connection may need to be disconnected first.' -ForegroundColor Yellow
            Write-Host 'Do not remove unrelated accounts. Disconnecting a managed work connection temporarily removes its Intune enrollment.'
        }
        Write-Host 'Complete the Microsoft sign-in and MFA yourself. Choose Restart later so this script can verify routing first.'
        Start-Process 'ms-settings:workplace'
        do {
            if ((Read-Host 'Press Enter after completing the join, or type CANCEL to stop') -eq 'CANCEL') { return }
            $join = Get-LocalJoinState
            Assert-ExistingJoinTenant $join $ExpectedTenant
            if ($join.AzureAdJoined -ne 'YES') { Write-Host 'Entra join is not complete yet. Use the Join this device link, not just the email field.' -ForegroundColor Yellow }
        } until ($join.AzureAdJoined -eq 'YES')
    }
    if (-not $join.DeviceId) { throw 'Windows did not report an Entra device ID.' }
    $filter = [uri]::EscapeDataString("deviceId eq '$($join.DeviceId)'")
    $directoryDevice = Wait-OnboardingState 'Waiting for this Entra joined device record' {
        $records = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=$filter&`$select=id,deviceId,displayName,trustType,physicalIds,extensionAttributes" -OutputType PSObject
        if (@($records.value).Count -eq 1 -and $records.value[0].trustType -eq 'AzureAd') { $records.value[0] }
    }
    $marker = Get-ExistingRoleMarker $SelectedRoute $directoryDevice
    # Administrator-controlled device attribute: current-install routing without an OOBE reset.
    $roleBody = @{extensionAttributes = @{extensionAttribute15 = $marker}} | ConvertTo-Json
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/devices/$($directoryDevice.id)" -Body $roleBody -ContentType 'application/json' | Out-Null
    $null = Wait-OnboardingState 'Waiting for the selected policy group' {
        $memberships = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/devices/$($directoryDevice.id)/checkMemberGroups" -Body (@{groupIds=@($SelectedRoute.GroupId)} | ConvertTo-Json) -ContentType 'application/json' -OutputType PSObject
        if ($memberships.value -contains $SelectedRoute.GroupId) { $true }
    }
    $managedFilter = [uri]::EscapeDataString("azureADDeviceId eq '$($join.DeviceId)'")
    if ($wasJoined) {
        $initialManaged = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$managedFilter&`$select=id,managementState" -OutputType PSObject
        if (@($initialManaged.value).Count -eq 0) {
            Write-Host 'This PC is already Entra joined, but no Intune record is visible.' -ForegroundColor Yellow
            Write-Host 'If enrollment just completed, choose WAIT. Otherwise choose ENROLL to open Windows MDM enrollment.'
            $enrollmentChoice = (Read-Host 'Type ENROLL, WAIT, or CANCEL').Trim().ToUpperInvariant()
            if ($enrollmentChoice -eq 'CANCEL') { return }
            if ($enrollmentChoice -eq 'ENROLL') {
                Start-Process 'ms-device-enrollment:?mode=mdm'
                if ((Read-Host 'Complete enrollment with the appropriate licensed work or DEM account, then Enter; or type CANCEL') -eq 'CANCEL') { return }
            } elseif ($enrollmentChoice -ne 'WAIT') { throw 'No enrollment option selected. Run again when ready.' }
        }
    }
    $managed = Wait-OnboardingState 'Waiting for Intune enrollment of this Windows installation' {
        $records = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$managedFilter&`$select=id,deviceName,managementState" -OutputType PSObject
        if (@($records.value).Count -gt 1) { throw 'Multiple Intune enrollments found for this device. Review duplicate records.' }
        if (@($records.value).Count -eq 1 -and $records.value[0].managementState -eq 'managed') { $records.value[0] }
    }
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($managed.id)" -Body '{"managedDeviceOwnerType":"company"}' -ContentType 'application/json' | Out-Null
    Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($managed.id)/syncDevice" | Out-Null
    Write-Host "`nVerified: Entra joined, Intune enrolled, and routed as $($SelectedRoute.Role)." -ForegroundColor Green
    Write-Host 'Intune sync requested. Policy and app installation still need to finish.'
    Write-Host 'No reset or restart requested. Test Datto and local administrator access before a normal restart.'
    Write-Host 'This path does not register the hardware in Autopilot for future resets.'
}

function Complete-OnboardingRegistration {
    param([bool]$AtOobe, $SelectedRoute, [bool]$SuppressRestart)
    if (-not $AtOobe) {
        throw 'Existing Windows must use the guided enrollment path, not the OOBE restart path.'
    }
    Write-Host 'After restart, continue Autopilot OOBE for Entra join and Intune enrollment.'
    if ($SelectedRoute.Usage -eq 'singleUser') {
        Write-Host 'The employee signs in with their own licensed work account.'
    } else {
        Write-Host 'Shared mode enrolls without a user. Technicians use their own accounts after setup.'
    }
    if (-not $SuppressRestart -and (Read-Host 'Type RESTART to restart into Autopilot, or Enter to restart later') -ceq 'RESTART') {
        shutdown.exe /r /t 15 /c 'Smart Systems Autopilot profile verified. Restarting into OOBE.'
        if ($LASTEXITCODE -ne 0) { throw 'Windows could not schedule the restart. Restart manually.' }
    } else { Write-Host 'No restart requested. Restart manually when ready.' }
}

$route = Select-OnboardingRole
if ($null -eq $route) { Write-Host 'Cancelled. Nothing has been changed.'; return }
if ($Preview) { $route; return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as administrator, or use Shift+F10 during Windows OOBE.'
}
$setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup'
$atOobe = Test-OnboardingOobe $setup
if ($atOobe) {
    Write-Host 'Detected Windows OOBE: prepare Autopilot setup.' -ForegroundColor Cyan
} else {
    Write-Host 'Detected an existing Windows installation.' -ForegroundColor Cyan
    Write-Host 'This path guides Entra join and verifies Intune enrollment NOW, without resetting Windows.' -ForegroundColor Yellow
    Write-Host 'It will not reset, automatically disconnect an account, or restart this PC.'
    if ($identity.User.Value -eq 'S-1-5-18') { throw 'Run the existing-PC path in an interactive administrator PowerShell window, not a background SYSTEM job.' }
    Assert-ExistingJoinTenant (Get-LocalJoinState) $tenantId
}
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
if ($edition -match '^Core') { throw 'Windows Home cannot Entra join. Install or upgrade to Windows Pro first.' }
if ($atOobe -and $route.Usage -eq 'shared') {
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
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Install-Module Microsoft.Graph.Authentication -Repository PSGallery -Scope AllUsers -Force -AllowClobber
    }
    Import-Module Microsoft.Graph.Authentication
    if (-not $atOobe) {
        Write-Host 'Sign in with an authorized Intune administrator to classify this PC and verify management.' -ForegroundColor Cyan
        Connect-MgGraph -TenantId $tenantId -ContextScope Process -UseDeviceCode -NoWelcome -Scopes @(
            'Directory.AccessAsUser.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'GroupMember.Read.All'
        )
        if ((Get-MgContext).TenantId -ne $tenantId) { throw 'Connected to the wrong Microsoft tenant.' }
        Enroll-ExistingInstallation -SelectedRoute $route -ExpectedTenant $tenantId
        return
    }
    Install-Script -Name Get-WindowsAutopilotInfo -RequiredVersion 3.9 -Repository PSGallery -Scope AllUsers -Force
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
    Complete-OnboardingRegistration -AtOobe $atOobe -SelectedRoute $route -SuppressRestart ([bool]$NoRestart)
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
