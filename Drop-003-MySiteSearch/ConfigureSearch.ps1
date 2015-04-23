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
$serverName = $env:COMPUTERNAME;
$inputFile = $myinvocation.mycommand.path.Replace($MyInvocation.MyCommand.name,"") + 'AutoSPInstallerInput.xml';
$t1 = (Get-Content $inputFile) -replace ('localhost', $env:COMPUTERNAME);
[xml]$global:xmlinput = $t1; 
#**************************************************************************************

#**************************************************************************************
# Functions
#**************************************************************************************
Function SetupManagedPaths([System.Xml.XmlElement]$webApp)
{
    $url = $webApp.Url + ":" + $webApp.Port
    If ($url -like "*localhost*") {$url = $url -replace "localhost","$env:COMPUTERNAME"}
    Write-Host -ForegroundColor White " - Setting up managed paths for `"$url`""

    If ($webApp.ManagedPaths)
    {
        ForEach ($managedPath in $webApp.ManagedPaths.ManagedPath)
        {
            If ($managedPath.Delete -eq "true")
            {
                Write-Host -ForegroundColor White "  - Deleting managed path `"$($managedPath.RelativeUrl)`" at `"$url`""
                Remove-SPManagedPath -Identity $managedPath.RelativeUrl -WebApplication $url -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
            Else
            {
                If ($managedPath.Explicit -eq "true")
                {
                    Write-Host -ForegroundColor White "  - Setting up explicit managed path `"$($managedPath.RelativeUrl)`" at `"$url`" and HNSCs..."
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -WebApplication $url -Explicit -ErrorAction SilentlyContinue | Out-Null
                    # Let's create it for host-named site collections too, in case we have any
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -HostHeader -Explicit -ErrorAction SilentlyContinue | Out-Null
                }
                Else
                {
                    Write-Host -ForegroundColor White "  - Setting up managed path `"$($managedPath.RelativeUrl)`" at `"$url`" and HNSCs..."
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -WebApplication $url -ErrorAction SilentlyContinue | Out-Null
                    # Let's create it for host-named site collections too, in case we have any
                    New-SPManagedPath -RelativeUrl $managedPath.RelativeUrl -HostHeader -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    }

    Write-Host -ForegroundColor White " - Done setting up managed paths at `"$url`""
}

Function ImportWebAdministration
{
    $queryOS = Gwmi Win32_OperatingSystem
    $queryOS = $queryOS.Version
    Try
    {
        If ($queryOS.Contains("6.0")) # Win2008
        {
            If (!(Get-PSSnapin WebAdministration -ErrorAction SilentlyContinue))
            {
                If (!(Test-Path $env:ProgramFiles\IIS\PowerShellSnapin\IIsConsole.psc1))
                {
                    Start-Process -Wait -NoNewWindow -FilePath msiexec.exe -ArgumentList "/i `"$env:SPbits\PrerequisiteInstallerFiles\iis7psprov_x64.msi`" /passive /promptrestart"
                }
                Add-PSSnapin WebAdministration
            }
        }
        Else # Win2008R2 or Win2012
        {
            Import-Module WebAdministration
        }
    }
    Catch
    {
        Throw " - Could not load IIS Administration module."

    }
}

function SetSearchCenterUrl ($searchCenterURL, $searchApp)
{
    Start-Sleep 10 # Wait for stuff to catch up so we don't get a concurrency error
    $searchApp.SearchCenterUrl = $searchCenterURL
    $searchApp.Update()
}

Function EnsureFolder ($path)
{
        If (!(Test-Path -Path $path -PathType Container))
        {
            Write-Host -ForegroundColor White " - $path doesn't exist; creating..."
            Try
            {
                New-Item -Path $path -ItemType Directory | Out-Null
            }
            Catch
            {
                Write-Warning "$($_.Exception.Message)"
                Throw " - Could not create folder $path!"
            }
        }
}

Function AddResourcesLink([string]$title,[string]$url)
{
    $centraladminapp = Get-SPWebApplication -IncludeCentralAdministration | ? {$_.IsAdministrationWebApplication}
    $centraladminurl = $centraladminapp.Url
    $centraladmin = (Get-SPSite $centraladminurl)

    $item = $centraladmin.RootWeb.Lists["Resources"].Items | Where { $_["URL"] -match ".*, $title" }
    If ($item -eq $null )
    {
        $item = $centraladmin.RootWeb.Lists["Resources"].Items.Add();
    }

    $url = $centraladminurl + $url + ", $title";
    $item["URL"] = $url;
    $item.Update();
}

function Update-SearchContentAccessAccount ($saName, $sa, $caa, $caapwd)
{
    try
    {
        Write-Host -ForegroundColor White "  - Setting content access account for $saName..."
        $sa | Set-SPEnterpriseSearchServiceApplication -DefaultContentAccessAccountName $caa -DefaultContentAccessAccountPassword $caapwd -ErrorVariable err
    }
    catch
    {
        if ($err -like "*update conflict*")
        {
            Write-Warning "An update conflict error occured, trying again."
            Update-SearchContentAccessAccount $saName, $sa, $caa, $caapwd
            $sa | Set-SPEnterpriseSearchServiceApplication -DefaultContentAccessAccountName $caa -DefaultContentAccessAccountPassword $caapwd -ErrorVariable err
        }
        else
        {
            throw $_
        }
    }
    finally {Clear-Variable err}
}

Function Get-ApplicationPool([System.Xml.XmlElement]$appPoolConfig)
{
    # Try and get the application pool if it already exists
    # SLN: Updated names
    $pool = Get-SPServiceApplicationPool -Identity $appPoolConfig.Name -ErrorVariable err -ErrorAction SilentlyContinue
    If ($err) {
        # The application pool does not exist so create.
        Write-Host -ForegroundColor White "  - Getting $($searchServiceAccount.Username) account for application pool..."
        $managedAccountSearch = (Get-SPManagedAccount -Identity $searchServiceAccount.Username -ErrorVariable err -ErrorAction SilentlyContinue)
        If ($err) {
            If (!([string]::IsNullOrEmpty($searchServiceAccount.Password)))
            {
                $appPoolConfigPWD = (ConvertTo-SecureString $searchServiceAccount.Password -AsPlainText -force)
                $accountCred = New-Object System.Management.Automation.PsCredential $searchServiceAccount.Username,$appPoolConfigPWD
            }
            Else
            {
                $accountCred = Get-Credential $searchServiceAccount.Username
            }
            $managedAccountSearch = New-SPManagedAccount -Credential $accountCred
        }
        Write-Host -ForegroundColor White "  - Creating $($appPoolConfig.Name)..."
        $pool = New-SPServiceApplicationPool -Name $($appPoolConfig.Name) -Account $managedAccountSearch
    }
    Return $pool
}

Function Get-DBPrefix ([xml]$xmlinput)
{
    $dbPrefix = $xmlinput.Configuration.Farm.Database.DBPrefix
    If (($dbPrefix -ne "") -and ($dbPrefix -ne $null)) {$dbPrefix += "_"}
    If ($dbPrefix -like "*localhost*") {$dbPrefix = $dbPrefix -replace "localhost","$env:COMPUTERNAME"}
    return $dbPrefix
}

Function WriteLine
{
    Write-Host -ForegroundColor White "--------------------------------------------------------------"
}

function Get-MajorVersionNumber ([xml]$xmlinput)
{
    # Create hash tables with major version to product year mappings & vice-versa
    $spYears = @{"14" = "2010"; "15" = "2013"}
    $spVersions = @{"2010" = "14"; "2013" = "15"}
    $env:spVer = $spVersions.(2013)
}

Function Get-SPManagedAccountXML([xml]$xmlinput, $commonName)
{
    $managedAccountXML = $xmlinput.Configuration.Farm.ManagedAccounts.ManagedAccount | Where-Object { $_.CommonName -eq $commonName }
    Return $managedAccountXML
}

Function ShouldIProvision([System.Xml.XmlNode] $node)
{
    If (!$node) {Return $false} # In case the node doesn't exist in the XML file
    # Allow for comma- or space-delimited list of server names in Provision or Start attribute
    If ($node.GetAttribute("Provision")) {$v = $node.GetAttribute("Provision").Replace(","," ")}
    ElseIf ($node.GetAttribute("Start")) {$v = $node.GetAttribute("Start").Replace(","," ")}
    ElseIf ($node.GetAttribute("Install")) {$v = $node.GetAttribute("Install").Replace(","," ")}
    If ($v -eq $true) { Return $true; }
    Return MatchComputerName $v $env:COMPUTERNAME
}

Function MatchComputerName($computersList, $computerName)
{
	If ($computersList -like "*$computerName*") { Return $true; }
    foreach ($v in $computersList) {
      If ($v.Contains("*") -or $v.Contains("#")) {
            # wildcard processing
            foreach ($item in -split $v) {
                $item = $item -replace "#", "[\d]"
                $item = $item -replace "\*", "[\S]*"
                if ($computerName -match $item) {return $true;}
            }
        }
    }
}

Function ConfigureObjectCache([System.Xml.XmlElement]$webApp)
{
    Try
    {
        $url = $webApp.Url + ":" + $webApp.Port
        $wa = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webApp.Name}
        $superUserAcc = $xmlinput.Configuration.Farm.ObjectCacheAccounts.SuperUser
        $superReaderAcc = $xmlinput.Configuration.Farm.ObjectCacheAccounts.SuperReader
        # If the web app is using Claims auth, change the user accounts to the proper syntax
        If ($wa.UseClaimsAuthentication -eq $true)
        {
            $superUserAcc = 'i:0#.w|' + $superUserAcc
            $superReaderAcc = 'i:0#.w|' + $superReaderAcc
        }
        Write-Host -ForegroundColor White " - Applying object cache accounts to `"$url`"..."
        $wa.Properties["portalsuperuseraccount"] = $superUserAcc
        Set-WebAppUserPolicy $wa $superUserAcc "Super User (Object Cache)" "Full Control"
        $wa.Properties["portalsuperreaderaccount"] = $superReaderAcc
        Set-WebAppUserPolicy $wa $superReaderAcc "Super Reader (Object Cache)" "Full Read"
        $wa.Update()
        Write-Host -ForegroundColor White " - Done applying object cache accounts to `"$url`""
    }
    Catch
    {
        $_
        Write-Warning "An error occurred applying object cache to `"$url`""
        Pause "exit"
    }
}

Function Set-WebAppUserPolicy($wa, $userName, $displayName, $perm)
{
    try {
        [Microsoft.SharePoint.Administration.SPPolicyCollection]$policies = $wa.Policies
        [Microsoft.SharePoint.Administration.SPPolicy]$policy = $policies.Add($userName, $displayName)
        [Microsoft.SharePoint.Administration.SPPolicyRole]$policyRole = $wa.PolicyRoles | where {$_.Name -eq $perm}
        If ($policyRole -ne $null)
        {
            Write-Host -ForegroundColor White " - Granting $userName $perm to $($wa.Url)..."
            $policy.PolicyRoleBindings.Add($policyRole)
        }
        $wa.Update()
    }
    catch {}
}

function CreateEnterpriseSearchServiceApp([xml]$xmlinput)
{
    Get-MajorVersionNumber $xmlinput
    $searchServiceAccount = Get-SPManagedAccountXML $xmlinput -CommonName "SearchService"
    # Check if the Search Service account username has been specified before we try to convert its password to a secure string
    if (!([string]::IsNullOrEmpty($searchServiceAccount.Username)))
    {
        $secSearchServicePassword = ConvertTo-SecureString -String $searchServiceAccount.Password -AsPlainText -Force
    }
    else
    {
        Write-Host -ForegroundColor White " - Managed account credentials for Search Service have not been specified."
    }
    # We now do a check that both Search is being requested for provisioning and that we are not running the Foundation SKU
    If ((ShouldIProvision $xmlinput.Configuration.ServiceApps.EnterpriseSearchService -eq $true) -and (Get-Command -Name New-SPEnterpriseSearchServiceApplication -ErrorAction SilentlyContinue) -and ($xmlinput.Configuration.Install.SKU -ne "Foundation"))
    {
        WriteLine
        Write-Host -ForegroundColor White " - Provisioning Enterprise Search..."
        # SLN: Added support for local host
        $svcConfig = $xmlinput.Configuration.ServiceApps.EnterpriseSearchService
        $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
        $portalURL = $portalWebApp.URL
        $portalPort = $portalWebApp.Port
        if ($xmlinput.Configuration.ServiceApps.UserProfileServiceApp.Provision -ne $false) # We didn't use ShouldIProvision here as we want to know if UPS is being provisioned in this farm, not just on this server
        {
            $mySiteWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "MySiteHost"}
            # If we have asked to create a MySite Host web app, use that as the MySite host location
            if ($mySiteWebApp)
            {
                $mySiteURL = $serverName;
                $mySitePort = $mySiteWebApp.Port
                $mySiteHostLocation = $mySiteURL+":"+$mySitePort
            }
            else # Use the value provided in the $userProfile node
            {
                $mySiteHostLocation = $xmlinput.Configuration.ServiceApps.UserProfileServiceApp.MySiteHostLocation
            }
            # Strip out any protocol values
            $mySiteHostHeaderAndPort,$null = $mySiteHostLocation -replace "http://","" -replace "https://","" -split "/"
        }

        $dataDir = $xmlinput.Configuration.Install.DataDir
        if($dataDir) {
        $dataDir = $dataDir.TrimEnd("\") }
        # Set it to the default value if it's not specified in $xmlinput
        if ([string]::IsNullOrEmpty($dataDir)) {$dataDir = "$env:ProgramFiles\Microsoft Office Servers\$env:spVer.0\Data"}

        $searchSvc = Get-SPEnterpriseSearchServiceInstance -Local
        If ($searchSvc -eq $null) {
            Throw "  - Unable to retrieve search service."
        }
        if ([string]::IsNullOrEmpty($svcConfig.CustomIndexLocation))
        {
            # Use the default location
            $indexLocation = "$dataDir\Office Server\Applications"
        }
        else
        {
            $indexLocation = $svcConfig.CustomIndexLocation
            $indexLocation = $indexLocation.TrimEnd("\")
            # If the requested index location is not the default, make sure the new location exists so we can use it later in the script
            if ($indexLocation -ne "$dataDir\Office Server\Applications")
            {
                Write-Host -ForegroundColor White " - Checking requested IndexLocation path..."
                EnsureFolder $svcConfig.CustomIndexLocation
            }
        }
        Write-Host -ForegroundColor White "  - Configuring search service..." -NoNewline
        Get-SPEnterpriseSearchService | Set-SPEnterpriseSearchService  `
          -ContactEmail $svcConfig.ContactEmail -ConnectionTimeout $svcConfig.ConnectionTimeout `
          -AcknowledgementTimeout $svcConfig.AcknowledgementTimeout -ProxyType $svcConfig.ProxyType `
          -IgnoreSSLWarnings $svcConfig.IgnoreSSLWarnings -InternetIdentity $svcConfig.InternetIdentity -PerformanceLevel $svcConfig.PerformanceLevel `
          -ServiceAccount $searchServiceAccount.Username -ServicePassword $secSearchServicePassword
        If ($?) {Write-Host -ForegroundColor Green "Done."}


        If ($true) # SharePoint 2013 steps
        {
            $svcConfig.EnterpriseSearchServiceApplications.EnterpriseSearchServiceApplication | ForEach-Object {
                $appConfig = $_
                $dbPrefix = Get-DBPrefix $xmlinput
                If (!([string]::IsNullOrEmpty($appConfig.Database.DBServer)))
                {
                    $dbServer = $appConfig.Database.DBServer
                }
                Else
                {
                    $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
                }
                $secContentAccessAcctPWD = ConvertTo-SecureString -String $appConfig.ContentAccessAccountPassword -AsPlainText -Force

                # Finally using ShouldIProvision here like everywhere else in the script...
                $installCrawlComponent = ShouldIProvision $appConfig.CrawlComponent
                $installQueryComponent = ShouldIProvision $appConfig.QueryComponent
                $installAdminComponent = ShouldIProvision $appConfig.AdminComponent
                $installSyncSvc = ShouldIProvision $appConfig.SearchQueryAndSiteSettingsComponent
                $installAnalyticsProcessingComponent = ShouldIProvision $appConfig.AnalyticsProcessingComponent
                $installContentProcessingComponent = ShouldIProvision $appConfig.ContentProcessingComponent
                $installIndexComponent = ShouldIProvision $appConfig.IndexComponent
                
                $pool = Get-ApplicationPool $appConfig.ApplicationPool
                $adminPool = Get-ApplicationPool $appConfig.AdminComponent.ApplicationPool
                $appPoolUserName = $searchServiceAccount.Username

                $saAppPool = Get-SPServiceApplicationPool -Identity $pool -ErrorAction SilentlyContinue
                if($saAppPool -eq $null)
                {
                    Write-Host -ForegroundColor White "  - Creating Service Application Pool..."

                    $appPoolAccount = Get-SPManagedAccount -Identity $appPoolUserName -ErrorAction SilentlyContinue
                    if($appPoolAccount -eq $null)
                    {
                        Write-Host -ForegroundColor White "  - Please supply the password for the Service Account..."
                        $appPoolCred = Get-Credential $appPoolUserName
                        $appPoolAccount = New-SPManagedAccount -Credential $appPoolCred -ErrorAction SilentlyContinue
                    }

                    $appPoolAccount = Get-SPManagedAccount -Identity $appPoolUserName -ErrorAction SilentlyContinue

                    if($appPoolAccount -eq $null)
                    {
                        Throw "  - Cannot create or find the managed account $appPoolUserName, please ensure the account exists."
                    }

                    New-SPServiceApplicationPool -Name $pool -Account $appPoolAccount -ErrorAction SilentlyContinue | Out-Null
                }

                # From http://mmman.itgroove.net/2012/12/search-host-controller-service-in-starting-state-sharepoint-2013-8/
                # And http://blog.thewulph.com/?p=374
                Write-Host -ForegroundColor White "  - Fixing registry permissions for Search Host Controller Service..." -NoNewline
                $acl = Get-Acl HKLM:\System\CurrentControlSet\Control\ComputerName
                $person = [System.Security.Principal.NTAccount] "WSS_WPG" # Trimmed down from the original "Users"
                $access = [System.Security.AccessControl.RegistryRights]::FullControl
                $inheritance = [System.Security.AccessControl.InheritanceFlags] "ContainerInherit, ObjectInherit"
                $propagation = [System.Security.AccessControl.PropagationFlags]::None
                $type = [System.Security.AccessControl.AccessControlType]::Allow
                $rule = New-Object System.Security.AccessControl.RegistryAccessRule($person, $access, $inheritance, $propagation, $type)
                $acl.AddAccessRule($rule)
                Set-Acl HKLM:\System\CurrentControlSet\Control\ComputerName $acl
                Write-Host -ForegroundColor White "OK."

                Write-Host -ForegroundColor White "  - Checking Search Service Instance..." -NoNewline
                If ($searchSvc.Status -eq "Disabled")
                {
                    Write-Host -ForegroundColor White "Starting..." -NoNewline
                    $searchSvc | Start-SPEnterpriseSearchServiceInstance
                    If (!$?) {Throw "  - Could not start the Search Service Instance."}
                    # Wait
                    $searchSvc = Get-SPEnterpriseSearchServiceInstance -Local
                    While ($searchSvc.Status -ne "Online")
                    {
                        Write-Host -ForegroundColor Blue "." -NoNewline
                        Start-Sleep 1
                        $searchSvc = Get-SPEnterpriseSearchServiceInstance -Local
                    }
                    Write-Host -BackgroundColor Green -ForegroundColor Black $($searchSvc.Status)
                }
                Else {Write-Host -ForegroundColor White "Already $($searchSvc.Status)."}

                if ($installSyncSvc)
                {
                    Write-Host -ForegroundColor White "  - Checking Search Query and Site Settings Service Instance..." -NoNewline
                    $searchQueryAndSiteSettingsService = Get-SPEnterpriseSearchQueryAndSiteSettingsServiceInstance -Local
                    If ($searchQueryAndSiteSettingsService.Status -eq "Disabled")
                    {
                        Write-Host -ForegroundColor White "Starting..." -NoNewline
                        $searchQueryAndSiteSettingsService | Start-SPEnterpriseSearchQueryAndSiteSettingsServiceInstance
                        If (!$?) {Throw "  - Could not start the Search Query and Site Settings Service Instance."}
                        Write-Host -ForegroundColor Green $($searchQueryAndSiteSettingsService.Status)
                    }
                    Else {Write-Host -ForegroundColor White "Already $($searchQueryAndSiteSettingsService.Status)."}
                }

                Write-Host -ForegroundColor White "  - Checking Search Service Application..." -NoNewline
                $searchApp = Get-SPEnterpriseSearchServiceApplication -Identity $appConfig.Name -ErrorAction SilentlyContinue
                If ($searchApp -eq $null)
                {
                    Write-Host -ForegroundColor White "Creating $($appConfig.Name)..." -NoNewline
                    $searchApp = New-SPEnterpriseSearchServiceApplication -Name $appConfig.Name `
                        -DatabaseServer $dbServer `
                        -DatabaseName $($dbPrefix+$appConfig.Database.Name) `
                        -FailoverDatabaseServer $appConfig.FailoverDatabaseServer `
                        -ApplicationPool $pool `
                        -AdminApplicationPool $adminPool `
                        -Partitioned:([bool]::Parse($appConfig.Partitioned))
                    If (!$?) {Throw "  - An error occurred creating the $($appConfig.Name) application."}
                    Write-Host -ForegroundColor Green "Done."
                }
                Else {Write-Host -ForegroundColor White "Already exists."}

                # Update the default Content Access Account
                Update-SearchContentAccessAccount $($appConfig.Name) $searchApp $($appConfig.ContentAccessAccount) $secContentAccessAcctPWD

                # If the index location isn't already set to either the default location or our custom-specified location, set the default location for the search service instance
                if ($indexLocation -ne "$dataDir\Office Server\Applications" -or $indexLocation -ne $searchSvc.DefaultIndexLocation)
                {
                    Write-Host -ForegroundColor White "  - Setting default index location on search service instance..." -NoNewline
                    $searchSvc | Set-SPEnterpriseSearchServiceInstance -DefaultIndexLocation $indexLocation -ErrorAction SilentlyContinue
                    if ($?) {Write-Host -ForegroundColor White "OK."}
                }

                # Look for a topology that has components, or is still Inactive, because that's probably our $clone
                $clone = $searchApp.Topologies | Where {$_.ComponentCount -gt 0 -and $_.State -eq "Inactive"} | Select-Object -First 1
                if (!$clone)
                {
                    # Clone the active topology
                    Write-Host -ForegroundColor White "  - Cloning the active search topology..." -NoNewline
                    $clone = $searchApp.ActiveTopology.Clone()
                    Write-Host -ForegroundColor White "OK."
                }
                else
                {
                    Write-Host -ForegroundColor White "  - Using existing cloned search topology."
                    # Since this clone probably doesn't have all its components added yet, we probably want to keep it if it isn't activated after this pass
                    $keepClone = $true
                }
                $activateTopology = $false
                # Check if each search component is already assigned to the current server, then check that it's actually being requested for the current server, then create it as required.
                Write-Host -ForegroundColor White "  - Checking admin component..." -NoNewline
                $adminComponents = $clone.GetComponents() | Where-Object {$_.Name -like "AdminComponent*"}
                If ($installAdminComponent)
                {
                    if (!($adminComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        Write-Host -ForegroundColor White "Creating..." -NoNewline
                        New-SPEnterpriseSearchAdminComponent -SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            Write-Host -ForegroundColor White "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {Write-Host -ForegroundColor White "Already exists on this server."}
                    $adminComponentReady = $true
                }
                else {Write-Host -ForegroundColor White "Not requested for this server."}
                if ($adminComponents) {Write-Host -ForegroundColor White "  - Admin component(s) already exist(s) in the farm."; $adminComponentReady = $true}

                Write-Host -ForegroundColor White "  - Checking content processing component..." -NoNewline
                $contentProcessingComponents = $clone.GetComponents() | Where-Object {$_.Name -like "ContentProcessingComponent*"}
                if ($installContentProcessingComponent)
                {
                    if (!($contentProcessingComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        Write-Host -ForegroundColor White "Creating..." -NoNewline
                        New-SPEnterpriseSearchContentProcessingComponent -SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            Write-Host -ForegroundColor White "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {Write-Host -ForegroundColor White "Already exists on this server."}
                    $contentProcessingComponentReady = $true
                }
                else {Write-Host -ForegroundColor White "Not requested for this server."}
                if ($contentProcessingComponents) {Write-Host -ForegroundColor White "  - Content processing component(s) already exist(s) in the farm."; $contentProcessingComponentReady = $true}

                Write-Host -ForegroundColor White "  - Checking analytics processing component..." -NoNewline
                $analyticsProcessingComponents = $clone.GetComponents() | Where-Object {$_.Name -like "AnalyticsProcessingComponent*"}
                if ($installAnalyticsProcessingComponent)
                {
                    if (!($analyticsProcessingComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        Write-Host -ForegroundColor White "Creating..." -NoNewline
                        New-SPEnterpriseSearchAnalyticsProcessingComponent -SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            Write-Host -ForegroundColor White "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {Write-Host -ForegroundColor White "Already exists on this server."}
                    $analyticsProcessingComponentReady = $true
                }
                else {Write-Host -ForegroundColor White "Not requested for this server."}
                if ($analyticsProcessingComponents) {Write-Host -ForegroundColor White "  - Analytics processing component(s) already exist(s) in the farm."; $analyticsProcessingComponentReady = $true}

                Write-Host -ForegroundColor White "  - Checking crawl component..." -NoNewline
                $crawlComponents = $clone.GetComponents() | Where-Object {$_.Name -like "CrawlComponent*"}
                if ($installCrawlComponent)
                {
                    if (!($crawlComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        Write-Host -ForegroundColor White "Creating..." -NoNewline
                        New-SPEnterpriseSearchCrawlComponent -SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            Write-Host -ForegroundColor White "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {Write-Host -ForegroundColor White "Already exists on this server."}
                    $crawlComponentReady = $true
                }
                else {Write-Host -ForegroundColor White "Not requested for this server."}
                if ($crawlComponents) {Write-Host -ForegroundColor White "  - Crawl component(s) already exist(s) in the farm."; $crawlComponentReady = $true}

                Write-Host -ForegroundColor White "  - Checking index component..." -NoNewline
                $indexingComponents = $clone.GetComponents() | Where-Object {$_.Name -like "IndexComponent*"}
                if ($installIndexComponent)
                {
                    if (!($indexingComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        Write-Host -ForegroundColor White "Creating..." -NoNewline
                        # Specify the RootDirectory parameter only if it's different than the default path
                        if ($indexLocation -ne "$dataDir\Office Server\Applications")
                        {$rootDirectorySwitch = @{RootDirectory = $indexLocation}}
                        else {$rootDirectorySwitch = @{}}
                        New-SPEnterpriseSearchIndexComponent -SearchTopology $clone -SearchServiceInstance $searchSvc @rootDirectorySwitch | Out-Null
                        If ($?)
                        {
                            Write-Host -ForegroundColor White "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {Write-Host -ForegroundColor White "Already exists on this server."}
                    $indexComponentReady = $true
                }
                else {Write-Host -ForegroundColor White "Not requested for this server."}
                if ($indexingComponents) {Write-Host -ForegroundColor White "  - Index component(s) already exist(s) in the farm."; $indexComponentReady = $true}

                Write-Host -ForegroundColor White "  - Checking query processing component..." -NoNewline
                $queryComponents = $clone.GetComponents() | Where-Object {$_.Name -like "QueryProcessingComponent*"}
                if ($installQueryComponent)
                {
                    if (!($queryComponents | Where-Object {MatchComputerName $_.ServerName $env:COMPUTERNAME}))
                    {
                        Write-Host -ForegroundColor White "Creating..." -NoNewline
                        New-SPEnterpriseSearchQueryProcessingComponent -SearchTopology $clone -SearchServiceInstance $searchSvc | Out-Null
                        If ($?)
                        {
                            Write-Host -ForegroundColor White "OK."
                            $newComponentsCreated = $true
                        }
                    }
                    else {Write-Host -ForegroundColor White "Already exists on this server."}
                    $queryComponentReady = $true
                }
                else {Write-Host -ForegroundColor White "Not requested for this server."}
                if ($queryComponents) {Write-Host -ForegroundColor White "  - Query component(s) already exist(s) in the farm."; $queryComponentReady = $true}

                $searchApp | Get-SPEnterpriseSearchAdministrationComponent | Set-SPEnterpriseSearchAdministrationComponent -SearchServiceInstance $searchSvc

                if ($adminComponentReady -and $contentProcessingComponentReady -and $analyticsProcessingComponentReady -and $indexComponentReady -and $crawlComponentReady -and $queryComponentReady) {$activateTopology = $true}
                # Check if any new search components were added (or if we have a clone with more components than the current active topology) and if we're ready to activate the topology
                if ($newComponentsCreated -or ($clone.ComponentCount -gt $searchApp.ActiveTopology.ComponentCount))
                {
                    if ($activateTopology)
                    {
                        Write-Host -ForegroundColor White "  - Activating Search Topology..." -NoNewline
                        $clone.Activate()
                        If ($?)
                        {
                            Write-Host -ForegroundColor White "OK."
                            # Clean up original or previous unsuccessfully-provisioned search topologies
                            $inactiveTopologies = $searchApp.Topologies | Where {$_.State -eq "Inactive"}
                            if ($inactiveTopologies -ne $null)
                            {
                                Write-Host -ForegroundColor White "  - Removing old, inactive search topologies:"
                                foreach ($inactiveTopology in $inactiveTopologies)
                                {
                                    Write-Host -ForegroundColor White "   -"$inactiveTopology.TopologyId.ToString()
                                    $inactiveTopology.Delete()
                                }
                            }
                        }
                    }
                    else
                    {
                        Write-Host -ForegroundColor White "  - Not activating topology yet as there seem to be components still pending."
                    }
                }
                elseif ($keepClone -ne $true) # Delete the newly-cloned topology since nothing was done
                # TODO: Check that the search topology is truly complete and there are no more servers to install
                {
                    Write-Host -ForegroundColor White "  - Deleting unneeded cloned topology..."
                    $clone.Delete()
                }
                # Clean up any empty, inactive topologies
                $emptyTopologies = $searchApp.Topologies | Where {$_.ComponentCount -eq 0 -and $_.State -eq "Inactive"}
                if ($emptyTopologies -ne $null)
                {
                    Write-Host -ForegroundColor White "  - Removing empty and inactive search topologies:"
                    foreach ($emptyTopology in $emptyTopologies)
                    {
                        Write-Host -ForegroundColor White "  -"$emptyTopology.TopologyId.ToString()
                        $emptyTopology.Delete()
                    }
                }
                Write-Host -ForegroundColor White "  - Checking search service application proxy..." -NoNewline
                If (!(Get-SPEnterpriseSearchServiceApplicationProxy -Identity $appConfig.Proxy.Name -ErrorAction SilentlyContinue))
                {
                    Write-Host -ForegroundColor White "Creating..." -NoNewline
                    $searchAppProxy = New-SPEnterpriseSearchServiceApplicationProxy -Name $appConfig.Proxy.Name -SearchApplication $appConfig.Name
                    If ($?) {Write-Host -ForegroundColor White "OK."}
                }
                Else {Write-Host -ForegroundColor White "Already exists."}

                # Check the Search Host Controller Service for a known issue ("stuck on starting")
                Write-Host -ForegroundColor White "  - Checking for stuck Search Host Controller Service (known issue)..."
                $searchHostServices = Get-SPServiceInstance | ? {$_.TypeName -eq "Search Host Controller Service"}
                foreach ($sh in $searchHostServices)
                {
                    Write-Host -ForegroundColor White "   - Server: $($sh.Parent.Address)..." -NoNewline
                    if ($sh.Status -eq "Provisioning")
                    {
                        Write-Host -ForegroundColor White "Re-provisioning..." -NoNewline
                        $sh.Unprovision()
                        $sh.Provision($true)
                        Write-Host -ForegroundColor Green "Done."
                    }
                    else {Write-Host -ForegroundColor White "OK."}
                }

                # Add link to resources list
                AddResourcesLink $appConfig.Name ("searchadministration.aspx?appid=" +  $searchApp.Id)

                function SetSearchCenterUrl ($searchCenterURL, $searchApp)
                {
                    Start-Sleep 10 # Wait for stuff to catch up so we don't get a concurrency error
                    $searchApp.SearchCenterUrl = $searchCenterURL
                    $searchApp.Update()
                }

                If (!([string]::IsNullOrEmpty($appConfig.SearchCenterUrl)))
                {
                    # Set the SP2013 Search Center URL per http://blogs.technet.com/b/speschka/archive/2012/10/29/how-to-configure-the-global-search-center-url-for-sharepoint-2013-using-powershell.aspx
                    Write-Host -ForegroundColor White "  - Setting the Global Search Center URL to $($appConfig.SearchCenterURL)..." -NoNewline
                    while ($done -ne $true)
                    {
                        try
                        {
                            # Get the #searchApp object again to prevent conflicts
                            $searchApp = Get-SPEnterpriseSearchServiceApplication -Identity $appConfig.Name
                            SetSearchCenterUrl $appConfig.SearchCenterURL.TrimEnd("/") $searchApp
                            if ($?)
                            {
                                $done = $true
                                Write-Host -ForegroundColor White "OK."
                            }
                        }
                        catch
                        {
                            Write-Output $_
                            if ($_ -like "*update conflict*")
                            {
                                Write-Host -ForegroundColor Yellow "  - An update conflict occurred, retrying..."
                            }
                            else {Write-Output $_; $done = $true}
                        }
                    }
                }
                Else {Write-Host -ForegroundColor Yellow "  - SearchCenterUrl was not specified, skipping."}
                Write-Host -ForegroundColor White " - Search Service Application successfully provisioned."

                WriteLine
            }
        }

        # SLN: Create the network share (will report an error if exist)
        # default to primitives
        $pathToShare = """" + $svcConfig.ShareName + "=" + $indexLocation + """"
        # The path to be shared should exist if the Enterprise Search App creation succeeded earlier
        EnsureFolder $indexLocation
        Write-Host -ForegroundColor White " - Creating network share $pathToShare"
        Start-Process -FilePath net.exe -ArgumentList "share $pathToShare `"/GRANT:WSS_WPG,CHANGE`"" -NoNewWindow -Wait -ErrorAction SilentlyContinue

        # Set the crawl start addresses (including the elusive sps3:// URL required for People Search, if My Sites are provisioned)
        # Updated to include all web apps and host-named site collections, not just main Portal and MySites host
        ForEach ($webAppConfig in $xmlinput.Configuration.WebApplications.WebApplication)
        {
            if ([string]::IsNullOrEmpty($crawlStartAddresses))
            {
                $crawlStartAddresses = $($webAppConfig.url)+":"+$($webAppConfig.Port)
            }
            else
            {
                $crawlStartAddresses += ","+$($webAppConfig.url)+":"+$($webAppConfig.Port)
            }
        }

        If ($mySiteHostHeaderAndPort)
        {
        	# Need to set the correct sps (People Search) URL protocol in case the web app that hosts My Sites is SSL-bound
        	If ($mySiteHostLocation -like "https*") {$peopleSearchProtocol = "sps3s://"}
        	Else {$peopleSearchProtocol = "sps3://"}
        	$crawlStartAddresses += ","+$peopleSearchProtocol+$mySiteHostHeaderAndPort
        }
        Write-Host -ForegroundColor White " - Setting up crawl addresses for default content source..." -NoNewline
        Get-SPEnterpriseSearchServiceApplication | Get-SPEnterpriseSearchCrawlContentSource | Set-SPEnterpriseSearchCrawlContentSource -StartAddresses $crawlStartAddresses
        If ($?) {Write-Host -ForegroundColor White "OK."}
        if ($env:spVer -eq "15") # Invoke-WebRequest requires PowerShell 3.0 but if we're installing SP2013 and we've gotten this far, we must have v3.0
        {
            # Issue a request to the Farm Search Administration page to avoid a Health Analyzer warning about 'Missing Server Side Dependencies'
            $ca = Get-SPWebApplication -IncludeCentralAdministration | ? {$_.IsAdministrationWebApplication}
            $centralAdminUrl = $ca.Url
            if ($ca.Url -like "http://*" -or $ca.Url -like "*$($env:COMPUTERNAME)*") # If Central Admin uses SSL, only attempt the web request if we're on the same server as Central Admin, otherwise it may throw a certificate error due to our self-signed cert
            {
                try
                {
                    Write-Host -ForegroundColor White " - Requesting searchfarmdashboard.aspx (resolves Health Analyzer error)..."
                    $null = Invoke-WebRequest -Uri $centralAdminUrl"searchfarmdashboard.aspx" -UseDefaultCredentials -DisableKeepAlive -UseBasicParsing -ErrorAction SilentlyContinue
                }
                catch {}
            }
        }
        WriteLine
    }
    Else
    {
        WriteLine
        # Set the service account to something other than Local System to avoid Health Analyzer warnings
        If (!([string]::IsNullOrEmpty($searchServiceAccount.Username)) -and !([string]::IsNullOrEmpty($secSearchServicePassword)))
        {
            # Use the values for Search Service account and password, if they've been defined
            $username = $searchServiceAccount.Username
            $password = $secSearchServicePassword
        }
        Else
        {
            $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
            $username = $spservice.username
            $password = ConvertTo-SecureString "$($spservice.password)" -AsPlaintext -Force
        }
        Write-Host -ForegroundColor White " - Applying service account $username to Search Service..."
        Get-SPEnterpriseSearchService | Set-SPEnterpriseSearchService -ServiceAccount $username -ServicePassword $password
        If (!$?) {Write-Error " - An error occurred setting the Search Service account!"}
        WriteLine
    }
}

Function Add-LocalIntranetURL ($url)
{
    If (($url -like "*.*") -and (($webApp.AddURLToLocalIntranetZone) -eq $true))
    {
        # Strip out any protocol value
        $url = $url -replace "http://","" -replace "https://",""
        $splitURL = $url -split "\."
        # Thanks to CodePlex user Eulenspiegel for the updates $urlDomain syntax (https://autospinstaller.codeplex.com/workitem/20486)
        $urlDomain = $url.Substring($splitURL[0].Length + 1)
        Write-Host -ForegroundColor White " - Adding *.$urlDomain to local Intranet security zone..."
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Name $urlDomain -ItemType Leaf -Force | Out-Null
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$urlDomain" -Name '*' -value "1" -PropertyType dword -Force | Out-Null
    }
}

Function CreateWebApp([System.Xml.XmlElement]$webApp)
{
    Get-MajorVersionNumber $xmlinput
    # Look for a managed account that matches the web app type, e.g. "Portal" or "MySiteHost"
    $webAppPoolAccount = Get-SPManagedAccountXML $xmlinput $webApp.Type
    # If no managed account is found matching the web app type, just use the Portal managed account
    if (!$webAppPoolAccount)
    {
        $webAppPoolAccount = Get-SPManagedAccountXML $xmlinput -CommonName "Portal"
        if ([string]::IsNullOrEmpty($webAppPoolAccount.username)) {throw " - `"Portal`" managed account not found! Check your XML."}
    }
    $webAppName = $webApp.name
    $appPool = $webApp.applicationPool
    $dbPrefix = Get-DBPrefix $xmlinput
    $database = $dbPrefix+$webApp.Database.Name
    $dbServer = $webApp.Database.DBServer
    $url = $webApp.url
    $port = $webApp.port
    if($port -ne "80")
    {
        $fullUrl = "$($url):$($port)";
    }
    else
    {
        $fullUrl = $url;
    }
    # Check for an existing App Pool
    $existingWebApp = Get-SPWebApplication $fullUrl -ErrorAction SilentlyContinue;#| Where-Object { ($_.ApplicationPool).Name -eq $appPool }
    $appPoolExists = ($existingWebApp -ne $null)
    # If we haven't specified a DB Server then just use the default used by the Farm
    If ([string]::IsNullOrEmpty($dbServer))
    {
        $dbServer = $xmlinput.Configuration.Farm.Database.DBServer
    }
    
    $useSSL = $false
    $installedOfficeServerLanguages = (Get-Item "HKLM:\Software\Microsoft\Office Server\15.0\InstalledLanguages").GetValueNames() | ? {$_ -ne ""}
    # Strip out any protocol value
    If ($url -like "https://*") {$useSSL = $true}
    $hostHeader = $url -replace "http://","" -replace "https://",""
    if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
    {
        Write-Host -ForegroundColor White " - Skipping setting the web app directory path name (not currently working on Windows 2012 w/SP2010)..."
        $pathSwitch = @{}
    }
    else
    {
        # Set the directory path for the web app to something a bit more friendly
        ImportWebAdministration
        # Get the default root location for web apps
        $iisWebDir = (Get-ItemProperty "IIS:\Sites\Default Web Site\" -name physicalPath -ErrorAction SilentlyContinue) -replace ("%SystemDrive%","$env:SystemDrive")
        if (!([string]::IsNullOrEmpty($iisWebDir)))
        {
            $pathSwitch = @{Path = "$iisWebDir\wss\VirtualDirectories\$webAppName-$port"}
        }
        else {$pathSwitch = @{}}
    }
    # Only set $hostHeaderSwitch to blank if the UseHostHeader value exists has explicitly been set to false
    if (!([string]::IsNullOrEmpty($webApp.UseHostHeader)) -and $webApp.UseHostHeader -eq $false)
    {
        $hostHeaderSwitch = @{}
    }
    else {$hostHeaderSwitch = @{HostHeader = $hostHeader}}
    if (!([string]::IsNullOrEmpty($webApp.useClaims)) -and $webApp.useClaims -eq $false)
    {
        # Create the web app using Classic mode authentication
        $authProviderSwitch = @{}
    }
    else # Configure new web app to use Claims-based authentication
    {
        If ($($webApp.useBasicAuthentication) -eq $true)
        {
            $authProvider = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication -UseBasicAuthentication
        }
        Else
        {
            $authProvider = New-SPAuthenticationProvider #-UseWindowsIntegratedAuthentication
        }
        $authProviderSwitch = @{AuthenticationProvider = $authProvider}
        If ((Gwmi Win32_OperatingSystem).Version -like "6.0*") # If we are running Win2008 (non-R2), we may need the claims hotfix
        {
            [bool]$claimsHotfixRequired = $true
            Write-Host -ForegroundColor Yellow " - Web Applications using Claims authentication require an update"
            Write-Host -ForegroundColor Yellow " - Apply the http://go.microsoft.com/fwlink/?LinkID=184705 update after setup."
        }
    }
    if ($appPoolExists)
    {
        $appPoolAccountSwitch = @{}
    }
    else
    {
        $appPoolAccountSwitch = @{ApplicationPoolAccount = $($webAppPoolAccount.username)}
    }
    $getSPWebApplication = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webAppName}
    If (!$appPoolExists)
    {
        Write-Host -ForegroundColor White " - Creating Web App `"$webAppName`""
        New-SPWebApplication -Name $webAppName -ApplicationPool $appPool -DatabaseServer $dbServer -DatabaseName $database -Url $url -Port $port -SecureSocketsLayer:$useSSL @hostHeaderSwitch @appPoolAccountSwitch @authProviderSwitch @pathSwitch | Out-Null
        If (-not $?) { Throw " - Failed to create web application" }
    }
    Else {Write-Host -ForegroundColor White " - Web app `"$webAppName`" already provisioned."}
    SetupManagedPaths $webApp
    If ($useSSL)
    {
        $SSLHostHeader = $hostHeader
        $SSLPort = $port
        $SSLSiteName = $webAppName
        if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($env:spVer -eq "14"))
        {
            Write-Host -ForegroundColor White " - Assigning certificate(s) in a separate PowerShell window..."
            Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -ArgumentList "-Command `". $env:dp0\AutoSPInstallerFunctions.ps1`; AssignCert $SSLHostHeader $SSLPort $SSLSiteName; Start-Sleep 2`"" -Wait
        }
        else {AssignCert $SSLHostHeader $SSLPort $SSLSiteName}
    }

    # If we are provisioning any Office Web Apps, Visio, Excel, Access or PerformancePoint services, we need to grant the generic app pool account access to the newly-created content database
    # Per http://technet.microsoft.com/en-us/library/ff829837.aspx and http://autospinstaller.codeplex.com/workitem/16224 (thanks oceanfly!)
    If ((ShouldIProvision $xmlinput.Configuration.OfficeWebApps.ExcelService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.OfficeWebApps.PowerPointService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.OfficeWebApps.WordViewingService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.VisioService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.ExcelServices -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.AccessService -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.AccessServices -eq $true) -or `
        (ShouldIProvision $xmlinput.Configuration.EnterpriseServiceApps.PerformancePointService -eq $true))
    {
        $spservice = Get-SPManagedAccountXML $xmlinput -CommonName "spservice"
        Write-Host -ForegroundColor White " - Granting $($spservice.username) rights to `"$webAppName`"..." -NoNewline
        $wa = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webAppName}
        $wa.GrantAccessToProcessIdentity("$($spservice.username)")
        Write-Host -ForegroundColor White "OK."
    }
    if ($webApp.GrantCurrentUserFullControl -eq $true)
    {
        $currentUser = "$env:USERDOMAIN\$env:USERNAME"
        $wa = Get-SPWebApplication | Where-Object {$_.DisplayName -eq $webAppName}
        if ($wa.UseClaimsAuthentication -eq $true) {$currentUser = 'i:0#.w|' + $currentUser}
        Set-WebAppUserPolicy $wa $currentUser "$env:USERNAME" "Full Control"
    }
    WriteLine
    
    if ($webApp.SiteCollections.SelectSingleNode("SiteCollection")) # Only go through these steps if we actually have a site collection to create
    {
        ForEach ($siteCollection in $webApp.SiteCollections.SiteCollection)
        {
            $dbPrefix = Get-DBPrefix $xmlinput
            $getSPSiteCollection = $null
            $siteCollectionName = $siteCollection.Name
            $siteURL = $siteCollection.siteURL
            if (!([string]::IsNullOrEmpty($($siteCollection.CustomDatabase)))) # Check if we have specified a non-default content database for this site collection
            {
                $siteDatabase = $dbPrefix+$siteCollection.CustomDatabase
            }
            else # Just use the first, default content database for the web application
            {
                $siteDatabase = $database
            }
            $template = $siteCollection.template
            # If an OwnerAlias has been specified, make it the primary, and the currently logged-in account the secondary. Otherwise, make the app pool account for the web app the primary owner
            if (!([string]::IsNullOrEmpty($($siteCollection.Owner))))
            {
                $ownerAlias = $siteCollection.Owner
            }
            else
            {
                $ownerAlias = $webAppPoolAccount.username
            }
            $LCID = $siteCollection.LCID
            $siteCollectionLocale = $siteCollection.Locale
            $siteCollectionTime24 = $siteCollection.Time24
            # If a template has been pre-specified, use it when creating the Portal site collection; otherwise, leave it blank so we can select one when the portal first loads
            If (($template -ne $null) -and ($template -ne ""))
            {
                $templateSwitch = @{Template = $template}
            }
            else {$templateSwitch = @{}}
            if ($siteCollection.HostNamedSiteCollection -eq $true)
            {
                $hostHeaderWebAppSwitch = @{HostHeaderWebApplication = $($webApp.url)+":"+$($webApp.port)}
            }
            else {$hostHeaderWebAppSwitch = @{}}
            Write-Host -ForegroundColor White " - Checking for Site Collection `"$siteURL`"..."
            $getSPSiteCollection = Get-SPSite -Limit ALL | Where-Object {$_.Url -eq $siteURL}
            If (($getSPSiteCollection -eq $null) -and ($siteURL -ne $null))
            {
                # Verify that the Language we're trying to create the site in is currently installed on the server
                $culture = [System.Globalization.CultureInfo]::GetCultureInfo(([convert]::ToInt32($LCID)))
                $cultureDisplayName = $culture.DisplayName
                If (!($installedOfficeServerLanguages | Where-Object {$_ -eq $culture.Name}))
                {
                    Write-Warning "You must install the `"$culture ($cultureDisplayName)`" Language Pack before you can create a site using LCID $LCID"
                }
                Else
                {
                    $siteDatabaseExists = Get-SPContentDatabase -Identity $siteDatabase -ErrorAction SilentlyContinue
                    if (!$siteDatabaseExists)
                    {
                        Write-Host -ForegroundColor White " - Creating new content database `"$siteDatabase`"..."
                        New-SPContentDatabase -Name $siteDatabase -WebApplication (Get-SPWebApplication $webApp.url) | Out-Null
                    }
                    Write-Host -ForegroundColor White " - Creating Site Collection `"$siteURL`"..."
                    $site = New-SPSite -Url $siteURL -OwnerAlias $ownerAlias -SecondaryOwner $env:USERDOMAIN\$env:USERNAME -ContentDatabase $siteDatabase -Description $siteCollectionName -Name $siteCollectionName -Language $LCID -Template $template -ErrorAction Stop
                    if($site.RootWeb.NoCrawl -eq $true) {
                        $site.RootWeb.NoCrawl = $false; }

                    # JDM Not all Web Templates greate the default SharePoint Croups that are made by the UI
                    # JDM These lines will insure that the the approproprate SharePoint Groups, Owners, Members, Visitors are created
                    $primaryUser = $site.RootWeb.EnsureUser($ownerAlias)
                    $secondaryUser = $site.RootWeb.EnsureUser("$env:USERDOMAIN\$env:USERNAME")
                    $title = $site.RootWeb.title
                    Write-Host -ForegroundColor White " - Ensuring default groups are created..."
                    $site.RootWeb.CreateDefaultAssociatedGroups($primaryUser, $secondaryUser, $title)

                    # Add the Portal Site Connection to the web app, unless of course the current web app *is* the portal
                    # Inspired by http://www.toddklindt.com/blog/Lists/Posts/Post.aspx?ID=264
                    $portalWebApp = $xmlinput.Configuration.WebApplications.WebApplication | Where {$_.Type -eq "Portal"} | Select-Object -First 1
                    $portalSiteColl = $portalWebApp.SiteCollections.SiteCollection | Select-Object -First 1
                    If ($site.URL -ne $portalSiteColl.siteURL)
                    {
                        Write-Host -ForegroundColor White " - Setting the Portal Site Connection for `"$siteCollectionName`"..."
                        $site.PortalName = $portalSiteColl.Name
                        $site.PortalUrl = $portalSiteColl.siteUrl
                    }
                    If ($siteCollectionLocale)
                    {
                        Write-Host -ForegroundColor White " - Updating the locale for `"$siteCollectionName`" to `"$siteCollectionLocale`"..."
                        $site.RootWeb.Locale = [System.Globalization.CultureInfo]::CreateSpecificCulture($siteCollectionLocale)
                    }
                    If ($siteCollectionTime24)
                    {
                        Write-Host -ForegroundColor White " - Updating 24 hour time format for `"$siteCollectionName`" to `"$siteCollectionTime24`"..."
                        $site.RootWeb.RegionalSettings.Time24 = $([System.Convert]::ToBoolean($siteCollectionTime24))
                    }
                    $site.RootWeb.Update()
                }
            }
            Else {Write-Host -ForegroundColor White " - Skipping creation of site `"$siteCollectionName`" - already provisioned."}
            if ($siteCollection.HostNamedSiteCollection -eq $true)
            {
                Add-LocalIntranetURL ($siteURL)
                # Updated so that we don't add URLs to the local hosts file of a server that's not running the Foundation Web Application service
                if ($xmlinput.Configuration.WebApplications.AddURLsToHOSTS -eq $true -and !(($xmlinput.Configuration.Farm.Services.SelectSingleNode("FoundationWebApplication")) -and !(ShouldIProvision $xmlinput.Configuration.Farm.Services.FoundationWebApplication -eq $true)))
                {
                    # Add the hostname of this host header-based site collection to the local HOSTS so it's immediately resolvable locally
                    # Strip out any protocol and/or port values
                    $hostname,$null = $siteURL -replace "http://","" -replace "https://","" -split ":"
                    AddToHOSTS $hostname
                }
            }
            WriteLine
        }
    }
    else
    {
        Write-Host -ForegroundColor Yellow " - No site collections specified for $($webapp.url) - skipping."
    }
}

function ConfigureMySiteSettings([System.Xml.XmlElement]$config)
{
    $siteUrl = $null;

    $mySiteHostWebApp = $config.WebApplications.WebApplication | ? {$_.type -eq 'MySiteHost'};
    $mySiteWebAppUrl = "$($mySiteHostWebApp.url):$($mySiteHostWebApp.port)";


    $mySiteWebApp = Get-SPWebApplication -Identity $mySiteWebAppUrl -ErrorAction SilentlyContinue;

    Write-Host " - Turning on Self-Site Creation for MySite";
        
    if($mySiteWebApp)
    {  
        $mySiteWebApp.SelfServiceSiteCreationEnabled = $true;

        $siteUrlToSet = "/my/"; 
        $mySiteWebApp.SelfServiceCreationParentSiteUrl = $siteUrlToSet; 
        $mySiteWebApp.ShowStartASiteMenuItem = $true;
        $mySiteWebApp.SelfServiceCreateIndividualSite = $true;
        $mySiteWebApp.Update();
    }

    $mySiteUrl = $mySiteHostWebApp.SiteCollections.SiteCollection | ? {$_.Name -eq 'My Site Host'};

    if($mySiteUrl)
    {
        $ups = Get-SPServiceApplication | ? {$_.TypeName -like 'User Profile *'};
        
        $mySite = Get-SPSite -Identity $mySiteUrl.siteUrl -ErrorAction SilentlyContinue;

        if($mySite)
        {
            $ctx = Get-SPServiceContext -Site $mySite;
            $upm = new-object Microsoft.Office.Server.UserProfiles.UserProfileManager($ctx);
            $mySiteUrlToSet = $mySiteUrl.siteUrl + "/";
            $upm.MySiteHostUrl = $mySiteUrlToSet;
            $upm.PersonalSiteInclusion = "my/personal";

        }
    }
}
#**************************************************************************************

#**************************************************************************************
# Primary Statement Blocks
#**************************************************************************************

$global:xmlinput.Configuration.WebApplications.WebApplication | ForEach-Object {
    $waInput = $_;
    CreateWebApp $_; 
}
CreateEnterpriseSearchServiceApp $global:xmlinput;

ConfigureMySiteSettings $global:xmlinput.Configuration;

#**************************************************************************************