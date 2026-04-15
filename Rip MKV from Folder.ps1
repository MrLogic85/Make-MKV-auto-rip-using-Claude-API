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

. (Join-Path $PSScriptRoot "common.ps1")

# Verify tools exist
if (-not (Test-Path $makemkvcon)) { Write-Log "Error: MakeMKV not found at $makemkvcon"; exit }
if (-not (Test-Path $mkvmerge))   { Write-Log "Error: MKVToolNix not found at $mkvmerge"; exit }

# Select source folder
if ($defaultSourceRoots.Count -eq 0) {
    Write-Host "Error: No source folders configured. Please add at least one entry to `$defaultSourceRoots in config.ps1."
    exit
} elseif ($defaultSourceRoots.Count -eq 1) {
    $sourceRoot = $defaultSourceRoots[0]
    Write-Log "Source: $sourceRoot"
} else {
    $idx        = Invoke-Menu -Title "Select source folder:" -Options $defaultSourceRoots -NoBeep
    $sourceRoot = $defaultSourceRoots[$idx]
    Write-Log "Source: $sourceRoot"
}

# Select destination folder
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

# Discover all immediate subfolders that contain a BDMV subdirectory
$bdmvFolders = @(Get-ChildItem -Path $sourceRoot -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "BDMV") } |
    Sort-Object Name)

if ($bdmvFolders.Count -eq 0) {
    Write-Log "No BDMV folders found in $sourceRoot. Exiting."
    exit
}

Write-Log "Found $($bdmvFolders.Count) BDMV folder(s) in $sourceRoot"

$copyJob           = $null
$lastCopySucceeded = $false
$lastSourceFolder  = $null

foreach ($folder in $bdmvFolders) {

    # Wait for the previous copy to finish, then delete that source folder if it succeeded
    $lastCopySucceeded = Wait-CopyJob
    if ($lastSourceFolder) {
        if ($lastCopySucceeded) {
            Remove-Item -Path $lastSourceFolder -Recurse -Force
            Write-Log "Deleted source folder: $lastSourceFolder"
        } else {
            Write-Log "Skipping delete of $lastSourceFolder — previous copy failed."
        }
    }

    $filePath = $folder.FullName
    Write-Log ""
    Write-Log "Processing folder: $($folder.Name)"

    # -------------------------------------------------------------------------
    # Parse titles from folder
    # -------------------------------------------------------------------------
    $infoOutput = & $makemkvcon -r info "file://$filePath" 2>&1

    $titles = Invoke-ParseTitles $infoOutput

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
    # Read disc metadata from folder
    # -------------------------------------------------------------------------
    $bdmtXml    = $null
    $discImages = @()

    $bdmtDir  = Join-Path $filePath "BDMV\META\DL"
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

    # -------------------------------------------------------------------------
    # Identify movie via Claude
    # -------------------------------------------------------------------------
    $discInfoLines = @("Folder name: $($folder.Name)")

    $id           = Invoke-IdentifyMovie $discInfoLines $bdmtXml $titleLines $discImages
    $movieName    = $id.Name
    $movieEdition = $id.Edition

    $movieFolder = Join-Path $destRoot $movieName
    $finalMkv    = Join-Path $movieFolder "$movieName.mkv"

    Write-Log "Movie: $movieName"
    Write-Log "Destination: $movieFolder"

    if (Test-Path $finalMkv) {
        Write-Log "WARNING: MKV already exists at $finalMkv"
        $idx = Invoke-Menu -Title "File already exists. Overwrite?" -Options @("No, skip this folder", "Yes, overwrite") -Default 0
        if ($idx -ne 1) {
            Write-Log "Skipping $($folder.Name)."
            continue
        }
    }

    # -------------------------------------------------------------------------
    # Select title
    # -------------------------------------------------------------------------
    if ($id.TitleNum -ne $null) {
        $chosenTitle = $id.TitleNum
        Write-Log "Claude selected title: $chosenTitle"
    } else {
        Write-Log "Claude could not determine title. Please select manually."
        $titleKeys   = @($titlesWithAudio | ForEach-Object { $_.Key })
        $idx         = Invoke-Menu -Title "Select title:" -Options $titleLines
        $chosenTitle = $titleKeys[$idx]
    }

    # -------------------------------------------------------------------------
    # Step 1: Rip from folder
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Log "Step 1: Ripping title $chosenTitle from folder..."

    $beforeRip   = Get-Date
    $tempMkvName = "temp_ripping_$([System.Guid]::NewGuid().ToString('N')).mkv"
    $tempMkv     = Join-Path $localTemp $tempMkvName
    & $makemkvcon mkv "file://$filePath" $chosenTitle "$localTemp"
    $ripExitCode = $LASTEXITCODE

    $generatedMkv = Get-ChildItem -Path $localTemp -Filter "*.mkv" |
        Where-Object { $_.LastWriteTime -gt $beforeRip } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($ripExitCode -ne 0 -or -not $generatedMkv) {
        Write-Log "Error: Ripping failed (exit code $ripExitCode). Skipping $($folder.Name)."
        if ($generatedMkv) {
            Remove-Item -Path $generatedMkv.FullName -ErrorAction SilentlyContinue
            Write-Log "Removed partial MKV file."
        }
        continue
    }

    Rename-Item -Path $generatedMkv.FullName -NewName $tempMkvName

    # -------------------------------------------------------------------------
    # Steps 2 & 3: Select and filter audio tracks
    # -------------------------------------------------------------------------
    $audioResult   = Invoke-SelectAudioTracks $tempMkv $movieName
    $localFinalMkv = Invoke-FilterAudio $tempMkv $audioResult.KeepIds $movieName

    # -------------------------------------------------------------------------
    # Step 4: Copy to destination (background job)
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "Step 4: Starting copy to destination in background..."

    $finalMkv = Start-DestinationCopy $localFinalMkv $movieName $movieEdition $destRoot

    $keptTracks   = $audioResult.AudioTracks | Where-Object { $audioResult.KeepIds -contains "$($_.id)" }
    $audioSummary = ($keptTracks | ForEach-Object { "$($_.codec)[$($_.properties.language)]" }) -join ", "

    Write-Host ""
    Write-Log "=== DONE ==="
    Write-Log "Movie: $movieName"
    Write-Log "Audio: $audioSummary"
    Write-Log "Location: $finalMkv"
    Write-Log "Log saved to: $logFile"

    $lastSourceFolder = $filePath

} # end foreach

# Wait for the last copy job and clean up its source folder
$lastCopySucceeded = Wait-CopyJob
if ($lastSourceFolder) {
    if ($lastCopySucceeded) {
        Remove-Item -Path $lastSourceFolder -Recurse -Force
        Write-Log "Deleted source folder: $lastSourceFolder"
    } else {
        Write-Log "Skipping delete of $lastSourceFolder — copy failed."
    }
}

Write-Log "All folders processed."
