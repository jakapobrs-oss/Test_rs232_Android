<#
=====================================================================
 Test-ToshibaTv.ps1 — เทส Toshiba RS232 จาก notebook (เฟส 1) — SCAFFOLD
=====================================================================
 ⚠️ ตัวนี้เป็น "โครง" (placeholder) ยังไม่ wire คำสั่ง friendly เหมือนยี่ห้ออื่น
 เพราะ Toshiba "ไม่มีโปรโตคอล RS232 มาตรฐานกลาง" — ต่างกันตามสาย/รุ่น/ODM จริงๆ:

   • TD-Z / TD-E commercial display (เช่น TD-Z551) — เฟรม [address][function][data][end]
       (มี spec ใน user manual ของรุ่นนั้น หน้า "RS-232C Remote Control")
   • REGZA consumer TV — ส่วนใหญ่ "ไม่มี" พอร์ต RS232 หรือต่างกันตาม ODM
   • HD-DVD / Blu-ray player — start code 0x45 0xB5 (คนละอุปกรณ์ ไม่ใช่ทีวี)

 เพราะยิง byte ผิดเข้าจอจริงมีความเสี่ยง สคริปต์นี้จึง "ไม่เดา byte"
 แต่ใช้งานได้จริง 2 อย่าง:
   1) เปิดพอร์ต + ยืนยันว่า adapter/สาย/COM ใช้ได้ (รันเปล่าๆ = smoke test)
   2) -Raw "<hex>" — แปะ byte จาก manual รุ่นของคุณมายิงได้ทันที (อ่านคำตอบให้ด้วย)

 วิธีใช้:
   .\Test-ToshibaTv.ps1                    # หา COM port + เปิดพอร์ต (ยืนยัน adapter ใช้ได้)
   .\Test-ToshibaTv.ps1 -Port COM3
   .\Test-ToshibaTv.ps1 -Raw "<byte จาก manual รุ่นคุณ>"   # เช่น power on/off ที่คัดจากเอกสาร RS232 ของรุ่นนั้น
   .\Test-ToshibaTv.ps1 -Command on        # จะขึ้นข้อความบอกวิธีหา byte (ยังไม่ wire)

 จะ "อัปเกรดเป็น tester เต็ม" ได้เมื่อมี: รุ่น Toshiba + เอกสาร RS232 ของรุ่นนั้น
   (PDF / หน้า command / ลิงก์) — แล้วเติมตาราง -Command -> byte ตาม pattern ยี่ห้ออื่น

 พอร์ต default: 9600 bps, 8N1, no flow control (TD commercial หลายรุ่นต้องสายไขว้/null modem)
 อ้างอิง: Toshiba TD-Z551 User Manual หน้า "RS-232C Remote Control" (ManualsLib 764508)
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
    [int]$Value = -1,        # สงวนไว้ (ยังไม่ wire vol จนกว่าจะรู้รุ่น)
    [string]$Raw,
    [int]$Id = 0,            # สงวนไว้: address code ของ TD commercial (ต่างตามรุ่น)
    [int]$TimeoutMs = 2000
)

$ErrorActionPreference = 'Stop'

# ---------- หา COM port อัตโนมัติ (logic เดียวกับ tester ตัวอื่น) ----------
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

# ---------- ข้อความช่วยเหลือ: Toshiba ต่างตามรุ่น ----------
function Show-ToshibaHelp {
    Write-Host "ℹ️  Toshiba ยังไม่ wire คำสั่ง friendly เพราะโปรโตคอลต่างกันตามรุ่น/ODM" -ForegroundColor Yellow
    Write-Host "    วิธีเดินต่อ:" -ForegroundColor Yellow
    Write-Host "      1) เปิด user manual ของรุ่นคุณ หา section 'RS-232C Remote Control'" -ForegroundColor Gray
    Write-Host "      2) คัด byte (เช่น power on/off) มายิงด้วย -Raw เช่น:" -ForegroundColor Gray
    Write-Host "           .\Test-ToshibaTv.ps1 -Raw `"<hex จาก doc>`"" -ForegroundColor Gray
    Write-Host "      3) อยากได้ tester เต็ม (-Command on/off/vol...) → ส่งรุ่น + doc มาให้เติม" -ForegroundColor Gray
    Write-Host "    ตระกูลโปรโตคอลที่พบ: TD-Z/TD-E commercial = [address][function][data][end] ·" -ForegroundColor DarkGray
    Write-Host "    REGZA consumer มักไม่มี RS232 · HD-DVD player = start 0x45 0xB5 (คนละอุปกรณ์)" -ForegroundColor DarkGray
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
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (Toshiba — scaffold)`n" -ForegroundColor Green

function ConvertTo-Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }
function ConvertFrom-Hex([string]$s) { return ,([byte[]]($s -split '[\s,]+' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })) }

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

# ส่ง byte ดิบ (จาก -Raw) แล้วอ่านคำตอบ — ใช้ได้กับทุกรุ่นถ้า byte มาจาก doc ที่ถูกต้อง
function Send-Frame([byte[]]$frame) {
    $sp.DiscardInBuffer()
    Write-Host ("TX > " + (ConvertTo-Hex $frame)) -ForegroundColor Yellow
    $sp.Write($frame, 0, $frame.Length)
    $resp = Read-Bytes
    if ($resp.Count -eq 0) {
        Write-Host "RX < (ไม่มีคำตอบใน $TimeoutMs ms)" -ForegroundColor Red
        Write-Host "     เช็ค: 1) จอเสียบปลั๊ก/standby อยู่มั้ย  2) หัวต่อ/สายไขว้ (null modem)" -ForegroundColor DarkGray
        Write-Host "          3) baud/รูปแบบ byte ตรง doc รุ่นมั้ย  4) บางรุ่นต้องเปิด RS232 control ใน menu ก่อน" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + (ConvertTo-Hex $resp)) -ForegroundColor Green
    Write-Host "     → มีคำตอบกลับมา = สาย + พอร์ต + จอ คุยกันได้ (เทียบความหมาย byte กับ doc รุ่นต่อ)" -ForegroundColor Cyan
    return $resp
}

# ---------- รัน ----------
try {
    if ($Raw) {
        Send-Frame (ConvertFrom-Hex $Raw) | Out-Null
    } elseif ($Command) {
        # ยังไม่ wire คำสั่ง friendly — บอกวิธีหา byte แทนการเดา
        Write-Host "TX > (ยังไม่ส่ง — '$Command' ยังไม่ถูก map เป็น byte สำหรับ Toshiba)`n" -ForegroundColor Yellow
        Show-ToshibaHelp
    } else {
        Write-Host "=== Smoke Test (ยืนยัน adapter/สาย/พอร์ต — ยังไม่ยิงคำสั่งเข้าจอ) ===`n" -ForegroundColor Cyan
        Write-Host "✅ พอร์ต $Port เปิด/ปิดได้ = สาย RS232-to-USB + driver + COM ใช้งานได้ (ครึ่งแรกของเฟส 1 ผ่าน)" -ForegroundColor Green
        Write-Host "   เหลือครึ่งหลัง: ยืนยันโปรโตคอลกับจอ Toshiba — ต้องใช้ byte ของรุ่นคุณ`n" -ForegroundColor Gray
        Show-ToshibaHelp
    }
} finally {
    $sp.Close()
}
