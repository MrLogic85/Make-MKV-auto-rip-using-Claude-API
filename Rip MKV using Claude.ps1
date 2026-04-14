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
        model    = "claude-sonnet-4-6"
        max_tokens = 500
        messages = @(@{ role = "user"; content = $prompt })
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.anthropic.com/v1/messages" `
            -Method POST `
            -Headers @{
                "x-api-key"         = $claudeApiKey
                "anthropic-version" = "2023-06-01"
                "content-type"      = "application/json"
            } `
            -Body $body
        return $response.content[0].text.Trim()
    } catch {
        Write-Log "Error calling Claude API: $_"
        return $null
    }
}

function Wait-CopyJob {
    if ($script:copyJob) {
        Write-Log "Waiting for background copy to complete..."
        $result = Receive-Job -Job $script:copyJob -Wait -AutoRemoveJob
        foreach ($msg in $result.Messages) { Write-Log $msg }
        if ($result.Success) {
            Write-Log "Copy complete. Size: $($result.FileSize) GB"
        } else {
            Write-Log "Background copy failed. Check log for details."
        }
        $script:copyJob = $null
    }
}

function New-Title {
    return @{
        Size           = 0
        SizeText       = ""
        Duration       = ""
        AudioTrackNums = @()
        AudioTracks    = @{}
        VideoCodec     = ""
        Resolution     = ""
        ChapterCount   = 0
    }
}

# Verify tools exist
if (-not (Test-Path $makemkvcon)) { Write-Log "Error: MakeMKV not found at $makemkvcon"; exit }
if (-not (Test-Path $mkvmerge))   { Write-Log "Error: MKVToolNix not found at $mkvmerge"; exit }

# Select destination once upfront
if ($defaultDestRoots.Count -eq 0) {
    Write-Host "Error: No destinations configured. Please add at least one entry to `$defaultDestRoots in config.ps1."
    exit
} elseif ($defaultDestRoots.Count -eq 1) {
    $destRoot = $defaultDestRoots[0]
    Write-Log "Destination: $destRoot"
} else {
    Write-Host ""
    Write-Host "Select destination:"
    for ($i = 0; $i -lt $defaultDestRoots.Count; $i++) {
        $marker = if ($i -eq 0) { " (default)" } else { "" }
        Write-Host "  $($i + 1): $($defaultDestRoots[$i])$marker"
    }
    do {
        $destChoice = Read-Host "Enter number (press Enter for 1)"
        if ([string]::IsNullOrWhiteSpace($destChoice)) { $destChoice = "1" }
        $isValid = $destChoice -match '^\d+$' -and [int]$destChoice -ge 1 -and [int]$destChoice -le $defaultDestRoots.Count
        if (-not $isValid) { Write-Host "Please enter a number between 1 and $($defaultDestRoots.Count)." }
    } while (-not $isValid)
    $destRoot = $defaultDestRoots[[int]$destChoice - 1]
    Write-Log "Destination: $destRoot"
}

$lastDiscName = $null
$copyJob      = $null
while ($true) {

    $movieName = $null

    # -------------------------------------------------------------------------
    # Find disc
    # -------------------------------------------------------------------------
    Write-Log "Scanning for disc..."
    $infoOutput = & $makemkvcon -r info disc:0 2>&1
    $driveFound = $infoOutput | Where-Object { $_ -match '^DRV:0,' -and $_ -notmatch ',256,' }

    if (-not $driveFound) {
        Write-Log "Error: No disc found in drive 0. Please insert disc and try again."
        Wait-CopyJob
        exit
    }

    Write-Log "Disc found. Fetching title information..."

    # Extract disc name from CINFO
    $discName = ""
    foreach ($line in $infoOutput) {
        if ($line -match '^CINFO:2,0,"([^"]+)"') {
            $discName = $matches[1]
            break
        }
    }

    if ($discName -and $discName -eq $lastDiscName) {
        Write-Log "WARNING: Same disc detected ('$discName'). Please insert a different disc. Exiting."
        Wait-CopyJob
        exit
    }

    # -------------------------------------------------------------------------
    # Identify movie name via Claude
    # -------------------------------------------------------------------------
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

    $nameMatch = if ($claudeNameResponse) {
        [regex]::Match($claudeNameResponse, 'NAME:(.+)')
    } else {
        [regex]::Match('', 'NAME:(.+)')
    }

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
        do {
            Write-Host ""
            $movieName = Read-Host "Enter movie name and year (e.g. Inception (2010))"
            $isValid = $movieName -match '.+\(\d{4}\)'
            if (-not $isValid) { Write-Host "Invalid format. Use: Movie Name (Year)" }
        } while (-not $isValid)
    }

    $movieName = $movieName -replace ':', ' -' -replace '"', "'" -replace '[\\/*?<>|]', ''
    $movieName = $movieName -replace '\s{2,}', ' '

    $movieFolder = Join-Path $destRoot $movieName
    $finalMkv   = Join-Path $movieFolder "$movieName.mkv"

    Write-Log "Movie: $movieName"
    Write-Log "Destination: $movieFolder"

    if (Test-Path $finalMkv) {
        Write-Log "WARNING: MKV already exists at $finalMkv"
        do {
            $confirm = Read-Host "Overwrite? (y/n)"
            if ($confirm -ne 'y' -and $confirm -ne 'n') { Write-Host "Please enter y or n." }
        } while ($confirm -ne 'y' -and $confirm -ne 'n')
        if ($confirm -ne 'y') {
            Write-Log "Aborted by user."
            continue
        }
    }

    # -------------------------------------------------------------------------
    # Parse titles from disc info
    # -------------------------------------------------------------------------
    $titles = @{}

    foreach ($line in $infoOutput) {
        if ($line -match '^TINFO:(\d+),11,0,"(\d+)"') {
            $tNum = [int]$matches[1]
            if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
            $titles[$tNum].Size     = [long]$matches[2]
            $titles[$tNum].SizeText = [math]::Round([long]$matches[2] / 1GB, 2).ToString() + " GB"
        }
        if ($line -match '^TINFO:(\d+),9,0,"([^"]+)"') {
            $tNum = [int]$matches[1]
            if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
            $titles[$tNum].Duration = $matches[2]
        }
        if ($line -match '^TINFO:(\d+),25,0,"(\d+)"') {
            $tNum = [int]$matches[1]
            if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
            $titles[$tNum].ChapterCount = [int]$matches[2]
        }
        if ($line -match '^SINFO:(\d+),0,7,0,"([^"]+)"') {
            $tNum = [int]$matches[1]
            if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
            $titles[$tNum].VideoCodec = $matches[2]
        }
        if ($line -match '^SINFO:(\d+),0,19,0,"([^"]+)"') {
            $tNum = [int]$matches[1]
            if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
            $titles[$tNum].Resolution = $matches[2]
        }
        if ($line -match '^SINFO:(\d+),(\d+),1,6202,"Audio"') {
            $tNum     = [int]$matches[1]
            $trackNum = [int]$matches[2]
            if (-not $titles.ContainsKey($tNum)) { $titles[$tNum] = New-Title }
            if (-not $titles[$tNum].AudioTracks.ContainsKey($trackNum)) {
                $titles[$tNum].AudioTracks[$trackNum] = @{ TrackNum = $trackNum; ShortName = ""; Language = "" }
                $titles[$tNum].AudioTrackNums += $trackNum
            }
        }
        if ($line -match '^SINFO:(\d+),(\d+),6,0,"([^"]+)"') {
            $tNum     = [int]$matches[1]
            $trackNum = [int]$matches[2]
            if ($titles.ContainsKey($tNum) -and $titles[$tNum].AudioTracks.ContainsKey($trackNum)) {
                $titles[$tNum].AudioTracks[$trackNum].ShortName = $matches[3]
            }
        }
        if ($line -match '^SINFO:(\d+),(\d+),3,0,"([a-z]{3})"') {
            $tNum     = [int]$matches[1]
            $trackNum = [int]$matches[2]
            if ($titles.ContainsKey($tNum) -and $titles[$tNum].AudioTracks.ContainsKey($trackNum)) {
                $titles[$tNum].AudioTracks[$trackNum].Language = $matches[3]
            }
        }
    }

    # -------------------------------------------------------------------------
    # Select title via Claude
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "Available titles:"
    $titleLines = @()
    $titlesWithAudio = $titles.GetEnumerator() | Where-Object { $_.Value.AudioTracks.Count -gt 0 } | Sort-Object Key
    foreach ($t in $titlesWithAudio) {
        $audioList = ($t.Value.AudioTrackNums |
            ForEach-Object { $t.Value.AudioTracks[$_] } |
            ForEach-Object { "$($_.ShortName)[$($_.Language)]" }) -join ", "
        Write-Log "  Title $($t.Key): $($t.Value.VideoCodec), $($t.Value.Duration), $($t.Value.SizeText), $($t.Value.Resolution), $($t.Value.ChapterCount) chapters"
        Write-Log "    Audio: $audioList"
        $titleLines += "Title $($t.Key): $($t.Value.VideoCodec), $($t.Value.Duration), $($t.Value.SizeText), $($t.Value.Resolution), $($t.Value.ChapterCount) chapters, Audio: $audioList"
    }

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

    $titleMatch = if ($claudeTitleResponse) {
        [regex]::Match($claudeTitleResponse, 'TITLE:(\w+)')
    } else {
        [regex]::Match('', 'TITLE:(\w+)')
    }

    if ($titleMatch.Success -and $titleMatch.Groups[1].Value -match '^\d+$') {
        $chosenTitle = [int]$titleMatch.Groups[1].Value
        Write-Log "Claude selected title: $chosenTitle"
    } else {
        Write-Log "Claude could not determine title. Please select manually."
        $validTitleNums = $titles.Keys | Where-Object { $titles[$_].AudioTracks.Count -gt 0 }
        do {
            Write-Host ""
            $val     = Read-Host "Enter title number ($($validTitleNums -join ', '))"
            $isValid = $val -match '^\d+$' -and $validTitleNums -contains [int]$val
            if (-not $isValid) { Write-Host "Invalid title number. Please try again." }
        } while (-not $isValid)
        $chosenTitle = [int]$val
    }

    # -------------------------------------------------------------------------
    # Step 1: Rip
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Log "Step 1: Ripping title $chosenTitle from disc..."

    $beforeRip = Get-Date
    $tempMkv   = Join-Path $localTemp "temp_ripping_$([System.Guid]::NewGuid().ToString('N')).mkv"
    & $makemkvcon mkv disc:0 $chosenTitle "$localTemp"
    $generatedMkv = Get-ChildItem -Path $localTemp -Filter "*.mkv" |
        Where-Object { $_.LastWriteTime -gt $beforeRip } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $generatedMkv) {
        Write-Log "Error: Could not find ripped MKV file. Exiting."
        Wait-CopyJob
        exit
    }

    Rename-Item -Path $generatedMkv.FullName -NewName (Split-Path $tempMkv -Leaf)

    # -------------------------------------------------------------------------
    # Step 2: Identify and select audio tracks via Claude
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "Step 2: Identifying audio tracks in MKV..."

    try {
        $identifyOutput = & $mkvmerge --identify --identification-format json "$tempMkv" 2>&1
        $mkvJson = $identifyOutput | ConvertFrom-Json
    } catch {
        Write-Log "Error: Failed to parse MKVToolNix JSON output: $_. Exiting."
        Wait-CopyJob
        exit
    }

    $mkvAudioTracks = $mkvJson.tracks | Where-Object { $_.type -eq "audio" }

    if (-not $mkvAudioTracks) {
        Write-Log "Error: No audio tracks found in MKV. Exiting."
        Wait-CopyJob
        exit
    }

    Write-Log "Audio tracks in MKV:"
    $trackLines = @()
    foreach ($track in $mkvAudioTracks) {
        $lang      = $track.properties.language
        $codec     = $track.codec
        $channels  = $track.properties.audio_channels
        $sampleRate = $track.properties.audio_sampling_frequency
        $bitDepth  = $track.properties.audio_bits_per_sample
        $trackName = $track.properties.track_name
        $default   = $track.properties.default_track
        $forced    = $track.properties.forced_track

        $info = "Track $($track.id): $codec [$lang]"
        if ($channels)   { $info += ", $channels channels" }
        if ($sampleRate) { $info += ", ${sampleRate}Hz" }
        if ($bitDepth)   { $info += ", ${bitDepth}-bit" }
        if ($trackName)  { $info += ", name: '$trackName'" }
        if ($default)    { $info += ", default" }
        if ($forced)     { $info += ", forced" }

        Write-Log "  $info"
        $trackLines += $info
    }

    Write-Log ""
    Write-Log "Asking Claude to select audio tracks..."
    $langList    = $preferredAudioLanguages -join ", "
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

    $audioMatch = if ($claudeAudioResponse) {
        [regex]::Match($claudeAudioResponse, 'KEEP:([\d,\s]+)')
    } else {
        [regex]::Match('', 'KEEP:([\d,\s]+)')
    }

    if (-not $audioMatch.Success) {
        Write-Log "Claude could not determine audio tracks. Keeping all tracks."
        $keepIds = $mkvAudioTracks | ForEach-Object { "$($_.id)" }
    } else {
        $keepIds = $audioMatch.Groups[1].Value -split "," | ForEach-Object { $_.Trim() }
        Write-Log "Claude selected tracks: $($keepIds -join ', ')"
    }

    if ($keepIds.Count -eq 0) {
        Write-Log "No track IDs extracted. Keeping all tracks."
        $keepIds = $mkvAudioTracks | ForEach-Object { "$($_.id)" }
    }

    # -------------------------------------------------------------------------
    # Step 3: Filter audio with MKVToolNix
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "Step 3: Filtering audio with MKVToolNix..."

    $localFinalMkv = Join-Path $localTemp "$movieName.mkv"
    $audioArg      = $keepIds -join ","

    & $mkvmerge -o "$localFinalMkv" --audio-tracks $audioArg "$tempMkv"

    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
        Remove-Item -Path $tempMkv
        Write-Log "Removed temporary MKV."
    } else {
        Write-Log "Error: MKVToolNix failed (exit code $LASTEXITCODE). Temporary MKV kept at: $tempMkv"
        Wait-CopyJob
        exit
    }

    # Check display dimensions
    $videoJson  = & $mkvmerge --identify --identification-format json "$localFinalMkv" 2>&1 | ConvertFrom-Json
    $videoTrack = $videoJson.tracks | Where-Object { $_.type -eq "video" } | Select-Object -First 1

    if ($videoTrack) {
        $displayDim = $videoTrack.properties.display_dimensions
        $pixelDim   = $videoTrack.properties.pixel_dimensions

        if ($displayDim -match '(\d+)x(\d+)') {
            $dispW = [int]$matches[1]
            $dispH = [int]$matches[2]
            $ratio = $dispW / $dispH

            if ($ratio -gt 0.9 -and $ratio -lt 1.1) {
                Write-Log "WARNING: Display dimensions look wrong ($displayDim, nearly 1:1). Pixel dimensions are $pixelDim."
                Write-Log "Please check the video manually and select the correct aspect ratio."
                Write-Host ""
                Write-Host "Common aspect ratios:"
                Write-Host "  1: 16:9      (1920x1080)"
                Write-Host "  2: 2.35:1    (1920x816)"
                Write-Host "  3: 2.39:1    (1920x803)"
                Write-Host "  4: 4:3       (1440x1080)"
                Write-Host "  5: Custom"
                Write-Host "  6: Keep as is"
                do {
                    $arChoice = Read-Host "Select aspect ratio (1-6)"
                    if ($arChoice -notmatch '^[1-6]$') { Write-Host "Please enter a number between 1 and 6." }
                } while ($arChoice -notmatch '^[1-6]$')

                $newW = $null
                $newH = $null
                switch ($arChoice) {
                    "1" { $newW = 1920; $newH = 1080 }
                    "2" { $newW = 1920; $newH = 816 }
                    "3" { $newW = 1920; $newH = 803 }
                    "4" { $newW = 1440; $newH = 1080 }
                    "5" {
                        do {
                            $customW  = Read-Host "Enter display width"
                            $isValidW = $customW -match '^\d+$' -and [int]$customW -gt 0
                            if (-not $isValidW) { Write-Host "Please enter a valid positive number." }
                        } while (-not $isValidW)
                        do {
                            $customH  = Read-Host "Enter display height"
                            $isValidH = $customH -match '^\d+$' -and [int]$customH -gt 0
                            if (-not $isValidH) { Write-Host "Please enter a valid positive number." }
                        } while (-not $isValidH)
                        $newW = [int]$customW
                        $newH = [int]$customH
                    }
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

    # -------------------------------------------------------------------------
    # Step 4: Copy to destination (background job)
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "Step 4: Starting copy to destination in background..."

    # Wait for the previous disc's copy to finish before starting a new one
    Wait-CopyJob

    if (-not (Test-Path $movieFolder)) {
        New-Item -ItemType Directory -Path $movieFolder | Out-Null
        Write-Log "Created folder: $movieFolder"
    }

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

    $script:copyJob = Start-Job -ScriptBlock {
        param($src, $dst)
        try {
            Copy-Item -Path $src -Destination $dst -Force
            Remove-Item -Path $src
            $fileSize = [math]::Round((Get-Item $dst).Length / 1GB, 2)
            return @{ Success = $true; FileSize = $fileSize; Messages = @("Copied MKV to: $dst") }
        } catch {
            Remove-Item -Path $src -ErrorAction SilentlyContinue
            return @{ Success = $false; FileSize = 0; Messages = @("Error: Failed to copy MKV to destination: $_") }
        }
    } -ArgumentList $localFinalMkv, $finalMkv

    $keptTracks   = $mkvAudioTracks | Where-Object { $keepIds -contains "$($_.id)" }
    $audioSummary = ($keptTracks | ForEach-Object { "$($_.codec)[$($_.properties.language)]" }) -join ", "

    Write-Log ""
    Write-Log "=== DONE ==="
    Write-Log "Movie: $movieName"
    Write-Log "Audio: $audioSummary"
    Write-Log "Location: $finalMkv"
    Write-Log "Log saved to: $logFile"

    $lastDiscName = $discName

    # -------------------------------------------------------------------------
    # Eject disc and wait for next
    # -------------------------------------------------------------------------
    $driveLine   = $driveFound | Select-Object -First 1
    $driveLetter = if ($driveLine -match '"([A-Z]:)"') { $matches[1] } else { $null }
    if ($driveLetter) {
        Write-Log "Ejecting disc ($driveLetter)..."
        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace(17).ParseName($driveLetter).InvokeVerb("Eject")
    } else {
        Write-Log "Could not determine drive letter for eject."
    }

    Write-Host ""
    Write-Log "Waiting for next disc..."
    do {
        Start-Sleep -Seconds 5
        $pollOutput = & $makemkvcon -r info disc:0 2>&1
        $discReady  = $pollOutput | Where-Object { $_ -match '^DRV:0,' -and $_ -notmatch ',256,' }
    } while (-not $discReady)
    Write-Log "New disc detected."

} # end while
