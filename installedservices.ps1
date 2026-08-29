Get-Service | Where-Object { $_.DisplayName -like "*Microsoft*" } |
    Sort-Object DisplayName |
    Format-Table Name, DisplayName, Status