<#
=====================================================================
 Test-NecTv.ps1 — เทสยิงคำสั่ง NEC large-format display RS232 (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ NEC (MultiSync/large-format) + โปรโตคอล" ทำงานจริง
 ใช้แค่ PowerShell ที่มีในเครื่อง ยังไม่เกี่ยวกับแอพ Android

 วิธีใช้:
   .\Test-NecTv.ps1                    # หา COM port อัตโนมัติ + ถามสถานะ power (read-only)
   .\Test-NecTv.ps1 -Port COM3
   .\Test-NecTv.ps1 -Command power?    # ถามสถานะเปิด/ปิด
   .\Test-NecTv.ps1 -Command on / off  # !! เปิด/ปิดจอ
   .\Test-NecTv.ps1 -Command mute / unmute
   .\Test-NecTv.ps1 -Command hdmi1
   .\Test-NecTv.ps1 -Raw "01 30 41 30 41 30 43 02 ... 0D"   # ส่ง byte ดิบเอง

 โปรโตคอล NEC (external control / monitor-control):
   เฟรม = [SOH=01] '0' [dest] [src] [msgType] [len(2)] [STX=02] [message] [ETX=03] [BCC] [CR=0D]
   msgType: 'A'(0x41)=Command · 'E'(0x45)=Set parameter · 'C'=Get parameter
   BCC = XOR ของทุก byte ตั้งแต่หลัง SOH ('0') ไปจนถึง ETX
   จอตอบกลับทุกคำสั่ง (command reply) → มี RX = สาย+โปรโตคอลคุยกันได้
   พอร์ต: 9600 bps (บางรุ่น 38400), 8N1, no flow control — มักต้องใช้สายไขว้ (null modem)
   หมายเหตุ: รหัส input ของ HDMI2/HDMI3 ต่างกันตามรุ่น — ใช้ -Raw + ดู External Control doc ของรุ่น
   อ้างอิง: NEC External Control (sharpnecdisplays) / Just Add Power NEC codes
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
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (NEC external control)`n" -ForegroundColor Green

function ConvertTo-Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }
function ConvertFrom-Hex([string]$s) { return ,([byte[]]($s -split '[\s,]+' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })) }

# ---------- เฟรมที่ verify byte แล้ว (Just Add Power) + power? ที่ derive BCC เอง ----------
# message อยู่ระหว่าง STX..ETX:  power 'C203D6000X' (X=1 on/4 off) · mute/input ใช้ set-parameter 'E'
$Frames = @{
    'power?' = '01 30 41 30 41 30 36 02 30 31 44 36 03 74 0D'   # get power status (read-only) BCC=0x74
    'on'     = '01 30 41 30 41 30 43 02 43 32 30 33 44 36 30 30 30 31 03 73 0D'
    'off'    = '01 30 41 30 41 30 43 02 43 32 30 33 44 36 30 30 30 34 03 76 0D'
    'mute'   = '01 30 41 30 45 30 41 02 30 30 38 44 30 30 30 31 03 09 0D'
    'unmute' = '01 30 41 30 45 30 41 02 30 30 38 44 30 30 30 32 03 0A 0D'
    'hdmi1'  = '01 30 41 30 45 30 41 02 30 30 36 30 30 30 31 31 03 72 0D'
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
        Write-Host "     เช็ค: 1) จอเสียบปลั๊ก/standby อยู่มั้ย  2) NEC มักต้องใช้สายไขว้ (null modem)" -ForegroundColor DarkGray
        Write-Host "          3) บาง baud เป็น 38400 (ลอง -Baud 38400)  4) Monitor ID / dest address ตรงมั้ย" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + (ConvertTo-Hex $resp)) -ForegroundColor Green
    Write-Host "     → มีคำตอบกลับมา = สาย + โปรโตคอลคุยกันได้" -ForegroundColor Cyan
    return $resp
}

# ---------- รัน ----------
try {
    if ($Raw) {
        Send-Frame (ConvertFrom-Hex $Raw) | Out-Null
    } elseif ($Command) {
        $key = $Command.ToLower() -replace '^power-?on$', 'on' -replace '^power-?off$', 'off' -replace '^(status|state)$', 'power?'
        if ($Frames.ContainsKey($key)) {
            Send-Frame (ConvertFrom-Hex $Frames[$key]) | Out-Null
        } else {
            Write-Host "ไม่รู้จัก '$Command' — ใช้ได้: power? on off mute unmute hdmi1  (HDMI2/3 ใช้ -Raw + doc รุ่น)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "=== Smoke Test (ถามสถานะ power อย่างเดียว ไม่เปลี่ยนค่าจอ) ===`n" -ForegroundColor Cyan
        $r = Send-Frame (ConvertFrom-Hex $Frames['power?'])
        Write-Host ''
        if ($r) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ NEC คุยกันได้ — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบ — ไล่เช็คตามคำแนะนำด้านบน (NEC มักต้องสายไขว้ + ลอง -Baud 38400)" -ForegroundColor Yellow
        }
    }
} finally {
    $sp.Close()
}
