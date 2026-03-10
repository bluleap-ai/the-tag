#ifndef BLE_IMAGE_SERVICE_H
#define BLE_IMAGE_SERVICE_H

#include <zephyr/types.h>

#define EPD_IMAGE_SIZE 5776 /* 152*152/4 bytes, 2bpp */

/* BLE Image Service UUIDs */
#define BLE_IMAGE_SERVICE_UUID \
    BT_UUID_128_ENCODE(0x12345678, 0x1234, 0x5678, 0x1234, 0x56789abcdef0)

#define BLE_IMAGE_DATA_CHAR_UUID \
    BT_UUID_128_ENCODE(0x12345678, 0x1234, 0x5678, 0x1234, 0x56789abcdef1)

#define BLE_IMAGE_CTRL_CHAR_UUID \
    BT_UUID_128_ENCODE(0x12345678, 0x1234, 0x5678, 0x1234, 0x56789abcdef2)

/* Control commands (phone -> firmware) */
#define IMG_CMD_START  0x01 /* [0x01, size_lo, size_hi] */
#define IMG_CMD_COMMIT 0x02 /* [0x02] */
#define IMG_CMD_CANCEL 0x03 /* [0x03] */
#define IMG_CMD_FIND   0x04 /* [0x04] — blink LED to help user locate tag */

/* Status notifications (firmware -> phone) */
#define IMG_STATUS_READY       0x00 /* Ready for data */
#define IMG_STATUS_PROGRESS    0x01 /* [0x01, received_lo, received_hi] */
#define IMG_STATUS_DISPLAYING  0x10 /* Started display refresh */
#define IMG_STATUS_DONE        0x11 /* Display refresh complete */
#define IMG_STATUS_FINDING     0x20 /* Find-device LED blink started */
#define IMG_STATUS_ERROR       0xFF /* [0xFF, error_code] */

#define IMG_ERR_INVALID_SIZE   0x01
#define IMG_ERR_OVERFLOW       0x02
#define IMG_ERR_NOT_STARTED    0x03
#define IMG_ERR_INCOMPLETE     0x04

typedef void (*ble_image_ready_cb_t)(const uint8_t *data, uint16_t size);
typedef void (*ble_find_device_cb_t)(void);

void ble_image_service_init(ble_image_ready_cb_t callback);
void ble_image_service_set_find_cb(ble_find_device_cb_t callback);
void ble_image_notify_display_done(void);

#endif /* BLE_IMAGE_SERVICE_H */
