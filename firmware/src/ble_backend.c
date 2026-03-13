#include <zephyr/kernel.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>

#include "ble_image_service.h"
#include "mic_driver.h"

LOG_MODULE_REGISTER(ble_backend);

/* Work item to restart advertising from the system workqueue
 * (must not block the BT RX thread in the disconnected callback). */
static struct k_work adv_restart_work;

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, BLE_IMAGE_SERVICE_UUID),
};

static const struct bt_data sd[] = {
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
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

static void adv_restart_work_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	start_adv();
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

	/* Stop mic capture if still running (prevents resource leak) */
	mic_driver_stop();

	/* Defer advertising restart to the system workqueue so we do not
	 * block the BT RX thread – the stack needs to finish connection
	 * cleanup before bt_le_adv_start() can succeed. */
	k_work_submit(&adv_restart_work);
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

	k_work_init(&adv_restart_work, adv_restart_work_handler);
	bt_conn_auth_cb_register(&auth_cb_display);

	start_adv();
}