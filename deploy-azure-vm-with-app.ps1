param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$VmSize = "Standard_B2s",

    [Parameter(Mandatory = $true)]
    [string]$AdminUsername,

    [Parameter(Mandatory = $true)]
    [string]$AdminPassword,

    [Parameter(Mandatory = $true)]
    [string]$VnetName,

    [Parameter(Mandatory = $true)]
    [string]$SubnetName,

    [Parameter(Mandatory = $true)]
    [string]$Image = "Win2019Datacenter",

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$StorageContainerName,

    [Parameter(Mandatory = $true)]
    [string]$BlobPath,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]$AppConfigRepoUrl,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $true)]
    [string]$WorkspacePrimarySharedKey,

    [string]$LogAnalyticsWorkspaceName = "law-$VmName"
)

$ErrorActionPreference = "Stop"

function Write-StructuredLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message,
        [hashtable]$Data = @{}
    )

    $entry = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Level     = $Level
        Message   = $Message
        Script    = "deploy-azure-vm-with-app.ps1"
        ResourceGroup = $ResourceGroupName
        VmName = $VmName
        Environment = $EnvironmentName
    }

    foreach ($key in $Data.Keys) {
        $entry[$key] = $Data[$key]
    }

    $jsonLine = $entry | ConvertTo-Json -Compress -Depth 6
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $logFile = Join-Path $logDir "deploy-$VmName.jsonl"
    Add-Content -Path $logFile -Value $jsonLine
    Write-Host $jsonLine
}

function Ensure-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI (az) is not installed or not in PATH."
    }
}

function Invoke-AzCli {
    param([string[]]$Args)

    $output = az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Args -join ' ')`n$output"
    }
    return $output
}

function New-UserDataScript {
    param(
        [string]$StorageAccountName,
        [string]$StorageContainerName,
        [string]$BlobPath,
        [string]$EnvironmentName,
        [string]$AppConfigRepoUrl,
        [string]$WorkspaceResourceId,
        [string]$WorkspacePrimarySharedKey,
        [string]$VmName
    )

    $scriptContent = @"
<powershell>
$ErrorActionPreference = 'Stop'

$env:Path += ';C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\Git\cmd'

# Install IIS and Web-Server features
Install-WindowsFeature Web-Server, Web-Mgmt-Tools, Web-Management-Console -ErrorAction SilentlyContinue

# Install Azure Monitor Agent (Windows)
$workspaceId = '$WorkspaceResourceId'
$workspaceKey = '$WorkspacePrimarySharedKey'
$agentMsi = 'C:\AzureMonitorAgent\AMAWindowsInstaller.msi'
$agentDir = 'C:\AzureMonitorAgent'
New-Item -ItemType Directory -Path $agentDir -Force | Out-Null

$downloadUrl = 'https://packages.microsoft.com/azuremonitoragent/windows/ama-windows-x64.msi'
Invoke-WebRequest -Uri $downloadUrl -OutFile $agentMsi

Start-Process msiexec.exe -ArgumentList '/i', $agentMsi, '/qn' -Wait -NoNewWindow

# Configure Azure Monitor Agent to send logs to workspace
$workspaceConfig = @"
[workspace]
workspaceresourceid = $workspaceId
workspacekey = $workspaceKey
"@
Set-Content -Path 'C:\Program Files\Microsoft Monitoring Agent\Agent\CustomSinks\AzureMonitorAgent.config' -Value $workspaceConfig -Force

# Restart agent service
Restart-Service -Name HealthService -ErrorAction SilentlyContinue

# Install Git and unzip tools if missing
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    choco install git -y
}

# Download application package from Azure Blob Storage
$storageAccount = '$StorageAccountName'
$container = '$StorageContainerName'
$blob = '$BlobPath'
$downloadDir = 'C:\inetpub\wwwroot\app'
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

$storageKey = az storage account keys list -n $storageAccount --query "[0].value" -o tsv
$env:AZURE_STORAGE_CONNECTION_STRING = "DefaultEndpointsProtocol=https;AccountName=$storageAccount;AccountKey=$storageKey;EndpointSuffix=core.windows.net"

az storage blob download --container-name $container --name $blob --file "$downloadDir\app.zip" --auth-mode login
Expand-Archive -Path "$downloadDir\app.zip" -DestinationPath $downloadDir -Force

# Clone environment-specific config from Git or repo URL
$repoUrl = '$AppConfigRepoUrl'
$configDir = 'C:\inetpub\wwwroot\app-config'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

if ($repoUrl -match 'https://') {
    git clone $repoUrl $configDir
    Set-Location $configDir
    git checkout $EnvironmentName
}

# Copy config folder contents into app directory
Copy-Item -Path "$configDir\*" -Destination $downloadDir -Recurse -Force

# Configure IIS site
$siteName = 'Default Web Site'
Remove-Item -Recurse -Force 'C:\inetpub\wwwroot\*'
Copy-Item -Path "$downloadDir\*" -Destination 'C:\inetpub\wwwroot\' -Recurse -Force

# Create a simple app pool if required
Import-Module WebAdministration
if (-not (Get-Item 'IIS:\AppPools\DefaultAppPool' -ErrorAction SilentlyContinue)) {
    New-Item 'IIS:\AppPools\DefaultAppPool' -Force | Out-Null
}

# Configure logging to Azure Monitor/Workspace via IIS logs forwarding
$logPath = 'C:\inetpub\logs\LogFiles\W3SVC1'
New-Item -ItemType Directory -Path $logPath -Force | Out-Null

# Enable application logs and write a bootstrap marker
Set-Content -Path 'C:\inetpub\wwwroot\bootstrap.log' -Value "Deployment completed for $VmName at $(Get-Date -Format o)"

# Restart IIS
iisreset /restart

</powershell>
"@

    return $scriptContent
}

function New-CloudInitFile {
    param([string]$UserDataScript)

    $tempPath = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tempPath -Value $UserDataScript -Encoding UTF8
    return $tempPath
}

try {
    Write-StructuredLog -Level "INFO" -Message "Starting Azure VM deployment" -Data @{ Step = "initialization" }

    Ensure-AzCli

    $resourceGroupExists = az group exists -n $ResourceGroupName
if ($resourceGroupExists -eq 'false') {
    Invoke-AzCli -Args @('group','create','--name',$ResourceGroupName,'--location',$Location)
}

$subnetId = az network vnet subnet show --resource-group $ResourceGroupName --vnet-name $VnetName --name $SubnetName --query id -o tsv
if ([string]::IsNullOrWhiteSpace($subnetId)) {
    throw "Subnet $SubnetName was not found in VNet $VnetName."
}

$userDataScript = New-UserDataScript -StorageAccountName $StorageAccountName -StorageContainerName $StorageContainerName -BlobPath $BlobPath -EnvironmentName $EnvironmentName -AppConfigRepoUrl $AppConfigRepoUrl -WorkspaceResourceId $WorkspaceResourceId -WorkspacePrimarySharedKey $WorkspacePrimarySharedKey -VmName $VmName
$userDataFile = New-CloudInitFile -UserDataScript $userDataScript

Write-Host "Creating Azure VM $VmName in resource group $ResourceGroupName..."

$vmCreateArgs = @(
    'vm','create',
    '--resource-group',$ResourceGroupName,
    '--name',$VmName,
    '--location',$Location,
    '--size',$VmSize,
    '--image',$Image,
    '--admin-username',$AdminUsername,
    '--admin-password',$AdminPassword,
    '--subnet',$subnetId,
    '--nsg-rule','RDP',
    '--public-ip-sku','Standard',
    '--custom-data',$userDataFile
)

Invoke-AzCli -Args $vmCreateArgs

Write-StructuredLog -Level "INFO" -Message "VM deployment completed successfully" -Data @{ Step = "completed" ; UserDataFile = $userDataFile }
Write-Host "VM deployment completed."
Write-Host "User data script stored at: $userDataFile"
}
catch {
    Write-StructuredLog -Level "ERROR" -Message $_.Exception.Message -Data @{ Step = "failed" }
    throw
}
