#**************************************************************************************
# Input Arguments
#**************************************************************************************
param ()
#**************************************************************************************

#**************************************************************************************
# References and Snapins
#**************************************************************************************
$snapin = Get-PSSnapin | Where-Object {$_.Name -eq 'Microsoft.SharePoint.Powershell'}
if ($snapin -eq $null) {
  Add-PsSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
}
# Might not be needed. Will clean up on the final stages.
$spCmdlets = Get-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction silentlycontinue
if ($spCmdlets -eq $null) { 
    Add-PSSnapin Microsoft.SharePoint.PowerShell
}
#************************************************************************************** 

#**************************************************************************************
# Variables and Constants
#**************************************************************************************
$displayName = "AD Sync Connection";
$forestName = "corp.contoso.com";
$includeOUs = "DC=corp,DC=contoso,DC=com";
$domain = "corp";
$userName = "spadmin";
$password = "password";


$useSsl = $false;
$useDisabledFilter = $false;
[string]$ldapFilter = "(&(objectCategory=person)(objectClass=user))";
[string]$claimProviderType = "Windows";
[string]$claimProviderId = "Windows";
[string]$claimIdMapAttribute = "samAccountName";

# Pseudo-constants
$DEFAULT_SITE_SUBSCRIPTION_ID = [Guid]::Empty
$INVOKE_ATTRIBUTES_NON_PUBLIC_MEMBERS = ([System.Reflection.BindingFlags]::NonPublic -bOr [System.Reflection.BindingFlags]::Instance)
#**************************************************************************************
  
#**************************************************************************************
# Functions
#**************************************************************************************
function ReadConfig()
{
    [xml]$configFile = Get-Content UPSConfig.xml;

   return $configFile;
}

function CheckForExistingSyncConnection($userProfileApp, $displayName)
{
     # Get Service Context before creating an instance of ConfigManager
     $serviceContext = [Microsoft.SharePoint.SPServiceContext]::GetContext($userProfileApp.ServiceApplicationProxyGroup, $DEFAULT_SITE_SUBSCRIPTION_ID);
     $upConfigMgr = New-Object Microsoft.Office.Server.UserProfiles.UserProfileConfigManager($serviceContext);
     if ($upConfigMgr.ConnectionManager.Contains($displayName)) {
        return $true;
     } 
     else
     {
        return $false;
     }
}

function ProvisionDirectSyncConnection($userProfileApp, $displayName, $forestName, $syncOU, $useSsl, $domain, $username, $password)
{
    try
    {
        Write-Host "Preparing to create new synchronization connection: " -NoNewline
        Write-Host $displayName -ForegroundColor blue
        $serviceContext = [Microsoft.SharePoint.SPServiceContext]::GetContext($userProfileApp.ServiceApplicationProxyGroup, $DEFAULT_SITE_SUBSCRIPTION_ID)
        $upConfigMgr = New-Object Microsoft.Office.Server.UserProfiles.UserProfileConfigManager($serviceContext)
        if ($upConfigMgr.ConnectionManager.Contains($displayName)) {
            Write-Host (" - Sync connection already exists. No action taken.") -ForegroundColor yellow
            $t1 = $upConfigMgr.ConnectionManager[$displayName];
            $t2 = New-Object [Microsoft.Office.Server.UserProfiles]::ActiveDirectoryImportConnection;

            $props = $t1.PropertyMapping;

            foreach($prop in $t1.PropertyMapping)
            {
                Write-Host $prop;
            }
            $adConn = $props.Connection;
            Write-Host "Here!";
        } else {
            # Some additional parameter setup and cleanup
            [Microsoft.Office.Server.UserProfiles.ConnectionType]$connType = [Microsoft.Office.Server.UserProfiles.ConnectionType]::ActiveDirectoryImport;
            $dcId = [Guid]::NewGuid()
            $securePassword = [System.Security.SecureString](ConvertTo-SecureString $password -AsPlainText -Force)
            if ($useSsl) {
                $isSslUsed = $true
            } else {
                $isSslUsed = $false
            }
            if ($useDisabledFilter) {
                $isDisabledFilterUsed = $true
            } else {
                $isDisabledFilterUsed = $false
            }
 
            # Parameters needed for naming context creation
            $isDomain = $true
            $excludedOU = New-Object System.Collections.Generic.List[[System.String]]
            $includedOU = New-Object System.Collections.Generic.List[[System.String]]
            $includedOU.Add($syncOU)
            $filterOutUnlicensed = New-Object System.Collections.Generic.List[[System.Boolean]]
            $filterOutUnlicensed.Add($false)
            $preferredDCs = New-Object System.Collections.Generic.List[[System.String]]
            $useOnlyPreferredDCs = $false
             
            # Perform an LDAP lookup to get the object ID for the target domain.
            $ldapLookupContext = "LDAP://" + $forestName
            $ldapUsername = $domain + "\" + $username
            $objDomain = New-Object System.DirectoryServices.DirectoryEntry($ldapLookupContext, $ldapUsername, $password)
            if ($useSsl) {
                $objDomain.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer
            }
            $ldapDomainDn = $objDomain.distinguishedName
            $ldapDomainGuid = New-Object Guid($objDomain.objectGUID)
                     
            # Creation of the objects needed to properly specify the OU for the sync connection
            Add-SPProfileSyncConnection -ProfileServiceApplication $userProfileApp.Id -ConnectionForestName $forestName -ConnectionDomain $domain -ConnectionUserName $username -ConnectionPassword $securePassword -ConnectionSynchronizationOU $syncOU;

            # Still here? Looks like everything worked.
            Write-Host (" - Sync connection successfully provisioned.") -ForegroundColor green
        }
    }
    catch [Exception] {
        
        $err = $_.Exception
        while ( $err.InnerException ) {
            $err = $err.InnerException
            Write-Host $err.Message
        }
    }
}

function CorrectUPSFlag()
{
    $upa = Get-SPServiceApplication | ? {$_.typename -like 'User Profile *'}
    if ($upa -eq $null)
    {
        Write-Host "No User Profile service application is found."
        Return
    }

    if ($upa.noILMUsed -eq $true)
    {
        Write-Host "Reverting back the NoILMUsed flag to false..."
        $upa.noILMUsed = $false    
        try
        {
            $upa.Update()
        }
        catch
        {
            Write-Host "Failed updating UPA once. Try it again..."
            $upa = Get-SPServiceApplication | ? {$_.typename -like 'User Profile *'}
            $upa.noILMUsed = $false 
            $upa.Update()
        }

        # check the flag after update
        $upa = Get-SPServiceApplication | ? {$_.typename -like 'User Profile *'}
        if ($upa.noILMUsed -eq $false)
        {
            Write-Host "Successfully reverted back the NoILMUsed flag to false."
        }
        else
        {
            Write-Host "Failed to revert back the flag. Please try running the script again."
            Return;
        }
    }
    else
    {
        Write-Host "The NOILMUsed flag is already set to false. "
    }

    # check sync service status
    $syncServices = @(Get-SPServiceinstance | ? {$_.typename -like 'User Profile Synchronization *'})
    $flag = $false
    foreach ($service in $syncServices)
    {
        if ($service.status -eq 'Online')
        {
            $flag = $true
            break
        }
    }

    if ($flag -eq $false)
    {
        Write-Host "The User Profile Synchronization service is not started in this farm. Please proceed with restarting the profile sync service when in need." 
    }
    else
    {
        Write-Host "All appears to be good."
    }

}

function Get-SPServiceContext([Microsoft.SharePoint.Administration.SPServiceApplication]$profileApp)
{
    if($profileApp -eq $null)
    {
        #----- Get first User Profile Service Application
        $profileApp = @(Get-SPServiceApplication | ? { $_.TypeName -eq "User Profile Service Application" })[0]
    }  
return [Microsoft.SharePoint.SPServiceContext]::GetContext(
        $profileApp.ServiceApplicationProxyGroup, 
        [Microsoft.SharePoint.SPSiteSubscriptionIdentifier]::Default) 
}

function ProvisionDirectSyncConnectionMain($userProfileApp, $displayName, $forestName, $syncOU, $useSsl, $useDisabledFilter, $ldapFilter, $domain, $username, $password, $claimProviderType, $claimProviderId, $claimIdMapAttribute)
{
    try 
    {
        Write-Host "Preparing to create new synchronization connection: " -NoNewline
        Write-Host $displayName -ForegroundColor blue
        $serviceContext = [Microsoft.SharePoint.SPServiceContext]::GetContext($userProfileApp.ServiceApplicationProxyGroup, $DEFAULT_SITE_SUBSCRIPTION_ID)
        $upConfigMgr = New-Object Microsoft.Office.Server.UserProfiles.UserProfileConfigManager($serviceContext)
        if ($upConfigMgr.ConnectionManager.Contains($displayName)) {
            Write-Host (" - Sync connection already exists. No action taken.") -ForegroundColor yellow
        } else {
            # Some additional parameter setup and cleanup
            $connType = [Microsoft.Office.Server.UserProfiles.ConnectionType]::ActiveDirectoryImport
            $dcId = [Guid]::NewGuid()
            $securePassword = [System.Security.SecureString](ConvertTo-SecureString $password -AsPlainText -Force)
            if ($useSsl) {
                $isSslUsed = $true
            } else {
                $isSslUsed = $false
            }
            if ($useDisabledFilter) {
                $isDisabledFilterUsed = $true
            } else {
                $isDisabledFilterUsed = $false
            }
 
            # Parameters needed for naming context creation
            $isDomain = $true
            $excludedOU = New-Object System.Collections.Generic.List[[System.String]]
            $includedOU = New-Object System.Collections.Generic.List[[System.String]]
            $includedOU.Add($syncOU)
            $filterOutUnlicensed = New-Object System.Collections.Generic.List[[System.Boolean]]
            $filterOutUnlicensed.Add($false)
            $preferredDCs = New-Object System.Collections.Generic.List[[System.String]]
            $useOnlyPreferredDCs = $false
             
            # Perform an LDAP lookup to get the object ID for the target domain.
            $ldapLookupContext = "LDAP://" + $forestName
            $ldapUsername = $domain + "\" + $username
            $objDomain = New-Object System.DirectoryServices.DirectoryEntry($ldapLookupContext, $ldapUsername, $password)
            if ($useSsl) {
                $objDomain.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer
            }
            $ldapDomainDn = $objDomain.distinguishedName
            $ldapDomainGuid = New-Object Guid($objDomain.objectGUID)
                     
            # Creation of the objects needed to properly specify the OU for the sync connection
            $dnCtx = New-Object Microsoft.Office.Server.UserProfiles.DirectoryServiceNamingContext(
                $ldapDomainDn, $forestName, $isDomain, $ldapDomainGuid, $includedOU, $excludedOU, $preferredDCs, $useOnlyPreferredDCs)
            $namingContext = New-Object System.Collections.Generic.List[[Microsoft.Office.Server.UserProfiles.DirectoryServiceNamingContext]]
            $namingContext.Add($dnCtx)
            $ncParam = [System.Collections.Generic.List[Microsoft.Office.Server.UserProfiles.DirectoryServiceNamingContext]]$namingContext
 
            # Since the method we're about to invoke is internal, some hoops have to be jumped through
            # to call it via PowerShell and Reflection
            $paramTypes = @([Microsoft.Office.Server.UserProfiles.ConnectionType], [System.Guid], `
                            [System.String], [System.String], [System.Boolean], [System.Boolean], [System.String], `
                            [System.String], [System.String], [System.Security.SecureString], `
                            [System.Collections.Generic.List[Microsoft.Office.Server.UserProfiles.DirectoryServiceNamingContext]], `
                            [System.String], [System.String], [System.String])
            $addConnMethodInfo = [Microsoft.Office.Server.UserProfiles.ConnectionManager].GetMethod("AddActiveDirectoryImportConnection", `
                                 $INVOKE_ATTRIBUTES_NON_PUBLIC_MEMBERS, $null, $paramTypes, $null)
            $methodParams = @($connType, $dcId, $displayName, $forestName, $isSslUsed, $isDisabledFilterUsed, $ldapFilter, `
                            $domain, $username, $securePassword, $ncParam, $claimProviderType, $claimProviderId, $claimIdMapAttribute)
            $addConnMethodInfo.Invoke($upConfigMgr.ConnectionManager, $methodParams)
     
            # Still here? Looks like everything worked.
            Write-Host (" - Sync connection successfully provisioned.") -ForegroundColor green
        }
    } 
    catch [Exception] {
        Write-Error $Error[0]
        $err = $_.Exception
        while ( $err.InnerException ) {
            $err = $err.InnerException
            Write-Host $err.Message
        }
    }
}
 


#**************************************************************************************
 
 
#**************************************************************************************
# Primary Statement Blocks
#**************************************************************************************

$upa = Get-SPServiceApplication | where {$_.TypeName -like "User Profile *"};
$upaProxy = Get-SPServiceApplicationProxy | where {$_.TypeName -like "User Profile *"};

$serviceContext= Get-SPServiceContext
$configManager = New-Object Microsoft.Office.Server.UserProfiles.UserProfileConfigManager($serviceContext)
      
if($configManager.IsSynchronizationRunning() -eq $false)
{
    if(-not (CheckForExistingSyncConnection $upa $displayName))
    {
        ProvisionDirectSyncConnection $upa $displayName $forestName $includeOUs $false $domain $userName $password;
    }
    else
    {
        Write-Host " - Sync connection already exists. No action taken." -ForegroundColor Yellow;
    }
    $configManager.StartSynchronization($true);
    Write-Host " - Started Synchronizing" -ForegroundColor green;
}
else
{
    Write-Host " - Already Synchronizing" -ForegroundColor green;
}
   
   

#**************************************************************************************