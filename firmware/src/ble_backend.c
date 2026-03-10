#include <zephyr/kernel.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>

#include "ble_image_service.h"
#include "fast_pair_service.h"

LOG_MODULE_REGISTER(ble_backend);

/*
 * Advertisement data (31-byte limit):
 *   - BT flags                   : 3 bytes
 *   - Fast Pair service data 16  : 7 bytes  (UUID 0xFE2C + 3-byte model ID)
 *
 * The image-service UUID128 and device name live in the scan response so that
 * the advertisement packet stays small enough to also carry Fast Pair data.
 *
 * Fast Pair service data format (per Google Fast Pair spec §2.1):
 *   Byte 0-1 : Service UUID 0xFE2C in little-endian
 *   Byte 2-4 : 24-bit Model ID (big-endian) when unprovisioned,
 *              or beacon identifier when provisioned (GFDM mode)
 */
static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	/* Fast Pair service data: UUID 0xFE2C (LE) followed by model ID */
	BT_DATA_BYTES(BT_DATA_SVC_DATA16,
		      0x2C, 0xFE,                           /* UUID 0xFE2C */
		      (FAST_PAIR_MODEL_ID >> 16) & 0xFF,    /* Model ID byte 2 */
		      (FAST_PAIR_MODEL_ID >>  8) & 0xFF,    /* Model ID byte 1 */
		       FAST_PAIR_MODEL_ID        & 0xFF),   /* Model ID byte 0 */
};

/*
 * Scan response data:
 *   - Device name          : carries "the-tag" so the app can scan by name
 *   - Image service UUID128: allows UUID-based scanning as a fallback
 */
static const struct bt_data sd[] = {
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME,
		sizeof(CONFIG_BT_DEVICE_NAME) - 1),
	BT_DATA_BYTES(BT_DATA_UUID128_SOME, BLE_IMAGE_SERVICE_UUID),
};

static void start_adv(void)
{
	int err;

	err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_1, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
	if (err) {
		LOG_ERR("Advertising failed to start (err %d)", err);
		return;
	}

	LOG_INF("Advertising successfully started");
}

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		LOG_ERR("Connection failed, err 0x%02x %s", err, bt_hci_err_to_str(err));
	} else {
		LOG_INF("Connected");
	}
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	LOG_INF("Disconnected, reason 0x%02x %s", reason, bt_hci_err_to_str(reason));
	start_adv();
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = connected,
	.disconnected = disconnected,
};

static void auth_cancel(struct bt_conn *conn)
{
	char addr[BT_ADDR_LE_STR_LEN];

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	LOG_INF("Pairing cancelled: %s", addr);
}

static struct bt_conn_auth_cb auth_cb_display = {
	.cancel = auth_cancel,
};

void backend_ble_hook(bool status, void *ctx)
{
	ARG_UNUSED(ctx);

	if (status) {
		LOG_INF("Bluetooth Logger Backend enabled.");
	} else {
		LOG_INF("Bluetooth Logger Backend disabled.");
	}
}

void ble_backend_init(void)
{
	int err;

	LOG_INF("Bluetooth LOG Demo");
	// logger_backend_ble_set_hook(backend_ble_hook, NULL);
	err = bt_enable(NULL);
	if (err) {
		LOG_ERR("Bluetooth init failed (err %d)", err);
		return;
	}
	
	settings_load();
	
	bt_conn_auth_cb_register(&auth_cb_display);

	start_adv();
}