Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    Id        = 41, 1074, 6006, 6008, 1001
    StartTime = (Get-Date).AddDays(-1)
} | Select-Object TimeCreated, Id, Message | Format-List
