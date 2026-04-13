[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$configFile = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $configFile)) {
    Write-Host "Error: config.ps1 not found. Please create it from config.example.ps1"
    exit
}
. $configFile

$logFile = Join-Path $localTemp "rip_log_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').txt"

if (-not (Test-Path $localTemp)) { New-Item -ItemType Directory -Path $localTemp | Out-Null }

function Write-Log($message) {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Invoke-Claude($prompt) {
    $body = @{
        model = "claude-sonnet-4-6"
        max_tokens = 500
        messages = @(@{ role = "user"; content = $prompt })
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" `
            -Method POST `
            -Headers @{
                "x-api-key" = $claudeApiKey
                "anthropic-version" = "2023-06-01"
                "content-type" = "application/json"
            } -Body $body
        return $response.content[0].text.Trim()
    } catch {
        Write-Log "Error calling Claude API: $_"
        return $null
    }
}

function New-Title {
    return @{ Size = 0; SizeText = ""; Duration = ""; AudioTrackNums = @(); AudioTracks = @{}; VideoCodec = ""; Resolution = ""; ChapterCount = 0 }
}

# Verify tools exist
if (-not (Test-Path $makemkvcon)) { Write-Log "Error: MakeMKV not found at $makemkvcon"; exit }
if (-not (Test-Path $mkvmerge)) { Write-Log "Error: MKVToolNix not found at $mkvmerge"; exit }

# Ask for destination upfront
Write-Host ""
$destRoot = Read-Host "Enter destination folder (press Enter for $defaultDestRoot)"
if ([string]::IsNullOrWhiteSpace($destRoot)) {
    $destRoot = $defaultDestRoot
}

# Find disc
Write-Log "Scanning for disc..."
$discInfo = & $makemkvcon -r info disc:0 2>&1
$driveFound = $discInfo | Where-Object { $_ -match '^DRV:0,' -and $_ -notmatch ',256,' }

if (-not $driveFound) {
    Write-Log "Error: No disc found in drive 0. Please insert disc and try again."
    exit
}

Write-Log "Disc found. Fetching title information..."
$infoOutput = & $makemkvcon -r info disc:0 2>&1

# Extract disc name from CINFO
$discName = ""
foreach ($line in $infoOutput) {
    if ($line -match '^CINFO:2,0,"([^"]+)"') {
        $discName = $matches[1]
        break
    }
}

$namePrompt = @"
The following is a Blu-ray disc name: "$discName"

Please identify the movie and format it exactly as: Movie Name (Year)
For example: The Dark Knight (2008)
Make sure the name matches the title on https://www.themoviedb.org/

Return your answer as: NAME:Movie Name (Year)
If you cannot identify the movie with confidence, return: NAME:UNKNOWN
The formatting of the last line is important since I will parse your response with regex: NAME:(.+)

Important: Do not use special Unicode characters like checkmarks or cross marks in your response. Use plain text only.
"@

$claudeNameResponse = Invoke-Claude $namePrompt
Write-Log "Claude name response: $claudeNameResponse"

$nameMatch = [regex]::Match($claudeNameResponse, 'NAME:(.+)')
if ($nameMatch.Success) {
    $extractedName = $nameMatch.Groups[1].Value.Trim()
    if ($extractedName -ne "UNKNOWN" -and $extractedName -match '.+\(\d{4}\)') {
        $movieName = $extractedName
        Write-Log "Claude identified movie: $movieName"
    } else {
        Write-Log "Claude could not identify movie from disc name."
    }
} else {
    Write-Log "Claude returned unexpected response for movie name."
}

# Fall back to manual input if needed
if (-not $movieName) {
    Write-Host ""
    $movieName = Read-Host "Enter movie name and year (e.g. Inception (2010))"
    if ([string]::IsNullOrWhiteSpace($movieName)) {
        Write-Host "No movie name entered. Exiting."
        exit
    }
}

$movieFolder = Join-Path $destRoot $movieName
$finalMkv = Join-Path $movieFolder "$movieName.mkv"

Write-Log "Movie: $movieName"
Write-Log "Destination: $movieFolder"

if (Test-Path $finalMkv) {
    Write-Log "WARNING: MKV already exists at $finalMkv"
    $confirm = Read-Host "Overwrite? (y/n)"
    if ($confirm -ne 'y') {
        Write-Log "Aborted by user."
        exit
    }
}

# Parse titles
$titles = @{}

foreach ($line in $infoOutput) {
    if ($line -match '^TINFO:(\d+),11,0,"(\d+)"') {
        $tNum = [int]$matches[1]
        if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
        $titles[$tNum].Size = [long]$matches[2]
        $titles[$tNum].SizeText = [math]::Round([long]$matches[2] / 1GB, 2).ToString() + " GB"
    }
    if ($line -match '^TINFO:(\d+),9,0,"([^"]+)"') {
        $tNum = [int]$matches[1]
        if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
        $titles[$tNum].Duration = $matches[2]
    }
    if ($line -match '^SINFO:(\d+),0,7,0,"([^"]+)"') {
        $tNum = [int]$matches[1]
        if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
        $titles[$tNum].VideoCodec = $matches[2]
    }
    if ($line -match '^SINFO:(\d+),(\d+),1,6202,"Audio"') {
        $tNum = [int]$matches[1]; $trackNum = [int]$matches[2]
        if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
        if (-not $titles[$tNum].AudioTracks.ContainsKey($trackNum)) {
            $titles[$tNum].AudioTracks[$trackNum] = @{ TrackNum = $trackNum; ShortName = ""; Language = "" }
            $titles[$tNum].AudioTrackNums += $trackNum
        }
    }
    if ($line -match '^SINFO:(\d+),(\d+),6,0,"([^"]+)"') {
        $tNum = [int]$matches[1]; $trackNum = [int]$matches[2]
        if ($titles.ContainsKey($tNum) -and $titles[$tNum].AudioTracks.ContainsKey($trackNum)) {
            $titles[$tNum].AudioTracks[$trackNum].ShortName = $matches[3]
        }
    }
    if ($line -match '^SINFO:(\d+),(\d+),3,0,"([a-z]{3})"') {
        $tNum = [int]$matches[1]; $trackNum = [int]$matches[2]
        if ($titles.ContainsKey($tNum) -and $titles[$tNum].AudioTracks.ContainsKey($trackNum)) {
            $titles[$tNum].AudioTracks[$trackNum].Language = $matches[3]
        }
    }
	if ($line -match '^TINFO:(\d+),25,0,"(\d+)"') {
        $tNum = [int]$matches[1]
        if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
        $titles[$tNum].ChapterCount = [int]$matches[2]
    }
    if ($line -match '^SINFO:(\d+),0,19,0,"([^"]+)"') {
        $tNum = [int]$matches[1]
        if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
        $titles[$tNum].Resolution = $matches[2]
    }
}

# Build title list for display and Claude
Write-Log ""
Write-Log "Available titles:"
$titleLines = @()
foreach ($t in ($titles.GetEnumerator() | Where-Object { $_.Value.AudioTracks.Count -gt 0 } | Sort-Object Key)) {
    $audioList = ($t.Value.AudioTrackNums | ForEach-Object { $t.Value.AudioTracks[$_] } | ForEach-Object { "$($_.ShortName)[$($_.Language)]" }) -join ", "
    Write-Log "  Title $($t.Key): $($t.Value.VideoCodec), $($t.Value.Duration), $($t.Value.SizeText), $($t.Value.Resolution), $($t.Value.ChapterCount) chapters"
    Write-Log "    Audio: $audioList"
	$titleLines += "Title $($t.Key): $($t.Value.VideoCodec), $($t.Value.Duration), $($t.Value.SizeText), $($t.Value.Resolution), $($t.Value.ChapterCount) chapters, Audio: $audioList"
}

# Ask Claude to pick the best title
Write-Log ""
Write-Log "Asking Claude to select best title..."
$titlePrompt = @"
I am ripping the Blu-ray movie '$movieName'. Below are the available titles found on the disc. Please identify which title number is the main feature film. Consider the expected runtime of this movie and look for the title that best matches. Ignore bonus features, trailers, commentary tracks and short clips.

Return your answer as: TITLE:number
For example: TITLE:4
If you cannot determine the main feature with confidence, return: TITLE:UNKNOWN
The formatting for the last line is important since I will parse your response with regex: TITLE:(\w+)

Important: Do not use special Unicode characters like checkmarks or cross marks in your response. Use plain text only.

$($titleLines -join "`n")
"@

$claudeTitleResponse = Invoke-Claude $titlePrompt
Write-Log "Claude title response: $claudeTitleResponse"

$titleMatch = [regex]::Match($claudeTitleResponse, 'TITLE:(\w+)')
if ($titleMatch.Success -and $titleMatch.Groups[1].Value -match '^\d+$') {
    $chosenTitle = [int]$titleMatch.Groups[1].Value
    Write-Log "Claude selected title: $chosenTitle"
} else {
    Write-Log "Claude could not determine title. Please select manually."
    Write-Host ""
    $val = Read-Host "Enter title number"
    $chosenTitle = [int]$val
}

# Rip
Write-Host ""
Write-Log "Step 1: Ripping title $chosenTitle from disc..."

$beforeRip = Get-Date
$tempMkv = Join-Path $localTemp "temp_ripping_$([System.Guid]::NewGuid().ToString('N')).mkv"
& $makemkvcon mkv disc:0 $chosenTitle "$localTemp"
$generatedMkv = Get-ChildItem -Path $localTemp -Filter "*.mkv" | Where-Object { $_.LastWriteTime -gt $beforeRip } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $generatedMkv) {
    Write-Log "Error: Could not find ripped MKV file. Exiting."
    exit
}

Rename-Item -Path $generatedMkv.FullName -NewName (Split-Path $tempMkv -Leaf)

# Identify audio tracks
Write-Log ""
Write-Log "Step 2: Identifying audio tracks in MKV..."

try {
    $identifyOutput = & $mkvmerge --identify --identification-format json "$tempMkv" 2>&1
    $mkvJson = $identifyOutput | ConvertFrom-Json
} catch {
    Write-Log "Error: Failed to parse MKVToolNix JSON output: $_. Exiting."
    exit
}

$mkvAudioTracks = $mkvJson.tracks | Where-Object { $_.type -eq "audio" }

if (-not $mkvAudioTracks) {
    Write-Log "Error: No audio tracks found in MKV. Exiting."
    exit
}

Write-Log "Audio tracks in MKV:"
$trackLines = @()
foreach ($track in $mkvAudioTracks) {
    $lang = $track.properties.language
    $codec = $track.codec
    $channels = $track.properties.audio_channels
    $sampleRate = $track.properties.audio_sampling_frequency
    $bitDepth = $track.properties.audio_bits_per_sample
    $trackName = $track.properties.track_name
    $default = $track.properties.default_track
    $forced = $track.properties.forced_track

    $info = "Track $($track.id): $codec [$lang]"
    if ($channels) { $info += ", $channels channels" }
    if ($sampleRate) { $info += ", ${sampleRate}Hz" }
    if ($bitDepth) { $info += ", ${bitDepth}-bit" }
    if ($trackName) { $info += ", name: '$trackName'" }
    if ($default) { $info += ", default" }
    if ($forced) { $info += ", forced" }

    Write-Log "  $info"
    $trackLines += $info
}

# Ask Claude to pick the best audio tracks
Write-Log ""
Write-Log "Asking Claude to select audio tracks..."
$langList = $preferredAudioLanguages -join ", "
$audioPrompt = @"
I have an MKV file of the movie '$movieName' with the following audio tracks. Please select which track IDs to keep based on these rules:
1. Keep the highest quality format available (TrueHD or DTS-HD MA preferred over DTS or AC-3)
2. Keep tracks in these preferred languages: $langList
3. Keep the original language of the film if it is not English
4. If multiple tracks exist for the same language at different quality levels, keep only the highest quality one. If multiple tracks exist for the same language at the same quality level, keep ALL of them as they may be different mixes.

Return your final answer as: KEEP:1,2,3
The formatting of the last line is important since I will parse your response with regex: KEEP:([\d,\s]+)

Important: Do not use special Unicode characters like checkmarks or cross marks in your response. Use plain text only.

$($trackLines -join "`n")
"@

$claudeAudioResponse = Invoke-Claude $audioPrompt
Write-Log "Claude audio response: $claudeAudioResponse"

$match = [regex]::Match($claudeAudioResponse, 'KEEP:([\d,\s]+)')
if (-not $match.Success) {
    Write-Log "Claude could not determine audio tracks. Keeping all tracks."
    $keepIds = $mkvAudioTracks | ForEach-Object { "$($_.id)" }
} else {
    $keepIds = $match.Groups[1].Value -split "," | ForEach-Object { $_.Trim() }
    Write-Log "Claude selected tracks: $($keepIds -join ', ')"
}

if ($keepIds.Count -eq 0) {
    Write-Log "No track IDs extracted. Keeping all tracks."
    $keepIds = $audioTracks | ForEach-Object { "$($_.id)" }
}

# Filter with MKVToolNix
Write-Log ""
Write-Log "Step 3: Filtering with MKVToolNix..."

$localFinalMkv = Join-Path $localTemp "$movieName.mkv"
$audioArg = $keepIds -join ","

& $mkvmerge -o "$localFinalMkv" --audio-tracks $audioArg "$tempMkv"

if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
    Remove-Item -Path $tempMkv
    Write-Log "Removed temporary MKV."
} else {
    Write-Log "Error: MKVToolNix failed (exit code $LASTEXITCODE). Temporary MKV kept at: $tempMkv"
    exit
}

# Check display dimensions
$videoJson = & $mkvmerge --identify --identification-format json "$localFinalMkv" 2>&1 | ConvertFrom-Json
$videoTrack = $videoJson.tracks | Where-Object { $_.type -eq "video" } | Select-Object -First 1

if ($videoTrack) {
    $displayDim = $videoTrack.properties.display_dimensions
    $pixelDim = $videoTrack.properties.pixel_dimensions

    if ($displayDim -match '(\d+)x(\d+)') {
        $dispW = [int]$matches[1]
        $dispH = [int]$matches[2]
        $ratio = $dispW / $dispH

        if ($ratio -gt 0.9 -and $ratio -lt 1.1) {
            Write-Log "WARNING: Display dimensions look wrong ($displayDim, nearly 1:1). Pixel dimensions are $pixelDim."
            Write-Log "Please check the video manually and select the correct aspect ratio."
            Write-Host ""
            Write-Host "Common aspect ratios:"
            Write-Host "  1: 16:9  (1920x1080)"
            Write-Host "  2: 2.35:1 Scope (1920x816)"
            Write-Host "  3: 2.39:1 Scope (1920x803)"
            Write-Host "  4: 4:3  (1440x1080)"
            Write-Host "  5: Keep as is"
            $arChoice = Read-Host "Select aspect ratio (1-5)"

            $newW = $null
            $newH = $null
            switch ($arChoice) {
                "1" { $newW = 1920; $newH = 1080 }
                "2" { $newW = 1920; $newH = 816 }
                "3" { $newW = 1920; $newH = 803 }
                "4" { $newW = 1440; $newH = 1080 }
            }

            if ($newW -and $newH) {
                & $mkvpropedit "$localFinalMkv" --edit track:v1 --set display-width=$newW --set display-height=$newH
                if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
                    Write-Log "Fixed display dimensions to ${newW}x${newH}."
                } else {
                    Write-Log "WARNING: Failed to fix display dimensions."
                }
            } else {
                Write-Log "Display dimensions kept as is."
            }
        }
    }
}

# Copy to NAS
Write-Log ""
Write-Log "Step 4: Copying to NAS..."

if (-not (Test-Path $movieFolder)) {
    New-Item -ItemType Directory -Path $movieFolder | Out-Null
    Write-Log "Created folder: $movieFolder"
}

# Write minimal NFO with source
$nfoPath = Join-Path $movieFolder "$movieName.nfo"
if (-not (Test-Path $nfoPath)) {
    $nfoContent = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
    <source>Blu-ray</source>
</movie>
"@
    [System.IO.File]::WriteAllText($nfoPath, $nfoContent, [System.Text.Encoding]::UTF8)
    Write-Log "Created NFO with source: Blu-ray"
}

Copy-Item -Path $localFinalMkv -Destination $finalMkv -Force
Remove-Item -Path $localFinalMkv
Write-Log "Copied MKV to: $finalMkv"

$fileSize = [math]::Round((Get-Item $finalMkv).Length / 1GB, 2)
$keptTracks = $mkvAudioTracks | Where-Object { $keepIds -contains "$($_.id)" }
$audioSummary = ($keptTracks | ForEach-Object { "$($_.codec)[$($_.properties.language)]" }) -join ", "

Write-Log ""
Write-Log "=== DONE ==="
Write-Log "Movie: $movieName"
Write-Log "Audio: $audioSummary"
Write-Log "Size: $fileSize GB"
Write-Log "Location: $finalMkv"
Write-Log "Log saved to: $logFile"