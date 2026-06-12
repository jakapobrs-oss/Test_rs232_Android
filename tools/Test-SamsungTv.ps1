<#
=====================================================================
 Test-SamsungTv.ps1 — เทสยิงคำสั่ง Samsung MDC RS232 จาก notebook (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ Samsung + โปรโตคอล MDC" ทำงานจริง
 โดยยังไม่เกี่ยวกับแอพ Android เลย — ใช้แค่ PowerShell ที่มีในเครื่อง

 วิธีใช้:
   .\Test-SamsungTv.ps1                       # หา COM port อัตโนมัติ + เทสถามสถานะ (ไม่เปลี่ยนอะไรบนจอ)
   .\Test-SamsungTv.ps1 -Port COM3            # ระบุพอร์ตเอง
   .\Test-SamsungTv.ps1 -Command power?       # ถามสถานะเปิด/ปิด
   .\Test-SamsungTv.ps1 -Command on           # !! สั่งเปิดจอ
   .\Test-SamsungTv.ps1 -Command off          # !! สั่งปิดจอ (standby)
   .\Test-SamsungTv.ps1 -Command vol -Value 30  # ตั้งเสียง 30
   .\Test-SamsungTv.ps1 -Command mute / unmute
   .\Test-SamsungTv.ps1 -Command hdmi1 / hdmi2 / hdmi3
   .\Test-SamsungTv.ps1 -Id 1                  # จอตั้ง MDC ID = 1 (ดูในเมนู)
   .\Test-SamsungTv.ps1 -Raw "AA 11 00 00 11" # ส่ง byte ดิบเอง (ขั้นสูง)

 โปรโตคอล Samsung MDC (Multiple Display Control):
   เฟรม = [0xAA] [cmd] [ID] [len] [data...] [checksum]
   checksum = (cmd + ID + len + ผลรวม data) & 0xFF   (ไม่รวม header 0xAA)
   จอตอบ  = [0xAA] [0xFF] [ID] [len] [0x41=ACK / 0x4E=NAK] [cmd] [val...] [cs]
   cmd ที่ใช้: 0x11 power · 0x12 volume(0-100) · 0x13 mute · 0x14 input source
   พอร์ต: 9600 bps, 8 data bits, no parity, 1 stop bit, no flow control
   อ้างอิง: Samsung MDC Protocol (v13.x)
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
    [int]$Value = -1,        # ใช้กับ -Command vol (ระดับเสียง 0-100)
    [string]$Raw,            # ส่ง byte ดิบเอง เช่น "AA 11 00 00 11"
    [int]$Id = 0,            # MDC ID ของจอ (ตั้งในเมนูจอ ปกติ 0)
    [int]$TimeoutMs = 2000
)

$ErrorActionPreference = 'Stop'

# ---------- หา COM port อัตโนมัติ (ใช้ logic เดียวกับ Test-LgTv.ps1) ----------
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

# ---------- เปิดพอร์ต (Samsung MDC ใช้ 9600 8N1 ไม่มี flow control) ----------
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.Handshake = 'None'
$sp.ReadTimeout = 200
try {
    $sp.Open()
} catch [System.UnauthorizedAccessException] {
    Write-Host "❌ $Port ถูกโปรแกรมอื่นเปิดค้างอยู่ (ปิด PuTTY/Arduino IDE/โปรแกรม serial อื่นก่อน)" -ForegroundColor Red
    exit 1
}
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (Samsung MDC, ID=$Id)`n" -ForegroundColor Green

# ---------- สร้างเฟรม MDC + คำนวณ checksum ----------
function Build-Mdc([byte]$cmd, [byte[]]$data) {
    if ($null -eq $data) { $data = @() }
    $len = [byte]$data.Count
    $body = @($cmd, [byte]$Id, $len) + $data           # ส่วนที่เอาไปคิด checksum (ไม่รวม 0xAA)
    $sum = 0; foreach ($b in $body) { $sum += $b }
    $cs = [byte]($sum -band 0xFF)
    return ,([byte[]](@(0xAA) + $body + @($cs)))
}

function ConvertTo-Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }

# ---------- อ่านคำตอบ: เก็บ byte จนเงียบ (gap > 150ms) หรือหมดเวลา ----------
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

# ---------- ส่งเฟรมแล้วแปลผลคำตอบ ----------
function Send-Frame([byte[]]$frame) {
    $sp.DiscardInBuffer()
    Write-Host ("TX > " + (ConvertTo-Hex $frame)) -ForegroundColor Yellow
    $sp.Write($frame, 0, $frame.Length)

    $resp = Read-Bytes
    if ($resp.Count -eq 0) {
        Write-Host "RX < (ไม่มีคำตอบใน $TimeoutMs ms)" -ForegroundColor Red
        Write-Host "     เช็ค: 1) จอเสียบปลั๊กอยู่มั้ย (standby ก็ตอบได้)  2) หัวต่อแน่นมั้ย" -ForegroundColor DarkGray
        Write-Host "          3) บางรุ่นต้องใช้สายไขว้ (null modem)  4) MDC ID ตรงกับที่ตั้งในจอมั้ย (ลอง -Id ให้ตรง)" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + (ConvertTo-Hex $resp)) -ForegroundColor Green

    # คำตอบมาตรฐาน: AA FF [id] [len] [Ack/Nak] [cmd] [val...] [cs]
    $ackIdx = [Array]::IndexOf($resp, [byte]0x41)   # 'A' = ACK
    $nakIdx = [Array]::IndexOf($resp, [byte]0x4E)   # 'N' = NAK
    if ($ackIdx -ge 0 -and $ackIdx + 2 -lt $resp.Count) {
        $rcmd = $resp[$ackIdx + 1]; $val = $resp[$ackIdx + 2]
        switch ($rcmd) {
            0x11 { if ($val -eq 1) { Write-Host "     → จอเปิดอยู่ (Power ON)" -ForegroundColor Cyan } else { Write-Host "     → จอปิดอยู่ (Standby)" -ForegroundColor Cyan } }
            0x12 { Write-Host "     → ระดับเสียง = $val" -ForegroundColor Cyan }
            0x13 { if ($val -eq 1) { Write-Host "     → ถูก Mute อยู่" -ForegroundColor Cyan } else { Write-Host "     → เสียงปกติ (ไม่ Mute)" -ForegroundColor Cyan } }
            0x14 { Write-Host ("     → Input ปัจจุบัน = 0x" + $val.ToString('X2')) -ForegroundColor Cyan }
            default { Write-Host "     → ACK (จอรับคำสั่งสำเร็จ)" -ForegroundColor Cyan }
        }
    } elseif ($nakIdx -ge 0) {
        Write-Host "     → จอตอบ NAK = รับคำสั่งได้แต่ไม่ยอมรับค่า (เช็ค data/คำสั่งรองรับในรุ่นนี้มั้ย)" -ForegroundColor Magenta
    }
    return $resp
}

# ---------- แปลง -Command friendly → เฟรม MDC ----------
function Invoke-Named([string]$name) {
    switch -Regex ($name.ToLower()) {
        '^(power\?|status|state)$' { return Send-Frame (Build-Mdc 0x11 @()) }        # ถาม power (len=0 = query)
        '^(on|power-?on)$'         { return Send-Frame (Build-Mdc 0x11 @(0x01)) }
        '^(off|power-?off)$'       { return Send-Frame (Build-Mdc 0x11 @(0x00)) }
        '^vol\?$'                  { return Send-Frame (Build-Mdc 0x12 @()) }
        '^(vol|volume)$' {
            if ($Value -lt 0 -or $Value -gt 100) { Write-Host "ใส่ระดับเสียงด้วย -Value 0..100 เช่น -Command vol -Value 30" -ForegroundColor Yellow; return $null }
            return Send-Frame (Build-Mdc 0x12 @([byte]$Value))
        }
        '^mute$'   { return Send-Frame (Build-Mdc 0x13 @(0x01)) }
        '^unmute$' { return Send-Frame (Build-Mdc 0x13 @(0x00)) }
        '^hdmi1$'  { return Send-Frame (Build-Mdc 0x14 @(0x21)) }    # 0x21 = HDMI1
        '^hdmi2$'  { return Send-Frame (Build-Mdc 0x14 @(0x23)) }    # 0x23 = HDMI2
        '^hdmi3$'  { return Send-Frame (Build-Mdc 0x14 @(0x31)) }    # 0x31 = HDMI3
        default {
            Write-Host "ไม่รู้จักคำสั่ง '$name' — ใช้ได้: power? on off vol(-Value n) vol? mute unmute hdmi1 hdmi2 hdmi3" -ForegroundColor Yellow
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
        Write-Host "=== Smoke Test (query อย่างเดียว ไม่เปลี่ยนค่าจอ) ===`n" -ForegroundColor Cyan
        $r1 = Send-Frame (Build-Mdc 0x11 @())   # ถาม power
        Write-Host ''
        $r2 = Send-Frame (Build-Mdc 0x12 @())   # ถาม volume
        Write-Host ''
        if ($r1 -or $r2) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ Samsung ใช้งานได้จริง — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบจากจอ — ไล่เช็คตามคำแนะนำด้านบน แล้วรันซ้ำ" -ForegroundColor Yellow
            Write-Host "(ถ้าไม่รู้ MDC ID ของจอ ลองไล่ -Id 0, 1 หรือดูในเมนู Multi Control ของจอ)" -ForegroundColor DarkGray
        }
    }
} finally {
    $sp.Close()
}
