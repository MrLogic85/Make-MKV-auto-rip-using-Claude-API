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
        $path = Read-Host "Enter destination folder path"
        Write-Log "Destination: $path"
        return $path
    }

    $path = $defaultDestRoots[$idx]
    Write-Log "Destination: $path"
    return $path
}

# Logs all titles with audio and builds the title lines array used by Claude and menus.
# Returns @{ TitleLines = <string[]>; TitlesWithAudio = <ordered entries> }
function Get-TitleLines($titles) {
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
    return @{
        TitleLines      = $titleLines
        TitlesWithAudio = $titlesWithAudio
    }
}

# Returns the chosen title number from Claude's suggestion or a manual menu fallback.
function Select-Title($id, $titleLines, $titlesWithAudio) {
    if ($id.TitleNum -ne $null) {
        Write-Log "Claude selected title: $($id.TitleNum)"
        return $id.TitleNum
    }
    Write-Log "Claude could not determine title. Please select manually."
    $titleKeys   = @($titlesWithAudio | ForEach-Object { $_.Key })
    $idx         = Invoke-Menu -Title "Select title:" -Options $titleLines
    return $titleKeys[$idx]
}

# Logs the final DONE summary after a successful rip.
function Write-DoneSummary($audioResult, $movieName, $finalMkv) {
    $keptTracks   = $audioResult.AudioTracks | Where-Object { $audioResult.KeepIds -contains "$($_.id)" }
    $audioSummary = ($keptTracks | ForEach-Object { "$($_.codec)[$($_.properties.language)]" }) -join ", "

    Write-Host ""
    Write-Log "=== DONE ==="
    Write-Log "Movie: $movieName"
    Write-Log "Audio: $audioSummary"
    Write-Log "Location: $finalMkv"
    Write-Log "Log saved to: $logFile"
}

function Get-DiscSource($resolution) {
    $pixels = if ($resolution -match '^(\d+)x(\d+)$') { [int]$Matches[1] * [int]$Matches[2] } else { 0 }
    if     ($pixels -ge 8000000) { return "UHD_BLURAY" }
    elseif ($pixels -le 500000)  { return "DVD" }
    else                         { return "BLURAY" }
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

# Sends a prompt (plus optional images) to Claude using structured outputs.
# Returns the reply parsed into an object matching $schema, or $null if the call failed
# or Claude did not finish its answer.
function Invoke-Claude($prompt, $schema, $imagePaths = @()) {
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

    # Adaptive thinking lets Claude reason through harder discs before answering, and
    # the summarized thinking is logged. Don't ask for reasoning in the answer itself:
    # newer models refuse that as "reasoning extraction".
    $body = @{
        model         = "claude-sonnet-5-5"
        max_tokens    = 8000
        thinking      = @{ type = "adaptive"; display = "summarized" }
        output_config = @{ format = @{ type = "json_schema"; schema = $schema } }
        messages      = @(@{ role = "user"; content = $content })
    } | ConvertTo-Json -Depth 20

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
    } catch {
        # Windows PowerShell hides the API's error body, so read it from the response
        $errorBody = $null
        try { $errorBody = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
        Write-Log "Error calling Claude API: $_ $errorBody"
        return $null
    }

    if ($response.stop_reason -ne "end_turn") {
        $category = if ($response.stop_details.category) { ", $($response.stop_details.category)" } else { "" }
        Write-Log "Claude did not finish its answer (stop reason: $($response.stop_reason)$category)."
        return $null
    }

    # Thinking blocks may come first; the answer is in the text block
    $response.content | Where-Object { $_.type -eq "thinking" -and $_.thinking } | ForEach-Object {
        Write-Log "Claude thinking: $($_.thinking.Trim())"
    }
    $text = ($response.content | Where-Object { $_.type -eq "text" } | Select-Object -First 1).text
    Write-Log "Claude response: $text"

    try {
        return $text | ConvertFrom-Json
    } catch {
        Write-Log "Could not parse Claude response as JSON: $_"
        return $null
    }
}

# Looks up a "Movie Name (Year)" on TMDB. Optional: returns $null without a call if
# $tmdbReadAccessToken is not configured.
# Returns @{ Id; Title; Year; Runtime (minutes, 0 if unknown) } or $null if not found.
function Find-TmdbMovie($movieName) {
    if (-not $tmdbReadAccessToken -or $tmdbReadAccessToken -like "YOUR_*") { return $null }
    if ($movieName -notmatch '^(.+?)\s*\((\d{4})\)$') { return $null }
    $query = $Matches[1]
    $year  = [int]$Matches[2]

    $headers = @{ Authorization = "Bearer $tmdbReadAccessToken"; accept = "application/json" }
    try {
        $search  = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/search/movie?query=$([uri]::EscapeDataString($query))" -Headers $headers
        $results = @($search.results | Where-Object { $_.release_date -match '^\d{4}' })

        # Results are sorted by relevance; prefer an exact year, then allow +-1 for regional release dates
        $match = $results | Where-Object { [int]$_.release_date.Substring(0, 4) -eq $year } | Select-Object -First 1
        if (-not $match) {
            $match = $results | Where-Object { [Math]::Abs([int]$_.release_date.Substring(0, 4) - $year) -le 1 } | Select-Object -First 1
        }
        if (-not $match) {
            Write-Log "TMDB: no match for $movieName. Using Claude's name."
            return $null
        }

        $details = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/movie/$($match.id)" -Headers $headers
        return @{
            Id      = $details.id
            Title   = $details.title
            Year    = $details.release_date.Substring(0, 4)
            Runtime = if ($details.runtime) { [int]$details.runtime } else { 0 }
        }
    } catch {
        Write-Log "Error calling TMDB API: $_. Using Claude's name."
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

# Calls Claude in a loop until the movie is identified. If a TMDB token is configured,
# the name is matched against TMDB and Claude re-picks edition and title using the
# official runtime.
# Returns @{ Name = <sanitized name>; Edition = <edition or $null>; TitleNum = <int or $null>;
#            TmdbId = <int or $null> }
function Invoke-IdentifyMovie($discInfoLines, $bdmtXml, $titleLines, $discImages) {
    $movieName    = $null
    $movieEdition = $null
    $userHint     = $null
    $titleNum     = $null

    $editions = @(
        "Collectors Edition", "Criterion Collection", "Director's Cut", "Extended Edition",
        "Final Edition", "IMAX", "Open Matte", "Remastered", "Special Edition",
        "Superduper Cut", "Theatrical Edition", "Ultimate Edition", "Uncut", "Unrated"
    )

    # Restrict the title answer to title numbers that actually exist on the disc
    $titleNums   = @($titleLines | ForEach-Object { if ($_ -match '^Title (\d+):') { [int]$Matches[1] } })
    $titleSchema = if ($titleNums.Count) { @{ anyOf = @(@{ type = "integer"; enum = $titleNums }, @{ type = "null" }) } } else { @{ type = "null" } }

    $schema = [ordered]@{
        type                 = "object"
        properties           = [ordered]@{
            name    = @{ type = "string" }
            edition = @{ type = "string"; enum = $editions + "NONE" }
            title   = $titleSchema
        }
        required             = @("name", "edition", "title")
        additionalProperties = $false
    }

    $editionInstructions = @"
Identify the edition or version if this is a special cut. Only specify an edition if you are confident it differs from the standard release. The edition can sometimes be derived from the length of the movie compared to the known theatrical runtime, but only do so if confident. Pick from this list:
$(($editions | ForEach-Object { "   - $_" }) -join "`n")
"@
    $titleInstructions = "Select the title number of the main feature film from the disc titles above. IMPORTANT! Consider the **expected runtime**, some discs have tracks that are longer than the movie, those tracks are usually extra material, not the main feature. Ignore bonus features, trailers, commentary tracks and short clips."
    $editionTitleFields = @"
- edition: the edition, or NONE if this is the standard version or you cannot determine the edition.
- title: the main feature title number, or null if you cannot determine it with confidence.
"@

    do {
        $hintSection   = if ($userHint)           { "`n`nAdditional hint from user: $userHint" } else { "" }
        $bdmtSection   = if ($bdmtXml)            { "`n`nDisc metadata XML:`n$bdmtXml" }         else { "" }
        $titlesSection = if ($titleLines.Count -gt 0) { "`n`nDisc titles:`n" + ($titleLines -join "`n") } else { "" }
        $discSection   = "The following information was collected from a Blu-ray disc:`n" + ($discInfoLines -join "`n") + $bdmtSection + $titlesSection + $hintSection

        $namePrompt = @"
$discSection

Please identify the movie, its edition, and the title number of the main feature.

1. Identify the movie and format it exactly as: Movie Name (Year)
   Make sure the name matches the title on https://www.themoviedb.org/

2. $editionInstructions

3. $titleInstructions

Answer fields:
- name: Movie Name (Year), or UNKNOWN if you cannot identify the movie with high confidence.
$editionTitleFields
"@

        Write-Log "Sending to Claude: $($discInfoLines -join '; ')"
        if ($bdmtXml)          { Write-Log "  + disc metadata XML" }
        if ($titleLines.Count) { Write-Log "  + $($titleLines.Count) titles" }
        if ($discImages.Count) { Write-Log "  + $($discImages.Count) image(s)" }
        if ($userHint)         { Write-Log "  + user hint: $userHint" }
        Write-Log "Asking Claude to identify disc, edition and title..."
        $claudeResponse = Invoke-Claude $namePrompt $schema $discImages

        if ($claudeResponse) {
            if ($claudeResponse.edition -ne "NONE") {
                $movieEdition = $claudeResponse.edition
                Write-Log "Claude identified edition: $movieEdition"
            }

            $extractedName = "$($claudeResponse.name)".Trim()
            if ($extractedName -ne "UNKNOWN" -and $extractedName -match '.+\(\d{4}\)') {
                $movieName = $extractedName
                Write-Log "Claude identified movie: $movieName"
            } else {
                Write-Log "Claude could not identify movie from disc name."
            }

            if ($claudeResponse.title -ne $null) {
                $titleNum = [int]$claudeResponse.title
            }
        } else {
            Write-Log "Claude returned no usable response for movie name."
        }

        if (-not $movieName) {
            Invoke-Beep
            Write-Host ""
            $userHint = Read-Host "Enter movie hint for Claude"
        }
    } while (-not $movieName)

    $tmdb = Find-TmdbMovie $movieName
    if ($tmdb) {
        $movieName = "$($tmdb.Title) ($($tmdb.Year))"
        Write-Log "TMDB match: $movieName, runtime $($tmdb.Runtime) min (TMDB id $($tmdb.Id))"

        if ($tmdb.Runtime -gt 0) {
            $refinePrompt = @"
$discSection

The movie on this disc is $movieName. According to TMDB, its theatrical runtime is $($tmdb.Runtime) minutes.

1. $editionInstructions

2. $titleInstructions

Answer fields:
$editionTitleFields
"@
            $refineSchema = [ordered]@{
                type                 = "object"
                properties           = [ordered]@{
                    edition = $schema.properties.edition
                    title   = $titleSchema
                }
                required             = @("edition", "title")
                additionalProperties = $false
            }

            Write-Log "Asking Claude to select edition and title using the TMDB runtime..."
            $refined = Invoke-Claude $refinePrompt $refineSchema $discImages
            # Keep the first answer if this call fails
            if ($refined) {
                $movieEdition = if ($refined.edition -ne "NONE") { $refined.edition } else { $null }
                $titleNum     = if ($refined.title -ne $null) { [int]$refined.title } else { $null }
                Write-Log "Claude edition: $(if ($movieEdition) { $movieEdition } else { 'standard' }), title: $(if ($titleNum -ne $null) { $titleNum } else { 'undetermined' })"
            }
        }
    }

    $movieName = $movieName -replace ':', ' -' -replace '"', "'" -replace '[\\/*?<>|]', ''
    $movieName = $movieName -replace '\s{2,}', ' '

    return @{
        Name     = $movieName
        Edition  = $movieEdition
        TitleNum = $titleNum
        TmdbId   = if ($tmdb) { $tmdb.Id } else { $null }
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

Answer with "keep": the track IDs to keep.

$($trackLines -join "`n")
"@

    $audioSchema = [ordered]@{
        type                 = "object"
        properties           = [ordered]@{
            keep = @{ type = "array"; items = @{ type = "integer"; enum = @($mkvAudioTracks | ForEach-Object { [int]$_.id }) } }
        }
        required             = @("keep")
        additionalProperties = $false
    }

    $claudeAudioResponse = Invoke-Claude $audioPrompt $audioSchema

    if (-not $claudeAudioResponse) {
        Write-Log "Claude could not determine audio tracks. Prompting for manual selection."
        $keepIds = $null
    } else {
        $keepIds = @($claudeAudioResponse.keep | ForEach-Object { "$_" } | Select-Object -Unique)
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

    & $mkvmerge -o "$localFinalMkv" --audio-tracks $audioArg "$tempMkv" | Out-Host

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
                    & $mkvpropedit "$localFinalMkv" --edit track:v1 --set display-width=$newW --set display-height=$newH | Out-Host
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
function Start-DestinationCopy($localFinalMkv, $movieName, $movieEdition, $destRoot, $source = "Blu-ray", $tmdbId = $null) {
    $movieFolder = Join-Path $destRoot $movieName
    $finalMkv    = Join-Path $movieFolder "$movieName.mkv"

    if (-not (Test-Path $movieFolder)) {
        New-Item -ItemType Directory -Path $movieFolder | Out-Null
        Write-Log "Created folder: $movieFolder"
    }

    $nfoPath    = Join-Path $movieFolder "$movieName.nfo"
    $existingNfo = Get-ChildItem -Path $movieFolder -Recurse -Filter "*.nfo" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $existingNfo) {
        $editionTag = if ($movieEdition) { "`n    <edition>$movieEdition</edition>" } else { "" }
        # Kodi-style id tag, same format tinyMediaManager writes; lets it scrape by id
        $tmdbTag    = if ($tmdbId) { "`n    <uniqueid type=`"tmdb`" default=`"true`">$tmdbId</uniqueid>" } else { "" }
        $nfoContent = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
    <source>$source</source>$editionTag$tmdbTag
</movie>
"@
        [System.IO.File]::WriteAllText($nfoPath, $nfoContent, [System.Text.Encoding]::UTF8)
        $editionLog = if ($movieEdition) { ", edition: $movieEdition" } else { "" }
        $tmdbLog    = if ($tmdbId) { ", TMDB id: $tmdbId" } else { "" }
        Write-Log "Created NFO with source: $source$editionLog$tmdbLog"
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
