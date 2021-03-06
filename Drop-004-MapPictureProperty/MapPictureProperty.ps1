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
#************************************************************************************** 

#**************************************************************************************
# Variables and Constants
#**************************************************************************************
$spsProperty = "Picture";
$fimProperty = "thumbnailPhoto";
$mySiteHostUrl = "http://$($env:COMPUTERNAME):8080/my";
#**************************************************************************************
 
#**************************************************************************************
# Functions
#**************************************************************************************
function MapAttribute([string]$fimProperty, [string]$spsProperty, [string]$connectionName)
{
    $CentralAdminURL = Get-spwebapplication -includecentraladministration | where {$_.IsAdministrationWebApplication} | Select-Object -ExpandProperty Url
    $site = Get-SPSite $CentralAdminURL

     
    if ($site) 
        {Write-Host "Successfully obtained site reference!"} 
    else 
        {Write-Host "Failed to obtain site reference"} 
      
    $serviceContext = Get-SPServiceContext -Site $site;
    
    if ($serviceContext) 
        {Write-Host "Successfully obtained service context!"} 
    else 
        {Write-Host "Failed to obtain service context"} 
    $upManager = new-object Microsoft.Office.Server.UserProfiles.UserProfileConfigManager($serviceContext) 
    
    if ($upManager) 
        {Write-Host "Successfully obtained user profile manager!"} 
    else 
        {Write-Host "Failed to obtain user profile manager"} 
    $synchConnection = $upManager.ConnectionManager 
    
    if ($synchConnection) 
        {Write-Host "Successfully obtained synchronization connection!"} 
    else 
        {Write-Host "Failed to obtain user synchronization connection!"} 
    
    Write-Host "Adding the attribute mapping..." 
    $synchConnection.PropertyMapping.AddNewMapping([Microsoft.Office.Server.UserProfiles.ProfileType]::User, $spsProperty, $fimProperty) 
    Write-Host "Done!"
}

function Get-SPServiceContextLocal([Microsoft.SharePoint.Administration.SPServiceApplication]$profileApp)
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

#**************************************************************************************

#**************************************************************************************
# Primary Statement Blocks
#**************************************************************************************

MapAttribute "thumbnailPhoto" "PictureURL" "corp-contoso-com";

Write-Host "Importing Pictures to MySite ($mySiteHostUrl)";
Update-SPProfilePhotoStore -MySiteHostLocation $mySiteHostUrl -CreateThumbnailsForImportedPhotos $true -Verbose;
#**************************************************************************************