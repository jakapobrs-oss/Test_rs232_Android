<#
=====================================================================
 Test-LgTv.ps1 — เทสยิงคำสั่ง LG RS232 จาก notebook โดยตรง (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + ทีวี LG + โปรโตคอล" ทำงานจริง
 โดยยังไม่เกี่ยวกับแอพ Android เลย — ใช้แค่ PowerShell ที่มีในเครื่อง

 วิธีใช้:
   .\Test-LgTv.ps1                          # หา COM port อัตโนมัติ + เทสถามสถานะ (ไม่เปลี่ยนอะไรบนทีวี)
   .\Test-LgTv.ps1 -Port COM3               # ระบุพอร์ตเอง
   .\Test-LgTv.ps1 -Command "ka 01 FF"      # ส่งคำสั่งเดียว (ถาม power)
   .\Test-LgTv.ps1 -Command "kf 01 1E"      # ตั้งเสียง 30
   .\Test-LgTv.ps1 -Command "ka 01 00"      # !! สั่งปิดจอ (standby)

 รูปแบบคำสั่ง LG: [cmd1][cmd2] [SetID hex] [Data hex] + CR
 ทีวีตอบ:        [cmd2] [SetID] OK[data]x   หรือ  NG[data]x
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
    [int]$TimeoutMs = 2000
)

$ErrorActionPreference = 'Stop'

# ---------- หา COM port ----------
function Find-SerialPort {
    $names = [System.IO.Ports.SerialPort]::GetPortNames()
    if (-not $names) {
        Write-Host "❌ ไม่พบ COM port ในเครื่องเลย — เสียบสาย RS232-to-USB แล้วรอ driver ติดตั้ง (ดูใน Device Manager)" -ForegroundColor Red
        exit 1
    }

    # ดึงชื่อ friendly name เพื่อดูว่าพอร์ตไหนเป็น USB adapter (FTDI/CH340/Prolific/CP210x)
    $pnp = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match '\(COM\d+\)' }
    Write-Host "พอร์ตที่พบในเครื่อง:" -ForegroundColor Cyan
    foreach ($p in $pnp) { Write-Host ("  - " + $p.Name) }

    $usb = $pnp | Where-Object { $_.Name -match 'USB|CH340|CH341|FTDI|Prolific|CP210|Serial.*Adapter' -and $_.Name -notmatch 'Communications Port' }
    if ($usb.Count -eq 1 -and $usb[0].Name -match '\((COM\d+)\)') {
        return $Matches[1]   # เจอ USB adapter ตัวเดียว → ใช้ตัวนั้นเลย
    }
    if ($usb.Count -gt 1) {
        Write-Host "⚠️ พบ USB serial หลายตัว — ระบุเองด้วย -Port COMx" -ForegroundColor Yellow
        exit 1
    }
    # ไม่เจอ USB adapter เลย — ถ้ามีแต่ COM1 onboard ให้เตือน เพราะปกติหน้างานใช้สาย USB
    Write-Host "⚠️ ไม่พบ USB serial adapter (เจอแต่พอร์ต onboard) — ถ้าตั้งใจใช้พอร์ตนั้นให้ระบุ -Port COM1" -ForegroundColor Yellow
    exit 1
}

if (-not $Port) { $Port = Find-SerialPort }

# ---------- เปิดพอร์ต (LG ใช้ 9600 8N1 ไม่มี flow control) ----------
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.Handshake = 'None'
$sp.ReadTimeout = 200
$sp.NewLine = "`r"
try {
    $sp.Open()
} catch [System.UnauthorizedAccessException] {
    Write-Host "❌ $Port ถูกโปรแกรมอื่นเปิดค้างอยู่ (ปิดโปรแกรม serial อื่นก่อน เช่น PuTTY/Arduino IDE)" -ForegroundColor Red
    exit 1
}
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ`n" -ForegroundColor Green

# ---------- ส่งคำสั่งแล้วรออ่านคำตอบจนเจอตัวปิดท้าย 'x' หรือหมดเวลา ----------
function Send-LgCommand([string]$cmd) {
    $sp.DiscardInBuffer()
    Write-Host ("TX > " + $cmd) -ForegroundColor Yellow
    $sp.Write($cmd + "`r")

    $buf = ''
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try { $buf += [char]$sp.ReadChar() } catch [System.TimeoutException] { }
        if ($buf -match 'x') { break }   # โปรโตคอล LG จบ response ด้วย 'x' เสมอ
    }

    if (-not $buf) {
        Write-Host "RX < (ไม่มีคำตอบใน $TimeoutMs ms)" -ForegroundColor Red
        Write-Host "     เช็ค: 1) ทีวีเสียบปลั๊กอยู่มั้ย (standby ก็ตอบได้)  2) หัว DB9/แจ็ค 3.5mm แน่นมั้ย" -ForegroundColor DarkGray
        Write-Host "          3) บางรุ่นต้องใช้สายไขว้ (null modem)  4) Set ID ตรงกับที่ตั้งในทีวีมั้ย (ลอง 00 = ทุกเครื่อง)" -ForegroundColor DarkGray
        return $null
    }

    $clean = $buf.Trim()
    Write-Host ("RX < " + $clean) -ForegroundColor Green

    # แปลความหมายคำตอบที่รู้จัก เพื่อให้อ่านผลง่าย
    if ($clean -match '^([a-z])\s+([0-9a-fA-F]{2})\s+OK([0-9a-fA-F]{2,4})x$') {
        $c2 = $Matches[1]; $data = $Matches[3]
        $dec = [Convert]::ToInt32($data, 16)
        switch ($c2) {
            'a' { if ($data -eq '01') { Write-Host "     → ทีวีเปิดอยู่ (Power ON)" -ForegroundColor Cyan } else { Write-Host "     → ทีวีปิดอยู่ (Standby)" -ForegroundColor Cyan } }
            'f' { Write-Host "     → ระดับเสียง = $dec" -ForegroundColor Cyan }
            'e' { if ($data -eq '00') { Write-Host "     → เสียงถูก Mute อยู่" -ForegroundColor Cyan } else { Write-Host "     → เสียงปกติ (ไม่ Mute)" -ForegroundColor Cyan } }
            'b' { Write-Host "     → Input ปัจจุบัน = 0x$data" -ForegroundColor Cyan }
        }
    } elseif ($clean -match 'NG') {
        Write-Host "     → ทีวีตอบ NG = รับคำสั่งได้แต่ไม่ยอมรับค่า (เช็ครูปแบบ data/คำสั่งรองรับในรุ่นนี้มั้ย)" -ForegroundColor Magenta
    }
    return $clean
}

# ---------- รัน ----------
try {
    if ($Command) {
        # โหมดส่งคำสั่งเดียวตามที่ระบุ
        Send-LgCommand $Command | Out-Null
    } else {
        # โหมด smoke test: ถามสถานะอย่างเดียว ไม่เปลี่ยนค่าอะไรบนทีวี (ปลอดภัยกับหน้างาน)
        Write-Host "=== Smoke Test (query อย่างเดียว ไม่เปลี่ยนค่าทีวี) ===`n" -ForegroundColor Cyan
        $r1 = Send-LgCommand 'ka 01 FF'   # ถามสถานะเปิด/ปิด
        Write-Host ''
        $r2 = Send-LgCommand 'kf 01 FF'   # ถามระดับเสียง
        Write-Host ''
        if ($r1 -or $r2) {
            Write-Host "🎉 สาย + โปรโตคอล + ทีวี ใช้งานได้จริง — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบจากทีวี — ไล่เช็คตามคำแนะนำด้านบน แล้วรันซ้ำ" -ForegroundColor Yellow
            Write-Host "(ถ้า Set ID ไม่ใช่ 1 ลอง: .\Test-LgTv.ps1 -Command 'ka 00 FF' — 00 = broadcast ทุก Set ID)" -ForegroundColor DarkGray
        }
    }
} finally {
    $sp.Close()   # ปิดพอร์ตเสมอ ไม่งั้นครั้งถัดไปจะเปิดไม่ได้
}
