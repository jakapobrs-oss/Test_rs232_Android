<#
=====================================================================
 Test-ViewSonicTv.ps1 — เทสยิงคำสั่ง ViewSonic Commercial Display RS232 (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ ViewSonic (commercial/LFD) + โปรโตคอล" ทำงานจริง
 โดยยังไม่เกี่ยวกับแอพ Android เลย — ใช้แค่ PowerShell ที่มีในเครื่อง

 วิธีใช้:
   .\Test-ViewSonicTv.ps1                       # หา COM port อัตโนมัติ + ถามสถานะ power (read-only)
   .\Test-ViewSonicTv.ps1 -Port COM3            # ระบุพอร์ตเอง
   .\Test-ViewSonicTv.ps1 -Command power?       # ถามสถานะเปิด/ปิด
   .\Test-ViewSonicTv.ps1 -Command on           # !! เปิดจอ
   .\Test-ViewSonicTv.ps1 -Command off          # !! ปิดจอ (standby)
   .\Test-ViewSonicTv.ps1 -Command vol -Value 30  # ตั้งเสียง 30 (0-100)
   .\Test-ViewSonicTv.ps1 -Command mute / unmute
   .\Test-ViewSonicTv.ps1 -Command hdmi1          # สลับ input เป็น HDMI
   .\Test-ViewSonicTv.ps1 -Id 2                    # จอตั้ง Monitor ID = 2 (default 1)
   .\Test-ViewSonicTv.ps1 -Raw "38 30 32 73 21 30 30 31 0D"   # ส่ง byte ดิบเอง

 โปรโตคอล ViewSonic Commercial Display RS232 (Protocol 1 = แบบมี ID):
   เฟรม (9 byte) = ['8'=Length] [ID 2 ASCII] [Type] [Command] [Value×3 ASCII] [CR=0x0D]
   Length ฟิกซ์ที่ '8' (0x38) สำหรับเฟรม 9 byte นี้  ·  ID = เลข 2 หลัก ASCII เช่น 01, "99"=ทุกจอ (ไม่มีตอบกลับ)
   Type:  's'(0x73)=Set  ·  'g'(0x67)=Get/query  ·  ตอบกลับ 'r'(0x72)=reply / '+'(0x2B)=set OK / '-'(0x2D)=invalid
   Set codes:  Power '!'(0x21) 001=ON/000=STBY · Volume '5'(0x35) 000-100 · Mute '6'(0x36) 001=on/000=off
               Input '"'(0x22) 000=VGA/001=HDMI/002=DVI-D/003=AV/004=YPbPr/005=S-Video
   Get codes (value ส่ง "000"):  Power 'l'(0x6C) · Volume 'f'(0x66) · Mute 'g'(0x67) · Input 'j'(0x6A) · ACK 'z'(0x7A)
   ** ไม่มี checksum ** — เฟรมสั้นและเป็น ASCII ล้วน
   พอร์ต: 9600 bps, 8 data bits, no parity, 1 stop bit, no flow control · ต้องใช้สายไขว้ (null modem)
   อ้างอิง: ViewSonic Commercial Display RS-232 Protocol Rev 1.x (ตัวอย่างในเอกสาร: Set Brightness 76 TV-02 = 38 30 32 73 24 30 37 36 0D)
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 9600,
    [string]$Command,
    [int]$Value = -1,        # ใช้กับ -Command vol (ระดับเสียง 0-100)
    [string]$Raw,            # ส่ง byte ดิบเอง
    [int]$Id = 1,            # Monitor ID ของจอ (ตั้งในเมนู, 1-26, "99"=ทุกจอ)
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

# ---------- สร้างเฟรม ViewSonic (ASCII ล้วน ไม่มี checksum) ----------
# Length ฟิกซ์ '8' · ID 2 หลัก · type 's'/'g' · cmd 1 ตัว · value 3 ตัว · CR
function Build-Vs([char]$type, [char]$cmd, [string]$val3) {
    if ($Id -lt 0 -or $Id -gt 99) { throw "ID ต้องอยู่ช่วง 0-99 (99=ทุกจอ)" }
    $idStr = '{0:D2}' -f $Id
    $s = '8' + $idStr + [string]$type + [string]$cmd + $val3 + "`r"   # `r = CR (0x0D)
    return ,([byte[]][System.Text.Encoding]::ASCII.GetBytes($s))
}

function ConvertTo-Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }

# ---------- self-test: ยืนยันโครงเฟรมตรง spec ก่อนยิงจริง ----------
# โครงเฟรมอ้างตัวอย่างในเอกสาร (Set Brightness 76 TV-02 = 38 30 32 73 24 ...) → power ON TV-02 ต้องได้ 38 30 32 73 21 30 30 31 0D
$savedId = $Id; $Id = 2
$check = Build-Vs ([char]0x73) ([char]0x21) '001'
$Id = $savedId
$expect = [byte[]](0x38,0x30,0x32,0x73,0x21,0x30,0x30,0x31,0x0D)
if ((ConvertTo-Hex $check) -ne (ConvertTo-Hex $expect)) {
    Write-Host "❌ self-test เฟรมไม่ตรง spec — หยุดก่อนเพื่อความปลอดภัย" -ForegroundColor Red
    Write-Host ("   got=" + (ConvertTo-Hex $check)) -ForegroundColor DarkGray
    exit 1
}

if (-not $Port) { $Port = Find-SerialPort }

# ---------- เปิดพอร์ต (9600 8N1 ไม่มี flow control) ----------
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.Handshake = 'None'
$sp.ReadTimeout = 200
try {
    $sp.Open()
} catch [System.UnauthorizedAccessException] {
    Write-Host "❌ $Port ถูกโปรแกรมอื่นเปิดค้างอยู่ (ปิด PuTTY/Arduino IDE/โปรแกรม serial อื่นก่อน)" -ForegroundColor Red
    exit 1
}
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (ViewSonic Commercial, ID=$Id)`n" -ForegroundColor Green

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
        Write-Host "     เช็ค: 1) จอเสียบปลั๊กอยู่มั้ย  2) ViewSonic commercial มักต้องใช้สายไขว้ (null modem)" -ForegroundColor DarkGray
        Write-Host "          3) Monitor ID ตรงกับที่ตั้งในจอมั้ย (ลอง -Id ให้ตรง)  4) ตั้ง RS232 control เปิดในเมนูจอ" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + (ConvertTo-Hex $resp)) -ForegroundColor Green

    # ตอบกลับ: หา marker type byte
    if ([Array]::IndexOf($resp, [byte]0x72) -ge 0) {              # 'r' = get reply → ค่าคือ 3 ASCII ก่อน CR
        $digits = ($resp | Where-Object { $_ -ge 0x30 -and $_ -le 0x39 })
        if ($digits.Count -ge 3) {
            $val = -join ($digits[-3..-1] | ForEach-Object { [char]$_ })
            Write-Host "     → ค่าที่อ่านได้ = $val" -ForegroundColor Cyan
        } else {
            Write-Host "     → จอตอบ reply (r)" -ForegroundColor Cyan
        }
    } elseif ([Array]::IndexOf($resp, [byte]0x2B) -ge 0) {        # '+' = set valid
        Write-Host "     → จอรับคำสั่งสำเร็จ (ACK '+')" -ForegroundColor Cyan
    } elseif ([Array]::IndexOf($resp, [byte]0x2D) -ge 0) {        # '-' = invalid
        Write-Host "     → จอตอบ invalid ('-') = คำสั่ง/ค่าไม่ถูกต้องสำหรับรุ่นนี้" -ForegroundColor Magenta
    }
    return $resp
}

# ---------- แปลง -Command friendly → เฟรม ----------
function Invoke-Named([string]$name) {
    switch -Regex ($name.ToLower()) {
        '^(power\?|status|state)$' { return Send-Frame (Build-Vs ([char]0x67) ([char]0x6C) '000') }   # Get power
        '^(on|power-?on)$'         { return Send-Frame (Build-Vs ([char]0x73) ([char]0x21) '001') }
        '^(off|power-?off)$'       { return Send-Frame (Build-Vs ([char]0x73) ([char]0x21) '000') }
        '^vol\?$'                  { return Send-Frame (Build-Vs ([char]0x67) ([char]0x66) '000') }    # Get volume
        '^(vol|volume)$' {
            if ($Value -lt 0 -or $Value -gt 100) { Write-Host "ใส่ระดับเสียงด้วย -Value 0..100 เช่น -Command vol -Value 30" -ForegroundColor Yellow; return $null }
            return Send-Frame (Build-Vs ([char]0x73) ([char]0x35) ('{0:D3}' -f $Value))
        }
        '^(vol\+|vol-)$' { Write-Host "ViewSonic ไม่มีคำสั่งเพิ่ม/ลดเสียงแบบ relative — ใช้ -Command vol -Value <0-100> แทน" -ForegroundColor Yellow; return $null }
        '^mute$'   { return Send-Frame (Build-Vs ([char]0x73) ([char]0x36) '001') }
        '^unmute$' { return Send-Frame (Build-Vs ([char]0x73) ([char]0x36) '000') }
        '^hdmi1$'  { return Send-Frame (Build-Vs ([char]0x73) ([char]0x22) '001') }    # input HDMI
        '^(hdmi2|hdmi3)$' { Write-Host "สเปกกลาง ViewSonic มี HDMI เดียว (input 001) — ใช้ hdmi1; ถ้ารุ่นมีหลาย HDMI ใช้ -Raw ตาม doc รุ่น" -ForegroundColor Yellow; return $null }
        default {
            Write-Host "ไม่รู้จักคำสั่ง '$name' — ใช้ได้: power? on off vol(-Value n) vol? mute unmute hdmi1" -ForegroundColor Yellow
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
        $r = Send-Frame (Build-Vs ([char]0x67) ([char]0x6C) '000')   # Get power status
        Write-Host ''
        if ($r) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ ViewSonic คุยกันได้ — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบ — ไล่เช็คตามคำแนะนำด้านบน (ลองสายไขว้ + -Id ให้ตรงกับจอ)" -ForegroundColor Yellow
        }
    }
} finally {
    $sp.Close()
}
