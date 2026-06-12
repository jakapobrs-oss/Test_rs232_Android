<#
=====================================================================
 Test-PanasonicTv.ps1 — เทสยิงคำสั่ง Panasonic RS232C จาก notebook (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ Panasonic professional + โปรโตคอล" ทำงานจริง
 ใช้แค่ PowerShell ที่มีในเครื่อง ยังไม่เกี่ยวกับแอพ Android

 วิธีใช้:
   .\Test-PanasonicTv.ps1                   # หา COM port อัตโนมัติ + ถามสถานะ power (QPW)
   .\Test-PanasonicTv.ps1 -Port COM3
   .\Test-PanasonicTv.ps1 -Command power?   # ถามสถานะ (QPW → :0 standby / :1 on)
   .\Test-PanasonicTv.ps1 -Command on / off # !! เปิด(PON)/ปิด(POF)
   .\Test-PanasonicTv.ps1 -Command vol -Value 30   # AVL:030
   .\Test-PanasonicTv.ps1 -Command vol+ / vol-     # AUU / AUD
   .\Test-PanasonicTv.ps1 -Command mute / unmute   # AMT:1 / AMT:0
   .\Test-PanasonicTv.ps1 -Command hdmi1 / hdmi2 / hdmi3   # IMS:HM1..HM3
   .\Test-PanasonicTv.ps1 -Raw "PON"        # ส่งคำสั่งดิบ (สคริปต์หุ้ม STX/ETX ให้)

 โปรโตคอล Panasonic professional display:
   ส่ง = <STX=0x02> + คำสั่ง ASCII + <ETX=0x03>   เช่น  02 'P''O''N' 03
   คำสั่ง: PON เปิด · POF ปิด · QPW ถาม power · AVL:nnn ตั้งเสียง(000-100)
           AUU/AUD เพิ่ม/ลดเสียง · AMT:1/0 mute · IMS:HM1 เลือก HDMI1
   จอตอบ: หุ้ม STX/ETX เช่น "QPW:1" หรือ "ER401" (error)
   พอร์ต: 9600 bps, 8N1, no flow control
   หมายเหตุ: บางรุ่นถ้าตั้ง serial password ไว้ต้องใส่ก่อน (ปกติไม่ตั้ง = ไม่ต้อง)
             บางรุ่นเก่าใช้ IIS แทน IMS สำหรับเลือก input
   อ้างอิง: Panasonic Serial Command List (docs.connect.panasonic.com)
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
    [int]$Value = -1,        # ใช้กับ -Command vol (0-100)
    [string]$Raw,
    [int]$TimeoutMs = 2000
)

$ErrorActionPreference = 'Stop'

# ---------- หา COM port อัตโนมัติ (logic เดียวกับ Test-LgTv.ps1) ----------
function Find-SerialPort {
    $names = [System.IO.Ports.SerialPort]::GetPortNames()
    if (-not $names) {
        Write-Host "❌ ไม่พบ COM port ในเครื่องเลย — เสียบสาย RS232-to-USB แล้วรอ driver ติดตั้ง (ดูใน Device Manager)" -ForegroundColor Red
        exit 1
    }
    $pnp = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match '\(COM\d+\)' }
    Write-Host "พอร์ตที่พบในเครื่อง:" -ForegroundColor Cyan
    foreach ($p in $pnp) { Write-Host ("  - " + $p.Name) }

    $usb = $pnp | Where-Object { $_.Name -match 'USB|CH340|CH341|FTDI|Prolific|CP210|Serial.*Adapter' -and $_.Name -notmatch 'Communications Port' }
    if ($usb.Count -eq 1 -and $usb[0].Name -match '\((COM\d+)\)') { return $Matches[1] }
    if ($usb.Count -gt 1) {
        Write-Host "⚠️ พบ USB serial หลายตัว — ระบุเองด้วย -Port COMx" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "⚠️ ไม่พบ USB serial adapter (เจอแต่พอร์ต onboard) — ถ้าตั้งใจใช้พอร์ตนั้นให้ระบุ -Port COM1" -ForegroundColor Yellow
    exit 1
}

if (-not $Port) { $Port = Find-SerialPort }

# ---------- เปิดพอร์ต ----------
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.Handshake = 'None'
$sp.ReadTimeout = 200
try {
    $sp.Open()
} catch [System.UnauthorizedAccessException] {
    Write-Host "❌ $Port ถูกโปรแกรมอื่นเปิดค้างอยู่ (ปิด PuTTY/Arduino IDE/โปรแกรม serial อื่นก่อน)" -ForegroundColor Red
    exit 1
}
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (Panasonic STX/ETX)`n" -ForegroundColor Green

# ---------- ส่งคำสั่ง ASCII หุ้ม STX/ETX แล้วอ่านจนเจอ ETX/หมดเวลา ----------
function Send-Pana([string]$cmd) {
    $sp.DiscardInBuffer()
    Write-Host ("TX > <STX>$cmd<ETX>") -ForegroundColor Yellow
    $frame = [char]0x02 + $cmd + [char]0x03
    $sp.Write($frame)

    $sb = ''
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = $sp.ReadChar()
            if ($c -eq 0x03) { break }            # ETX = จบคำตอบ
            if ($c -ne 0x02) { $sb += [char]$c }  # ข้าม STX นำหน้า
        } catch [System.TimeoutException] { }
    }

    $clean = $sb.Trim()
    if (-not $clean) {
        Write-Host "RX < (ไม่มีคำตอบใน $TimeoutMs ms)" -ForegroundColor Red
        Write-Host "     เช็ค: 1) จอเสียบปลั๊ก/standby อยู่มั้ย  2) หัวต่อ/สายไขว้  3) รุ่นนี้ตั้ง serial password ไว้มั้ย" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + $clean) -ForegroundColor Green
    if ($clean -match '^QPW:?\s*([01])') {
        if ($Matches[1] -eq '1') { Write-Host "     → จอเปิดอยู่ (Power ON)" -ForegroundColor Cyan } else { Write-Host "     → จอปิดอยู่ (Standby)" -ForegroundColor Cyan }
    } elseif ($clean -match '^ER') {
        Write-Host "     → จอตอบ Error ($clean) = รับ byte ได้แต่คำสั่ง/พารามิเตอร์ไม่ถูกในรุ่นนี้" -ForegroundColor Magenta
    }
    return $clean
}

function Invoke-Named([string]$name) {
    switch -Regex ($name.ToLower()) {
        '^(power\?|status|state)$' { return Send-Pana 'QPW' }
        '^(on|power-?on)$'         { return Send-Pana 'PON' }
        '^(off|power-?off)$'       { return Send-Pana 'POF' }
        '^vol\?$'                  { return Send-Pana 'QAV' }
        '^(vol|volume)$' {
            if ($Value -lt 0 -or $Value -gt 100) { Write-Host "ใส่ระดับเสียงด้วย -Value 0..100" -ForegroundColor Yellow; return $null }
            return Send-Pana ("AVL:" + $Value.ToString('000'))
        }
        '^vol\+$'   { return Send-Pana 'AUU' }
        '^vol-$'    { return Send-Pana 'AUD' }
        '^mute$'    { return Send-Pana 'AMT:1' }
        '^unmute$'  { return Send-Pana 'AMT:0' }
        '^hdmi1$'   { return Send-Pana 'IMS:HM1' }
        '^hdmi2$'   { return Send-Pana 'IMS:HM2' }
        '^hdmi3$'   { return Send-Pana 'IMS:HM3' }
        default {
            Write-Host "ไม่รู้จัก '$name' — ใช้ได้: power? on off vol(-Value n) vol? vol+ vol- mute unmute hdmi1 hdmi2 hdmi3" -ForegroundColor Yellow
            return $null
        }
    }
}

# ---------- รัน ----------
try {
    if ($Raw) {
        Send-Pana $Raw | Out-Null
    } elseif ($Command) {
        Invoke-Named $Command | Out-Null
    } else {
        Write-Host "=== Smoke Test (ถามสถานะ power อย่างเดียว ไม่เปลี่ยนค่าจอ) ===`n" -ForegroundColor Cyan
        $r = Send-Pana 'QPW'
        Write-Host ''
        if ($r) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ Panasonic คุยกันได้ — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบ — ไล่เช็คตามคำแนะนำด้านบน แล้วรันซ้ำ" -ForegroundColor Yellow
        }
    }
} finally {
    $sp.Close()
}
