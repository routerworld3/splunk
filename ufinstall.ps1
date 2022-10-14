
#https://community.splunk.com/t5/Installation/Powershell-for-splunk-forwarder-installation/m-p/570984
$Environment = [System.Net.Dns]::GetHostByName(($env:COMPUTERNAME))
Write-Host "This script will only work as admin!" -BackgroundColor Magenta
Start-Process -FilePath C:\Windows\system32\msiexec.exe -ArgumentList "/i C:\share\splunkforwarder-9.0.1-82c987350fde-x64-release.msi AGREETOLICENSE=Yes SERVICESTARTTYPE=auto DEPLOYMENT_SERVER=192.168.98.99:8089 GENRANDOMPASSWORD=1 /quiet" -Wait -NoNewWindow
#Installs the Splunk Forwarder
Start-Process -FilePath C:\Windows\system32\msiexec.exe -ArgumentList "/i splunkforwarder-8.2.0-e053ef3c985f-x64-release.msi AGREETOLICENSE=Yes SERVICESTARTTYPE=auto GENRANDOMPASSWORD=1 /quiet" -Wait -NoNewWindow
Start-Process -FilePath C:\Windows\system32\msiexec.exe -ArgumentList "/i C:\share\splunkforwarder-9.0.1-82c987350fde-x64-release.msi AGREETOLICENSE=Yes SERVICESTARTTYPE=auto DEPLOYMENT_SERVER=IP:8089 GENRANDOMPASSWORD=1 /quiet" -Wait -NoNewWindow
#Stop the Splunk Universal Forwarder
Write-Host "Stopping the Splunk Forwarder Service"
Stop-Service -Name SplunkForwarder
Start-Sleep -Seconds 5

#Copy the zzz_config file into the Splunk Program Files
Write-Host "Copying the configuration files"
Copy-Item -Path .\zzz_config_base -Recurse -Destination "C:\Program Files\SplunkUniversalForwarder\etc\apps\"
Start-Sleep -Seconds 5

#Restart the splunk service
Do{
    
    Write-Host "Attempting to restart Splunk Forwarder Service"
    Start-Service -Name SplunkForwarder
    Start-Sleep -Seconds 10

    $Splunk = Get-Service -Name SplunkForwarder 
}until($Splunk.Status -eq "Running")
Write-Host "Splunk Service restarted successfully" -ForegroundColor Green
 

In the folder of my script I have another folder named "zzz_config_base" and in that folder,
a "local" folder, and in the local folder is my deploymentclient.conf file which you can create.
That conf file has your information to point the forwarder to your Deployment Server.
