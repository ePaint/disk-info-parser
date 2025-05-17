Param
(
    [Parameter(Mandatory = $true)]
    [string[]]$FilePaths,
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ""
)

# ---------------------------------------- SETTINGS ---------------------------------------- #

# Log path
$Global:GenerateLogFile = $false
$Global:LogPath = ".\logs\log [Timestamp].txt"

# ------------------------------------------------------------------------------------------ #

Clear-Host

$LogTimestamp = Get-Date -Format "yyyy-MM-dd HH-mm-ss-fff"

$Global:LogPath = $Global:LogPath.Replace("[Timestamp]", $LogTimestamp)

If ($OutputPath -eq "") {
    $Timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $OutputPath = "ParsedDiskInfo-$Timestamp.txt"
}

Function Write-Log {
    Param (
        [Parameter(Mandatory = $false)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [System.ConsoleColor]$Color = "Gray"
    )

    $Timestamp = "[$(Get-Date -Format "dd/MM/yyyy HH:mm:ss.fff")] "
    Write-Host $Timestamp -NoNewline -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor $Color
    If ($Global:GenerateLogFile) {
        If (-Not (Test-Path -Path $Global:LogPath)) {
            New-Item -Path $Global:LogPath -ItemType File -Force | Out-Null
        }
        Add-Content -LiteralPath $Global:LogPath -Value "$Timestamp$Message"
    }
}

Function Get-FixedWidthColumns {
    Param (
        [Parameter(Mandatory = $true)]
        [string]$HeaderLine
    )

    $knownColumns = @(
        'ID',
        'Cur',
        'Wor',
        'Thr',
        'RawValues(6)',
        'Attribute Name'
    )

    $Columns = @()
    $Offset = 0

    ForEach ($Col in $knownColumns) {
        $Index = $HeaderLine.IndexOf($col, $Offset)
        If ($Index -lt 0) {
            Continue
        }
        $Columns += [PSCustomObject]@{
            Name  = $Col
            Start = $Index
            End   = $Index + $Col.Length - 1
        }
        $Offset = $Index + $Col.Length
    }

    $Columns | ForEach-Object {
        Write-Log "Found SMART column '$($_.Name)'"
    }

    Return $Columns
}

function Convert-FixedWidthToCsv {
    Param (
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )
    
    $Columns = Get-FixedWidthColumns -HeaderLine $Lines[0]
    
    $Output = ForEach ($Line in $Lines[1..($Lines.Count - 1)]) {
        If (-not [string]::IsNullOrWhiteSpace($Line)) {
            $Row = [ordered]@{}
            
            For ($i = 0; $i -lt $Columns.Count; $i++) {
                $Col = $columns[$i]
                $Start = $Col.Start
                
                If ($i -eq $Columns.Count - 1) {
                    $Value = $Line.Substring($start).Trim()
                }
                Else {
                    $Length = $Columns[$i + 1].Start - $Start
                    $Value = $Line.Substring($Start, $Length).Trim()
                }
                
                If ($Col.Name -eq "RawValues(6)") {
                    $Value = [int64]::Parse($Value, [System.Globalization.NumberStyles]::HexNumber)
                }
                $Row[$Col.Name] = $Value
            }
            
            [PSCustomObject]$Row
        }
    }

    Return $Output
}

Function Get-DiskMetadata {
    Param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Disk
    )

    $Disk.Content = $Disk.Content[1..$($Disk.Content.Count - 1)]

    $Metadata = [PSCustomObject]@{
        "GeneralProperties" = @{}
        "SMART"             = @{}
    }

    $Section = "GeneralProperties"
    Write-Log "Parsing $Section section for disk $($Disk.Label)" Green
    $Disk.Content | ForEach-Object {
        $Line = $_
        Switch ($Section) {
            "GeneralProperties" {
                If ($Line -eq "") {
                    Write-Log "Finished parsing $Section section for disk $($Disk.Label)" Green
                    $Section = "SMART"
                    Write-Log "Parsing $Section section for disk $($Disk.Label)" Green
                    Continue
                }
    
                $PropertyPattern = '^\s*(?<Property>.+?)\s*:\s*(?<Value>.+)$'
                $Property = $Line -replace $PropertyPattern, '$1'
                $Value = $Line -replace $PropertyPattern, '$2'
                Write-Log "Found General Property '$Property' with value '$Value'" 
                $Metadata.$Section.Add($Property, $Value)
            }
            "SMART" {
                If ($Line -match "^-- S.M.A.R.T") {
                    $SmarthBlock = @()
                    Continue
                }
                If ($Line -eq "") {
                    $Metadata.SMART = Convert-FixedWidthToCsv -Lines $SmarthBlock
                    Write-Log "Finished parsing $Section section for disk $($Disk.Label)" Green
                    $Section = "END"
                    Continue
                }
                $SmarthBlock += $Line
            }
        }
    }

    $Metadata.GeneralProperties = [PSCustomObject]$Metadata.GeneralProperties

    Return $Metadata
}

Function Get-DiskList {
    [OutputType([string])]
    Param (
        [Parameter(Mandatory = $true)]
        [Object[]]$Content
    )

    $DiskPattern = '\((?<Index>\d+)\) (?<Model>.+?) :'

    $DiskList = @()

    $Content | ForEach-Object {
        If ($_ -match '^-- Disk List -+$') {
            $InsideDiskList = $true
        }
        ElseIf ($InsideDiskList -and $_ -match '^-+$') {
            $InsideDiskList = $false
        }
        ElseIf ($InsideDiskList) {
            $DiskList += [regex]::Matches($_, $DiskPattern) | ForEach-Object {
                [PSCustomObject]@{
                    Index    = $_.Groups['Index'].Value
                    Model    = $_.Groups['Model'].Value
                    Label    = "($($_.Groups['Index'].Value)) $($_.Groups['Model'].Value)"
                    Match    = "^ \($($_.Groups['Index'].Value)\) $($_.Groups['Model'].Value)$"
                    Content  = @()
                    Metadata = @{}
                }
            }
        }
    }
    
    $DiskIndex = 0
    $Disk = $DiskList[$DiskIndex]
    $DiskIndex++
    If ($DiskList.Count -gt $DiskIndex) {
        $NextDisk = $DiskList[$DiskIndex]
    }
    Else {
        $NextDisk = $null
    }
    $Content | ForEach-Object {
        If ($_ -match $Disk.Match) {
            $InsideDisk = $true
        }
        ElseIf ($InsideDisk -and $null -ne $NextDisk -and $_ -match $NextDisk.Match) {
            $Disk = $DiskList[$DiskIndex]
            $DiskIndex++
            If ($DiskList.Count -gt $DiskIndex) {
                $NextDisk = $DiskList[$DiskIndex]
            }
            Else {
                $NextDisk = $null
            }
        }
        ElseIf ($InsideDisk) {
            $Disk.Content += $_
        }
    }
    $DiskList | ForEach-Object {
        $Disk = $_
        $Disk.Metadata = Get-DiskMetadata -Disk $Disk
    }

    Return $DiskList
}

Function Convert-DiskToString {
    Param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Disk
    )

    $Output = @()
    $Output += "---------------------------------------------"
    $Output += "Disk: $($Disk.Label)"
    $Output += $Disk.Metadata.GeneralProperties | Format-List
    $Output += $Disk.Metadata.SMART | Format-Table
    $Output += "---------------------------------------------"
    Return $Output
}

Write-Log "Raw File Paths: $FilePaths" Cyan
$FilePaths | ForEach-Object {
    Write-Log "Processing File: $_" Cyan
    $Content = Get-Content -Path $_
    $DiskList = Get-DiskList -Content $Content
    $Output = $DiskList | ForEach-Object { Convert-DiskToString -Disk $_ }
    $Output | Out-File -FilePath $OutputPath -Append -Encoding UTF8
}