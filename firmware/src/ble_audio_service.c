#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "ble_audio_service.h"
#include "mic_driver.h"

LOG_MODULE_REGISTER(ble_audio_svc, CONFIG_LOG_DEFAULT_LEVEL);

static struct bt_uuid_128 audio_svc_uuid  = BT_UUID_INIT_128(BLE_AUDIO_SERVICE_UUID);
static struct bt_uuid_128 audio_data_uuid = BT_UUID_INIT_128(BLE_AUDIO_DATA_CHAR_UUID);
static struct bt_uuid_128 audio_ctrl_uuid = BT_UUID_INIT_128(BLE_AUDIO_CTRL_CHAR_UUID);

static bool data_notifications_enabled;
static bool ctrl_notifications_enabled;

static void audio_data_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value);
static void audio_ctrl_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t audio_ctrl_write_cb(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                   const void *buf, uint16_t len, uint16_t offset,
                                   uint8_t flags);

/*
 * GATT service attribute table (indices used when sending notifications):
 *   [0] Primary service declaration
 *   [1] Audio Data characteristic declaration
 *   [2] Audio Data characteristic value   ← notify audio frames here
 *   [3] Audio Data CCC descriptor
 *   [4] Audio Ctrl characteristic declaration
 *   [5] Audio Ctrl characteristic value   ← notify status here
 *   [6] Audio Ctrl CCC descriptor
 */
BT_GATT_SERVICE_DEFINE(audio_svc,
    BT_GATT_PRIMARY_SERVICE(&audio_svc_uuid),

    /* Audio Data – Notify only (firmware → phone) */
    BT_GATT_CHARACTERISTIC(&audio_data_uuid.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_NONE,
                           NULL, NULL, NULL),
    BT_GATT_CCC(audio_data_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),

    /* Audio Control – Write + Notify (phone ↔ firmware) */
    BT_GATT_CHARACTERISTIC(&audio_ctrl_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL, audio_ctrl_write_cb, NULL),
    BT_GATT_CCC(audio_ctrl_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/* ------------------------------------------------------------------ */
/* CCC callbacks                                                        */
/* ------------------------------------------------------------------ */

static void audio_data_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    data_notifications_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Audio data notifications %s",
            data_notifications_enabled ? "enabled" : "disabled");

    /* Mic start/stop is driven by the explicit CMD_START / CMD_STOP
     * commands on the control characteristic – not by CCC toggling –
     * to avoid a double-start race and to give the app full control. */
}

static void audio_ctrl_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    ctrl_notifications_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Audio ctrl notifications %s",
            ctrl_notifications_enabled ? "enabled" : "disabled");
}

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

static void send_ctrl_status(uint8_t status)
{
    if (!ctrl_notifications_enabled) {
        return;
    }
    /* Audio Ctrl char value is at index 5 */
    const struct bt_gatt_attr *attr = &audio_svc.attrs[5];
    int err = bt_gatt_notify(NULL, attr, &status, sizeof(status));

    if (err) {
        LOG_DBG("Ctrl status notify failed: %d", err);
    }
}

/* ------------------------------------------------------------------ */
/* Control write handler                                                */
/* ------------------------------------------------------------------ */

static ssize_t audio_ctrl_write_cb(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                   const void *buf, uint16_t len, uint16_t offset,
                                   uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(offset);
    ARG_UNUSED(flags);

    const uint8_t *cmd = buf;

    if (len < 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    switch (cmd[0]) {
    case AUDIO_CMD_START:
        LOG_INF("Audio CMD_START received");
        mic_driver_start();
        send_ctrl_status(AUDIO_STATUS_RECORDING);
        break;

    case AUDIO_CMD_STOP:
        LOG_INF("Audio CMD_STOP received");
        mic_driver_stop();
        send_ctrl_status(AUDIO_STATUS_STOPPED);
        break;

    default:
        LOG_WRN("Unknown audio command: 0x%02x", cmd[0]);
        return BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED);
    }

    return len;
}

/* ------------------------------------------------------------------ */
/* Public API                                                           */
/* ------------------------------------------------------------------ */

void ble_audio_service_notify_frame(const uint8_t *lc3_data, uint16_t len, uint16_t seq)
{
    if (!data_notifications_enabled) {
        return;
    }

    if (len > AUDIO_FRAME_BYTES) {
        len = AUDIO_FRAME_BYTES;
    }

    /* Build notification: [seq_lo, seq_hi, len_lo, len_hi, ...lc3_data...] */
    uint8_t frame[AUDIO_FRAME_HEADER_SIZE + AUDIO_FRAME_BYTES];

    frame[0] = (uint8_t)(seq & 0xFF);
    frame[1] = (uint8_t)((seq >> 8) & 0xFF);
    frame[2] = (uint8_t)(len & 0xFF);
    frame[3] = (uint8_t)((len >> 8) & 0xFF);
    memcpy(&frame[AUDIO_FRAME_HEADER_SIZE], lc3_data, len);

    /* Audio Data char value is at index 2 */
    const struct bt_gatt_attr *attr = &audio_svc.attrs[2];
    int err = bt_gatt_notify(NULL, attr, frame, AUDIO_FRAME_HEADER_SIZE + len);

    if (err) {
        LOG_DBG("Audio frame notify failed (seq=%u): %d", seq, err);
    }
}

bool ble_audio_service_is_streaming(void)
{
    return data_notifications_enabled;
}

void ble_audio_service_init(void)
{
    data_notifications_enabled = false;
    ctrl_notifications_enabled = false;
    LOG_INF("BLE Audio Service initialised");
}
