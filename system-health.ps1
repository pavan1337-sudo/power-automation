<# 
    Basic System Infrastructure Check
    Author: Pavan-ready version
    Purpose: Quick health snapshot of a Windows server/workstation
#>

Write-Host "=== System Infrastructure Check Started ===" -ForegroundColor Cyan

$results = @()

function Add-Result {
    param($Item, $Value)
    $results += [PSCustomObject]@{
        Item  = $Item
        Value = $Value
    }
}

# -----------------------------
# 1. OS Information
# -----------------------------
$os = Get-CimInstance Win32_OperatingSystem
Add-Result "OS Caption" $os.Caption
Add-Result "OS Version" $os.Version
Add-Result "Last Boot Time" $os.LastBootUpTime

# -----------------------------
# 2. CPU Info
# -----------------------------
$cpu = Get-CimInstance Win32_Processor
Add-Result "CPU Name" $cpu.Name
Add-Result "CPU Cores" $cpu.NumberOfCores
Add-Result "CPU Load (%)" $cpu.LoadPercentage

# -----------------------------
# 3. Memory Info
# -----------------------------
$memTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$memFree  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)

Add-Result "Total Memory (GB)" $memTotal
Add-Result "Free Memory (GB)" $memFree

# -----------------------------
# 4. Disk Info (C:)
# -----------------------------
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$diskFree = [math]::Round($disk.FreeSpace / 1GB, 2)
$diskTotal = [math]::Round($disk.Size / 1GB, 2)

Add-Result "Disk Total (GB)" $diskTotal
Add-Result "Disk Free (GB)" $diskFree

# -----------------------------
# 5. Network Info
# -----------------------------
$net = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "169.*"}
Add-Result "IP Address" $net.IPAddress
Add-Result "Interface Alias" $net.InterfaceAlias

# -----------------------------
# 6. Important Services
# -----------------------------
$services = @("Winmgmt","BITS","W32Time")

foreach ($svc in $services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    Add-Result "Service: $svc" ($s.Status)
}

# -----------------------------
# OUTPUT
# -----------------------------
Write-Host "`n=== System Infra Summary ===" -ForegroundColor Yellow
$results | Format-Table -AutoSize

Write-Host "`n=== Check Completed ===" -ForegroundColor Cyan