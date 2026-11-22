#requires -Version 5.1
# Run from elevated Windows PowerShell, at OOBE or on an existing PC.
[CmdletBinding()]
param([switch]$Preview, [switch]$NoRestart, [string]$ComputerName, [switch]$AddCorporateIdentifier)
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

function Test-OnboardingComputerName {
    param([string]$Name)
    # Conservative Windows/NetBIOS and DNS-compatible names, including SS-DENVER-METRO.
    return ($Name.Length -ge 1 -and $Name.Length -le 15 -and
        $Name -match '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$' -and
        $Name -notmatch '^\d+$' -and $Name -notmatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$')
}

function Read-OnboardingComputerName {
    param([string]$InitialName)
    if ($InitialName) {
        $name = $InitialName.Trim().ToUpperInvariant()
        if (-not (Test-OnboardingComputerName $name)) { throw 'Invalid -ComputerName. Use 1-15 letters, numbers or hyphens; start/end with a letter or number; not all numbers or a reserved name.' }
        return $name
    }
    Write-Host 'Optional PC name: 1-15 letters, numbers or hyphens. Example: SS-DENVER-METRO.'
    Write-Host 'Press Enter to keep the current name on an existing PC, or the profile default at OOBE.'
    while ($true) {
        $name = (Read-Host 'PC name').Trim().ToUpperInvariant()
        if (-not $name) { return $null }
        if (Test-OnboardingComputerName $name) { return $name }
        Write-Host 'Invalid name: use 1-15 letters/numbers/hyphens, no leading/trailing hyphen, not all numbers or a reserved name.' -ForegroundColor Yellow
    }
}

function Assert-OnboardingNameAvailable {
    param([string]$Name, [string]$CurrentDeviceId)
    if (-not $Name) { return }
    if (-not (Test-OnboardingComputerName $Name)) { throw 'Invalid computer name.' }
    $nameFilter = [uri]::EscapeDataString("displayName eq '$Name'")
    $matchesByName = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=$nameFilter&`$select=id,deviceId,displayName" -OutputType PSObject
    if (@($matchesByName.value | Where-Object { $_.deviceId -ne $CurrentDeviceId }).Count -gt 0) {
        throw "An Entra device already uses '$Name'. Choose another name or review the existing record; nothing is deleted automatically."
    }
}

function Set-ExistingOnboardingName {
    param([string]$Name)
    if (-not $Name) { return }
    if (-not (Test-OnboardingComputerName $Name)) { throw 'Invalid computer name.' }
    $active = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
    $configured = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($active -ne $configured) {
        if ($configured -ne $Name) { throw "A different rename to '$configured' is already pending. Resolve it before setting '$Name'." }
        Write-Host "PC name '$Name' is already pending. A normal restart is required." -ForegroundColor Yellow
        return
    }
    if ($active -eq $Name) { Write-Host "PC already uses '$Name'."; return }
    $result = Rename-Computer -NewName $Name -Force -PassThru
    if (-not $result.HasSucceeded) { throw 'Windows did not accept the computer rename.' }
    $configured = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($configured -ne $Name) { throw 'The pending Windows name did not match the requested name.' }
    Write-Host "PC rename queued: $active -> $Name. It takes effect after a normal restart." -ForegroundColor Yellow
    Write-Host 'Intune and Entra inventory can continue showing the old name until the PC restarts and checks in.'
}

function Set-AutopilotOnboardingName {
    param([string]$AutopilotId, [string]$Name, [string]$ExpectedTag)
    if (-not $Name) { return }
    if (-not (Test-OnboardingComputerName $Name)) { throw 'Invalid computer name.' }
    $record = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/deviceManagement/windowsAutopilotDeviceIdentities/$AutopilotId" -OutputType PSObject
    if ($record.groupTag -ne $ExpectedTag) { throw 'Autopilot tag does not match the selected route. The device was not renamed.' }
    $nameBody = @{displayName=$Name;groupTag=$ExpectedTag} | ConvertTo-Json
    Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/deviceManagement/windowsAutopilotDeviceIdentities/$AutopilotId/updateDeviceProperties" -Body $nameBody -ContentType 'application/json' | Out-Null
    $null = Wait-OnboardingState 'Waiting for the requested Autopilot computer name' {
        $updated = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/deviceManagement/windowsAutopilotDeviceIdentities/$AutopilotId" -OutputType PSObject
        if ($updated.groupTag -ne $ExpectedTag) { throw 'Autopilot tag changed during name verification.' }
        if ($updated.displayName -eq $Name) { $true }
    }
    Write-Host "Verified Autopilot PC name: $Name" -ForegroundColor Green
}

function Select-CorporateIdentifierOption {
    Write-Host 'Optional: add this PC to Intune Corporate Device Identifiers (manufacturer + model + serial).'
    Write-Host 'Autopilot already identifies corporate devices. This separate list is normally unnecessary for Autopilot.'
    Write-Host 'Microsoft notes this list changes enrollment-time classification: unmatched Windows devices can be classified as personal before other enrollment rules determine final ownership.' -ForegroundColor Yellow
    Write-Host 'It does not change ownership retroactively. Existing-PC enrollment still explicitly sets Corporate ownership.'
    while ($true) {
        $answer = (Read-Host 'Type ADD to include this PC, or Enter to skip (recommended)').Trim()
        if (-not $answer) { return $false }
        if ($answer -ceq 'ADD') { return $true }
        Write-Host 'Enter ADD or press Enter to skip.' -ForegroundColor Yellow
    }
}

function New-OnboardingCorporateIdentity {
    param([string]$Manufacturer, [string]$Model, [string]$Serial)
    $manufacturerValue = $Manufacturer.Trim()
    $modelValue = $Model.Trim()
    $serialValue = $Serial.Trim().Replace('.', '')
    foreach ($value in @($manufacturerValue, $modelValue, $serialValue)) {
        if (-not $value -or $value -match '[,\r\n]' -or $value -match '^(Default\s*string|To be filled by O\.?E\.?M\.?|Unknown|None|Not (specified|applicable)|System (Serial Number|Manufacturer|Product Name)|0+|1+|123456789)$') {
            throw 'Corporate identifier contains a missing, ambiguous or placeholder hardware value. Correct the firmware inventory, or rerun and skip this optional step. Do not invent a serial number.'
        }
    }
    return @{
        '@odata.type' = '#microsoft.graph.importedDeviceIdentity'
        importedDeviceIdentifier = (@($manufacturerValue, $modelValue, $serialValue) -join ',')
        importedDeviceIdentityType = 'manufacturerModelSerial'
        platform = 'windows'
        description = 'Smart Systems onboarding'
    }
}

function Add-OnboardingCorporateIdentity {
    $windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$windows.CurrentBuildNumber
    $revision = [int]$windows.UBR
    if (-not (($build -eq 19045 -and $revision -ge 4598) -or
        ($build -in @(22621,22631) -and $revision -ge 3374) -or $build -gt 22631)) {
        throw 'This Windows build does not support Windows Corporate Device Identifiers. Update Windows or skip this optional step.'
    }
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $corporateIdentity = New-OnboardingCorporateIdentity $computer.Manufacturer $computer.Model $bios.SerialNumber
    Write-Host "Corporate identifier: $($corporateIdentity.importedDeviceIdentifier)"
    $searchBody = @{importedDeviceIdentities=@($corporateIdentity)} | ConvertTo-Json -Depth 5
    $existing = Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/deviceManagement/importedDeviceIdentities/searchExistingIdentities" -Body $searchBody -ContentType 'application/json' -OutputType PSObject
    $matching = @($existing.value | Where-Object { $_.importedDeviceIdentityType -eq 'manufacturerModelSerial' -and $_.importedDeviceIdentifier -eq $corporateIdentity.importedDeviceIdentifier })
    if ($matching.Count -gt 0) { Write-Host 'Verified: this Corporate Device Identifier already exists.' -ForegroundColor Green; return }
    $importBody = @{importedDeviceIdentities=@($corporateIdentity);overwriteImportedDeviceIdentities=$false} | ConvertTo-Json -Depth 5
    $response = Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/deviceManagement/importedDeviceIdentities/importDeviceIdentityList" -Body $importBody -ContentType 'application/json' -OutputType PSObject
    $success = @($response.value | Where-Object { $_.status -eq $true -and $_.importedDeviceIdentityType -eq 'manufacturerModelSerial' -and $_.importedDeviceIdentifier -eq $corporateIdentity.importedDeviceIdentifier })
    if ($success.Count -ne 1) { throw 'Microsoft did not confirm this Corporate Device Identifier import. Review Intune before retrying.' }
    $null = Wait-OnboardingState 'Waiting for Corporate Device Identifier verification' {
        $verified = Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/deviceManagement/importedDeviceIdentities/searchExistingIdentities" -Body $searchBody -ContentType 'application/json' -OutputType PSObject
        $match = @($verified.value | Where-Object { $_.importedDeviceIdentityType -eq 'manufacturerModelSerial' -and $_.importedDeviceIdentifier -eq $corporateIdentity.importedDeviceIdentifier })
        if ($match.Count -gt 0) { $true }
    }
    Write-Host 'Verified: Corporate Device Identifier added. Enrollment and protection still need to complete.' -ForegroundColor Green
}

function Assert-OnboardingAdminContext {
    $context = Get-MgContext
    if ($context.TenantId -ne $tenantId) { throw 'Connected to the wrong Microsoft tenant.' }
    if ($context.Account -ieq 'intune.enroll@cosmartsystems.com') {
        throw 'intune.enroll is the Windows enrollment account, not the script administrator. Rerun and authenticate the script with an authorized Intune administrator; use intune.enroll separately in Windows Settings.'
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
    param($SelectedRoute, [string]$ExpectedTenant, [string]$DesiredName)
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
    Assert-OnboardingNameAvailable -Name $DesiredName -CurrentDeviceId $join.DeviceId
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
    Set-ExistingOnboardingName -Name $DesiredName
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
$requestedName = Read-OnboardingComputerName -InitialName $ComputerName
$route | Add-Member -NotePropertyName DesiredName -NotePropertyValue $requestedName
$includeCorporateIdentifier = [bool]$AddCorporateIdentifier
if (-not $includeCorporateIdentifier) { $includeCorporateIdentifier = Select-CorporateIdentifierOption }
$route | Add-Member -NotePropertyName AddCorporateIdentifier -NotePropertyValue $includeCorporateIdentifier
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
if ($requestedName) { Write-Host "Requested PC name: $requestedName" -ForegroundColor Cyan }
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
        $existingScopes = @(
            'Directory.AccessAsUser.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'GroupMember.Read.All'
        )
        if ($includeCorporateIdentifier) { $existingScopes += 'DeviceManagementServiceConfig.ReadWrite.All' }
        Connect-MgGraph -TenantId $tenantId -ContextScope Process -UseDeviceCode -NoWelcome -Scopes $existingScopes
        Assert-OnboardingAdminContext
        if ($includeCorporateIdentifier) { Add-OnboardingCorporateIdentity }
        Enroll-ExistingInstallation -SelectedRoute $route -ExpectedTenant $tenantId -DesiredName $requestedName
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
    Assert-OnboardingAdminContext
    if ($includeCorporateIdentifier) { Add-OnboardingCorporateIdentity }
    Assert-OnboardingNameAvailable -Name $requestedName
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
    Set-AutopilotOnboardingName -AutopilotId $autopilotId -Name $requestedName -ExpectedTag $route.Tag
    $assigned = Wait-OnboardingState 'Waiting for selected profile and policy group' {
        $device = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/deviceManagement/windowsAutopilotDeviceIdentities/$autopilotId`?`$expand=deploymentProfile" -OutputType PSObject
        if (-not $device.groupTag) { return }
        if ($device.groupTag -ne $route.Tag) { throw 'Device has a different tag. Review its existing registration in Intune.' }
        if ($requestedName -and $device.displayName -ne $requestedName) { return }
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
