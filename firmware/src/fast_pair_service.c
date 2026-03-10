/*
 * Copyright (c) 2024 Kelvin
 * SPDX-License-Identifier: Apache-2.0
 *
 * Google Fast Pair GATT service implementation.
 *
 * Characteristics (all 128-bit UUIDs per the Fast Pair specification):
 *   Key-based Pairing : FE2C1234-8366-4814-8EB0-01DE32100BEA  (Write | Indicate)
 *   Passkey           : FE2C1235-8366-4814-8EB0-01DE32100BEA  (Write | Indicate)
 *   Account Key       : FE2C1236-8366-4814-8EB0-01DE32100BEA  (Write)
 *
 * Account keys are persisted using the Zephyr settings subsystem (NVS backend)
 * under the "fp/" namespace.
 *
 * NOTE: Full key-based pairing requires P-256 ECDH and AES-128 decryption
 * (enable CONFIG_TINYCRYPT_ECC_DH=y and CONFIG_TINYCRYPT_AES=y).  The write
 * handlers below are prepared for that extension; the crypto stubs can be
 * replaced once the tinyCrypt integration is in place.
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/settings/settings.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "fast_pair_service.h"

LOG_MODULE_REGISTER(fast_pair_svc, CONFIG_LOG_DEFAULT_LEVEL);

/* --------------------------------------------------------------------------
 * UUID definitions
 * -------------------------------------------------------------------------- */

/* Fast Pair service UUID: 0xFE2C (16-bit, assigned by BT SIG to Google) */
static struct bt_uuid_16 fp_svc_uuid = BT_UUID_INIT_16(BT_UUID_FAST_PAIR_VAL);

/*
 * 128-bit characteristic UUIDs.
 * BT_UUID_128_ENCODE generates bytes in little-endian order as required by
 * the Zephyr BLE stack.
 */
#define FP_KBP_CHAR_UUID \
	BT_UUID_128_ENCODE(0xFE2C1234, 0x8366, 0x4814, 0x8EB0, 0x01DE32100BEAULL)

#define FP_PASSKEY_CHAR_UUID \
	BT_UUID_128_ENCODE(0xFE2C1235, 0x8366, 0x4814, 0x8EB0, 0x01DE32100BEAULL)

#define FP_ACCOUNT_KEY_CHAR_UUID \
	BT_UUID_128_ENCODE(0xFE2C1236, 0x8366, 0x4814, 0x8EB0, 0x01DE32100BEAULL)

static struct bt_uuid_128 fp_kbp_char_uuid      = BT_UUID_INIT_128(FP_KBP_CHAR_UUID);
static struct bt_uuid_128 fp_passkey_char_uuid  = BT_UUID_INIT_128(FP_PASSKEY_CHAR_UUID);
static struct bt_uuid_128 fp_acct_key_char_uuid = BT_UUID_INIT_128(FP_ACCOUNT_KEY_CHAR_UUID);

/* --------------------------------------------------------------------------
 * Account key storage
 * -------------------------------------------------------------------------- */

static uint8_t account_keys[FAST_PAIR_MAX_ACCOUNT_KEYS][FAST_PAIR_ACCOUNT_KEY_SIZE];
static uint8_t account_key_count;

/* Beacon rotation counter — incremented on each boot; used as GFDM seed. */
static uint32_t beacon_rotation_counter;

/* --------------------------------------------------------------------------
 * Zephyr settings handler
 * -------------------------------------------------------------------------- */

static int fp_settings_set(const char *name, size_t len,
			    settings_read_cb read_cb, void *cb_arg)
{
	const char *next;
	int rc;

	if (settings_name_steq(name, "akc", &next) && !next) {
		if (len != sizeof(account_key_count)) {
			return -EINVAL;
		}
		rc = read_cb(cb_arg, &account_key_count, sizeof(account_key_count));
		if (rc < 0) {
			return rc;
		}
		if (account_key_count > FAST_PAIR_MAX_ACCOUNT_KEYS) {
			account_key_count = FAST_PAIR_MAX_ACCOUNT_KEYS;
		}
		LOG_INF("Fast Pair: loaded key count %u", account_key_count);
		return 0;
	}

	if (settings_name_steq(name, "rot", &next) && !next) {
		if (len != sizeof(beacon_rotation_counter)) {
			return -EINVAL;
		}
		rc = read_cb(cb_arg, &beacon_rotation_counter, sizeof(beacon_rotation_counter));
		if (rc < 0) {
			return rc;
		}
		beacon_rotation_counter++;
		return settings_save_one("fp/rot", &beacon_rotation_counter,
					 sizeof(beacon_rotation_counter));
	}

	if (settings_name_steq(name, "ak", &next) && next) {
		/* Key index is the first character after "ak/" */
		if (next[0] < '0' || next[0] > '9') {
			return -EINVAL;
		}
		long idx = next[0] - '0';

		if (idx < 0 || idx >= FAST_PAIR_MAX_ACCOUNT_KEYS ||
		    len != FAST_PAIR_ACCOUNT_KEY_SIZE) {
			return -EINVAL;
		}
		rc = read_cb(cb_arg, account_keys[idx], FAST_PAIR_ACCOUNT_KEY_SIZE);
		if (rc < 0) {
			return rc;
		}
		LOG_INF("Fast Pair: loaded account key slot %ld", idx);
		return 0;
	}

	return -ENOENT;
}

static struct settings_handler fp_settings_handler = {
	.name  = "fp",
	.h_set = fp_settings_set,
};

/* --------------------------------------------------------------------------
 * Internal helpers for persisting account keys
 * -------------------------------------------------------------------------- */

static int fp_save_account_key(uint8_t idx, const uint8_t *key)
{
	char path[12]; /* "fp/ak/0" + NUL */

	snprintf(path, sizeof(path), "fp/ak/%u", idx);
	return settings_save_one(path, key, FAST_PAIR_ACCOUNT_KEY_SIZE);
}

static int fp_save_key_count(void)
{
	return settings_save_one("fp/akc", &account_key_count,
				 sizeof(account_key_count));
}

/* --------------------------------------------------------------------------
 * GATT characteristic callbacks
 * -------------------------------------------------------------------------- */

/* Key-based Pairing write handler (Write + Indicate) */
static ssize_t fp_kbp_write(struct bt_conn *conn,
			     const struct bt_gatt_attr *attr,
			     const void *buf, uint16_t len,
			     uint16_t offset, uint8_t flags)
{
	LOG_INF("Fast Pair: Key-based pairing request received (%u bytes)", len);

	/*
	 * Full implementation steps (requires CONFIG_TINYCRYPT_ECC_DH + AES):
	 *  1. Decrypt the 16-byte encrypted request with the device's ECDH
	 *     private key (P-256 shared secret as AES-128 key).
	 *  2. Verify request type byte (0x00 = key-based pairing request).
	 *  3. Generate a 128-bit anti-spoofing key and encrypt the response.
	 *  4. Indicate with the 16-byte encrypted response.
	 *
	 * For now the pairing handshake is logged for diagnostic purposes.
	 */

	return len;
}

static void fp_kbp_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	LOG_INF("Fast Pair: KBP indications %s",
		value == BT_GATT_CCC_INDICATE ? "enabled" : "disabled");
}

/* Passkey write handler (Write + Indicate) */
static ssize_t fp_passkey_write(struct bt_conn *conn,
				const struct bt_gatt_attr *attr,
				const void *buf, uint16_t len,
				uint16_t offset, uint8_t flags)
{
	LOG_INF("Fast Pair: Passkey write received (%u bytes)", len);

	/*
	 * Full implementation steps:
	 *  1. Decrypt passkey using the session key (derived from ECDH secret).
	 *  2. Compare with the locally generated/displayed passkey.
	 *  3. Indicate with the encrypted passkey if it matches.
	 */

	return len;
}

static void fp_passkey_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	LOG_INF("Fast Pair: Passkey indications %s",
		value == BT_GATT_CCC_INDICATE ? "enabled" : "disabled");
}

/*
 * Account Key write handler (Write only).
 *
 * Called by a paired Android phone to write a 16-byte AES-128 account key.
 * Keys are stored in NVS flash. If the key already exists it is not
 * duplicated. If all slots are full, the oldest key is replaced (FIFO).
 */
static ssize_t fp_account_key_write(struct bt_conn *conn,
				    const struct bt_gatt_attr *attr,
				    const void *buf, uint16_t len,
				    uint16_t offset, uint8_t flags)
{
	const uint8_t *new_key = (const uint8_t *)buf;
	uint8_t slot;

	if (len != FAST_PAIR_ACCOUNT_KEY_SIZE) {
		LOG_ERR("Fast Pair: invalid account key length %u (expected %u)",
			len, FAST_PAIR_ACCOUNT_KEY_SIZE);
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
	}

	/* Do not store duplicate keys. */
	for (uint8_t i = 0; i < account_key_count; i++) {
		if (memcmp(account_keys[i], new_key, FAST_PAIR_ACCOUNT_KEY_SIZE) == 0) {
			LOG_INF("Fast Pair: account key already stored in slot %u", i);
			return len;
		}
	}

	if (account_key_count < FAST_PAIR_MAX_ACCOUNT_KEYS) {
		slot = account_key_count;
		account_key_count++;
	} else {
		/* All slots full: evict oldest key (shift array, new key at end). */
		memmove(account_keys[0], account_keys[1],
			(FAST_PAIR_MAX_ACCOUNT_KEYS - 1) * FAST_PAIR_ACCOUNT_KEY_SIZE);
		slot = FAST_PAIR_MAX_ACCOUNT_KEYS - 1;
	}

	memcpy(account_keys[slot], new_key, FAST_PAIR_ACCOUNT_KEY_SIZE);

	fp_save_account_key(slot, new_key);
	fp_save_key_count();

	LOG_INF("Fast Pair: stored account key in slot %u (total: %u)",
		slot, account_key_count);

	return len;
}

/* --------------------------------------------------------------------------
 * GATT service definition
 * -------------------------------------------------------------------------- */

BT_GATT_SERVICE_DEFINE(fast_pair_svc,
	BT_GATT_PRIMARY_SERVICE(&fp_svc_uuid),

	/* Key-based Pairing: Write + Indicate */
	BT_GATT_CHARACTERISTIC(&fp_kbp_char_uuid.uuid,
			       BT_GATT_CHRC_WRITE | BT_GATT_CHRC_INDICATE,
			       BT_GATT_PERM_WRITE,
			       NULL, fp_kbp_write, NULL),
	BT_GATT_CCC(fp_kbp_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),

	/* Passkey: Write + Indicate */
	BT_GATT_CHARACTERISTIC(&fp_passkey_char_uuid.uuid,
			       BT_GATT_CHRC_WRITE | BT_GATT_CHRC_INDICATE,
			       BT_GATT_PERM_WRITE,
			       NULL, fp_passkey_write, NULL),
	BT_GATT_CCC(fp_passkey_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),

	/* Account Key: Write only */
	BT_GATT_CHARACTERISTIC(&fp_acct_key_char_uuid.uuid,
			       BT_GATT_CHRC_WRITE,
			       BT_GATT_PERM_WRITE,
			       NULL, fp_account_key_write, NULL),
);

/* --------------------------------------------------------------------------
 * Public API
 * -------------------------------------------------------------------------- */

bool fast_pair_has_account_keys(void)
{
	return account_key_count > 0;
}

uint8_t fast_pair_get_account_key_count(void)
{
	return account_key_count;
}

int fast_pair_get_adv_data(uint8_t *buf, size_t len)
{
	if (len < FAST_PAIR_ADV_SERVICE_DATA_LEN) {
		return -ENOMEM;
	}

	if (account_key_count == 0) {
		/*
		 * Unprovisioned mode: broadcast the 24-bit model ID.
		 * Android phones with Google Play Services will recognise this
		 * and display a Fast Pair prompt when in proximity.
		 */
		buf[0] = (FAST_PAIR_MODEL_ID >> 16) & 0xFF;
		buf[1] = (FAST_PAIR_MODEL_ID >>  8) & 0xFF;
		buf[2] =  FAST_PAIR_MODEL_ID        & 0xFF;
	} else {
		/*
		 * Provisioned / GFDM beacon mode.
		 *
		 * The rotation counter acts as a beacon identifier seed.
		 * A complete GFDM implementation should use AES-EAX to encrypt
		 * a 20-byte value derived from the account key + counter (see
		 * Fast Pair spec §3.1.2).  Requires CONFIG_TINYCRYPT_AES=y.
		 */
		buf[0] = (beacon_rotation_counter >> 16) & 0xFF;
		buf[1] = (beacon_rotation_counter >>  8) & 0xFF;
		buf[2] =  beacon_rotation_counter        & 0xFF;
	}

	return FAST_PAIR_ADV_SERVICE_DATA_LEN;
}

void fast_pair_service_init(void)
{
	int err;

	account_key_count      = 0;
	beacon_rotation_counter = 0;
	memset(account_keys, 0, sizeof(account_keys));

	/*
	 * Register the settings handler so that stored account keys are loaded
	 * when settings_load() is called later in ble_backend_init().
	 */
	err = settings_register(&fp_settings_handler);
	if (err) {
		LOG_ERR("Fast Pair: failed to register settings handler (err %d)", err);
		return;
	}

	LOG_INF("Fast Pair: service initialized (model ID: 0x%06X)", FAST_PAIR_MODEL_ID);
}
