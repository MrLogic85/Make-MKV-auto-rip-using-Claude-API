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

# Select destination once upfront
if ($defaultDestRoots.Count -eq 0) {
    Write-Host "Error: No destinations configured. Please add at least one entry to `$defaultDestRoots in config.ps1."
    exit
}
$destRoot = Select-Destination

$lastDiscName = $null
$copyJob      = $null
while ($true) {

    $bdmtXml    = $null
    $discImages = @()

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
    $titles = Invoke-ParseTitles $infoOutput

    $tl              = Get-TitleLines $titles
    $titleLines      = $tl.TitleLines
    $titlesWithAudio = $tl.TitlesWithAudio

    # -------------------------------------------------------------------------
    # Read disc metadata
    # -------------------------------------------------------------------------
    $volumeLabel = $null
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

    # -------------------------------------------------------------------------
    # Identify movie via Claude
    # -------------------------------------------------------------------------
    $discInfoLines = @("MakeMKV disc name: $discName")
    if ($volumeLabel) { $discInfoLines += "Drive volume label: $volumeLabel" }

    $id           = Invoke-IdentifyMovie $discInfoLines $bdmtXml $titleLines $discImages
    $movieName    = $id.Name
    $movieEdition = $id.Edition

    $movieFolder = Join-Path $destRoot $movieName
    $finalMkv    = Join-Path $movieFolder "$movieName.mkv"

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
    $chosenTitle = Select-Title $id $titleLines $titlesWithAudio

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
    # Steps 2 & 3: Select and filter audio tracks
    # -------------------------------------------------------------------------
    $audioResult   = Invoke-SelectAudioTracks $tempMkv $movieName
    $localFinalMkv = Invoke-FilterAudio $tempMkv $audioResult.KeepIds $movieName

    # -------------------------------------------------------------------------
    # Step 4: Copy to destination (background job)
    # -------------------------------------------------------------------------
    Write-Log ""
    Write-Log "Step 4: Starting copy to destination in background..."

    # Wait for the previous disc's copy to finish before starting a new one
    Wait-CopyJob

    $source   = Get-DiscSource $titles[$chosenTitle].Resolution
    $finalMkv = Start-DestinationCopy $localFinalMkv $movieName $movieEdition $destRoot $source

    Write-DoneSummary $audioResult $movieName $finalMkv

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
