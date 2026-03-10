/*
 * Copyright (c) 2024 Kelvin
 * SPDX-License-Identifier: Apache-2.0
 *
 * Google Fast Pair Service over BLE.
 *
 * Implements the Google Fast Pair GATT service (service UUID 0xFE2C) and
 * account-key storage for Google Find My Device Network (GFDM) beacon support.
 *
 * Spec reference: https://developers.google.com/nearby/fast-pair/spec
 */

#ifndef FAST_PAIR_SERVICE_H
#define FAST_PAIR_SERVICE_H

#include <zephyr/types.h>
#include <stdbool.h>

/* Google Fast Pair Service UUID (16-bit, assigned by Bluetooth SIG to Google) */
#define BT_UUID_FAST_PAIR_VAL 0xFE2C

/*
 * Google Fast Pair Model ID (24-bit).
 *
 * This placeholder (0x000000) must be replaced with a real Model ID obtained
 * by registering your device at:
 *   https://developers.google.com/nearby/fast-pair/console
 */
#define FAST_PAIR_MODEL_ID 0x000000U

/*
 * Emit a build warning when the placeholder model ID is used so that it is
 * not accidentally shipped in a production firmware.
 */
#if FAST_PAIR_MODEL_ID == 0x000000U
#warning "FAST_PAIR_MODEL_ID is 0x000000 (placeholder). Register a real Model ID at https://developers.google.com/nearby/fast-pair/console before production use."
#endif

/* Account Key size per the Fast Pair spec (AES-128 key: 16 bytes). */
#define FAST_PAIR_ACCOUNT_KEY_SIZE 16

/* Maximum number of account keys to persist in NVS flash. */
#define FAST_PAIR_MAX_ACCOUNT_KEYS 5

/*
 * Length of the Fast Pair advertisement service data payload (bytes):
 *   - Unprovisioned mode: 3-byte model ID.
 *   - Provisioned mode  : 3-byte encrypted/rotated identifier.
 */
#define FAST_PAIR_ADV_SERVICE_DATA_LEN 3

/**
 * @brief Initialize the Google Fast Pair GATT service.
 *
 * Registers the settings handler so that previously stored account keys are
 * loaded from NVS flash when settings_load() is subsequently called inside
 * ble_backend_init().
 *
 * Must be called **before** ble_backend_init().
 */
void fast_pair_service_init(void);

/**
 * @brief Check whether at least one account key is stored.
 *
 * @return true  Device is provisioned (has an account key from a paired phone).
 * @return false Device is unprovisioned.
 */
bool fast_pair_has_account_keys(void);

/**
 * @brief Return the number of stored account keys.
 *
 * @return Count in range [0, FAST_PAIR_MAX_ACCOUNT_KEYS].
 */
uint8_t fast_pair_get_account_key_count(void);

/**
 * @brief Fill @p buf with the Fast Pair advertisement service data payload.
 *
 * When unprovisioned the payload is the 3-byte model ID.
 * When provisioned  the payload contains a beacon identifier derived from
 * the stored account keys (rotation counter used as seed; full AES-EAX
 * encryption requires CONFIG_TINYCRYPT_AES=y).
 *
 * @param buf  Output buffer. Must be at least FAST_PAIR_ADV_SERVICE_DATA_LEN.
 * @param len  Capacity of @p buf.
 * @return     Number of bytes written, or a negative error code.
 */
int fast_pair_get_adv_data(uint8_t *buf, size_t len);

#endif /* FAST_PAIR_SERVICE_H */
