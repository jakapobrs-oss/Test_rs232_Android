<#
=====================================================================
 Test-SharpTv.ps1 — เทสยิงคำสั่ง Sharp AQUOS RS232 จาก notebook (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ Sharp + โปรโตคอล" ทำงานจริง
 ใช้แค่ PowerShell ที่มีในเครื่อง ยังไม่เกี่ยวกับแอพ Android

 วิธีใช้:
   .\Test-SharpTv.ps1                    # หา COM port อัตโนมัติ + ถามสถานะ power (POWR????)
   .\Test-SharpTv.ps1 -Port COM3
   .\Test-SharpTv.ps1 -Command power?    # ถามสถานะ
   .\Test-SharpTv.ps1 -Command rspw      # เปิดให้สั่ง power ตอน standby (ทำครั้งเดียว)
   .\Test-SharpTv.ps1 -Command on / off  # !! เปิด(POWR1)/ปิด(POWR0)
   .\Test-SharpTv.ps1 -Command vol -Value 30
   .\Test-SharpTv.ps1 -Command vol?
   .\Test-SharpTv.ps1 -Command mute / unmute
   .\Test-SharpTv.ps1 -Command hdmi1 / hdmi2 / hdmi3
   .\Test-SharpTv.ps1 -Raw "POWR0001"

 โปรโตคอล Sharp AQUOS:
   ทุกคำสั่ง = 8 ตัวอักษร ASCII (4 ตัวคำสั่ง + 4 ตัวพารามิเตอร์) ปิดท้าย <CR=0x0D>
   ถ้าพารามิเตอร์สั้นกว่า ให้เติมช่องว่างให้ครบ 8 — สคริปต์เติมให้อัตโนมัติ
   ตัวอย่าง: POWR0001 เปิด · POWR0000 ปิด · POWR???? ถาม
            VOLM0030 เสียง30 · MUTE0001 mute · IAVD0001 เลือก input
            RSPW0001 = อนุญาตให้ POWR1 ปลุกจอจาก standby (ต้องตั้งครั้งแรก)
   จอตอบ: "OK"+CR สำเร็จ · "ERR"+CR ไม่รับ · ค่าตัวเลข+CR สำหรับ query
   พอร์ต: 9600 bps (default), 8N1, no flow control
   หมายเหตุ: เลข IAVD ↔ ช่อง HDMI จริง ต่างกันตามรุ่น (ลองไล่ 1..n)
   อ้างอิง: Sharp AQUOS RS-232C control
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
    [int]$Value = -1,        # ใช้กับ -Command vol (0-100; ช่วงจริงตามรุ่น)
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
$sp.NewLine = "`r"
try {
    $sp.Open()
} catch [System.UnauthorizedAccessException] {
    Write-Host "❌ $Port ถูกโปรแกรมอื่นเปิดค้างอยู่ (ปิด PuTTY/Arduino IDE/โปรแกรม serial อื่นก่อน)" -ForegroundColor Red
    exit 1
}
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (Sharp AQUOS)`n" -ForegroundColor Green

# ---------- ส่งคำสั่ง 8 ตัว + CR แล้วอ่านจนเจอ CR/หมดเวลา ----------
function Send-Sharp([string]$cmd) {
    if ($cmd.Length -lt 8) { $cmd = $cmd.PadRight(8, ' ') }   # Sharp ต้องครบ 8 ตัว เติมช่องว่างถ้าสั้น
    elseif ($cmd.Length -gt 8) { $cmd = $cmd.Substring(0, 8) }
    $sp.DiscardInBuffer()
    Write-Host ("TX > '" + $cmd + "'<CR>") -ForegroundColor Yellow
    $sp.Write($cmd + "`r")

    $sb = ''
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = $sp.ReadChar()
            if ($c -eq 0x0D) { break }            # CR = จบคำตอบ
            if ($c -ne 0x0A) { $sb += [char]$c }  # ข้าม LF
        } catch [System.TimeoutException] { }
    }

    $clean = $sb.Trim()
    if (-not $clean) {
        Write-Host "RX < (ไม่มีคำตอบใน $TimeoutMs ms)" -ForegroundColor Red
        Write-Host "     เช็ค: 1) จอเสียบปลั๊ก/standby อยู่มั้ย  2) หัวต่อ/สายไขว้  3) ถ้าจะ on จาก standby ต้องสั่ง rspw ก่อน" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + $clean) -ForegroundColor Green
    if ($clean -match 'ERR') {
        Write-Host "     → จอตอบ ERR = รับ byte ได้แต่ไม่รับคำสั่งนี้ (เช็ครูปแบบ/รุ่นรองรับมั้ย)" -ForegroundColor Magenta
    } elseif ($clean -eq 'OK') {
        Write-Host "     → OK (จอรับคำสั่งสำเร็จ)" -ForegroundColor Cyan
    } else {
        Write-Host "     → ค่าที่อ่านได้ = $clean" -ForegroundColor Cyan
    }
    return $clean
}

function Invoke-Named([string]$name) {
    switch -Regex ($name.ToLower()) {
        '^(power\?|status|state)$' { return Send-Sharp 'POWR????' }
        '^rspw$'                   { return Send-Sharp 'RSPW0001' }   # อนุญาต power-on จาก standby
        '^(on|power-?on)$'         { return Send-Sharp 'POWR0001' }
        '^(off|power-?off)$'       { return Send-Sharp 'POWR0000' }
        '^vol\?$'                  { return Send-Sharp 'VOLM????' }
        '^(vol|volume)$' {
            if ($Value -lt 0 -or $Value -gt 100) { Write-Host "ใส่ระดับเสียงด้วย -Value 0..100" -ForegroundColor Yellow; return $null }
            return Send-Sharp ("VOLM" + $Value.ToString('0000'))
        }
        '^mute$'    { return Send-Sharp 'MUTE0001' }   # 1=on
        '^unmute$'  { return Send-Sharp 'MUTE0002' }   # 2=off
        '^hdmi1$'   { return Send-Sharp 'IAVD0001' }
        '^hdmi2$'   { return Send-Sharp 'IAVD0002' }
        '^hdmi3$'   { return Send-Sharp 'IAVD0003' }
        default {
            Write-Host "ไม่รู้จัก '$name' — ใช้ได้: power? rspw on off vol(-Value n) vol? mute unmute hdmi1 hdmi2 hdmi3" -ForegroundColor Yellow
            return $null
        }
    }
}

# ---------- รัน ----------
try {
    if ($Raw) {
        Send-Sharp $Raw | Out-Null
    } elseif ($Command) {
        Invoke-Named $Command | Out-Null
    } else {
        Write-Host "=== Smoke Test (ถามสถานะ power อย่างเดียว ไม่เปลี่ยนค่าจอ) ===`n" -ForegroundColor Cyan
        $r = Send-Sharp 'POWR????'
        Write-Host ''
        if ($r) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ Sharp คุยกันได้ — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบ — ไล่เช็คตามคำแนะนำด้านบน แล้วรันซ้ำ" -ForegroundColor Yellow
        }
    }
} finally {
    $sp.Close()
}
