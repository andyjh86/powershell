###################################
# This script scrapes all image URLS from a website.
# it must be run from a folder with the exact website name. it wil then scan the site and list all images found a link deep (so www.example.com/page and not example.com/page/subpage/)
# open powershell in the folder named www.example.com and the script will produce an excel with all image urls
######################################



# 1. Get the current folder name and build the target URL and CSV output path
$FolderName = Split-Path -Path $PWD -Leaf
$BaseUrl = "https://$FolderName"
$CsvPath = Join-Path -Path $PWD -ChildPath "$FolderName-images.csv"

$Headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
}

function Normalize-Url([string]$Url) {
    $Clean = ($Url -replace '^http://', 'https://').Split('#')[0]
    if ($Clean -match '^https://[^/]+/$') { return $Clean }
    return $Clean.TrimEnd('/')
}

Write-Host "Fetching homepage: $BaseUrl ..." -ForegroundColor Cyan

# 2. Fetch the homepage and resolve any www -> non-www redirect
try {
    $HomeResponse = Invoke-WebRequest -Uri $BaseUrl -Headers $Headers -UseBasicParsing -ErrorAction Stop
    $ActualBaseUri = $HomeResponse.BaseResponse.ResponseUri
    $RootHost = $ActualBaseUri.Host -replace '^www\.', ''
    $NormalizedHome = Normalize-Url $ActualBaseUri.AbsoluteUri
}
catch {
    Write-Error "Failed to load $BaseUrl. Status: $($_.Exception.Message)"
    return
}

# 3. Collect all unique internal page links (1 level deep) from the homepage
$PagesToCrawl = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
[void]$PagesToCrawl.Add($NormalizedHome)

$LinkMatches = [regex]::Matches($HomeResponse.Content, 'href=["'']([^"'']+)["'']', 'IgnoreCase')

foreach ($Match in $LinkMatches) {
    $RawHref = $Match.Groups[1].Value.Trim()
    
    if ($RawHref -match '^(#|mailto:|tel:|javascript:|data:)' -or 
        $RawHref -match '(/wp-json/|/feed/?$|xmlrpc\.php|\?ical=|^/?&$)' -or
        $RawHref -match '\.(jpg|jpeg|png|gif|webp|svg|avif|pdf|zip|css|js|xml|mp4|woff2?|ttf|eot|ico)(\?.*)?$') {
        continue
    }

    try {
        $ResolvedUri = [System.Uri]::new($ActualBaseUri, $RawHref)
        $LinkHost = $ResolvedUri.Host -replace '^www\.', ''

        if ($LinkHost -eq $RootHost -and $ResolvedUri.Scheme -match '^https?$') {
            [void]$PagesToCrawl.Add((Normalize-Url $ResolvedUri.AbsoluteUri))
        }
    }
    catch { }
}

Write-Host "Found $($PagesToCrawl.Count) unique internal pages to scan (1 link deep).`n" -ForegroundColor Cyan

# 4. Crawl each page, extract images, and group results by unique ImageUrl
$ImageRegistry = [ordered]@{}
$ImgRegex = '(?:src|data-src|data-lazy-src)=["'']([^"''>\s]+\.(?:jpg|jpeg|png|gif|webp|svg|avif)(?:\?[^"''>\s]*)?)["'']|url\(["'']?([^"''\)\s]+\.(?:jpg|jpeg|png|gif|webp|svg|avif)(?:\?[^"''\)\s]*)?)["'']?\)'

foreach ($PageUrl in $PagesToCrawl) {
    Write-Host "Scanning page: $PageUrl" -ForegroundColor Yellow

    if ($PageUrl -eq $NormalizedHome) {
        $PageHtml = $HomeResponse.Content
    }
    else {
        try {
            $PageResp = Invoke-WebRequest -Uri $PageUrl -Headers $Headers -UseBasicParsing -ErrorAction Stop
            $PageHtml = $PageResp.Content
        }
        catch {
            Write-Host "  [WARN] Could not load page: $PageUrl" -ForegroundColor DarkYellow
            continue
        }
    }

    $MatchesFound = [regex]::Matches($PageHtml, $ImgRegex, 'IgnoreCase')
    $PageImages = $MatchesFound | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value }
        elseif ($_.Groups[2].Success) { $_.Groups[2].Value }
    } | Select-Object -Unique

    foreach ($ImgSrc in $PageImages) {
        if ($ImgSrc -match '^data:') { continue }

        try {
            if ($ImgSrc -match "^//") {
                $FullImgUrl = "https:$ImgSrc"
            }
            elseif ($ImgSrc -notmatch "^https?://") {
                $FullImgUrl = [System.Uri]::new([System.Uri]$PageUrl, $ImgSrc).AbsoluteUri
            }
            else {
                $FullImgUrl = $ImgSrc
            }
        }
        catch { continue }

        if (-not $ImageRegistry.Contains($FullImgUrl)) {
            try {
                $ImgCheck = Invoke-WebRequest -Uri $FullImgUrl -Headers $Headers -Method Head -UseBasicParsing -ErrorAction Stop
                $Status = "OK"
                $StatusCode = [int]$ImgCheck.StatusCode
                Write-Host "  [OK - $StatusCode] $FullImgUrl" -ForegroundColor Green
            }
            catch {
                $Status = "BROKEN"
                $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "Error" }
                Write-Host "  [BROKEN - $StatusCode] $FullImgUrl" -ForegroundColor Red
            }

            $ImageRegistry[$FullImgUrl] = @{
                Domain     = $FolderName
                Status     = $Status
                StatusCode = $StatusCode
                ImageUrl   = [string]$FullImgUrl
                Pages      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        [void]$ImageRegistry[$FullImgUrl].Pages.Add($PageUrl)
    }
}

# 5. Build explicit flat rows and export to CSV
$Results = @()
foreach ($Key in $ImageRegistry.Keys) {
    $Entry = $ImageRegistry[$Key]
    $Results += [PSCustomObject][ordered]@{
        ImageUrl     = $Entry.ImageUrl
        Status       = $Entry.Status
        StatusCode   = $Entry.StatusCode
        PageCount    = $Entry.Pages.Count
        Domain       = $Entry.Domain
        FoundOnPages = ($Entry.Pages -join " | ")
    }
}

$Results | Select-Object ImageUrl, Status, StatusCode, PageCount, Domain, FoundOnPages | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
Write-Host "`nDone! Scanned $($PagesToCrawl.Count) pages and saved $($Results.Count) unique images to: $CsvPath" -ForegroundColor Cyan
