#ifndef BLE_AUDIO_SERVICE_H
#define BLE_AUDIO_SERVICE_H

#include <zephyr/types.h>
#include <stdbool.h>

/* LC3 audio parameters */
#define AUDIO_SAMPLE_RATE_HZ        16000
#define AUDIO_FRAME_DURATION_US     10000   /* 10 ms */
#define AUDIO_BITRATE_BPS           32000   /* 32 kbps */
#define AUDIO_FRAME_BYTES           40      /* 32000 / 8 * 0.010 = 40 bytes per LC3 frame */
#define AUDIO_CHANNELS              1       /* Mono */
#define AUDIO_PCM_SAMPLES_PER_FRAME 160     /* 16000 Hz * 0.010 s */

/* BLE Audio Service UUIDs */
#define BLE_AUDIO_SERVICE_UUID \
    BT_UUID_128_ENCODE(0x12345678, 0x1234, 0x5678, 0x1234, 0x56789abcdef3)

/* Audio Data characteristic – Notify (firmware → phone): carries LC3 frames */
#define BLE_AUDIO_DATA_CHAR_UUID \
    BT_UUID_128_ENCODE(0x12345678, 0x1234, 0x5678, 0x1234, 0x56789abcdef4)

/* Audio Control characteristic – Write | Notify (phone ↔ firmware): commands/status */
#define BLE_AUDIO_CTRL_CHAR_UUID \
    BT_UUID_128_ENCODE(0x12345678, 0x1234, 0x5678, 0x1234, 0x56789abcdef5)

/* Control commands (phone → firmware, written to ctrl char) */
#define AUDIO_CMD_START  0x01   /* Begin recording and streaming */
#define AUDIO_CMD_STOP   0x02   /* Stop recording and streaming */

/* Status notifications (firmware → phone, notified on ctrl char) */
#define AUDIO_STATUS_RECORDING  0x01
#define AUDIO_STATUS_STOPPED    0x02
#define AUDIO_STATUS_ERROR      0xFF

/*
 * Audio data frame layout sent as BLE notification on the data characteristic:
 *   Byte 0-1 : sequence number (little-endian)
 *   Byte 2-3 : LC3 payload length in bytes (little-endian)
 *   Byte 4…  : LC3-encoded audio payload
 */
#define AUDIO_FRAME_HEADER_SIZE 4

/**
 * @brief Initialise the BLE Audio GATT service.
 *
 * Must be called after bt_enable().
 */
void ble_audio_service_init(void);

/**
 * @brief Notify a single LC3 audio frame to all subscribed clients.
 *
 * @param lc3_data  Pointer to LC3-encoded frame bytes.
 * @param len       Length of lc3_data (must be <= AUDIO_FRAME_BYTES).
 * @param seq       Monotonically-increasing sequence number.
 */
void ble_audio_service_notify_frame(const uint8_t *lc3_data, uint16_t len, uint16_t seq);

/**
 * @brief Return true when at least one client has subscribed to audio data notifications.
 */
bool ble_audio_service_is_streaming(void);

#endif /* BLE_AUDIO_SERVICE_H */
