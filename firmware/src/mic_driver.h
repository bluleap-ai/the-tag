#ifndef MIC_DRIVER_H
#define MIC_DRIVER_H

#include <zephyr/types.h>
#include <stdbool.h>

/**
 * @brief Initialise the PDM microphone driver and LC3 encoder.
 *
 * Must be called before mic_driver_start().
 *
 * @return 0 on success, negative errno on failure.
 */
int mic_driver_init(void);

/**
 * @brief Start capturing audio and encoding to LC3.
 *
 * When audio data notifications are enabled on the BLE audio service,
 * this is called automatically.  It may also be triggered explicitly by
 * the AUDIO_CMD_START control command.
 *
 * Has no effect if the driver is already running.
 */
void mic_driver_start(void);

/**
 * @brief Stop capturing audio.
 *
 * Has no effect if the driver is not running.
 */
void mic_driver_stop(void);

/**
 * @brief Return true while audio capture is active.
 */
bool mic_driver_is_running(void);

#endif /* MIC_DRIVER_H */
