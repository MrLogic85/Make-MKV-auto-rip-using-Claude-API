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
        model    = "claude-sonnet-4-6"
        max_tokens = 500
        messages = @(@{ role = "user"; content = $content })
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
    $idx      = Invoke-Menu -Title "Select destination:" -Options $defaultDestRoots -NoBeep
    $destRoot = $defaultDestRoots[$idx]
    Write-Log "Destination: $destRoot"
}

$lastDiscName = $null
$copyJob      = $null
while ($true) {

    $movieName    = $null
    $movieEdition = $null
    $bdmtXml      = $null
    $discImages   = @()

    # -------------------------------------------------------------------------
    # Find disc
    # -------------------------------------------------------------------------
    Write-Log "Scanning for disc..."

    $discName    = ""
    $infoOutput  = $null
    $driveFound  = $null
    $lastWaitMsg = ""

    while (-not $discName) {
        $infoOutput = & $makemkvcon -r info disc:0 2>&1
        $driveFound = $infoOutput | Where-Object { $_ -match '^DRV:0,' -and $_ -notmatch ',256,' }

        if (-not $driveFound) {
            if ($lastWaitMsg -ne "no-disc") { Write-Log "No disc found. Waiting..."; $lastWaitMsg = "no-disc" }
            Start-Sleep -Seconds 5
            continue
        }

        foreach ($line in $infoOutput) {
            if ($line -match '^CINFO:2,0,"([^"]+)"') { $discName = $matches[1]; break }
        }

        if (-not $discName) {
            if ($lastWaitMsg -ne "not-readable") { Write-Log "Disc found but not yet readable. Waiting..."; $lastWaitMsg = "not-readable" }
            Start-Sleep -Seconds 5
        }
    }

    Write-Log "Disc ready: $discName"

    $driveLetter = if (($driveFound | Select-Object -First 1) -match '"([A-Z]:)"') { $matches[1] } else { $null }

    if ($discName -and $discName -eq $lastDiscName) {
        Write-Log "WARNING: Same disc detected ('$discName'). Please insert a different disc. Exiting."
        Wait-CopyJob
        exit
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

    Write-Log "Available titles:"
    $titleLines      = @()
    $titlesWithAudio = $titles.GetEnumerator() | Where-Object { $_.Value.AudioTracks.Count -gt 0 } | Sort-Object Key
    foreach ($t in $titlesWithAudio) {
        $audioList  = ($t.Value.AudioTrackNums |
            ForEach-Object { $t.Value.AudioTracks[$_] } |
            ForEach-Object { "$($_.ShortName)[$($_.Language)]" }) -join ", "
        Write-Log "  Title $($t.Key): $($t.Value.VideoCodec), $($t.Value.Duration), $($t.Value.SizeText), $($t.Value.Resolution), $($t.Value.ChapterCount) chapters"
        Write-Log "    Audio: $audioList"
        $titleLines += "Title $($t.Key): $($t.Value.VideoCodec), $($t.Value.Duration), $($t.Value.SizeText), $($t.Value.Resolution), $($t.Value.ChapterCount) chapters, Audio: $audioList"
    }

    # -------------------------------------------------------------------------
    # Identify movie name via Claude
    # -------------------------------------------------------------------------

    # Try to read human-readable title from the standard Blu-ray metadata file
    $volumeLabel  = $null
    $discImages   = @()
    if ($driveLetter) {
        try { $volumeLabel = [System.IO.DriveInfo]::new($driveLetter).VolumeLabel } catch {}

        $bdmtDir  = Join-Path $driveLetter "BDMV\META\DL"
        $bdmtPath = Join-Path $bdmtDir "bdmt_eng.xml"
        if (Test-Path $bdmtPath) {
            try {
                $bdmtXml = Get-Content $bdmtPath -Encoding UTF8 -Raw
                Write-Log "Read disc metadata XML."
            } catch {
                Write-Log "Could not read disc metadata XML."
            }
        }

        $discImages = @(Get-ChildItem -Path $bdmtDir -Include "*.jpg","*.png" -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending |
            Select-Object -First 2 -ExpandProperty FullName)
        if ($discImages.Count -gt 0) { Write-Log "Found $($discImages.Count) disc thumbnail(s)." }
    }

    if ($volumeLabel) { Write-Log "Drive volume label: $volumeLabel" }

    $discInfoLines = @("MakeMKV disc name: $discName")
    if ($volumeLabel) { $discInfoLines += "Drive volume label: $volumeLabel" }
    $bdmtSection   = if ($bdmtXml) { "`n`nDisc metadata XML:`n$bdmtXml" } else { "" }
    $titlesSection = if ($titleLines.Count -gt 0) { "`n`nDisc titles:`n" + ($titleLines -join "`n") } else { "" }
    $userHint      = $null

    do {
        $hintSection = if ($userHint) { "`n`nAdditional hint from user: $userHint" } else { "" }

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
        if ($bdmtXml)            { Write-Log "  + disc metadata XML" }
        if ($titlesSection)      { Write-Log "  + $($titleLines.Count) titles" }
        if ($discImages.Count)   { Write-Log "  + $($discImages.Count) image(s)" }
        if ($userHint)           { Write-Log "  + user hint: $userHint" }
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

        if (-not $movieName) {
            Invoke-Beep
            Write-Host ""
            $userHint = Read-Host "Enter movie hint for Claude"
        }
    } while (-not $movieName)

    $movieName = $movieName -replace ':', ' -' -replace '"', "'" -replace '[\\/*?<>|]', ''
    $movieName = $movieName -replace '\s{2,}', ' '

    $movieFolder = Join-Path $destRoot $movieName
    $finalMkv   = Join-Path $movieFolder "$movieName.mkv"

    Write-Log "Movie: $movieName"
    Write-Log "Destination: $movieFolder"

    if (Test-Path $finalMkv) {
        Write-Log "WARNING: MKV already exists at $finalMkv"
        $idx = Invoke-Menu -Title "File already exists. Overwrite?" -Options @("No, skip this disc", "Yes, overwrite") -Default 0
        if ($idx -ne 1) {
            Write-Log "Aborted by user."
            continue
        }
    }

    # -------------------------------------------------------------------------
    # Select title
    # -------------------------------------------------------------------------
    if ($titleMatch.Success -and $titleMatch.Groups[1].Value -match '^\d+$') {
        $chosenTitle = [int]$titleMatch.Groups[1].Value
        Write-Log "Claude selected title: $chosenTitle"
    } else {
        Write-Log "Claude could not determine title. Please select manually."
        $titleKeys   = @($titlesWithAudio | ForEach-Object { $_.Key })
        $idx         = Invoke-Menu -Title "Select title:" -Options $titleLines
        $chosenTitle = $titleKeys[$idx]
    }

    # -------------------------------------------------------------------------
    # Step 1: Rip
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Log "Step 1: Ripping title $chosenTitle from disc..."

    $tempMkv = $null
    $ripDone = $false
    while (-not $ripDone) {
        $beforeRip    = Get-Date
        $tempMkvName  = "temp_ripping_$([System.Guid]::NewGuid().ToString('N')).mkv"
        $tempMkv      = Join-Path $localTemp $tempMkvName
        & $makemkvcon mkv disc:0 $chosenTitle "$localTemp"
        $ripExitCode  = $LASTEXITCODE

        $generatedMkv = Get-ChildItem -Path $localTemp -Filter "*.mkv" |
            Where-Object { $_.LastWriteTime -gt $beforeRip } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($ripExitCode -ne 0 -or -not $generatedMkv) {
            Write-Log "Error: Ripping failed (exit code $ripExitCode)."

            # Remove any partial file left behind
            if ($generatedMkv) {
                Remove-Item -Path $generatedMkv.FullName -ErrorAction SilentlyContinue
                Write-Log "Removed partial MKV file."
            }

            # Eject the disc
            if ($driveLetter) {
                Write-Log "Ejecting disc ($driveLetter)..."
                $shell = New-Object -ComObject Shell.Application
                $shell.Namespace(17).ParseName($driveLetter).InvokeVerb("Eject")
            }

            $errIdx = Invoke-Menu `
                -Title "Ripping failed. Please clean the disc and re-insert it." `
                -Options @("Retry", "Skip to next disc")

            Write-Log "Waiting for disc..."
            do {
                Start-Sleep -Seconds 5
                $pollOutput = & $makemkvcon -r info disc:0 2>&1
                $discReady  = $pollOutput | Where-Object { $_ -match '^DRV:0,' -and $_ -notmatch ',256,' }
            } while (-not $discReady)

            if ($errIdx -eq 0) {
                # Retry: update driveFound so eject works correctly after a successful rip
                $driveFound = $discReady
                Write-Log "Disc detected. Retrying rip..."
            } else {
                # Skip: let the outer loop handle the new disc
                Write-Log "Skipping to next disc."
                break
            }
        } else {
            Rename-Item -Path $generatedMkv.FullName -NewName $tempMkvName
            $ripDone = $true
        }
    }

    if (-not $ripDone) { continue }

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
        $editionTag  = if ($movieEdition) { "`n    <edition>$movieEdition</edition>" } else { "" }
        $nfoContent  = @"
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

    $keptTracks   = $mkvAudioTracks | Where-Object { $keepIds -contains "$($_.id)" }
    $audioSummary = ($keptTracks | ForEach-Object { "$($_.codec)[$($_.properties.language)]" }) -join ", "

    Write-Host ""
    Write-Log "=== DONE ==="
    Write-Log "Movie: $movieName"
    Write-Log "Audio: $audioSummary"
    Write-Log "Location: $finalMkv"
    Write-Log "Log saved to: $logFile"

    $lastDiscName = $discName

    # -------------------------------------------------------------------------
    # Eject disc and wait for next
    # -------------------------------------------------------------------------
    if ($driveLetter) {
        Write-Log "Ejecting disc ($driveLetter)..."
        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace(17).ParseName($driveLetter).InvokeVerb("Eject")
        Start-Sleep -Seconds 2
    } else {
        Write-Log "Could not determine drive letter for eject."
    }
    Write-Host ""
} # end while
