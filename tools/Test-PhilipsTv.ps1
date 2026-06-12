<#
=====================================================================
 Test-PhilipsTv.ps1 — เทสยิงคำสั่ง Philips SICP RS232 จาก notebook (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ Philips + โปรโตคอล SICP" ทำงานจริง
 (SICP = Serial/ethernet Interface Communication Protocol — จอ Philips signage/healthcare)

 วิธีใช้:
   .\Test-PhilipsTv.ps1                    # หา COM port อัตโนมัติ + ถามสถานะ power (ไม่เปลี่ยนค่าจอ)
   .\Test-PhilipsTv.ps1 -Port COM3
   .\Test-PhilipsTv.ps1 -Command power?    # ถามสถานะเปิด/ปิด (GET 0x19)
   .\Test-PhilipsTv.ps1 -Command on / off  # !! เปิด/ปิดจอ (SET 0x18)
   .\Test-PhilipsTv.ps1 -Command vol -Value 30
   .\Test-PhilipsTv.ps1 -Id 1              # SICP monitor ID (ปกติ 1)
   .\Test-PhilipsTv.ps1 -Raw "05 01 00 19 1D"

 ⚠️ คำสั่ง input source (0xAC) และ mute ของ SICP "ต่างกันมากตาม version (v1.86/1.99/2.03)
    และตามรุ่น" — สคริปต์นี้จึงใส่เฉพาะที่ verify แล้ว (power/volume) ส่วน input/mute
    ให้เปิด doc SICP ของรุ่นนั้นแล้วยิงด้วย -Raw

 โปรโตคอล SICP:
   เฟรม     = [len] [monitorID] [0x00] [cmd] [data...] [checksum]
   len      = จำนวน byte ทั้งเฟรม (รวม len เองและ checksum)
   checksum = XOR ของทุก byte ก่อนหน้า checksum
   cmd: 0x18 set power (01=off/02=on) · 0x19 get power · 0x44 set volume
   จอตอบ ACK=0x06 / NACK=0x15 / NAV(ไม่รองรับ)=0x18  และมีเฟรมรายงานสถานะตามมา
   พอร์ต: 9600 bps (default; ตั้งได้ 1200-38400), 8N1, no flow control
   อ้างอิง: Philips SICP spec v1.99/v2.03
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
    [int]$Value = -1,        # ใช้กับ -Command vol (0-100)
    [string]$Raw,
    [int]$Id = 1,            # SICP monitor ID (ปกติ 1)
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
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (Philips SICP, ID=$Id)`n" -ForegroundColor Green

function ConvertTo-Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }

# ---------- สร้างเฟรม SICP + checksum (XOR) ----------
function Build-Sicp([byte]$cmd, [byte[]]$data) {
    if ($null -eq $data) { $data = @() }
    $len = [byte](5 + $data.Count)                       # len + id + 0x00 + cmd + data + checksum
    $body = @($len, [byte]$Id, [byte]0x00, $cmd) + $data
    $cs = 0; foreach ($b in $body) { $cs = $cs -bxor $b }
    return ,([byte[]]($body + @([byte]$cs)))
}

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
        Write-Host "     เช็ค: 1) จอเสียบปลั๊ก/standby อยู่มั้ย  2) หัวต่อ/สายไขว้  3) monitor ID ตรงมั้ย (-Id)" -ForegroundColor DarkGray
        Write-Host "          4) บางรุ่น baud ไม่ใช่ 9600 (ลอง -Baud 38400)" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + (ConvertTo-Hex $resp)) -ForegroundColor Green
    if ($resp -contains 0x06) { Write-Host "     → ACK (จอรับคำสั่งสำเร็จ)" -ForegroundColor Cyan }
    elseif ($resp -contains 0x15) { Write-Host "     → NACK (เฟรมผิด/checksum ไม่ตรง)" -ForegroundColor Magenta }
    # คำตอบ get power: byte data 0x02=เปิด / 0x01=ปิด
    if ($resp.Count -ge 5 -and $resp[3] -eq 0x19) {
        $st = $resp[4]
        if ($st -eq 2) { Write-Host "     → จอเปิดอยู่ (Power ON)" -ForegroundColor Cyan }
        elseif ($st -eq 1) { Write-Host "     → จอปิดอยู่ (Standby)" -ForegroundColor Cyan }
    }
    return $resp
}

function Invoke-Named([string]$name) {
    switch -Regex ($name.ToLower()) {
        '^(power\?|status|state)$' { return Send-Frame (Build-Sicp 0x19 @()) }            # GET power (read-only)
        '^(on|power-?on)$'         { return Send-Frame (Build-Sicp 0x18 @(0x02)) }         # SET power on
        '^(off|power-?off)$'       { return Send-Frame (Build-Sicp 0x18 @(0x01)) }         # SET power off
        '^(vol|volume)$' {
            if ($Value -lt 0 -or $Value -gt 100) { Write-Host "ใส่ระดับเสียงด้วย -Value 0..100" -ForegroundColor Yellow; return $null }
            return Send-Frame (Build-Sicp 0x44 @([byte]$Value, [byte]$Value))             # [audio out, speaker]
        }
        default {
            Write-Host "ไม่รู้จัก '$name' — สคริปต์นี้รองรับ: power? on off vol(-Value n)" -ForegroundColor Yellow
            Write-Host "(input/mute ของ SICP ต่างตามรุ่น — เปิด doc แล้วใช้ -Raw)" -ForegroundColor DarkGray
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
        Write-Host "=== Smoke Test (GET power อย่างเดียว ไม่เปลี่ยนค่าจอ) ===`n" -ForegroundColor Cyan
        $r = Send-Frame (Build-Sicp 0x19 @())
        Write-Host ''
        if ($r) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ Philips คุยกันได้ — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบ — ไล่เช็คตามคำแนะนำด้านบน (ลอง -Id อื่น หรือ -Baud 38400)" -ForegroundColor Yellow
        }
    }
} finally {
    $sp.Close()
}
