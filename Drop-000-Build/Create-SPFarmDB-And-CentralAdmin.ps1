#**************************************************************************************
# Input Arguments
#**************************************************************************************
 param()
#**************************************************************************************

#**************************************************************************************
# References and Snapins
#**************************************************************************************
$snapin = Get-PSSnapin | Where-Object {$_.Name -eq 'Microsoft.SharePoint.Powershell'}
if ($snapin -eq $null) {
  Add-PsSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
#**************************************************************************************

#**************************************************************************************
# Variables and Constants
#**************************************************************************************
$logFile = $myinvocation.mycommand.path.Replace($MyInvocation.MyCommand.name,"") + 'Log_BuildFarm_' + $(Get-Date -format "dd_MM_yyyy_HH_mm_ss") + '.csv';

$sqlServerName =  $env:COMPUTERNAME;

$SysAdmin = "corp\spadmin"
$SysAdminPassword = "password"

[string]$AliasName = "SPDEVSQL"
[string]$configPassphrase = "MySharePointPassPhrase!"
$s_configPassphrase = (ConvertTo-SecureString -String $configPassphrase -AsPlainText -force) 
[string]$farmUser = "corp\spadmin"
[string]$farmPassword = "password"

[string]$dbConfig = "Config_DB"
[string]$dbCentralAdmin = "SP2013_CentralAdmin_ContentDB"
[int]$caPort = 2013 
[string]$caAuthProvider = "NTLM"

#**************************************************************************************

#**************************************************************************************
# Functions
#**************************************************************************************


Function WriteLine
{
    Write-Host -ForegroundColor White "--------------------------------------------------------------"
}

# ---------------------------------------------------------------------
Function CreateSPFarmDBAndCentralAdmin
{
	Try
	{
		# Create the farm 
		WriteLine
		Write-Host -ForegroundColor White " - Creation of the SharePoint farm ..."
		  
		WriteLine
		Write-Output "Creating the configuration database $dbConfig"
		New-SPConfigurationDatabase -DatabaseName $dbConfig -DatabaseServer $AliasName -AdministrationContentDatabaseName $dbCentralAdmin -Passphrase  $s_configPassphrase -FarmCredentials $mycred 

		WriteLine
		# Check to make sure the farm exists and is running. if not, end the script 
		WriteLine
		$farm = Get-SPFarm
		if (!$farm -or $farm.Status -ne "Online") { 
			Write-Output "Farm was not created or is not running"
			exit 
		} 

		WriteLine  
		Write-Output "Create the Central Administration site on port $caPort"
		New-SPCentralAdministration -Port $caPort -WindowsAuthProvider $caAuthProvider
		WriteLine
		  
		# Perform the config wizard tasks 
		  
		WriteLine
		Write-Output "Install Help Collections"
		Install-SPHelpCollection -All 
		  
		Write-Output "Initialize security"
		Initialize-SPResourceSecurity 
		  
		Write-Output "Install services"
		Install-SPService 
		  
		Write-Output "Register features"
		Install-SPFeature -AllExistingFeatures -Force
		  
		Write-Output "Install Application Content"
		Install-SPApplicationContent

		WriteLine
		# ---------------------------------------------------------------------
 	}
	catch  [system.exception]
	{
        Write-Host -ForegroundColor Yellow " ->> Create SPFarm DB And Central Admin caught a system exception"
		Write-Host -ForegroundColor Red "Exception Message:", $_.Exception.ToString()
	}
	finally
	{
        WriteLine
	}
}

#**************************************************************************************
# Primary Statement Blocks
#**************************************************************************************
$password = ConvertTo-SecureString $SysAdminPassword -AsPlainText -Force;
$myCred = New-Object System.Management.Automation.PSCredential $SysAdmin, $password;

CreateSPFarmDBAndCentralAdmin;

#Start Central Administration 
WriteLine
Write-Output "Starting Central Administration"
& 'C:\Program Files\Common Files\Microsoft Shared\Web Server Extensions\15\BIN\psconfigui.exe' -cmd showcentraladmin 
  
Write-Output "Farm build complete."
WriteLine
#**************************************************************************************
