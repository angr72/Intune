#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates a bootable Windows 11 USB with injected drivers using a WinForms GUI.
.NOTES
    Requires Windows ADK (DISM) and must be run as Administrator.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region ── GUI ──────────────────────────────────────────────────────────────────

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Windows 11 USB Creator'
$form.Size = New-Object System.Drawing.Size(600, 480)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

function New-Label($text, $x, $y) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.AutoSize = $true
    return $lbl
}

function New-TextBox($x, $y, $w) {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point($x, $y)
    $tb.Width = $w
    $tb.ReadOnly = $true
    return $tb
}

function New-Button($text, $x, $y, $w) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point($x, $y)
    $btn.Width = $w
    return $btn
}

# ── ISO ──────────────────────────────────────────────────────────────────────
$form.Controls.Add((New-Label 'Windows 11 ISO:' 20 20))
$tbISO = New-TextBox 20 42 460
$form.Controls.Add($tbISO)
$btnISO = New-Button 'Browse…' 490 40 80
$btnISO.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'ISO files (*.iso)|*.iso'
    $dlg.Title  = 'Select Windows 11 ISO'
    if ($dlg.ShowDialog() -eq 'OK') { $tbISO.Text = $dlg.FileName }
})
$form.Controls.Add($btnISO)

# ── Drivers folder ───────────────────────────────────────────────────────────
$form.Controls.Add((New-Label 'Drivers folder (contains .inf files):' 20 80))
$tbDrivers = New-TextBox 20 102 460
$form.Controls.Add($tbDrivers)
$btnDrivers = New-Button 'Browse…' 490 100 80
$btnDrivers.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the folder containing driver packages (.inf)'
    if ($dlg.ShowDialog() -eq 'OK') { $tbDrivers.Text = $dlg.SelectedPath }
})
$form.Controls.Add($btnDrivers)

# ── USB drive ────────────────────────────────────────────────────────────────
$form.Controls.Add((New-Label 'Target USB drive:' 20 140))
$cmbUSB = New-Object System.Windows.Forms.ComboBox
$cmbUSB.Location  = New-Object System.Drawing.Point(20, 162)
$cmbUSB.Width     = 380
$cmbUSB.DropDownStyle = 'DropDownList'
$form.Controls.Add($cmbUSB)

$btnRefresh = New-Button 'Refresh' 410 160 80
$btnRefresh.Add_Click({
    $cmbUSB.Items.Clear()
    Get-Disk | Where-Object BusType -eq 'USB' | ForEach-Object {
        $disk = $_
        $parts = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        $letter = ($parts | Where-Object DriveLetter | Select-Object -First 1).DriveLetter
        $label  = if ($letter) { " ($letter`:)" } else { ' (no letter)' }
        $entry  = "Disk $($disk.Number) – $([math]::Round($disk.Size/1GB,1)) GB$label – $($disk.FriendlyName)"
        $cmbUSB.Items.Add($entry) | Out-Null
    }
    if ($cmbUSB.Items.Count -gt 0) { $cmbUSB.SelectedIndex = 0 }
    else { [System.Windows.Forms.MessageBox]::Show('No USB drives found.','USB Creator','OK','Warning') }
})
$form.Controls.Add($btnRefresh)

# Warn label
$lblWarn = New-Object System.Windows.Forms.Label
$lblWarn.Text      = '⚠  ALL DATA ON THE SELECTED USB DRIVE WILL BE ERASED.'
$lblWarn.ForeColor = [System.Drawing.Color]::DarkRed
$lblWarn.Location  = New-Object System.Drawing.Point(20, 200)
$lblWarn.AutoSize  = $true
$form.Controls.Add($lblWarn)

# ── Progress / log ───────────────────────────────────────────────────────────
$form.Controls.Add((New-Label 'Log:' 20 230))
$rtb = New-Object System.Windows.Forms.RichTextBox
$rtb.Location   = New-Object System.Drawing.Point(20, 250)
$rtb.Size       = New-Object System.Drawing.Size(550, 140)
$rtb.ReadOnly   = $true
$rtb.BackColor  = [System.Drawing.Color]::Black
$rtb.ForeColor  = [System.Drawing.Color]::LightGreen
$rtb.Font       = New-Object System.Drawing.Font('Consolas', 9)
$rtb.ScrollBars = 'Vertical'
$form.Controls.Add($rtb)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 398)
$progressBar.Size     = New-Object System.Drawing.Size(550, 18)
$progressBar.Style    = 'Marquee'
$progressBar.Visible  = $false
$form.Controls.Add($progressBar)

# ── Start button ─────────────────────────────────────────────────────────────
$btnStart = New-Button 'Create USB' 200 422 180
$btnStart.Height    = 32
$btnStart.BackColor = [System.Drawing.Color]::SteelBlue
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnStart)

#endregion

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$msg, [System.Drawing.Color]$color = [System.Drawing.Color]::LightGreen)
    $timestamp = (Get-Date -Format 'HH:mm:ss')
    $rtb.SelectionStart  = $rtb.TextLength
    $rtb.SelectionLength = 0
    $rtb.SelectionColor  = $color
    $rtb.AppendText("[$timestamp] $msg`n")
    $rtb.ScrollToCaret()
    $form.Refresh()
}

function Write-Error-Log($msg) { Write-Log $msg ([System.Drawing.Color]::Tomato) }
function Write-Step($msg)      { Write-Log "── $msg" ([System.Drawing.Color]::Cyan) }

function Get-DiskNumber {
    # Extract the disk number from the combo-box string "Disk N – …"
    if ($cmbUSB.SelectedItem -match '^Disk\s+(\d+)') { return [int]$Matches[1] }
    return $null
}

function Mount-ISO($isoPath) {
    Write-Step "Mounting ISO: $isoPath"
    $result = Mount-DiskImage -ImagePath $isoPath -PassThru
    $vol    = Get-Volume -DiskImage $result | Select-Object -First 1
    return $vol.DriveLetter
}

function Dismount-ISO($isoPath) {
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
}

#endregion

#region ── Main logic ───────────────────────────────────────────────────────────

$btnStart.Add_Click({

    # ── Validate inputs ──────────────────────────────────────────────────────
    $isoPath     = $tbISO.Text.Trim()
    $driverPath  = $tbDrivers.Text.Trim()
    $diskNumber  = Get-DiskNumber

    if (-not $isoPath -or -not (Test-Path $isoPath)) {
        [System.Windows.Forms.MessageBox]::Show('Please select a valid ISO file.','Validation','OK','Warning'); return
    }
    if (-not $driverPath -or -not (Test-Path $driverPath)) {
        [System.Windows.Forms.MessageBox]::Show('Please select a valid drivers folder.','Validation','OK','Warning'); return
    }
    if ($null -eq $diskNumber) {
        [System.Windows.Forms.MessageBox]::Show('Please select a USB drive.','Validation','OK','Warning'); return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This will ERASE Disk $diskNumber and create a bootable Windows 11 USB.`n`nContinue?",
        'Confirm', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    # ── UI lock ──────────────────────────────────────────────────────────────
    $btnStart.Enabled    = $false
    $btnISO.Enabled      = $false
    $btnDrivers.Enabled  = $false
    $btnRefresh.Enabled  = $false
    $progressBar.Visible = $true

    $tempMount  = $null   # WIM mount path
    $isoDrive   = $null   # ISO mount drive letter

    try {

        # ── Step 1: Format USB ───────────────────────────────────────────────
        Write-Step 'Formatting USB drive…'
        $disk = Get-Disk -Number $diskNumber
        if ($disk.IsReadOnly) { throw "Disk $diskNumber is write-protected." }

        Clear-Disk -Number $diskNumber -RemoveData -Confirm:$false -ErrorAction Stop
        Initialize-Disk -Number $diskNumber -PartitionStyle MBR -ErrorAction Stop

        # Boot partition (FAT32, 1 GB) – needed for UEFI + large install.wim split
        $bootPart = New-Partition -DiskNumber $diskNumber -Size 1GB -IsActive -AssignDriveLetter
        Format-Volume -Partition $bootPart -FileSystem FAT32 -NewFileSystemLabel 'BOOT' -Confirm:$false | Out-Null
        $bootLetter = (Get-Partition -DiskNumber $diskNumber -PartitionNumber $bootPart.PartitionNumber).DriveLetter

        # Data partition (NTFS, remainder) – holds install.wim > 4 GB
        $dataPart = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $dataPart -FileSystem NTFS -NewFileSystemLabel 'WIN11USB' -Confirm:$false | Out-Null
        $dataLetter = (Get-Partition -DiskNumber $diskNumber -PartitionNumber $dataPart.PartitionNumber).DriveLetter

        Write-Log "  Boot partition : ${bootLetter}:"
        Write-Log "  Data partition : ${dataLetter}:"

        # ── Step 2: Mount ISO ────────────────────────────────────────────────
        $isoDrive = Mount-ISO $isoPath
        if (-not $isoDrive) { throw 'Failed to mount ISO – could not determine drive letter.' }
        Write-Log "  ISO mounted at ${isoDrive}:"

        # ── Step 3: Copy ISO contents (boot files → FAT32 partition) ─────────
        Write-Step 'Copying boot files to FAT32 partition…'
        # Copy everything except sources\install.wim (too large for FAT32)
        robocopy "${isoDrive}:\" "${bootLetter}:\" /E /XF install.wim /NFL /NDL /NJH /NJS | Out-Null

        # ── Step 4: Copy install.wim to NTFS partition ───────────────────────
        Write-Step 'Copying install.wim to NTFS partition…'
        $srcWim  = "${isoDrive}:\sources\install.wim"
        $destSrc = "${dataLetter}:\sources"
        if (-not (Test-Path $destSrc)) { New-Item -ItemType Directory -Path $destSrc | Out-Null }
        Copy-Item -Path $srcWim -Destination "$destSrc\install.wim" -Force

        # ── Step 5: Make install.wim writeable then mount ────────────────────
        Write-Step 'Mounting install.wim for driver injection…'
        $destWim  = "$destSrc\install.wim"
        Set-ItemProperty -Path $destWim -Name IsReadOnly -Value $false

        # Pick image index 1 (adjust if needed)
        $wimInfo = & dism /Get-ImageInfo /ImageFile:"$destWim" 2>&1
        Write-Log ($wimInfo | Select-String 'Image Name' | Out-String).Trim()

        $tempMount = Join-Path $env:TEMP "WimMount_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempMount | Out-Null
        $dismOut = & dism /Mount-Image /ImageFile:"$destWim" /Index:1 /MountDir:"$tempMount" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "DISM mount failed:`n$dismOut" }
        Write-Log '  WIM mounted.'

        # ── Step 6: Inject drivers ───────────────────────────────────────────
        Write-Step "Injecting drivers from: $driverPath"
        $dismOut = & dism /Image:"$tempMount" /Add-Driver /Driver:"$driverPath" /Recurse /ForceUnsigned 2>&1
        $dismOut | ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "Driver injection failed. See log above." }

        # ── Step 7: Commit & unmount WIM ─────────────────────────────────────
        Write-Step 'Committing changes to install.wim…'
        $dismOut = & dism /Unmount-Image /MountDir:"$tempMount" /Commit 2>&1
        if ($LASTEXITCODE -ne 0) { throw "DISM unmount/commit failed:`n$dismOut" }
        $tempMount = $null
        Write-Log '  WIM saved.'

        # ── Step 8: Create bootmgr on FAT32 partition ────────────────────────
        Write-Step 'Writing boot sector…'
        & bootsect /nt60 "${bootLetter}:" /force /mbr 2>&1 | ForEach-Object { Write-Log "  $_" }

        Dismount-ISO $isoPath

        Write-Log ''
        Write-Log '✔  Done!  USB is ready.' ([System.Drawing.Color]::LimeGreen)
        [System.Windows.Forms.MessageBox]::Show(
            "USB creation complete!`n`nBoot partition : ${bootLetter}:`nData partition  : ${dataLetter}:",
            'Success', 'OK', 'Information')

    } catch {
        Write-Error-Log "ERROR: $_"
        # Clean up a dangling WIM mount if something went wrong
        if ($tempMount -and (Test-Path $tempMount)) {
            Write-Log 'Cleaning up WIM mount…' ([System.Drawing.Color]::Yellow)
            & dism /Unmount-Image /MountDir:"$tempMount" /Discard 2>&1 | Out-Null
            Remove-Item $tempMount -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($isoPath) { Dismount-ISO $isoPath }
        [System.Windows.Forms.MessageBox]::Show("An error occurred:`n`n$_", 'Error', 'OK', 'Error')

    } finally {
        $progressBar.Visible = $false
        $btnStart.Enabled    = $true
        $btnISO.Enabled      = $true
        $btnDrivers.Enabled  = $true
        $btnRefresh.Enabled  = $true
    }
})

#endregion

# Pre-populate USB list on open
$btnRefresh.PerformClick()
$form.ShowDialog() | Out-Null
