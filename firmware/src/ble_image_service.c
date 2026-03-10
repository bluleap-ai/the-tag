#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "ble_image_service.h"

LOG_MODULE_REGISTER(ble_image_svc, CONFIG_LOG_DEFAULT_LEVEL);

static uint8_t image_buffer[EPD_IMAGE_SIZE];
static uint16_t image_offset;
static uint16_t image_expected_size;
static bool transfer_active;
static ble_image_ready_cb_t ready_callback;
static ble_find_device_cb_t find_callback;

static struct bt_uuid_128 image_svc_uuid = BT_UUID_INIT_128(BLE_IMAGE_SERVICE_UUID);
static struct bt_uuid_128 image_data_uuid = BT_UUID_INIT_128(BLE_IMAGE_DATA_CHAR_UUID);
static struct bt_uuid_128 image_ctrl_uuid = BT_UUID_INIT_128(BLE_IMAGE_CTRL_CHAR_UUID);

static void ctrl_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t data_write_cb(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags);
static ssize_t ctrl_write_cb(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags);

BT_GATT_SERVICE_DEFINE(image_svc,
    BT_GATT_PRIMARY_SERVICE(&image_svc_uuid),

    /* Image Data characteristic - Write Without Response */
    BT_GATT_CHARACTERISTIC(&image_data_uuid.uuid,
                           BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_WRITE,
                           NULL, data_write_cb, NULL),

    /* Control characteristic - Write + Notify */
    BT_GATT_CHARACTERISTIC(&image_ctrl_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL, ctrl_write_cb, NULL),
    BT_GATT_CCC(ctrl_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

static bool notifications_enabled;

static void ctrl_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    notifications_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Image ctrl notifications %s", notifications_enabled ? "enabled" : "disabled");
}

static void send_notification(const uint8_t *data, uint16_t len)
{
    if (!notifications_enabled) {
        return;
    }

    /* Ctrl characteristic value attr is at index 4 (after svc, data chrc, data val, ctrl chrc) */
    const struct bt_gatt_attr *attr = &image_svc.attrs[4];

    bt_gatt_notify(NULL, attr, data, len);
}

static void send_status(uint8_t status)
{
    send_notification(&status, 1);
}

static void send_progress(uint16_t received)
{
    uint8_t buf[3] = {IMG_STATUS_PROGRESS, received & 0xFF, received >> 8};
    send_notification(buf, sizeof(buf));
}

static void send_error(uint8_t err_code)
{
    uint8_t buf[2] = {IMG_STATUS_ERROR, err_code};
    send_notification(buf, sizeof(buf));
}

static ssize_t data_write_cb(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags)
{
    if (!transfer_active) {
        LOG_WRN("Data received but no transfer active");
        send_error(IMG_ERR_NOT_STARTED);
        return len;
    }

    if (image_offset + len > image_expected_size) {
        LOG_ERR("Data overflow: offset=%u len=%u expected=%u", image_offset, len, image_expected_size);
        send_error(IMG_ERR_OVERFLOW);
        transfer_active = false;
        return len;
    }

    memcpy(&image_buffer[image_offset], buf, len);
    image_offset += len;

    /* Send progress every ~1KB */
    if ((image_offset % 1024) < len || image_offset == image_expected_size) {
        send_progress(image_offset);
    }

    return len;
}

static ssize_t ctrl_write_cb(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags)
{
    const uint8_t *cmd = buf;

    if (len < 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    switch (cmd[0]) {
    case IMG_CMD_START:
        if (len < 3) {
            return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
        }
        image_expected_size = cmd[1] | (cmd[2] << 8);
        if (image_expected_size > EPD_IMAGE_SIZE) {
            LOG_ERR("Invalid image size: %u (max %u)", image_expected_size, EPD_IMAGE_SIZE);
            send_error(IMG_ERR_INVALID_SIZE);
            return len;
        }
        image_offset = 0;
        transfer_active = true;
        memset(image_buffer, 0, sizeof(image_buffer));
        LOG_INF("Image transfer started, expecting %u bytes", image_expected_size);
        send_status(IMG_STATUS_READY);
        break;

    case IMG_CMD_COMMIT:
        if (!transfer_active) {
            send_error(IMG_ERR_NOT_STARTED);
            return len;
        }
        if (image_offset < image_expected_size) {
            LOG_WRN("Incomplete transfer: %u/%u bytes", image_offset, image_expected_size);
            send_error(IMG_ERR_INCOMPLETE);
            return len;
        }
        transfer_active = false;
        LOG_INF("Image transfer complete (%u bytes), displaying...", image_offset);
        send_status(IMG_STATUS_DISPLAYING);

        if (ready_callback) {
            ready_callback(image_buffer, image_offset);
        }
        break;

    case IMG_CMD_CANCEL:
        transfer_active = false;
        image_offset = 0;
        LOG_INF("Image transfer cancelled");
        break;

    case IMG_CMD_FIND:
        LOG_INF("Find-device command received: starting LED blink");
        send_status(IMG_STATUS_FINDING);
        if (find_callback) {
            find_callback();
        }
        break;

    default:
        LOG_WRN("Unknown control command: 0x%02x", cmd[0]);
        return BT_GATT_ERR(BT_ATT_ERR_NOT_SUPPORTED);
    }

    return len;
}

void ble_image_service_init(ble_image_ready_cb_t callback)
{
    ready_callback = callback;
    find_callback = NULL;
    transfer_active = false;
    image_offset = 0;
    LOG_INF("BLE Image Service initialized");
}

void ble_image_service_set_find_cb(ble_find_device_cb_t callback)
{
    find_callback = callback;
}

void ble_image_notify_display_done(void)
{
    send_status(IMG_STATUS_DONE);
    LOG_INF("Display done notification sent");
}
