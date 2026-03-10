/*
 * Copyright (c) 2024 Kelvin
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef FIND_MY_H
#define FIND_MY_H

#include <stdint.h>

/**
 * @file find_my.h
 * @brief Apple Find My (OpenHaystack) Offline Finding advertisement support.
 *
 * This module implements the OpenHaystack Offline Finding protocol, which
 * allows the device to be tracked via Apple's Find My network without any
 * Apple SDK.  It broadcasts a non-connectable BLE advertisement containing
 * an Apple manufacturer-specific payload that Apple devices silently relay
 * to Apple's servers.
 *
 * Protocol reference: https://github.com/seemoo-lab/openhaystack
 *
 * Key provisioning
 * ----------------
 * A real deployment requires a unique EC P-224 key pair generated with the
 * OpenHaystack desktop application.  The *compressed* 28-byte public key is
 * passed to find_my_init().  A demonstration placeholder key is provided in
 * find_my.c and selected by CONFIG_FIND_MY_DEMO_KEY.
 *
 * The device derives:
 *   - Its BLE random-static address from the first 6 bytes of the public key.
 *   - The advertisement payload from the remaining bytes.
 *
 * Key rotation
 * ------------
 * Apple's specification requires rotating the key pair every 15 minutes to
 * preserve user privacy.  For a production firmware, store multiple pre-
 * generated key pairs in flash and call find_my_rotate_key() on a timer.
 */

/** Size of a compressed EC P-224 public key used by Apple Find My. */
#define FIND_MY_PUBLIC_KEY_SIZE 28

/**
 * @brief Initialise the Apple Find My module.
 *
 * Must be called after bt_enable().  Derives the BLE identity address and
 * advertisement payload from @p public_key, then creates a dedicated
 * non-connectable extended advertising set.
 *
 * @param public_key  28-byte compressed EC P-224 public key.
 * @return 0 on success, negative errno on failure.
 */
int find_my_init(const uint8_t public_key[FIND_MY_PUBLIC_KEY_SIZE]);

/**
 * @brief Start Apple Find My advertising.
 *
 * The device will appear in the Apple Find My app once a nearby Apple device
 * picks up the advertisement and uploads the encrypted location report.
 *
 * @return 0 on success, negative errno on failure.
 */
int find_my_start(void);

/**
 * @brief Stop Apple Find My advertising.
 * @return 0 on success, negative errno on failure.
 */
int find_my_stop(void);

/**
 * @brief Rotate the public key used for Find My advertising.
 *
 * Stops the current advertising set, replaces the public key and derived
 * address, then restarts advertising.  Call every ~15 minutes in a production
 * firmware to satisfy Apple's privacy rotation requirements.
 *
 * @param public_key  New 28-byte compressed EC P-224 public key.
 * @return 0 on success, negative errno on failure.
 */
int find_my_rotate_key(const uint8_t public_key[FIND_MY_PUBLIC_KEY_SIZE]);

#endif /* FIND_MY_H */
