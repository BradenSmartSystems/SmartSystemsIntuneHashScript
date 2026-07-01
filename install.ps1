# Smart Systems - Autopilot registration from OOBE

$GroupTag = "STD-LAPTOP"

$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Installing prerequisites..." -ForegroundColor Cyan

Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

Write-Host "Installing Get-WindowsAutopilotInfo..." -ForegroundColor Cyan

Install-Script -Name Get-WindowsAutopilotInfo -Force

Write-Host "Uploading hardware hash with group tag '$GroupTag'..." -ForegroundColor Cyan
Write-Host "This can take a while. Do not close this window." -ForegroundColor Yellow

Get-WindowsAutopilotInfo -Online -GroupTag $GroupTag -Assign

Write-Host ""
Write-Host "Autopilot profile assignment completed." -ForegroundColor Green
Write-Host "Rebooting in 15 seconds..." -ForegroundColor Green

shutdown.exe /r /t 5 /c "Autopilot profile assigned. Rebooting into Autopilot OOBE."
