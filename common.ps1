# common.ps1 — shared functions for disc and folder ripping scripts
# Dot-source this file after loading config.ps1 and setting $logFile.
# All config variables ($claudeApiKey, $beepOnManualInput, $preferredAudioLanguages,
# $mkvmerge, $mkvpropedit, $localTemp, $logFile) are read from the caller's scope.

# Shows a destination selection menu built from $defaultDestRoots plus an "Other..."
# option. Returns the chosen path.
function Select-Destination {
    $options = @($defaultDestRoots) + "Other..."
    $idx     = Invoke-Menu -Title "Select destination:" -Options $options -NoBeep

    if ($idx -eq $defaultDestRoots.Count) {
        Invoke-Beep
        $path = Read-Host "Enter destination folder path"
        Write-Log "Destination: $path"
        return $path
    }

    $path = $defaultDestRoots[$idx]
    Write-Log "Destination: $path"
    return $path
}

function Write-Log($message) {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Invoke-Beep {
    if ($beepOnManualInput) {
        [Console]::Beep(600, 200)
        Start-Sleep -Milliseconds 100
        [Console]::Beep(600, 200)
    }
}

function Invoke-Claude($prompt, $imagePaths = @()) {
    $content = @()
    foreach ($path in $imagePaths) {
        if (Test-Path $path) {
            $bytes     = [System.IO.File]::ReadAllBytes($path)
            $base64    = [Convert]::ToBase64String($bytes)
            $ext       = [System.IO.Path]::GetExtension($path).ToLower()
            $mediaType = if ($ext -eq ".png") { "image/png" } else { "image/jpeg" }
            $content  += @{ type = "image"; source = @{ type = "base64"; media_type = $mediaType; data = $base64 } }
        }
    }
    $content += @{ type = "text"; text = $prompt }

    $body = @{
        model      = "claude-sonnet-4-6"
        max_tokens = 500
        messages   = @(@{ role = "user"; content = $content })
    } | ConvertTo-Json -Depth 10

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

# Waits for the background copy job to finish.
# Returns $true if the copy succeeded (or there was no job), $false on failure.
function Wait-CopyJob {
    if ($script:copyJob) {
        Write-Log "Waiting for background copy to complete..."
        $result = Receive-Job -Job $script:copyJob -Wait -AutoRemoveJob
        foreach ($msg in $result.Messages) { Write-Log $msg }
        $script:copyJob = $null
        if ($result.Success) {
            Write-Log "Copy complete. Size: $($result.FileSize) GB"
            return $true
        } else {
            Write-Log "Background copy failed. Check log for details."
            return $false
        }
    }
    return $true
}

function Invoke-Menu {
    param(
        [string]$Title,
        [string[]]$Options,
        [int]$Default = 0,
        [switch]$NoBeep
    )

    if (-not $NoBeep) { Invoke-Beep }
    $selected = $Default
    $count    = $Options.Count
    $esc      = [char]27

    Write-Host ""
    Write-Host $Title

    # Initial draw
    for ($i = 0; $i -lt $count; $i++) {
        if ($i -eq $selected) {
            Write-Host "  > $($Options[$i])" -ForegroundColor Cyan
        } else {
            Write-Host "    $($Options[$i])"
        }
    }

    while ($true) {
        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow'   { $selected = ($selected - 1 + $count) % $count }
            'DownArrow' { $selected = ($selected + 1) % $count }
            'Enter'     { return $selected }
        }

        # Move cursor up $count lines then redraw each line in place
        Write-Host "${esc}[$($count)A" -NoNewline
        for ($i = 0; $i -lt $count; $i++) {
            Write-Host "${esc}[2K" -NoNewline  # clear current line
            if ($i -eq $selected) {
                Write-Host "  > $($Options[$i])" -ForegroundColor Cyan
            } else {
                Write-Host "    $($Options[$i])"
            }
        }
    }
}

function Invoke-MultiSelectMenu {
    param(
        [string]$Title,
        [string[]]$Options,
        [bool[]]$Defaults,
        [switch]$NoBeep
    )

    if (-not $NoBeep) { Invoke-Beep }
    [bool[]]$checked = if ($Defaults) { $Defaults } else { @($false) * $Options.Count }
    $cursor  = 0
    $count   = $Options.Count + 1  # +1 for Done
    $esc     = [char]27

    function Draw-Item($i, $isCursor) {
        Write-Host "${esc}[2K" -NoNewline
        if ($i -lt $Options.Count) {
            $box = if ($checked[$i]) { "x" } else { " " }
            if ($isCursor) { Write-Host "  > [$box] $($Options[$i])" -ForegroundColor Cyan }
            else           { Write-Host "    [$box] $($Options[$i])" }
        } else {
            if ($isCursor) { Write-Host "  > Done" -ForegroundColor Cyan }
            else           { Write-Host "    Done" }
        }
    }

    Write-Host ""
    Write-Host $Title
    for ($i = 0; $i -lt $count; $i++) { Draw-Item $i ($i -eq $cursor) }

    while ($true) {
        $key = [Console]::ReadKey($true)

        switch ($key.Key) {
            'UpArrow'   { $cursor = ($cursor - 1 + $count) % $count }
            'DownArrow' { $cursor = ($cursor + 1) % $count }
            'Enter'     {
                if ($cursor -eq $Options.Count) { return $checked }
                $checked[$cursor] = -not $checked[$cursor]
            }
        }

        Write-Host "${esc}[$($count)A" -NoNewline
        for ($i = 0; $i -lt $count; $i++) { Draw-Item $i ($i -eq $cursor) }
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

# Parses makemkvcon info output into a hashtable keyed by title number.
function Invoke-ParseTitles($infoOutput) {
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

    return $titles
}

# Calls Claude in a loop until the movie is identified.
# Returns @{ Name = <sanitized name>; Edition = <edition or $null>; TitleNum = <int or $null> }
function Invoke-IdentifyMovie($discInfoLines, $bdmtXml, $titleLines, $discImages) {
    $movieName    = $null
    $movieEdition = $null
    $userHint     = $null
    $titleNum     = $null

    do {
        $hintSection   = if ($userHint)           { "`n`nAdditional hint from user: $userHint" } else { "" }
        $bdmtSection   = if ($bdmtXml)            { "`n`nDisc metadata XML:`n$bdmtXml" }         else { "" }
        $titlesSection = if ($titleLines.Count -gt 0) { "`n`nDisc titles:`n" + ($titleLines -join "`n") } else { "" }

        $namePrompt = @"
The following information was collected from a Blu-ray disc:
$($discInfoLines -join "`n")$bdmtSection$titlesSection$hintSection

Please identify the movie, its edition, and the title number of the main feature.

1. Identify the movie and format it exactly as: Movie Name (Year)
   Make sure the name matches the title on https://www.themoviedb.org/

2. Identify the edition or version if this is a special cut. Only specify an edition if you are confident it differs from the standard release. The edition can sometimes be derived from the length of the movie compared to the known theatrical runtime, but only do so if confident. Pick from this list:
   - Collectors Edition
   - Criterion Collection
   - Director's Cut
   - Extended Edition
   - Final Edition
   - IMAX
   - Open Matte
   - Remastered
   - Special Edition
   - Superduper Cut
   - Theatrical Edition
   - Ultimate Edition
   - Uncut
   - Unrated

3. Select the title number of the main feature film from the disc titles above. Consider the expected runtime and ignore bonus features, trailers, commentary tracks and short clips.

Return your answers on separate lines:
NAME:Movie Name (Year)
EDITION:edition name
TITLE:number
If you cannot identify the movie with high confidence, return: NAME:UNKNOWN
If this is the standard version or you cannot determine the edition, return: EDITION:NONE
If you cannot determine the main feature title with confidence, return: TITLE:UNKNOWN
The formatting is important since I will parse your response with these regexes: NAME:(.+), EDITION:(.+) and TITLE:(\w+)

Important: Do not use special Unicode characters like checkmarks or cross marks in your response. Use plain text only.
"@

        Write-Log "Sending to Claude: $($discInfoLines -join '; ')"
        if ($bdmtXml)          { Write-Log "  + disc metadata XML" }
        if ($titleLines.Count) { Write-Log "  + $($titleLines.Count) titles" }
        if ($discImages.Count) { Write-Log "  + $($discImages.Count) image(s)" }
        if ($userHint)         { Write-Log "  + user hint: $userHint" }
        Write-Log "Asking Claude to identify disc, edition and title..."
        $claudeResponse = Invoke-Claude $namePrompt $discImages
        Write-Log "Claude response: $claudeResponse"

        $nameMatch    = if ($claudeResponse) { [regex]::Match($claudeResponse, 'NAME:(.+)') }    else { [regex]::Match('', 'NAME:(.+)') }
        $editionMatch = if ($claudeResponse) { [regex]::Match($claudeResponse, 'EDITION:(.+)') } else { [regex]::Match('', 'EDITION:(.+)') }
        $titleMatch   = if ($claudeResponse) { [regex]::Match($claudeResponse, 'TITLE:(\w+)') }  else { [regex]::Match('', 'TITLE:(\w+)') }

        if ($editionMatch.Success) {
            $extractedEdition = $editionMatch.Groups[1].Value.Trim()
            if ($extractedEdition -ne "NONE") {
                $movieEdition = $extractedEdition
                Write-Log "Claude identified edition: $movieEdition"
            }
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

        if ($titleMatch.Success -and $titleMatch.Groups[1].Value -match '^\d+$') {
            $titleNum = [int]$titleMatch.Groups[1].Value
        }

        if (-not $movieName) {
            Invoke-Beep
            Write-Host ""
            $userHint = Read-Host "Enter movie hint for Claude"
        }
    } while (-not $movieName)

    $movieName = $movieName -replace ':', ' -' -replace '"', "'" -replace '[\\/*?<>|]', ''
    $movieName = $movieName -replace '\s{2,}', ' '

    return @{
        Name     = $movieName
        Edition  = $movieEdition
        TitleNum = $titleNum
    }
}

# Identifies audio tracks in the MKV, asks Claude which to keep, falls back to manual
# selection if needed.
# Returns @{ KeepIds = <string[]>; AudioTracks = <track objects> }
function Invoke-SelectAudioTracks($tempMkv, $movieName) {
    Write-Log ""
    Write-Log "Step 2: Identifying audio tracks in MKV..."

    try {
        $identifyOutput = & $mkvmerge --identify --identification-format json "$tempMkv" 2>&1
        $mkvJson = $identifyOutput | ConvertFrom-Json
    } catch {
        Write-Log "Error: Failed to parse MKVToolNix JSON output: $_. Exiting."
        Remove-Item -Path $tempMkv -ErrorAction SilentlyContinue
        Wait-CopyJob
        exit
    }

    $mkvAudioTracks = $mkvJson.tracks | Where-Object { $_.type -eq "audio" }

    if (-not $mkvAudioTracks) {
        Write-Log "Error: No audio tracks found in MKV. Exiting."
        Remove-Item -Path $tempMkv -ErrorAction SilentlyContinue
        Wait-CopyJob
        exit
    }

    Write-Log "Audio tracks in MKV:"
    $trackLines = @()
    foreach ($track in $mkvAudioTracks) {
        $lang       = $track.properties.language
        $codec      = $track.codec
        $channels   = $track.properties.audio_channels
        $sampleRate = $track.properties.audio_sampling_frequency
        $bitDepth   = $track.properties.audio_bits_per_sample
        $trackName  = $track.properties.track_name
        $default    = $track.properties.default_track
        $forced     = $track.properties.forced_track

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
    Write-Log "Asking Claude to select audio tracks ($($mkvAudioTracks.Count) tracks, preferred languages: $($preferredAudioLanguages -join ', '))..."
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
        Write-Log "Claude could not determine audio tracks. Prompting for manual selection."
        $keepIds = $null
    } else {
        $keepIds = $audioMatch.Groups[1].Value -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        Write-Log "Claude selected tracks: $($keepIds -join ', ')"
    }

    if (-not $keepIds -or $keepIds.Count -eq 0) {
        Write-Log "No track IDs extracted. Prompting for manual selection."
        $keepIds = $null
    }

    if (-not $keepIds) {
        $defaults = @($true) * $mkvAudioTracks.Count
        $checked  = Invoke-MultiSelectMenu -Title "Select audio tracks to keep:" -Options $trackLines -Defaults $defaults
        $keepIds  = @()
        for ($i = 0; $i -lt $mkvAudioTracks.Count; $i++) {
            if ($checked[$i]) { $keepIds += "$($mkvAudioTracks[$i].id)" }
        }
        Write-Log "Manual selection: tracks $($keepIds -join ', ')"
    }

    return @{
        KeepIds     = $keepIds
        AudioTracks = $mkvAudioTracks
    }
}

# Filters audio tracks with MKVToolNix and checks display dimensions.
# Returns the path to the filtered MKV; calls Wait-CopyJob + exit on fatal errors.
function Invoke-FilterAudio($tempMkv, $keepIds, $movieName) {
    Write-Log ""
    Write-Log "Step 3: Filtering audio with MKVToolNix..."

    $localFinalMkv = Join-Path $localTemp "$movieName.mkv"
    $audioArg      = $keepIds -join ","

    & $mkvmerge -o "$localFinalMkv" --audio-tracks $audioArg "$tempMkv"

    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
        Remove-Item -Path $tempMkv
        Write-Log "Removed temporary MKV."
    } else {
        Write-Log "Error: MKVToolNix failed (exit code $LASTEXITCODE)."
        Remove-Item -Path $tempMkv -ErrorAction SilentlyContinue
        Remove-Item -Path $localFinalMkv -ErrorAction SilentlyContinue
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
                $arIdx = Invoke-Menu `
                    -Title "Display dimensions look wrong ($displayDim, pixel: $pixelDim). Select aspect ratio:" `
                    -Options @(
                        "16:9      (1920x1080)",
                        "2.35:1    (1920x816)",
                        "2.39:1    (1920x803)",
                        "4:3       (1440x1080)",
                        "Custom",
                        "Keep as is"
                    ) `
                    -Default 5

                $newW = $null
                $newH = $null
                switch ($arIdx) {
                    0 { $newW = 1920; $newH = 1080 }
                    1 { $newW = 1920; $newH = 816 }
                    2 { $newW = 1920; $newH = 803 }
                    3 { $newW = 1440; $newH = 1080 }
                    4 {
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

    return $localFinalMkv
}

# Creates the destination folder and NFO, then starts the background copy job.
# Returns the destination MKV path for logging.
function Start-DestinationCopy($localFinalMkv, $movieName, $movieEdition, $destRoot) {
    $movieFolder = Join-Path $destRoot $movieName
    $finalMkv    = Join-Path $movieFolder "$movieName.mkv"

    if (-not (Test-Path $movieFolder)) {
        New-Item -ItemType Directory -Path $movieFolder | Out-Null
        Write-Log "Created folder: $movieFolder"
    }

    $nfoPath = Join-Path $movieFolder "$movieName.nfo"
    if (-not (Test-Path $nfoPath)) {
        $editionTag = if ($movieEdition) { "`n    <edition>$movieEdition</edition>" } else { "" }
        $nfoContent = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
    <source>Blu-ray</source>$editionTag
</movie>
"@
        [System.IO.File]::WriteAllText($nfoPath, $nfoContent, [System.Text.Encoding]::UTF8)
        $editionLog = if ($movieEdition) { ", edition: $movieEdition" } else { "" }
        Write-Log "Created NFO with source: Blu-ray$editionLog"
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

    return $finalMkv
}
