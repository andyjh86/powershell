# Set path to 7-Zip (adjust if installed elsewhere)
$exe7z = "C:\Program Files\7-Zip\7z.exe"

# Get all directories in the current folder
Get-ChildItem -Directory | ForEach-Object {
    $folderName = $_.Name
    $archiveName = "$folderName.7z"
    
    Write-Host "Archiving and encrypting: $folderName"
    
    # Run 7-Zip with password and header encryption enabled
    & $exe7z a -p"password" -mhe=on "$archiveName" ".\$folderName"
}

Write-Host "All folders processed!"
