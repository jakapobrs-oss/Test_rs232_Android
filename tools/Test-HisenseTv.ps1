<#
=====================================================================
 Test-HisenseTv.ps1 — เทสยิงคำสั่ง Hisense Prosumer TV RS232 (เฟส 1)
=====================================================================
 ใช้พิสูจน์ว่า "สาย RS232-to-USB + จอ Hisense (U1600 Prosumer series) + โปรโตคอล" ทำงานจริง
 โดยยังไม่เกี่ยวกับแอพ Android เลย — ใช้แค่ PowerShell ที่มีในเครื่อง

 วิธีใช้:
   .\Test-HisenseTv.ps1                       # หา COM port อัตโนมัติ + ถามสถานะ power (read-only)
   .\Test-HisenseTv.ps1 -Port COM3            # ระบุพอร์ตเอง
   .\Test-HisenseTv.ps1 -Command power?       # ถามสถานะเปิด/ปิด
   .\Test-HisenseTv.ps1 -Command on           # !! เปิดจอ
   .\Test-HisenseTv.ps1 -Command off          # !! ปิดจอ (standby)
   .\Test-HisenseTv.ps1 -Command vol -Value 30  # ตั้งเสียง 30 (0-100)
   .\Test-HisenseTv.ps1 -Command mute / unmute
   .\Test-HisenseTv.ps1 -Command hdmi1 / hdmi2 / hdmi3
   .\Test-HisenseTv.ps1 -Id 465               # ส่งให้จอ ID เฉพาะ (3 หลักท้าย MAC), default "ALL"=ทุกจอ
   .\Test-HisenseTv.ps1 -Raw "53 41 4C 4C 50 4F 57 52 30 30 30 31 CB 0D"   # ส่ง byte ดิบเอง

 โปรโตคอล Hisense Prosumer (U1600 series — RS-232/IR Protocol v3.6, ต่อผ่าน DB9):
   เฟรม (14 byte) = [OP] [CLIENT ID 3 ASCII] [COMMAND 4 ASCII] [DATA 4 ASCII] [CHECKSUM] [CR=0x0D]
   OP:  'S'(0x53)=Set/สั่ง  ·  'Q'(0x51)=Query/ถาม
   CLIENT ID:  "ALL"=ทุกจอ (generic, default) · หรือ 3 หลักท้าย MAC address ของจอ เช่น "465"
   COMMAND:  POWR(power) · VOLM(volume) · MUTE(mute) · INPT(input)
   DATA:  4 ASCII เช่น "0001" · query ใช้ "????"
   CHECKSUM = (256 - (ผลรวมทุก byte ตั้งแต่ OP ถึง DATA) mod 256) and 0xFF   (สอง's complement)
   ตอบกลับ = [CLIENT ID 3]:OKAY[DATA 4][CHECKSUM][CR]
   ค่า DATA ที่ใช้:  POWR 0001=on/0000=standby · MUTE 0001=on/0000=off · VOLM 0000-0100
                     INPT HDMI1=0009/HDMI2=0010/HDMI3=0011/HDMI4=0012/TV=0001/AV=0004/Component=0003/VGA=0006
   พอร์ต: 38400 bps, 8 data bits, no parity, 1 stop bit (ตั้ง RS232 control เปิดในเมนู Custom Install ของจอก่อน)
   ⚠️ คนละโปรโตคอลกับ Hisense commercial E/M/WR series (ต่อ RJ45, เฟรม S<id>POWR ON##<xor>) — ตัวนี้ใช้กับ U1600 Prosumer
   อ้างอิง: Hisense RS-232/IR Protocol v3.6 (ตัวอย่างในเอกสาร: POWR0001 power-on ALL = 53 41 4C 4C 50 4F 57 52 30 30 30 31 CB 0D)
=====================================================================
#>
param(
    [string]$Port,
    [int]$Baud = 38400,
    [string]$Command,
    [int]$Value = -1,        # ใช้กับ -Command vol (ระดับเสียง 0-100)
    [string]$Raw,            # ส่ง byte ดิบเอง
    [string]$Id = 'ALL',     # CLIENT ID: "ALL"=ทุกจอ หรือ 3 หลักท้าย MAC เช่น "465"
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

# ---------- สร้างเฟรม Hisense + คำนวณ checksum (256 - Σ) ----------
function Build-His([char]$op, [string]$cmd4, [string]$data4) {
    if ($Id.Length -ne 3) { throw "CLIENT ID ต้องยาว 3 ตัวอักษร เช่น 'ALL' หรือ '465' (ได้รับ '$Id')" }
    $core = [string]$op + $Id + $cmd4 + $data4       # 1+3+4+4 = 12 byte ก่อน checksum
    $bytes = [byte[]][System.Text.Encoding]::ASCII.GetBytes($core)
    $sum = 0; foreach ($b in $bytes) { $sum += [int]$b }
    $cs = [byte](((256 - ($sum % 256)) % 256))       # two's complement: (Σ + cs) ลงท้าย 0 mod 256
    return ,([byte[]]($bytes + $cs + [byte]0x0D))
}

function ConvertTo-Hex([byte[]]$bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }

# ---------- self-test: ยืนยัน checksum ตรงกับตัวอย่างจริงในเอกสาร "ก่อน" ยิงจอ ----------
# เป็น insurance กัน arithmetic เพี้ยนบน PowerShell แต่ละเครื่อง — ผิดเมื่อไหร่หยุดทันที
$savedId = $Id
$cases = @(
    @{ Id='465'; Op=[char]0x53; Cmd='POWR'; Data='0001'; Cs=0x05 },   # power-on จอ 465
    @{ Id='ALL'; Op=[char]0x53; Cmd='POWR'; Data='0000'; Cs=0xCC },   # standby ทุกจอ
    @{ Id='465'; Op=[char]0x51; Cmd='INPT'; Data='????'; Cs=0xD9 }    # query input จอ 465
)
foreach ($c in $cases) {
    $Id = $c.Id
    $f = Build-His $c.Op $c.Cmd $c.Data
    $gotCs = $f[$f.Length - 2]
    if ($gotCs -ne [byte]$c.Cs) {
        $Id = $savedId
        Write-Host "❌ self-test checksum ไม่ตรง spec ($($c.Cmd)$($c.Data): ได้ 0x$($gotCs.ToString('X2')) ควรเป็น 0x$('{0:X2}' -f $c.Cs)) — หยุดก่อนเพื่อความปลอดภัย" -ForegroundColor Red
        exit 1
    }
}
$Id = $savedId

if (-not $Port) { $Port = Find-SerialPort }

# ---------- เปิดพอร์ต (38400 8N1 ไม่มี flow control) ----------
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.Handshake = 'None'
$sp.ReadTimeout = 200
try {
    $sp.Open()
} catch [System.UnauthorizedAccessException] {
    Write-Host "❌ $Port ถูกโปรแกรมอื่นเปิดค้างอยู่ (ปิด PuTTY/Arduino IDE/โปรแกรม serial อื่นก่อน)" -ForegroundColor Red
    exit 1
}
Write-Host "✅ เปิด $Port @ $Baud bps สำเร็จ (Hisense Prosumer, ID=$Id)`n" -ForegroundColor Green

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
        Write-Host "     เช็ค: 1) เปิด RS232 control ในเมนู Custom Install ของจอแล้วยัง  2) baud 38400 ถูกมั้ย (ลอง -Baud 9600/115200)" -ForegroundColor DarkGray
        Write-Host "          3) ใช้ -Id เป็น 3 หลักท้าย MAC ของจอ (broadcast ALL บางทีไม่ตอบ)  4) สาย RXD/TXD สลับถูกด้าน" -ForegroundColor DarkGray
        return $null
    }
    Write-Host ("RX < " + (ConvertTo-Hex $resp)) -ForegroundColor Green

    # ตอบกลับ: [id]:OKAY[data4]... → หา "OKAY" แล้วอ่าน data 4 ตัวถัดไป
    $ascii = -join ($resp | ForEach-Object { if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } else { '.' } })
    $idx = $ascii.IndexOf('OKAY')
    if ($idx -ge 0) {
        Write-Host "     → จอตอบ OKAY = สาย + โปรโตคอลคุยกันได้" -ForegroundColor Cyan
        if ($idx + 8 -le $ascii.Length) {
            $data = $ascii.Substring($idx + 4, 4)
            Write-Host "     → DATA = $data" -ForegroundColor Cyan
        }
    } else {
        Write-Host "     → มีคำตอบกลับมา (ไม่พบ 'OKAY' — ดู byte ดิบด้านบน)" -ForegroundColor Cyan
    }
    return $resp
}

# ---------- แปลง -Command friendly → เฟรม ----------
function Invoke-Named([string]$name) {
    switch -Regex ($name.ToLower()) {
        '^(power\?|status|state)$' { return Send-Frame (Build-His ([char]0x51) 'POWR' '????') }   # Query power
        '^(on|power-?on)$'         { return Send-Frame (Build-His ([char]0x53) 'POWR' '0001') }
        '^(off|power-?off)$'       { return Send-Frame (Build-His ([char]0x53) 'POWR' '0000') }
        '^vol\?$'                  { return Send-Frame (Build-His ([char]0x51) 'VOLM' '????') }    # Query volume
        '^(vol|volume)$' {
            if ($Value -lt 0 -or $Value -gt 100) { Write-Host "ใส่ระดับเสียงด้วย -Value 0..100 เช่น -Command vol -Value 30" -ForegroundColor Yellow; return $null }
            return Send-Frame (Build-His ([char]0x53) 'VOLM' ('{0:D4}' -f $Value))
        }
        '^(vol\+|vol-)$' { Write-Host "Hisense ไม่มีคำสั่งเพิ่ม/ลดเสียงแบบ relative — ใช้ -Command vol -Value <0-100> แทน" -ForegroundColor Yellow; return $null }
        '^mute$'   { return Send-Frame (Build-His ([char]0x53) 'MUTE' '0001') }
        '^unmute$' { return Send-Frame (Build-His ([char]0x53) 'MUTE' '0000') }
        '^hdmi1$'  { return Send-Frame (Build-His ([char]0x53) 'INPT' '0009') }
        '^hdmi2$'  { return Send-Frame (Build-His ([char]0x53) 'INPT' '0010') }
        '^hdmi3$'  { return Send-Frame (Build-His ([char]0x53) 'INPT' '0011') }
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
        Write-Host "=== Smoke Test (ถามสถานะ power อย่างเดียว ไม่เปลี่ยนค่าจอ) ===`n" -ForegroundColor Cyan
        $r = Send-Frame (Build-His ([char]0x51) 'POWR' '????')   # Query power status
        Write-Host ''
        if ($r) {
            Write-Host "🎉 สาย + โปรโตคอล + จอ Hisense คุยกันได้ — เฟส 1 ผ่าน!" -ForegroundColor Green
        } else {
            Write-Host "ยังไม่ได้คำตอบ — ลอง -Id เป็น 3 หลักท้าย MAC ของจอ + เช็ค baud/เปิด RS232 ในเมนู" -ForegroundColor Yellow
        }
    }
} finally {
    $sp.Close()
}
