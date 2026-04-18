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

# Prompt for source folder
$sourceRoot = Read-Host "Enter source folder path"
if (-not (Test-Path $sourceRoot)) {
    Write-Host "Error: Source folder not found: $sourceRoot"
    exit
}
Write-Log "Source: $sourceRoot"

# Select destination folder
if ($defaultDestRoots.Count -eq 0) {
    Write-Host "Error: No destinations configured. Please add at least one entry to `$defaultDestRoots in config.ps1."
    exit
}
$destRoot = Select-Destination

# Discover all immediate subfolders that contain a BDMV subdirectory
$bdmvFolders = @(Get-ChildItem -Path $sourceRoot -Recurse -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "BDMV") } |
    Sort-Object FullName)

if ($bdmvFolders.Count -eq 0) {
    Write-Log "No BDMV folders found in $sourceRoot. Exiting."
    exit
}

Write-Log "Found $($bdmvFolders.Count) BDMV folder(s) in $sourceRoot"

$copyJob = $null

foreach ($folder in $bdmvFolders) {

    $filePath = $folder.FullName
    Write-Log ""
    Write-Log "Processing folder: $($folder.Name)"

    # -------------------------------------------------------------------------
    # Parse titles from folder
    # -------------------------------------------------------------------------
    $indexBdmv  = Join-Path $filePath "BDMV\index.bdmv"
    $infoOutput = & $makemkvcon -r info $indexBdmv 2>&1

    $titles = Invoke-ParseTitles $infoOutput

    $tl              = Get-TitleLines $titles
    $titleLines      = $tl.TitleLines
    $titlesWithAudio = $tl.TitlesWithAudio

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

    $relParent     = $folder.Parent.FullName.Substring($sourceRoot.TrimEnd('\').Length).TrimStart('\')
    $effectiveDest = if ($relParent) { Join-Path $destRoot $relParent } else { $destRoot }
    $movieFolder   = Join-Path $effectiveDest $movieName
    $finalMkv      = Join-Path $movieFolder "$movieName.mkv"

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
    $chosenTitle = Select-Title $id $titleLines $titlesWithAudio

    # -------------------------------------------------------------------------
    # Step 1: Rip from folder
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Log "Step 1: Ripping title $chosenTitle from folder..."

    $beforeRip   = Get-Date
    $tempMkvName = "temp_ripping_$([System.Guid]::NewGuid().ToString('N')).mkv"
    $tempMkv     = Join-Path $localTemp $tempMkvName
    & $makemkvcon mkv $indexBdmv $chosenTitle "$localTemp"
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
    # Step 4: Copy to destination, then delete source folder
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "Step 4: Copying to destination..."

    $source   = Get-DiscSource $titles[$chosenTitle].Resolution
    $finalMkv = Start-DestinationCopy $localFinalMkv $movieName $movieEdition $effectiveDest $source

    if (Wait-CopyJob) {
        # Move/rename NFO and SRT files to root before deleting disc data
        $toMove = @(Get-ChildItem -Path $filePath -Recurse -File |
            Where-Object { $_.Name -match '\.(nfo|srt)$' })
        foreach ($file in $toMove) {
            $compoundExt = if ($file.Name -match '(\.[a-z]{2,4}(\.[a-z]+)*\.[a-z]+)$') {
                $matches[1]
            } else {
                $file.Extension
            }
            $destName = "$movieName$compoundExt"
            $destPath = Join-Path $filePath $destName
            Move-Item -Path $file.FullName -Destination $destPath -Force
            Write-Log "Moved to root: $($file.Name) -> $destName"
        }

        Get-ChildItem -Path $filePath -Directory | ForEach-Object {
            Remove-Item -Path $_.FullName -Recurse -Force
            Write-Log "Deleted subfolder: $($_.Name)"
        }
    } else {
        Write-Log "Copy failed; disc data retained: $filePath"
    }

    Write-DoneSummary $audioResult $movieName $finalMkv

} # end foreach

Write-Log "All folders processed."
