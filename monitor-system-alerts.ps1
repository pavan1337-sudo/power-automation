param(
    [Parameter(Mandatory = $true)]
    [string[]]$ComputerNames,

    [int]$CpuThresholdPercent = 85,
    [int]$MemoryThresholdPercent = 85,
    [int]$DiskThresholdPercent = 85,
    [string]$SmtpServer,
    [int]$SmtpPort = 587,
    [string]$FromAddress,
    [string]$ToAddress,
    [string]$SmtpUsername,
    [string]$SmtpPassword,
    [string]$LogFilePath = "$PSScriptRoot\logs\monitor-alerts.jsonl",
    [string]$ReportPath = "$PSScriptRoot\logs\monitor-report",
    [string[]]$ServiceNames,
    [switch]$SendEmail,
    [switch]$UseSsl,
    [switch]$ExportReport
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
        Script = "monitor-system-alerts.ps1"
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
    $credential = Get-Credential -Message "Enter credentials to query remote systems"
    return $credential
}

function Get-SystemMetrics {
    param(
        [string]$ComputerName,
        [pscredential]$Credential
    )

    $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction SilentlyContinue
    if (-not $session) {
        Write-StructuredLog -Level "WARN" -Message "Unable to connect to host" -Data @{ ComputerName = $ComputerName }
        return $null
    }

    try {
        $result = Invoke-Command -Session $session -ScriptBlock {
            $cpu = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples | Select-Object -First 1 -ExpandProperty CookedValue
            $memory = Get-CimInstance Win32_OperatingSystem
            $totalMemoryGB = [math]::Round($memory.TotalVisibleMemorySize / 1MB, 2)
            $freeMemoryGB = [math]::Round($memory.FreePhysicalMemory / 1MB, 2)
            $memoryPercent = [math]::Round((($totalMemoryGB - $freeMemoryGB) / $totalMemoryGB) * 100, 2)

            $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
                $usedPercent = [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 2)
                [PSCustomObject]@{
                    Drive = $_.DeviceID
                    UsedPercent = $usedPercent
                }
            }

            $services = @()
            if ($using:ServiceNames -and $using:ServiceNames.Count -gt 0) {
                foreach ($serviceName in $using:ServiceNames) {
                    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                    $services += [PSCustomObject]@{
                        ServiceName = $serviceName
                        Status = if ($service) { $service.Status.ToString() } else { 'NotFound' }
                    }
                }
            }

            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                CpuPercent = [math]::Round($cpu, 2)
                MemoryPercent = $memoryPercent
                Disks = $disks
                Services = $services
            }
        }

        return $result
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

function Send-AlertEmail {
    param(
        [string]$ComputerName,
        [string]$Subject,
        [string]$Body,
        [pscredential]$Credential
    )

    if (-not $SendEmail) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($SmtpServer) -or [string]::IsNullOrWhiteSpace($FromAddress) -or [string]::IsNullOrWhiteSpace($ToAddress)) {
        throw "SMTP server, from address, and to address are required when SendEmail is used."
    }

    $smtp = [System.Net.Mail.SmtpClient]::new($SmtpServer, $SmtpPort)
    $smtp.EnableSsl = $UseSsl.IsPresent
    if ($SmtpUsername -and $SmtpPassword) {
        $smtp.Credentials = New-Object System.Net.NetworkCredential($SmtpUsername, $SmtpPassword)
    }

    $mail = [System.Net.Mail.MailMessage]::new()
    $mail.From = [System.Net.Mail.MailAddress]::new($FromAddress)
    $mail.To.Add($ToAddress)
    $mail.Subject = $Subject
    $mail.Body = $Body
    $mail.IsBodyHtml = $false

    $smtp.Send($mail)
    Write-StructuredLog -Level "INFO" -Message "Email alert sent" -Data @{ ComputerName = $ComputerName; Subject = $Subject }
}

try {
    Write-StructuredLog -Level "INFO" -Message "Starting system monitoring" -Data @{ Step = "initialization" }

    $credential = Get-DeploymentCredential

    $alerts = New-Object System.Collections.Generic.List[object]
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($computer in $ComputerNames) {
        $metrics = Get-SystemMetrics -ComputerName $computer -Credential $credential
        if (-not $metrics) { continue }

        if ($metrics.CpuPercent -ge $CpuThresholdPercent) {
            $alerts.Add([PSCustomObject]@{ ComputerName = $computer; Type = "CPU"; Value = $metrics.CpuPercent })
        }

        if ($metrics.MemoryPercent -ge $MemoryThresholdPercent) {
            $alerts.Add([PSCustomObject]@{ ComputerName = $computer; Type = "Memory"; Value = $metrics.MemoryPercent })
        }

        foreach ($disk in $metrics.Disks) {
            if ($disk.UsedPercent -ge $DiskThresholdPercent) {
                $alerts.Add([PSCustomObject]@{ ComputerName = $computer; Type = "Disk"; Value = $disk.UsedPercent; Drive = $disk.Drive })
            }
        }

        $results.Add([PSCustomObject]@{
            ComputerName = $computer
            CpuPercent = $metrics.CpuPercent
            MemoryPercent = $metrics.MemoryPercent
            Services = $metrics.Services
            Disks = $metrics.Disks
        })

        Write-StructuredLog -Level "INFO" -Message "Captured metrics" -Data @{ ComputerName = $computer; CpuPercent = $metrics.CpuPercent; MemoryPercent = $metrics.MemoryPercent }
    }

    if ($ExportReport) {
        if (-not (Test-Path $ReportPath)) {
            New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null
        }

        $csvPath = Join-Path $ReportPath "monitor-report.csv"
        $htmlPath = Join-Path $ReportPath "monitor-report.html"

        $results | Export-Csv -Path $csvPath -NoTypeInformation

        $html = @"
        <html><body><h2>System Monitoring Report</h2><table border="1" cellpadding="5"><tr><th>ComputerName</th><th>CPU%</th><th>Memory%</th><th>Services</th></tr>
        "@
        foreach ($item in $results) {
            $serviceText = ($item.Services | ForEach-Object { "{0}:{1}" -f $_.ServiceName, $_.Status }) -join '<br/>'
            $html += "<tr><td>$($item.ComputerName)</td><td>$($item.CpuPercent)</td><td>$($item.MemoryPercent)</td><td>$serviceText</td></tr>"
        }
        $html += "</table></body></html>"
        Set-Content -Path $htmlPath -Value $html -Encoding UTF8

        Write-StructuredLog -Level "INFO" -Message "Report exported" -Data @{ CsvPath = $csvPath; HtmlPath = $htmlPath }
    }

    if ($alerts.Count -gt 0) {
        $body = "System alerts detected:`n`n"
        foreach ($alert in $alerts) {
            $body += "- $($alert.ComputerName): $($alert.Type) at $($alert.Value)%"
            if ($alert.Drive) { $body += " on drive $($alert.Drive)" }
            $body += "`n"
        }

        foreach ($alert in $alerts) {
            Send-AlertEmail -ComputerName $alert.ComputerName -Subject "System Alert: $($alert.Type) on $($alert.ComputerName)" -Body $body -Credential $credential
        }
    }
    else {
        Write-StructuredLog -Level "INFO" -Message "No alerts detected" -Data @{ Step = "completed" }
    }
}
catch {
    Write-StructuredLog -Level "ERROR" -Message $_.Exception.Message -Data @{ Step = "failed" }
    throw
}

<#
Example:

PowerShell -ExecutionPolicy Bypass -File .\monitor-system-alerts.ps1 `
  -ComputerNames @("srv-app01","srv-app02","srv-sys01") `
  -CpuThresholdPercent 85 `
  -MemoryThresholdPercent 85 `
  -DiskThresholdPercent 90 `
  -SendEmail `
  -SmtpServer "smtp.contoso.com" `
  -SmtpPort 587 `
  -FromAddress "monitor@contoso.com" `
  -ToAddress "ops@contoso.com" `
  -SmtpUsername "monitor-user" `
  -SmtpPassword "your-password" `
  -UseSsl
#>
