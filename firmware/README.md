# the-tag
<img width="679" height="653" alt="image" src="https://github.com/user-attachments/assets/c280b38f-db3c-409a-aaa3-c54f0d905b22" />


# Components: 
- [Seeed Studio XIAO nRF54L15 Sense](https://www.seeedstudio.com/Seeed-Studio-XIAO-nRF54L15-Sense-Pre-Soldered-p-6500.html?srsltid=AfmBOoqPTqsxPYSpyJ1X8-ABDJ6ZhmzmzD8qlfOUBaC0Au0bjOC8lFFK)
- [ePaper Breakout Board for Seeed Studio XIAO](https://www.seeedstudio.com/ePaper-Breakout-Board-p-5804.html?srsltid=AfmBOoqj34irMFfLHrAsJpeER5vtpA0sM0G_N_hMMq1ya_562vqUIcqu)
- [E-ink 1,54 inch Shopee 4 colors](https://shopee.vn/%F0%9F%94%A5M%C3%A0n-h%C3%ACnh-E-Paper-M%C3%A0n-h%C3%ACnh-E-Ink-1.54-''-M%C3%A0n-h%C3%ACnh-E-Paper-152x152-M%C3%A0n-h%C3%ACnh-E-Ink-m%C3%A0u-Mini-i.127928025.41873920173)
- Or [E-ink 1,54 inch from proe 4 colors](https://www.proe.vn/1-64inch-square-e-paper-g-raw-display-168-168-red-yellow-black-white)  


# Hardware Connection for Developer version:
<img width="543" height="164" alt="image" src="https://github.com/user-attachments/assets/2be2b3ba-df4d-4b64-a039-8cb74c12c2f6" />
<img width="699" height="291" alt="image" src="https://github.com/user-attachments/assets/857440ce-5541-45d5-8d43-4ffeb70f7e5b" />
<img width="591" height="319" alt="image" src="https://github.com/user-attachments/assets/b8c4ba6b-f338-4ae3-85eb-c42865d235ce" />



# Share Folder 
- [Google Driver project folder](https://drive.google.com/drive/folders/1gwg72AfddP2lZDSd2DLhJ3Zl0bu9NLsG?usp=drive_link)

# 🚀 Getting Started

This project uses **West** (Zephyr’s meta-tool) to manage the workspace and modules.

Follow the steps below to initialize, build, and flash the firmware.

---

## 📦 1️⃣ Initialize the Workspace

Initialize the workspace directly from this repository:

```bash
west init -m git@github.com:bluleap-ai/the-tag.git --mr main etag
cd etag
west update
```

## 🛠️ 2️⃣ Build the Firmware

### Build for Seeed XIAO nRF54L15 (CPUAPP core) debug mode:

```bash
west build -b xiao_nrf54l15/nrf54l15/cpuapp the-tag -p
```

### Or Build for Seeed XIAO nRF54L15 (CPUAPP core) using sysbuild:

```bash
west build -b xiao_nrf54l15/nrf54l15/cpuapp the-tag --sysbuild -p
```

## 🔥 3️⃣ Flash the Device

After a successful build: Make sure your board is connected.

```bash
west flash
```

---

## 📲 BLE Image Transfer Protocol

The firmware exposes a custom BLE GATT service that allows a mobile app to send images to the e-ink display over Bluetooth Low Energy.

### Service & Characteristics

| Name | UUID | Properties |
|------|------|------------|
| Image Service | `12345678-1234-5678-1234-56789abcdef0` | — |
| Data Characteristic | `12345678-1234-5678-1234-56789abcdef1` | Write Without Response |
| Control Characteristic | `12345678-1234-5678-1234-56789abcdef2` | Write, Notify |

### Image Format

- Resolution: **152 x 152** pixels
- Color depth: **2 bits per pixel** (4 colors: black, white, red, yellow)
- Buffer size: **5776 bytes** (`152 * 152 / 4`)
- Pixel packing: 4 pixels per byte, MSB first — `[px0(2bit) px1(2bit) px2(2bit) px3(2bit)]`
- Color codes: `00` = black, `01` = white, `10` = yellow, `11` = red

### Control Commands (Phone → Firmware)

| Command | Bytes | Description |
|---------|-------|-------------|
| START | `0x01, size_lo, size_hi` | Begin transfer. Firmware resets buffer and expects `size` bytes. |
| COMMIT | `0x02` | Finalize transfer. Firmware validates and displays image. |
| CANCEL | `0x03` | Abort current transfer. |

### Status Notifications (Firmware → Phone)

| Status | Bytes | Description |
|--------|-------|-------------|
| READY | `0x00` | Firmware ready to receive data chunks. |
| PROGRESS | `0x01, received_lo, received_hi` | Bytes received so far (sent every ~1KB). |
| DISPLAYING | `0x10` | Transfer complete, e-ink refresh started. |
| DONE | `0x11` | E-ink refresh complete. |
| ERROR | `0xFF, error_code` | Transfer error occurred. |

### Error Codes

| Code | Name | Description |
|------|------|-------------|
| `0x01` | INVALID_SIZE | Requested size exceeds 5776 bytes |
| `0x02` | OVERFLOW | Data received exceeds expected size |
| `0x03` | NOT_STARTED | Data/commit received without a START |
| `0x04` | INCOMPLETE | COMMIT received before all bytes arrived |

### Transfer Sequence

```
Phone                              Firmware
  |                                    |
  |--- WRITE ctrl [0x01, lo, hi] ----->|  START (size = 5776)
  |<--- NOTIFY ctrl [0x00] -----------|  READY
  |                                    |
  |--- WRITE data [chunk 1] --------->|  (write-without-response)
  |--- WRITE data [chunk 2] --------->|
  |<--- NOTIFY ctrl [0x01, lo, hi] ---|  PROGRESS
  |--- WRITE data [chunk N] --------->|
  |                                    |
  |--- WRITE ctrl [0x02] ------------>|  COMMIT
  |<--- NOTIFY ctrl [0x10] -----------|  DISPLAYING
  |        (e-ink refresh ~3-5s)       |
  |<--- NOTIFY ctrl [0x11] -----------|  DONE
```

### Notes

- Negotiate MTU to **247** for optimal throughput (~244 bytes per data chunk).
- Data chunks are written sequentially; the firmware tracks the offset internally.
- The mobile app performs image conversion (resize, dithering, 4-color quantization) before sending.
- A Flutter companion app is available in the `mobile_app/` directory.

---

## 🍎 Apple Find My (OpenHaystack)

The firmware supports Apple's **Find My** network via the
[OpenHaystack](https://github.com/seemoo-lab/openhaystack) Offline Finding
protocol.  When enabled, the device broadcasts a non-connectable BLE
advertisement that nearby Apple devices silently forward to Apple's servers,
allowing the tag to appear in the **Find My** app — no Apple SDK required.

The feature runs as a **dedicated extended advertising set** (BLE 5.x) that
coexists with the connectable image-transfer advertising set.

### How it works

```
nRF54L15                   iPhone/Mac nearby          Apple servers
    |                              |                        |
    |-- OF advertisement -------->|                        |
    |   (non-connectable, ~1 s)   |-- encrypted report --->|
    |                              |                        |
                                                           Find My app
                                                           shows location
```

1. The device derives a **random-static BLE address** from the first 6 bytes
   of a 28-byte compressed EC P-224 public key.
2. It broadcasts an **Apple manufacturer-specific advertisement** (company ID
   `0x004C`, type `0x12`) containing the remaining key bytes and a key hint.
3. Apple devices in range encrypt the tag's location with the public key and
   upload the report anonymously to Apple's servers.
4. The owner retrieves and decrypts the location report using the matching
   **private key** in the OpenHaystack desktop app.

### Advertisement format (Offline Finding, type `0x12`)

| Offset | Length | Value |
|--------|--------|-------|
| 0–1 | 2 | Apple company ID `0x4C 0x00` |
| 2 | 1 | OF type `0x12` |
| 3 | 1 | OF sub-length `0x19` (25 bytes) |
| 4 | 1 | Status flags `0x00` |
| 5–26 | 22 | `public_key[6..27]` |
| 27 | 1 | `public_key[0] >> 6` (key hint) |
| 28 | 1 | Reserved `0x00` |

The BLE address is `public_key[0..5]` with the top 2 bits of byte 0 forced
to `1` (random-static address type).

### Key provisioning (production use)

1. Install the [OpenHaystack](https://github.com/seemoo-lab/openhaystack)
   desktop application on macOS.
2. Create a new accessory and export its **28-byte compressed EC P-224 public
   key** (displayed in the "Keys" column as a Base64 string).
3. Decode the Base64 string and pass the resulting byte array to
   `find_my_init()` instead of `NULL`:

```c
static const uint8_t my_public_key[FIND_MY_PUBLIC_KEY_SIZE] = {
    /* paste your 28 key bytes here */
};

find_my_init(my_public_key);
find_my_start();
```

4. Set `CONFIG_FIND_MY_DEMO_KEY=n` in `prj.conf` to disable the placeholder
   key and ensure only your real key is used.

> ⚠️ **The built-in demo key is a placeholder.**  It is NOT a valid EC P-224
> point.  Apple devices will relay the advertisement, but the encrypted
> location reports cannot be decrypted without a matching private key.  Always
> provision a real key pair for production hardware.

### Key rotation (production use)

Apple requires key rotation every **~15 minutes** for privacy.  Pre-generate
multiple key pairs with OpenHaystack, store them in flash, and call
`find_my_rotate_key()` on a timer:

```c
/* Example: rotate key every 15 minutes */
static const uint8_t keys[][FIND_MY_PUBLIC_KEY_SIZE] = { ... };
static int key_index;

void key_rotation_timer_handler(struct k_timer *t)
{
    key_index = (key_index + 1) % ARRAY_SIZE(keys);
    find_my_rotate_key(keys[key_index]);
}
K_TIMER_DEFINE(key_timer, key_rotation_timer_handler, NULL);
/* start timer: k_timer_start(&key_timer, K_MINUTES(15), K_MINUTES(15)); */
```

### Build configuration

`CONFIG_FIND_MY=y` is the default.  To disable Find My entirely:

```bash
west build -b xiao_nrf54l15/nrf54l15/cpuapp the-tag -p -- -DCONFIG_FIND_MY=n
```

---

## 🚀 Roadmap

### 🔧 Core Features
- [x] West workspace initialization
- [x] MCUboot integration

### 📡 Connectivity
- [x] Apple Find My (OpenHaystack) Offline Finding advertising
- [ ] BLE connection stability improvements
- [ ] Find My key rotation timer (15-minute interval)

### 🔋 Power Management
- [ ] Sleep mode optimization
- [ ] Low battery protection
- [ ] Power consumption measurement report

### 🧪 Testing
- [ ] Hardware validation
- [ ] Field testing
- [ ] CI pipeline setup
