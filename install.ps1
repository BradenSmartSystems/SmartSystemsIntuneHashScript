[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

Install-Script -Name Get-WindowsAutopilotInfo -Force

Get-WindowsAutopilotInfo -Online -GroupTag "STD-LAPTOP"
