param(
    [Parameter(Mandatory = $true)]
    [string]$SiteName,

    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$PhysicalPath,

    [string]$AppPoolName = "$SiteName-AppPool",
    [string]$HostName = "localhost",
    [int]$Port = 80,
    [int]$HttpsPort = 443,
    [switch]$EnableSsl,
    [string]$SslCertificateThumbprint,
    [string]$LogFilePath = "$PSScriptRoot\logs\deploy-$SiteName.jsonl",
    [int]$MaxLogSizeMB = 50,
    [int]$LogRetentionDays = 30,
    [string]$SplunkHecUrl,
    [string]$SplunkHecToken,
    [string]$SplunkSourceType = "iis_deployment",
    [switch]$EnableSplunkForwarding
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
        Script    = "deploy-iis-app.ps1"
        SiteName  = $SiteName
        AppPool   = $AppPoolName
        HostName  = $HostName
        Port      = $Port
        HttpsPort = $HttpsPort
    }

    foreach ($key in $Data.Keys) {
        $entry[$key] = $Data[$key]
    }

    $jsonLine = $entry | ConvertTo-Json -Compress -Depth 6
    $logDir = Split-Path -Parent $LogFilePath
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Rotate-LogFile -Path $LogFilePath -MaxSizeMB $MaxLogSizeMB -RetentionDays $LogRetentionDays
    Add-Content -Path $LogFilePath -Value $jsonLine
    Write-Host $jsonLine

    if ($EnableSplunkForwarding) {
        try {
            $splunkBody = [ordered]@{
                time = [int][Math]::Round((Get-Date).ToUniversalTime().Subtract([datetime]::new(1970,1,1,0,0,0, [System.DateTimeKind]::Utc)).TotalSeconds)
                host = $env:COMPUTERNAME
                source = $SiteName
                sourcetype = $SplunkSourceType
                event = $entry
            } | ConvertTo-Json -Depth 6

            $headers = @{ Authorization = "Splunk $SplunkHecToken" }
            Invoke-RestMethod -Uri $SplunkHecUrl -Method Post -Headers $headers -Body $splunkBody -ContentType "application/json" | Out-Null
        }
        catch {
            Write-Warning "Splunk HEC forwarding failed: $($_.Exception.Message)"
        }
    }
}

function Rotate-LogFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxSizeMB = 50,
        [int]$RetentionDays = 30
    )

    if (-not (Test-Path $Path)) {
        return
    }

    $fileInfo = Get-Item -Path $Path
    $maxBytes = $MaxSizeMB * 1MB
    if ($fileInfo.Length -lt $maxBytes) {
        return
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $archivedPath = "$Path.$timestamp.log"
    Move-Item -Path $Path -Destination $archivedPath -Force

    Get-ChildItem -Path "$Path.*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Ensure-IISModule {
    if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
        throw "WebAdministration module is not installed. Install IIS Management Console and retry."
    }
    Import-Module WebAdministration -ErrorAction Stop
}

function Ensure-AppPool {
    param([string]$Name)

    $pool = Get-Item "IIS:\AppPools\$Name" -ErrorAction SilentlyContinue
    if (-not $pool) {
        New-Item "IIS:\AppPools\$Name" -Force | Out-Null
        Write-StructuredLog -Level "INFO" -Message "Created IIS application pool" -Data @{ AppPool = $Name }
    }

    Set-ItemProperty "IIS:\AppPools\$Name" -Name managedRuntimeVersion -Value "v4.0"
    Set-ItemProperty "IIS:\AppPools\$Name" -Name managedPipelineMode -Value "Integrated"
    Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.identityType -Value "ApplicationPoolIdentity"
}

function Ensure-Website {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Pool
    )

    if (Test-Path "IIS:\Sites\$Name") {
        Stop-Website -Name $Name -ErrorAction SilentlyContinue
        Remove-Website -Name $Name -ErrorAction SilentlyContinue
        Write-StructuredLog -Level "INFO" -Message "Removed existing IIS website" -Data @{ Website = $Name }
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    New-Website -Name $Name -Port $Port -HostHeader $HostName -PhysicalPath $Path -ApplicationPool $Pool | Out-Null

    if ($EnableSsl) {
        if ([string]::IsNullOrWhiteSpace($SslCertificateThumbprint)) {
            throw "SSL is enabled but no certificate thumbprint was supplied."
        }

        $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $SslCertificateThumbprint }
        if (-not $cert) {
            throw "SSL certificate with thumbprint $SslCertificateThumbprint was not found in LocalMachine\My."
        }

        New-WebBinding -Name $Name -Protocol https -Port $HttpsPort -HostHeader $HostName -ErrorAction SilentlyContinue | Out-Null
        $binding = Get-WebBinding -Name $Name -Protocol https
        $binding.AddSslCertificate($cert.Thumbprint, "my")
        Write-StructuredLog -Level "INFO" -Message "Enabled HTTPS binding" -Data @{ Website = $Name; Port = $HttpsPort; Thumbprint = $SslCertificateThumbprint }
    }

    Write-StructuredLog -Level "INFO" -Message "Created IIS website" -Data @{ Website = $Name; Path = $Path; HttpPort = $Port; HttpsPort = $HttpsPort; HostHeader = $HostName }
}

try {
    Write-StructuredLog -Level "INFO" -Message "Starting deployment" -Data @{ Step = "initialization" }

    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script as Administrator."
    }

    if (-not (Test-Path $SourcePath)) {
        throw "Source folder not found: $SourcePath"
    }

    if (-not (Test-Path $PhysicalPath)) {
        New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null
    }

    if ($EnableSplunkForwarding -and ([string]::IsNullOrWhiteSpace($SplunkHecUrl) -or [string]::IsNullOrWhiteSpace($SplunkHecToken))) {
        throw "Splunk HEC forwarding is enabled but HEC URL or token was not provided."
    }

    Ensure-IISModule
    Ensure-AppPool -Name $AppPoolName

    Get-ChildItem -Path $PhysicalPath -Force | Remove-Item -Recurse -Force
    Copy-Item -Path (Join-Path $SourcePath '*') -Destination $PhysicalPath -Recurse -Force

    Ensure-Website -Name $SiteName -Path $PhysicalPath -Pool $AppPoolName
    Start-Website -Name $SiteName

    Write-StructuredLog -Level "INFO" -Message "Deployment completed successfully" -Data @{ SourcePath = $SourcePath; PhysicalPath = $PhysicalPath }
}
catch {
    Write-StructuredLog -Level "ERROR" -Message $_.Exception.Message -Data @{ Step = "failed" }
    throw
}

<#
Example:

PowerShell -ExecutionPolicy Bypass -File .\deploy-iis-app.ps1 `
  -SiteName "MyApp" `
  -SourcePath "C:\build\MyApp" `
  -PhysicalPath "C:\inetpub\wwwroot\MyApp" `
  -AppPoolName "MyAppPool" `
  -HostName "myapp.local" `
  -Port 80 `
  -EnableSsl `
  -SslCertificateThumbprint "ABC123..." `
  -HttpsPort 443 `
  -EnableSplunkForwarding `
  -SplunkHecUrl "https://splunk.example.com:8088/services/collector" `
  -SplunkHecToken "YOUR_TOKEN"
#>
