# Smart Systems - Autopilot hash upload script

$GroupTag = "STD-LAPTOP"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

Install-Script -Name Get-WindowsAutopilotInfo -Force

Get-WindowsAutopilotInfo -Online -GroupTag $GroupTag

Write-Host ""
Write-Host "Autopilot upload complete. Verify the device in Intune, wait for profile assignment, then restart." -ForegroundColor Green
Write-Host ""
