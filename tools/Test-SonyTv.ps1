<#
=====================================================================
 Test-SonyTv.ps1 — เทสยิงคำสั่ง Sony BRAVIA RS232C จาก notebook (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ Sony + โปรโตคอล" ทำงานจริง
 ใช้แค่ PowerShell ที่มีในเครื่อง ยังไม่เกี่ยวกับแอพ Android

 วิธีใช้:
   .\Test-SonyTv.ps1                      # หา COM port อัตโนมัติ + ถามสถานะ power (ไม่เปลี่ยนค่าจอ)
   .\Test-SonyTv.ps1 -Port COM3           # ระบุพอร์ตเอง
   .\Test-SonyTv.ps1 -Command power?      # ถามสถานะเปิด/ปิด (enquiry)
   .\Test-SonyTv.ps1 -Command on / off    # !! เปิด/ปิดจอ
   .\Test-SonyTv.ps1 -Command vol+ / vol- # เพิ่ม/ลดเสียง
   .\Test-SonyTv.ps1 -Command mute        # สลับ mute (toggle)
   .\Test-SonyTv.ps1 -Command hdmi1 / hdmi2 / hdmi3
   .\Test-SonyTv.ps1 -Raw "8C 00 00 02 01 8F"   # ส่ง byte ดิบเอง

 ⚠️ Sony มี 2 โปรโตคอลแล้วแต่รุ่น:
   (1) Classic binary — header 0x8C  ← สคริปต์นี้ใช้ตัวนี้ (รุ่น BRAVIA ทั่วไป/มืออาชีพหลายรุ่น)
   (2) Pro BRAVIA BZ/BU series ใหม่ — ASCII ขึ้นต้น "*S..." (คนละแบบ)
   ถ้าตัวนี้ไม่ตอบเลย ให้เช็คว่ารุ่นนั้นใช้โปรโตคอล (2) หรือไม่
   อ้างอิง: pro-bravia.sony.net/develop/integrate/rs-232c/

 โปรโตคอล classic (0x8C):
   เฟรมสั่ง   = [0x8C] [category] [function] [len] [data...] [checksum]
   เฟรมถาม    = [0x83] [category] [function] [0xFF] [0xFF] [checksum]
   len        = จำนวน byte ของ (data + checksum)
   checksum   = ผลรวมทุก byte รวม header แล้ว & 0xFF
   พอร์ต: 9600 bps, 8N1 (บางรุ่นตั้งได้ถึง 38400) ไม่มี flow control
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
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
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (Sony classic 0x8C)`n" -ForegroundColor Green

function ConvertTo-Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }

# ---------- สร้างเฟรมสั่ง (0x8C) + checksum ----------
function Build-Sony([byte]$cat, [byte]$fn, [byte[]]$data) {
    if ($null -eq $data) { $data = @() }
    $len = [byte]($data.Count + 1)                       # data + checksum
    $head = @([byte]0x8C, $cat, $fn, $len) + $data
    $sum = 0; foreach ($b in $head) { $sum += $b }       # checksum รวม header 0x8C ด้วย
    return ,([byte[]]($head + @([byte]($sum -band 0xFF))))
}

# ---------- อ่านคำตอบ: เก็บ byte จนเงียบหรือหมดเวลา ----------
function Read-Bytes {
    $list = New-Object System.Collections.Generic.List[byte]
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $last = Get-Date
    while ((Get-Date) -lt $deadline) {
        try {
            $b = $sp.ReadByte()
            if ($b -ge 0) { $list.Add([byte]$b); $last = Get-Date }
        } catch [System.TimeoutException] {
            if ($list.Count -gt 0 -and ((Get-Date) - $last).TotalMilliseconds -gt 150) { break }
        }
    }
    return ,$list.ToArray()
}

function Send-Frame([byte[]]$frame) {
    $sp.DiscardInBuffer()
    Write-Host ("TX > " + (ConvertTo-Hex $frame)) -ForegroundColor Yellow
    $sp.Write($frame, 0, $frame.Length)
    $resp = Read-Bytes
    if ($resp.Count -eq 0) {
        Write-Host "RX < (ไม่มีคำตอบใน $TimeoutMs ms)" -ForegroundColor Red
        Write-Host "     เช็ค: 1) จอเสียบปลั๊ก/standby อยู่มั้ย  2) หัวต่อแน่นมั้ย (Sony มักใช้แจ็ค 3.5mm หรือ DB9)" -ForegroundColor DarkGray
        Write-Host "          3) ลองสายไขว้ (null modem)  4) รุ่นนี้อาจใช้โปรโตคอล Pro BRAVIA แบบ ASCII '*S...' แทน" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + (ConvertTo-Hex $resp)) -ForegroundColor Green
    Write-Host "     → มีคำตอบกลับมา = สาย+โปรโตคอลคุยกันได้ (0x70 ขึ้นต้น = answer)" -ForegroundColor Cyan
    return $resp
}

# ---------- เฟรมที่ verify byte แล้ว (จาก spec/Just Add Power) ----------
function Invoke-Named([string]$name) {
    switch -Regex ($name.ToLower()) {
        '^(power\?|status|state)$' { return Send-Frame ([byte[]](0x83,0x00,0x00,0xFF,0xFF,0x81)) }  # enquiry power (read-only)
        '^(on|power-?on)$'         { return Send-Frame ([byte[]](0x8C,0x00,0x00,0x02,0x01,0x8F)) }
        '^(off|power-?off)$'       { return Send-Frame ([byte[]](0x8C,0x00,0x00,0x02,0x00,0x8E)) }
        '^vol\+$'                  { return Send-Frame ([byte[]](0x8C,0x00,0x05,0x03,0x00,0x00,0x94)) }
        '^vol-$'                   { return Send-Frame ([byte[]](0x8C,0x00,0x05,0x03,0x00,0x01,0x95)) }
        '^mute$'                   { return Send-Frame ([byte[]](0x8C,0x00,0x06,0x02,0x00,0x94)) }    # toggle
        '^hdmi1$'                  { return Send-Frame ([byte[]](0x8C,0x00,0x02,0x03,0x04,0x01,0x96)) }
        '^hdmi2$'                  { return Send-Frame ([byte[]](0x8C,0x00,0x02,0x03,0x04,0x02,0x97)) }
        '^hdmi3$'                  { return Send-Frame ([byte[]](0x8C,0x00,0x02,0x03,0x04,0x03,0x98)) }
        default {
            Write-Host "ไม่รู้จักคำสั่ง '$name' — ใช้ได้: power? on off vol+ vol- mute hdmi1 hdmi2 hdmi3" -ForegroundColor Yellow
            return $null
        }
    }
}

# ---------- รัน ----------
try {
    if ($Raw) {
        $bytes = ($Raw -split '[\s,]+' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
        Send-Frame ([byte[]]$bytes) | Out-Null
    } elseif ($Command) {
        Invoke-Named $Command | Out-Null
    } else {
        Write-Host "=== Smoke Test (ถามสถานะ power อย่างเดียว ไม่เปลี่ยนค่าจอ) ===`n" -ForegroundColor Cyan
        $r = Send-Frame ([byte[]](0x83,0x00,0x00,0xFF,0xFF,0x81))   # enquiry power
        Write-Host ''
        if ($r) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ Sony คุยกันได้ — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบ — ไล่เช็คตามคำแนะนำด้านบน (อย่าลืมเช็คว่ารุ่นใช้ classic 0x8C หรือ Pro BRAVIA ASCII)" -ForegroundColor Yellow
        }
    }
} finally {
    $sp.Close()
}
