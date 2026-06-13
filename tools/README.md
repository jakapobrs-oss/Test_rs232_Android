# tools/ — สคริปต์เทสโปรโตคอล RS232 (เฟส 1, แยกตามรุ่น/ยี่ห้อ)

สคริปต์ในโฟลเดอร์นี้ใช้ **พิสูจน์ว่า "สาย RS232-to-USB + ทีวี + โปรโตคอล" ทำงานจริง**
โดยยังไม่เกี่ยวกับแอป/เว็บเลย — ยิงคำสั่งจาก notebook ตรงๆ ผ่าน PowerShell ที่มีในเครื่อง
ใช้เป็นด่านแรกก่อนไปเทสบนแอป ถ้าด่านนี้ผ่าน แปลว่าฮาร์ดแวร์+โปรโตคอลโอเค

## สคริปต์ที่มีตอนนี้

| ไฟล์ | ยี่ห้อ | โปรโตคอล | สถานะ |
|---|---|---|---|
| `Test-LgTv.ps1`        | LG        | LG RS232 มาตรฐาน (`ka 01 FF`)             | ✅ ใช้งานได้ (verified หน้างาน) |
| `Test-SamsungTv.ps1`   | Samsung   | MDC hex frame `0xAA…` + checksum          | ✅ byte ตรวจแล้ว (รอเทสหน้างาน) |
| `Test-SonyTv.ps1`      | Sony      | Classic binary `0x8C…` + checksum         | ✅ byte ตรวจแล้ว (รอเทสหน้างาน) |
| `Test-PanasonicTv.ps1` | Panasonic | STX/ETX + ASCII (`PON`/`POF`/`QPW`)       | ✅ byte ตรวจแล้ว (รอเทสหน้างาน) |
| `Test-SharpTv.ps1`     | Sharp     | ASCII 8 ตัว + CR (`POWR0001`)             | ✅ byte ตรวจแล้ว (รอเทสหน้างาน) |
| `Test-NecTv.ps1`       | NEC       | External-control frame (SOH…ETX+BCC+CR)   | ✅ byte ตรวจแล้ว (รอเทสหน้างาน) |
| `Test-PhilipsTv.ps1`   | Philips   | SICP `[len][id][00][cmd]…[xor]`           | ✅ byte ตรวจแล้ว (รอเทสหน้างาน) |
| `Test-ToshibaTv.ps1`   | Toshiba   | ⚠️ ต่างตามรุ่น (TD-Z commercial/REGZA/ไม่มี) | 🧩 scaffold — เปิดพอร์ต + `-Raw` ได้ (ยังไม่ wire `-Command`) |

> "byte ตรวจแล้ว" = รูปแบบเฟรม/คำสั่ง/checksum อ้างอิงจาก spec/แหล่งทางการแล้ว แต่ยัง**ไม่ได้ทดสอบกับจอจริง** — เทสหน้างานด้วย smoke test (รันเปล่าๆ) ก่อนเสมอ
> 🧩 "scaffold" = โครงที่เปิดพอร์ต + รับ `-Raw` (แปะ byte จาก doc รุ่นมายิงเอง) ได้ แต่ยังไม่ map คำสั่ง friendly เพราะโปรโตคอลต่างตามรุ่น — ส่งรุ่น + เอกสาร RS232 มาเดี๋ยว wire `-Command` ให้เต็ม

## วิธีใช้ (เหมือนกันทุกตัว — คำสั่งแบบ friendly)

```powershell
.\Test-SamsungTv.ps1                      # หา COM port อัตโนมัติ + smoke test (query อย่างเดียว ไม่เปลี่ยนค่าจอ)
.\Test-SamsungTv.ps1 -Port COM3           # ระบุพอร์ตเอง
.\Test-SamsungTv.ps1 -Command power?      # ถามสถานะเปิด/ปิด
.\Test-SamsungTv.ps1 -Command on          # !! เปิดจอ
.\Test-SamsungTv.ps1 -Command off         # !! ปิดจอ (standby)
.\Test-SamsungTv.ps1 -Command vol -Value 30   # ตั้งเสียง 30
.\Test-SamsungTv.ps1 -Command mute / unmute
.\Test-SamsungTv.ps1 -Command hdmi1 / hdmi2 / hdmi3
.\Test-SamsungTv.ps1 -Raw "AA 11 00 00 11"    # ส่ง byte/คำสั่งดิบเอง (ขั้นสูง)
```

คำสั่ง `-Command` ที่รองรับ (แล้วแต่ยี่ห้อ): `power?` `on` `off` `vol -Value <n>` `vol?` `vol+` `vol-` `mute` `unmute` `hdmi1` `hdmi2` `hdmi3`
รันเปล่าๆ ไม่ใส่ `-Command` = **smoke test** ถามสถานะอย่างเดียว ปลอดภัยกับหน้างาน

> เริ่มหน้างานเสมอด้วยการรันเปล่าๆ (smoke test) ก่อน — ได้คำตอบกลับมา = สาย+โปรโตคอล+จอ คุยกันได้ → ค่อยลองสั่ง on/off

## โปรโตคอลย่อ (อ้างอิงเร็ว)

ทุกยี่ห้อ default พอร์ต **9600 bps, 8 data bits, no parity, 1 stop bit, no flow control** (เว้นระบุไว้)
หลายรุ่นต้องใช้ **สายไขว้ (null modem)** — ถ้า smoke test ไม่ตอบ ลองสลับสาย

- **LG** — `[cmd] [SetID] [Data]`+CR เช่น `ka 01 FF` · ตอบ `OK[data]x`/`NG…x` · ID 00=ทุกเครื่อง
- **Samsung (MDC)** — `0xAA [cmd] [ID] [len] [data] [cs]`, cs=(cmd+ID+len+Σdata)&0xFF · cmd 0x11 power/0x12 vol/0x13 mute/0x14 input · ตอบ `AA FF … 0x41(ACK)/0x4E(NAK)`
- **Sony (classic)** — `0x8C [cat] [fn] [len] [data] [cs]`, cs=Σ(ทุก byte รวม header)&0xFF · ถาม=`0x83…0xFF 0xFF` · ⚠️ รุ่น Pro BRAVIA BZ/BU ใหม่ใช้ ASCII `*S…` คนละแบบ
- **Panasonic** — `<STX> PON/POF/QPW/AVL:nnn/AMT:1/IMS:HM1 <ETX>` · ตอบหุ้ม STX/ETX หรือ `ER401` · บางรุ่นมี serial password
- **Sharp (AQUOS)** — ASCII 8 ตัว+CR: `POWR0001`(on)/`POWR0000`(off)/`POWR????`(ถาม) · `RSPW0001`=อนุญาตปลุกจาก standby · ตอบ `OK`/`ERR`
- **NEC** — `[SOH]'0'[dest][src][type][len][STX][msg][ETX][BCC][CR]`, BCC=XOR(หลัง SOH→ETX) · type A=command/E=set param · มักต้องสายไขว้
- **Philips (SICP)** — `[len][id][0x00][cmd][data][xor]` · cmd 0x18 set power(01=off/02=on)/0x19 get power/0x44 vol · ตอบ ACK=0x06/NACK=0x15

## ⏳ ยี่ห้อที่ยังไม่ได้ทำ (backlog — รอ verify เฉพาะรุ่น)

ยังไม่ ship เพราะ checksum/รหัสคำสั่ง**ต่างกันมากตามรุ่น** ถ้าจะใช้ ส่ง model + เอกสาร RS232 ของรุ่นนั้นมา เดี๋ยวเติม tester ให้:

- **Hisense** (E/M/WR series) — ASCII `S<id>POWR<ON/OFF>##<xor><CR>` เช่น power-on ID 5FA = `53 35 46 41 50 4F 57 52 4F 4E 23 23 C6 0D` · checksum = XOR เฉพาะบาง byte (เอกสารไฮไลต์สีเขียว) → ต้องดู doc รุ่นถึงคำนวณคำสั่งอื่นได้ · [Hisense RS232/IR Protocol PDF](https://assets.hisense-usa.com/assets/ProductDownloads/18/5342defe83/Hisense-RS-232-and-IR-Protocol-English_2.pdf)
- **ViewSonic** (commercial) — มี spec กลาง · [Commercial Displays RS232 PDF](https://www.viewsonicglobal.com/public/products_download/97/Commercial_Displays_RS232.pdf)
- **TCL** — โปรโตคอลไม่ standard (แล้วแต่ ODM/รุ่น) → ต้องขอเอกสารรายรุ่น
- **Toshiba** — มี scaffold `Test-ToshibaTv.ps1` แล้ว (เปิดพอร์ต + `-Raw` ได้); จะ wire `-Command` เต็มเมื่อได้รุ่น + doc — TD-Z/TD-E commercial มี spec ใน user manual ของรุ่น (เฟรม `[address][function][data][end]`), REGZA consumer ส่วนใหญ่ไม่มี RS232, HD-DVD player = start `0x45 0xB5` (คนละอุปกรณ์)

## วิธีเพิ่ม tester รุ่นใหม่

1. ตั้งชื่อตาม convention: **`Test-<ยี่ห้อ>Tv.ps1`**
2. คงพารามิเตอร์เดิมให้เหมือนทุกตัว: `-Port` `-Baud` `-Command` `-Value` `-Raw` `-TimeoutMs` (+ `-Id` ถ้าโปรโตคอลมี address)
3. ส่วนที่ **ใช้ซ้ำได้** จากตัวที่มี: ฟังก์ชัน `Find-SerialPort` (กรอง CH340/FTDI/Prolific/CP210x), การเปิด/ปิดพอร์ต, `Read-Bytes`/อ่านคำตอบ, การพิมพ์ผล
4. ส่วนที่ต้องแก้ต่างกัน: รูปแบบเฟรม+checksum, baud, การ parse คำตอบ, ตาราง `-Command` → byte

### ⚠️ Encoding (สำคัญ)
สคริปต์ใหม่ทุกตัวเซฟเป็น **UTF-8 with BOM** เพราะ Windows PowerShell 5.1 อ่านไฟล์ที่**ไม่มี BOM** เป็น ANSI →
คอมเมนต์/ข้อความไทยเพี้ยน และอาจ parse พังหน้างาน. ถ้าสร้างไฟล์ใหม่ ให้บันทึกเป็น UTF-8 BOM เสมอ
(ตัว `Test-LgTv.ps1` เดิมยังเป็น no-BOM — รันได้บน PowerShell 7/console UTF-8 แต่ควรแปลงเป็น BOM ให้ชัวร์ทุกเครื่อง)

ตรวจ syntax ทุกไฟล์เร็วๆ:
```powershell
Get-ChildItem .\Test-*.ps1 | ForEach-Object {
  $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$e)
  "{0}: {1}" -f $_.Name, ($(if($e.Count){"❌ $($e.Count) errors"}else{"✅ OK"}))
}
```
