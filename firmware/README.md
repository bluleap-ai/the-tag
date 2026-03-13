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

This project uses **West** (Zephyr’s meta-tool) together with the **Nordic Connect SDK (NCS) v3.2.4** to manage the workspace and modules.

Follow the steps below to set up the NCS toolchain, initialize the workspace, build, and flash the firmware.

---

## 🔧 0️⃣ Prerequisites: Install NCS Toolchain

Install the [nRF Connect SDK v3.2.4 toolchain](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/installation.html) using the **nRF Connect for Desktop** application:

1. Download and install [nRF Connect for Desktop](https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-for-Desktop).
2. Open the **Toolchain Manager** extension.
3. Install the **nRF Connect SDK v3.2.4** toolchain.
4. Open a terminal from the Toolchain Manager (this pre-configures PATH for `west`, CMake, and the Zephyr SDK).

Alternatively, install the toolchain manually by following the [NCS Getting Started guide](https://docs.nordicsemi.com/bundle/ncs-latest/page/nrf/installation/install_ncs.html).

---

## 📦 1️⃣ Initialize the Workspace

Initialize a local workspace inside the `firmware/` directory:

```bash
cd firmware
west init -l west-manifest
west update
```

> **Note:** `west update` fetches NCS v3.2.4 (`sdk-nrf`) and all its dependencies (including the NCS-integrated Zephyr fork). This replaces the previous dependency on upstream Zephyr `main`.

## 🛠️ 2️⃣ Build the Firmware

### Build for Seeed XIAO nRF54L15 (CPUAPP core) debug mode:

```bash
west build -b xiao_nrf54l15/nrf54l15/cpuapp . -p
```

### Or Build for Seeed XIAO nRF54L15 (CPUAPP core) using sysbuild:

```bash
west build -b xiao_nrf54l15/nrf54l15/cpuapp . --sysbuild -p
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

## 🚀 Roadmap

### 🔧 Core Features
- [x] West workspace initialization
- [x] MCUboot integration

### 📡 Connectivity
- [ ] BLE connection stability improvements

### 🔋 Power Management
- [ ] Sleep mode optimization
- [ ] Low battery protection
- [ ] Power consumption measurement report

### 🧪 Testing
- [ ] Hardware validation
- [ ] Field testing
- [ ] CI pipeline setup
