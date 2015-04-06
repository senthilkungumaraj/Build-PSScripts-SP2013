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
$logFile = $myinvocation.mycommand.path.Replace($MyInvocation.MyCommand.name,"") + 'Log_ConfigureUPS_' + $(Get-Date -format "dd_MM_yyyy_HH_mm_ss") + '.csv';
# Setup initial paths
$settingsFile = $myinvocation.mycommand.path.Replace($MyInvocation.MyCommand.name,"") + "Configuration.xml"

# Change the following three lines with your environment variables
$sqlServerName =  "SPDEVSQL";
$newAcct = "corp\spadmin";
$newPass = "password";


# Store the values from the CSV into variables - Do not change
$serviceAppName = "User Profile Service Application";
$serviceAppProxyName = "User Profile Service Application Proxy";

$mmsServiceAppName = "Managed Metadata Service Application";
$mmsServiceAppProxyName = "Managed Metadata Service Application Proxy";
                
$appPoolName = "SharePoint Web Services System";
$StatAccountLookup = $newAcct;
$profileDatabaseServer = $sqlServerName;
$profileDatabaseName = "UPS_Profile";
$socialDatabaseServer = $sqlServerName;
$socialDatabaseName = "UPS_Social";
$syncDatabaseServer = $sqlServerName;
$syncDatabaseName = "UPS_Sync"; 
#**************************************************************************************

#**************************************************************************************
# Functions
#**************************************************************************************
function New-StatSPProfileServiceApplication
{
	
	
    # Conduct Version Compatibility Check
    if (($true))
    {
        # Initialize Progress Variables
        [int]$progressNumPhases = 1
        [int]$progressNumPhasesComplete = 0
        [int]$progressTotalTasks = 6
        [int]$progressNumTasksComplete = 0
        [int]$progressTotal = 0
        [int]$progressBarId = 100
        $progressActivityName = "User Profile Service Application Setup"
        $startTime = [System.DateTime]::Now

        #

        Write-Host
        Write-Host $progressActivityName

        $progressCurrentOperation = "Processing the configuration file"
	    Write-Progress -Id $progressBarId -Activity $progressActivityName -Status "Reading Input Files" -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation
        Write-Verbose "$progressCurrentOperation"

       

        if ($true)
        {
	        foreach ($settingRow in $settings)
	        {
                # Initialize object variables
                $appPool = $null
                $serviceApp = $null
                $serviceAppProxy = $null

				Write-Host "Reading parameters ...";
				Write-Host "`tSQL Instance Name : $sqlServerName";
				Write-Host "`tService Account : $newAcct";
				Write-Host "`tService App Pool Name : $appPoolName";
				Write-Host "`tProfile Database Server : $profileDatabaseServer";
				Write-Host "`tProfile Database : $profileDatabaseName";
				Write-Host "`tSocial Database Server : $socialDatabaseServer";
				Write-Host "`tSocial Database : $socialDatabaseName";
				Write-Host "`tSync Database Server : $syncDatabaseServer";
				Write-Host "`tSync Database : $syncDatabaseName";
				Write-Host "`tService App Name : $serviceAppName";
				Write-Host "`tService App Proxy Name : $serviceAppProxyName";
            
            } # End for each on settings file

            try
            {
                try
                {
                    $existingUPSAppId = (Get-SPServiceApplication | Where-Object {$_.TypeName -like "User Profile*"} | Select-Object id).id.ToString();
                    Remove-SPServiceApplication -id $existingUPSAppId  -RemoveData -Confirm:$false # -ErrorAction SilentlyContinue;
			    }
			    catch{}

			    try
			    {
				    $existingUPSAppProxyId = (Get-SPServiceApplicationProxy | Where-Object {$_.TypeName -like "User Profile*"} | Select-Object id).id.ToString();
				    Remove-SPServiceApplicationProxy -id $existingUPSAppProxyId  -RemoveData -Confirm:$false  -ErrorAction SilentlyContinue;
			    }
			    catch{}

                # region Task 1 - Establish the Application Pool
                Write-Host "     Creating Service Application ($serviceAppName)"
	            $progressCurrentOperation = "Configuring the Service Application Pool"
                Write-Progress -Id $progressBarId -Activity $progressActivityName -Status ("Creating Service Application (" + $serviceAppName + ")") -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation
                Write-Verbose "$progressCurrentOperation"

                # Determine whether to use default app pool, an existing app pool other than the default, or create a new app pool
                
                # Attempt to get a reference to the application pool requested
                $appPool = Get-SPServiceApplicationPool $appPoolName | ? {$_.Name -eq $appPoolName} -ErrorAction SilentlyContinue
                

	            # Increment the progress variables for the current task
	            $progressNumTasksComplete++
	            $progressTotal = CalculateProgress $progressNumTasksComplete $progressTotalTasks $progressNumPhases $progressNumPhasesComplete

                #endregion Task 1

                #region Task 2 - Create the new Service Application
	            $progressCurrentOperation = "Creating a new SharePoint Service Application"
                Write-Progress -Id $progressBarId -Activity $progressActivityName -Status ("Creating Service Application (" + $serviceAppName + ")") -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation
                Write-Verbose "$progressCurrentOperation"

                # Check to see if the item exists...if not create it
                if ( (Get-SPServiceApplication -Name $serviceAppName -ErrorAction SilentlyContinue) -eq $null )
                {
                    try
                    {
                        $serviceApp = New-SPProfileServiceApplication -Name $serviceAppName -ApplicationPool $appPool -ProfileDBServer $profileDatabaseServer -ProfileDBName $profileDatabaseName -SocialDBServer $socialDatabaseServer -SocialDBName $socialDatabaseName -ProfileSyncDBServer $syncDatabaseServer -ProfileSyncDBName $syncDatabaseName 
                    }
                    catch
                    {
                        Write-Host "          Failed to create service application ($serviceAppName)" -ForegroundColor Red
                        throw
                    }
                }
                else
                {
                    Write-Host "          A Service Application with the same name ($serviceAppName) already exists" -ForegroundColor Yellow
                    throw (New-Object ApplicationException)
                }
                       
	            # Increment the progress variables for the current task
	            $progressNumTasksComplete++
	            $progressTotal = CalculateProgress $progressNumTasksComplete $progressTotalTasks $progressNumPhases $progressNumPhasesComplete

                #endregion Task 2

                #region Task 3 - Create the new Service Application Proxy
	            $progressCurrentOperation = "Creating a new Service Application Proxy"
                Write-Progress -Id $progressBarId -Activity $progressActivityName -Status ("Creating Service Application (" + $serviceAppName + ")") -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation
                Write-Verbose "$progressCurrentOperation"

                # Check to see if the item exists...if not create it
                if ( (Get-SPServiceApplicationProxy | Where-Object {$_.DisplayName -eq $serviceAppProxyName} -ErrorAction SilentlyContinue) -eq $null )
                {
                    try
                    {
                        $serviceAppProxy = New-SPProfileServiceApplicationProxy -Name $serviceAppProxyName -ServiceApplication $serviceApp -DefaultProxyGroup
                    }
                    catch
                    {
                        Write-Host "          Failed to create service application proxy ($serviceAppProxy)" -ForegroundColor Red
                        throw
                    }
                }
                else
                {
                    Write-Host "          A Service Application Proxy with the same name ($serviceAppProxyName) already exists" -ForegroundColor Yellow
                    throw (New-Object ApplicationException)
                }
                       
	            # Increment the progress variables for the current task
	            $progressNumTasksComplete++
	            $progressTotal = CalculateProgress $progressNumTasksComplete $progressTotalTasks $progressNumPhases $progressNumPhasesComplete

                #endregion Task 3
                
                #region Task 4 - Clean-up the DB Permissions in order to overcome Microsoft's PowerShell provisioning bug
	            $progressCurrentOperation = "Cleaning up database permissions"
                Write-Progress -Id $progressBarId -Activity $progressActivityName -Status ("Creating Service Application (" + $serviceAppName + ")") -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation
                Write-Verbose "$progressCurrentOperation"
                
                # Remove this
                if($false)
                {
                try
                {
                    # Attempt to get a reference to the farm service account
                    $farmServiceAcct = Get-StatAccount -ConfigPath $ConfigPath -StatAccountLookup $StatAccountLookup_FarmService
                }
                catch
                {
                    Write-Host "          The StatAccountLookup provided for the farm service account" -ForegroundColor Red
                    Write-Host "          ($StatAccountLookup_FarmService) was either not present in the" -ForegroundColor Red
                    Write-Host "          ServiceAccounts.csv or is no longer registered as a valid" -ForegroundColor Red
                    Write-Host "          SharePoint Managed Service Account" -ForegroundColor Red
                    throw
                }

                try
                {
                    # Setup the Alter command
                    $alterSQL = "ALTER USER [" + ($farmServiceAcct.UserNameWithDomain) + "] WITH DEFAULT_SCHEMA = dbo"

                    Write-Verbose "Altering Farm Service Default Schema for Profile DB..."
                    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection
                    $SqlConnectionString = "Server=" + $profileDatabaseServer + ";Database=" + $profileDatabaseName + ";Integrated Security=True"
                    $sqlConnection.ConnectionString = $SqlConnectionString
     
                    $sqlCmd = New-Object System.Data.SqlClient.SqlCommand
                    $sqlCmd.CommandText = $alterSQL
                    $sqlCmd.Connection = $sqlConnection 
                    $sqlConnection.Open() 
                    $sqlCmd.ExecuteNonQuery() > $null
                    $sqlConnection.Close() 

                    Write-Verbose "Altering Farm Service Default Schema for Social DB..."
                    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection
                    $SqlConnectionString = "Server=" + $socialDatabaseServer + ";Database=" + $socialDatabaseName + ";Integrated Security=True"
                    $sqlConnection.ConnectionString = $SqlConnectionString
     
                    $sqlCmd = New-Object System.Data.SqlClient.SqlCommand
                    $sqlCmd.CommandText = $alterSQL
                    $sqlCmd.Connection = $sqlConnection 
                    $sqlConnection.Open() 
                    $sqlCmd.ExecuteNonQuery() > $null
                    $sqlConnection.Close() 

                    Write-Verbose "Altering Farm Service Default Schema for Sync DB..."
                    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection
                    $SqlConnectionString = "Server=" + $syncDatabaseServer + ";Database=" + $syncDatabaseName + ";Integrated Security=True"
                    $sqlConnection.ConnectionString = $SqlConnectionString
     
                    $sqlCmd = New-Object System.Data.SqlClient.SqlCommand
                    $sqlCmd.CommandText = $alterSQL
                    $sqlCmd.Connection = $sqlConnection 
                    $sqlConnection.Open() 
                    $sqlCmd.ExecuteNonQuery() > $null
                    $sqlConnection.Close() 

                    Write-Verbose "Restarting SPTimerV4..." 
                    restart-service SPTimerV4 > $null

                }
                catch
                {
                    Write-Host "          Failed to clean-up database permissions" -ForegroundColor Red
                    throw
                }
                }
	            # Increment the progress variables for the current task
	            $progressNumTasksComplete++
	            $progressTotal = CalculateProgress $progressNumTasksComplete $progressTotalTasks $progressNumPhases $progressNumPhasesComplete

                #endregion Task 4

                #region Task 5 - Start the User Profile Service

                if($true) {
                $fimSvc = Get-Service | ? {$_.DisplayName -eq "Forefront Identity Manager Service"};

                $fimSvcObj = gwmi win32_service -filter "name='FIMService'";

                Set-Service $fimSvc.Name -startuptype automatic;

                $ChangeStatus = $fimSvcObj.change($null,$null,$null,$null,$null,$null,$newAcct,$newPass,$null,$null,$null) 
                If ($ChangeStatus.ReturnValue -eq "0")  
                    {write-host "`tSucessfully Changed User Account"} 

                $ChangeStatus = $null;
                
                $fimSyncSvc  = Get-Service | ? {$_.DisplayName -eq "Forefront Identity Manager Synchronization Service"};

                Set-Service $fimSyncSvc.Name -startuptype automatic;

                $fimSyncSvcObj = gwmi win32_service -filter "name='FIMSynchronizationService'";

                $ChangeStatus = $fimSyncSvcObj.change($null,$null,$null,$null,$null,$null,$newAcct,$newPass,$null,$null,$null) 
                If ($ChangeStatus.ReturnValue -eq "0")  
                    {write-host "`tSucessfully Changed User Account"} 
                
                }

	            $progressCurrentOperation = "Starting the User Profile Service"

                $serviceInstanceType = "User Profile Service"
                $serviceInstanceServer = (Get-ChildItem env:computername).value

                Write-Progress -Id $progressBarId -Activity $progressActivityName -Status ("Starting (" + $serviceInstanceType + " on Server " + $serviceInstanceServer +")") -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation
                Write-Verbose "$progressCurrentOperation"
                Write-Host "     Starting the SharePoint Service Instance ($serviceInstanceType)"

                $serviceInstance = $(Get-SPServiceInstance | where-object {$_.TypeName -match $serviceInstanceType} | 
                                                             where-object {$_.Server -match $serviceInstanceServer})
                
                $svcInst = Get-SPServiceInstance -Identity $serviceInstance;

                if($svcInst -ne $null -and $svcInst.Status -ne "Online")
                {
                    Start-SPServiceInstance -Identity $serviceInstance > $null  
                }

                # Wait for the UPS Service Instance to provision
                while ($serviceInstance.Status -ne "Online")
                {
                    $currentRuntime = [System.DateTime]::Now - $startTime
                    Write-Progress -Id $progressBarId -Activity $progressActivityName -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation ("The current operation has been running for {0}:{1}:{2}" -f $currentRuntime.Hours.ToString("00"), $currentRuntime.Minutes.ToString("00"), $currentRuntime.Seconds.ToString("00"))
                    # Refresh our service instance object
                    $serviceInstance = $(Get-SPServiceInstance | where-object {$_.TypeName -match $serviceInstanceType} | 
                                                                 where-object {$_.Server -match $serviceInstanceServer})

                    Start-Sleep -Seconds 10
                }

	            # Increment the progress variables for the current task
	            $progressNumTasksComplete++
	            $progressTotal = CalculateProgress $progressNumTasksComplete $progressTotalTasks $progressNumPhases $progressNumPhasesComplete

                # Reset the Service Instance variable
                $serviceInstance = $null

                # endregion

                # region Task 6 - Start the Synchronization Service
	            $progressCurrentOperation = "Starting the User Profile Synchronization Service"

                $serviceInstanceType = "User Profile Synchronization Service"
                $serviceInstanceServer = (Get-ChildItem env:computername).value

                Write-Progress -Id $progressBarId -Activity $progressActivityName -Status ("Starting (" + $serviceInstanceType + " on Server " + $serviceInstanceServer +")") -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation
                Write-Verbose "$progressCurrentOperation"
                Write-Host "     Starting the SharePoint Service Instance ($serviceInstanceType) on Server ($serviceInstanceServer)"

                $serviceInstance = $(Get-SPServiceInstance | where-object {$_.TypeName -match $serviceInstanceType} | 
                                                             where-object {$_.Server -match $serviceInstanceServer})



                $serviceApp = Get-SPServiceApplication | ? {$_.Name -eq $serviceAppName};

               

                # Removing these until proven needed for SP2013                
                $serviceInstance.Status = [Microsoft.SharePoint.Administration.SPObjectStatus]::Provisioning 
                $serviceInstance.IsProvisioned = $false 
                $serviceInstance.UserProfileApplicationGuid = $serviceApp.Id 
                $serviceInstance.Update() 
                
                $serviceApp.SetSynchronizationMachine($serviceInstance.Server.Address, $serviceInstance.Id, $newAcct, $newPass) 
                
                $svcInst = Get-SPServiceInstance -Identity $serviceInstance;

                if($svcInst -ne $null -and $svcInst.Status -ne "Online")
                {
                    Start-SPServiceInstance -Identity $serviceInstance > $null
                }

                $fimSvcObj = gwmi win32_service -filter "name='FIMService'";

                $StartStatus = $fimSvcObj.StartService();
                If ($StartStatus.ReturnValue -eq "0")  
                {write-host "$ServerN -> Service Started Successfully"} 

                $fimSvc = Get-Service | ? {$_.DisplayName -eq "Forefront Identity Manager Service"};
                $fimSvc.Start;

                Write-Host "This next will take atleast 15 to 20 minutes. Please wait...";

                # Wait for the UPS Service Instance to provision
                while ($serviceInstance.Status -ne "Online")
                {
                    $currentRuntime = [System.DateTime]::Now - $startTime
                    Write-Progress -Id $progressBarId -Activity $progressActivityName -PercentComplete $progressTotal -CurrentOperation $progressCurrentOperation ("The current operation has been running for {0}:{1}:{2}" -f $currentRuntime.Hours.ToString("00"), $currentRuntime.Minutes.ToString("00"), $currentRuntime.Seconds.ToString("00"))

                    # Refresh our service instance object
                    $serviceInstance = $(Get-SPServiceInstance | where-object {$_.TypeName -match $serviceInstanceType} | 
                                                                 where-object {$_.Server -match $serviceInstanceServer})
                    

                    Start-Sleep -Seconds 10;
                }

                # Reset IIS
                iisreset

	            # Increment the progress variables for the current task
	            $progressNumTasksComplete++
	            $progressTotal = CalculateProgress $progressNumTasksComplete $progressTotalTasks $progressNumPhases $progressNumPhasesComplete

                #endregion
                

            }
            catch [ApplicationException]
            {
            }
		    catch
		    { 
                Write-Host

                # Output the full error text
				Write-Error $_

		    }
		    finally
		    {
                # Clean-up code here if needed
		    }

        } # End settings file Null Check

        Write-Progress -Id $progressBarId -Activity $progressActivityName -Status "Finishing" -PercentComplete 100 -CurrentOperation "" -Completed
        Write-Host "$progressActivityName - Finished"
    }
    else
    {
	    Write-Host "     ERROR:" -ForegroundColor Red
	    Write-Host "     This script requires configuration files at version" $firstCompatibleVersion "or higher." -ForegroundColor Red
	    Write-Host "     Use the Get-Help command for a complete list of the configuration files used by this script." -ForegroundColor Red

    }
}

function CalculateProgress($progressNumTasksComplete, $progressTotalTasks, $progressNumPhases, $progressNumPhasesComplete)
{
    $totalComplete = ($progressNumTasksComplete / $progressTotalTasks) * 100;
    return $totalComplete;
}

function BuildMMS()
{
    try
    {
        $existingMMSAppId = (Get-SPServiceApplication | Where-Object {$_.TypeName -like "Managed Metadata*"} | Select-Object id).id.ToString();
        Remove-SPServiceApplication -id $existingMMSAppId  -RemoveData -Confirm:$false  -ErrorAction SilentlyContinue;
    }
	catch{}

	try
	{
	    $existingMMSAppProxyId = (Get-SPServiceApplicationProxy | Where-Object {$_.TypeName -like "Managed Metadata*"} | Select-Object id).id.ToString();
		Remove-SPServiceApplicationProxy -id $existingMMSAppProxyId  -RemoveData -Confirm:$false  -ErrorAction SilentlyContinue;
    }
	catch{}

    $appPool = $null;
    $serviceApp = $null;
    $serviceAppProxy = $null;

    # Attempt to get a reference to the application pool requested
    $appPool = Get-SPServiceApplicationPool $appPoolName | ? {$_.Name -eq $appPoolName} -ErrorAction SilentlyContinue

    # Check to see if the item exists...if not create it
    if ( (Get-SPServiceApplication -Name $mmsServiceAppName -ErrorAction SilentlyContinue) -eq $null )
    {
        try
        {
            $serviceApp = New-SPMetadataServiceApplication -Name $mmsServiceAppName -ApplicationPool $appPool -DatabaseName "MetadataDB";
            Write-Host "`tCreate Managed Metadata Service Application";
        }
        catch
        {
            Write-Host "          Failed to create service application ($mmsServiceAppName)" -ForegroundColor Red
            throw
        }
    }
    else
    {
        Write-Host "          A Service Application with the same name ($mmsServiceAppName) already exists" -ForegroundColor Yellow
        throw (New-Object ApplicationException)
    }

    # Check to see if the item exists...if not create it
    if ( (Get-SPServiceApplicationProxy | Where-Object {$_.DisplayName -eq $mmsServiceAppProxyName} -ErrorAction SilentlyContinue) -eq $null )
    {
        try
        {
            $serviceAppProxy = New-SPMetadataServiceApplicationProxy -Name $mmsServiceAppProxyName -ServiceApplication $serviceApp -DefaultProxyGroup;
            Write-Host "`tCreate Managed Metadata Service Application Proxy";
        }
        catch
        {
            Write-Host "          Failed to create service application proxy ($mmServiceAppProxyName)" -ForegroundColor Red
            throw
        }
    }
    else
    {
        Write-Host "          A Service Application Proxy with the same name ($mmServiceAppProxyName) already exists" -ForegroundColor Yellow
        throw (New-Object ApplicationException)
    }
}
#**************************************************************************************

#**************************************************************************************
# Primary Statement Blocks
#**************************************************************************************

Write-Host "**********************************************************************************************************";
Write-Host "Configuring User Profile Service";
Write-Host "**********************************************************************************************************";
Start-Transcript -Path $logFile;
New-StatSPProfileServiceApplication;
BuildMMS
Stop-Transcript;
Write-Host "**********************************************************************************************************";

#**************************************************************************************