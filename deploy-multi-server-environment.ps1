param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$TargetRootPath,

    [Parameter(Mandatory = $true)]
    [string[]]$AppServers,

    [Parameter(Mandatory = $true)]
    [string[]]$SysServers,

    [Parameter(Mandatory = $true)]
    [string[]]$GatewayServers,

    [Parameter(Mandatory = $true)]
    [string]$ConfigSourcePath,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentVariablesPath,

    [string]$ServicesFolderName = "services",
    [string]$LogFilePath = "$PSScriptRoot\logs\deploy-$EnvironmentName.jsonl",
    [string]$CredentialUser,
    [string]$CredentialPassword
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
        Level = $Level
        Message = $Message
        Script = "deploy-multi-server-environment.ps1"
        Environment = $EnvironmentName
    }

    foreach ($key in $Data.Keys) {
        $entry[$key] = $Data[$key]
    }

    $jsonLine = $entry | ConvertTo-Json -Compress -Depth 6
    $logDir = Split-Path -Parent $LogFilePath
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Add-Content -Path $LogFilePath -Value $jsonLine
    Write-Host $jsonLine
}

function Get-DeploymentCredential {
    if (-not $CredentialUser -or -not $CredentialPassword) {
        $creds = Get-Credential -Message "Enter credentials for deployment"
        return $creds
    }

    return New-Object System.Management.Automation.PSCredential($CredentialUser, (ConvertTo-SecureString $CredentialPassword -AsPlainText -Force))
}

function Copy-ToServer {
    param(
        [string]$ServerName,
        [string]$SourcePath,
        [string]$DestinationPath,
        [pscredential]$Credential
    )

    if (-not (Test-Path $SourcePath)) {
        throw "Source path not found: $SourcePath"
    }

    $remoteSession = New-PSSession -ComputerName $ServerName -Credential $Credential -ErrorAction Stop
    try {
        Invoke-Command -Session $remoteSession -ScriptBlock {
            param($DestinationPath, $SourcePath)
            if (-not (Test-Path $DestinationPath)) {
                New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            }
            Copy-Item -Path $SourcePath -Destination $DestinationPath -Recurse -Force
        } -ArgumentList $DestinationPath, $SourcePath
    }
    finally {
        Remove-PSSession -Session $remoteSession -ErrorAction SilentlyContinue
    }
}

function Expand-DeploymentPackage {
    param([string]$PackagePath, [string]$DestinationRoot)

    if (-not (Test-Path $PackagePath)) {
        throw "Deployment package not found: $PackagePath"
    }

    $packageName = Split-Path -Leaf $PackagePath
    $tempFolder = Join-Path $env:TEMP $packageName
    if (Test-Path $tempFolder) { Remove-Item $tempFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $tempFolder -Force | Out-Null

    if ([System.IO.Path]::GetExtension($PackagePath) -eq ".zip") {
        Expand-Archive -Path $PackagePath -DestinationPath $tempFolder -Force
    }
    else {
        Copy-Item -Path $PackagePath -Destination $tempFolder -Recurse -Force
    }

    $contentRoot = Join-Path $tempFolder (Get-ChildItem $tempFolder -Directory | Select-Object -First 1 -ExpandProperty FullName)
    if (-not (Test-Path $contentRoot)) {
        $contentRoot = $tempFolder
    }

    Copy-Item -Path (Join-Path $contentRoot '*') -Destination $DestinationRoot -Recurse -Force
}

function Deploy-EnvironmentAssets {
    param(
        [string[]]$ServerNames,
        [string]$Role,
        [string]$PackageRoot,
        [string]$DestinationRoot,
        [pscredential]$Credential
    )

    foreach ($server in $ServerNames) {
        Write-StructuredLog -Level "INFO" -Message "Deploying to server" -Data @{ Role = $Role; Server = $server }
        $remoteRoot = Join-Path $DestinationRoot $Role
        $sourceRoot = Join-Path $PackageRoot $Role

        if (-not (Test-Path $sourceRoot)) {
            Write-StructuredLog -Level "WARN" -Message "Role folder missing in package" -Data @{ Role = $Role; Server = $server }
            continue
        }

        Copy-ToServer -ServerName $server -SourcePath $sourceRoot -DestinationPath $remoteRoot -Credential $Credential
    }
}

try {
    Write-StructuredLog -Level "INFO" -Message "Starting multi-server deployment" -Data @{ Step = "initialization" }

    if (-not (Test-Path $PackagePath)) {
        throw "Deployment package not found: $PackagePath"
    }

    if (-not (Test-Path $ConfigSourcePath)) {
        throw "Config source path not found: $ConfigSourcePath"
    }

    if (-not (Test-Path $EnvironmentVariablesPath)) {
        throw "Environment variables file not found: $EnvironmentVariablesPath"
    }

    $credential = Get-DeploymentCredential

    $stagingRoot = Join-Path $env:TEMP "deployment-$EnvironmentName"
    if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    Expand-DeploymentPackage -PackagePath $PackagePath -DestinationRoot $stagingRoot

    $configTarget = Join-Path $stagingRoot "config"
    New-Item -ItemType Directory -Path $configTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $ConfigSourcePath '*') -Destination $configTarget -Recurse -Force

    $envVarsTarget = Join-Path $stagingRoot "environment-vars"
    New-Item -ItemType Directory -Path $envVarsTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $EnvironmentVariablesPath '*') -Destination $envVarsTarget -Recurse -Force

    $servicesTarget = Join-Path $stagingRoot $ServicesFolderName
    New-Item -ItemType Directory -Path $servicesTarget -Force | Out-Null

    foreach ($role in @('APP','SYS','GATEWAY')) {
        $roleRoot = Join-Path $stagingRoot $role
        if (-not (Test-Path $roleRoot)) {
            New-Item -ItemType Directory -Path $roleRoot -Force | Out-Null
        }
    }

    $appServers = @($AppServers)
    $sysServers = @($SysServers)
    $gatewayServers = @($GatewayServers)

    Deploy-EnvironmentAssets -ServerNames $appServers -Role "APP" -PackageRoot $stagingRoot -DestinationRoot $TargetRootPath -Credential $credential
    Deploy-EnvironmentAssets -ServerNames $sysServers -Role "SYS" -PackageRoot $stagingRoot -DestinationRoot $TargetRootPath -Credential $credential
    Deploy-EnvironmentAssets -ServerNames $gatewayServers -Role "GATEWAY" -PackageRoot $stagingRoot -DestinationRoot $TargetRootPath -Credential $credential

    Write-StructuredLog -Level "INFO" -Message "Multi-server deployment completed successfully" -Data @{ Step = "completed" }
}
catch {
    Write-StructuredLog -Level "ERROR" -Message $_.Exception.Message -Data @{ Step = "failed" }
    throw
}

<#
Example:

PowerShell -ExecutionPolicy Bypass -File .\deploy-multi-server-environment.ps1 `
  -EnvironmentName "Prod" `
  -PackagePath "C:\packages\prod-deployment.zip" `
  -TargetRootPath "C:\deploy" `
  -AppServers @("app01","app02") `
  -SysServers @("sys01") `
  -GatewayServers @("gw01") `
  -ConfigSourcePath "C:\configs\prod" `
  -EnvironmentVariablesPath "C:\configs\envvars\prod"
#>
