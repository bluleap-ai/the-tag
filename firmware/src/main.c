/*
 * Copyright (c) 2024 Kelvin
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/device.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>

#include "ble_backend.h"
#include "ble_image_service.h"
#include "ble_audio_service.h"
#include "mic_driver.h"
#include "image_boaviet.h"

LOG_MODULE_REGISTER(main, CONFIG_LOG_DEFAULT_LEVEL);

#define EPD_WIDTH 152
#define EPD_HEIGHT 152
#define BUFFER_SIZE (EPD_WIDTH * EPD_HEIGHT / 4)

/* GPIO pins */
#define DC_NODE    DT_NODELABEL(gpio1)
#define RESET_NODE DT_NODELABEL(gpio1)
#define BUSY_NODE  DT_NODELABEL(gpio1)
#define CS_NODE    DT_NODELABEL(gpio1)

#define DC_PIN     7   // P1.07 (D3)
#define RESET_PIN  4   // P1.04 (D0)
#define BUSY_PIN   11  // P1.11 (D5)
#define CS_PIN     5   // P1.05 (D1)

/* LED */
#define LED0_NODE DT_ALIAS(led0)

static struct gpio_dt_spec dc_gpio;
static struct gpio_dt_spec reset_gpio;
static struct gpio_dt_spec busy_gpio;
static struct gpio_dt_spec cs_gpio;
static struct gpio_dt_spec led = GPIO_DT_SPEC_GET(LED0_NODE, gpios);

static const struct device *spi_dev;
static struct spi_config spi_cfg;

static uint8_t frame_buffer[BUFFER_SIZE];

static K_SEM_DEFINE(image_ready_sem, 0, 1);
static const uint8_t *pending_image_data;
static uint16_t pending_image_size;

static void on_ble_image_ready(const uint8_t *data, uint16_t size)
{
    pending_image_data = data;
    pending_image_size = size;
    k_sem_give(&image_ready_sem);
}

/* Helper functions */
static void jd79661_write_cmd(uint8_t cmd)
{
    struct spi_buf tx_buf = {.buf = &cmd, .len = 1};
    struct spi_buf_set tx_bufs = {.buffers = &tx_buf, .count = 1};
    
    gpio_pin_set_dt(&cs_gpio, 1);  // CS active (low)
    gpio_pin_set_dt(&dc_gpio, 0);  // Command mode
    spi_write(spi_dev, &spi_cfg, &tx_bufs);
    gpio_pin_set_dt(&cs_gpio, 0);  // CS inactive (high)
}

static void jd79661_write_data(uint8_t data)
{
    struct spi_buf tx_buf = {.buf = &data, .len = 1};
    struct spi_buf_set tx_bufs = {.buffers = &tx_buf, .count = 1};
    
    gpio_pin_set_dt(&cs_gpio, 1);  // CS active (low)
    gpio_pin_set_dt(&dc_gpio, 1);  // Data mode
    spi_write(spi_dev, &spi_cfg, &tx_bufs);
    gpio_pin_set_dt(&cs_gpio, 0);  // CS inactive (high)
}

static void jd79661_write_data_bulk(const uint8_t *data, size_t len)
{
    gpio_pin_set_dt(&cs_gpio, 1);  // CS active (low)
    gpio_pin_set_dt(&dc_gpio, 1);  // Data mode
    
    // Write in chunks
    const size_t chunk_size = 256;
    for (size_t i = 0; i < len; i += chunk_size) {
        size_t remaining = len - i;
        size_t write_len = (remaining < chunk_size) ? remaining : chunk_size;
        
        struct spi_buf tx_buf = {.buf = (void *)(data + i), .len = write_len};
        struct spi_buf_set tx_bufs = {.buffers = &tx_buf, .count = 1};
        spi_write(spi_dev, &spi_cfg, &tx_bufs);
    }
    
    gpio_pin_set_dt(&cs_gpio, 0);  // CS inactive (high)
}

static void jd79661_wait_busy(void)
{
    int cnt = 0;
    /* BUSY=0 means busy, BUSY=1 means idle */
    LOG_INF("Waiting for busy (initial: %d)...", gpio_pin_get_dt(&busy_gpio));
    while (gpio_pin_get_dt(&busy_gpio) == 0) {
        k_msleep(10);
        cnt++;
        if (cnt > 500) { // 5s timeout
            LOG_ERR("Busy timeout!");
            break;
        }
    }
    LOG_INF("Busy released");
}

static void jd79661_reset(void)
{
    k_msleep(20);
    gpio_pin_set_dt(&reset_gpio, 0);  // Reset low
    k_msleep(40);
    gpio_pin_set_dt(&reset_gpio, 1);  // Reset high
    k_msleep(50);
}

static int jd79661_init(void)
{
    LOG_INF("Initializing JD79661...");
    
    jd79661_reset();
    jd79661_wait_busy();
    
    // Initialization sequence from STM32 sample code
    jd79661_write_cmd(0x4D);
    jd79661_write_data(0x78);
    k_usleep(100);
    
    jd79661_write_cmd(0x00);  // PSR
    jd79661_write_data(0x0F);
    jd79661_write_data(0x29);
    k_usleep(100);
    
    jd79661_write_cmd(0x01);  // PWRR
    jd79661_write_data(0x07);
    jd79661_write_data(0x00);
    k_usleep(100);
    
    jd79661_write_cmd(0x03);  // POFS
    jd79661_write_data(0x10);
    jd79661_write_data(0x54);
    jd79661_write_data(0x44);
    k_usleep(100);
    
    jd79661_write_cmd(0x06);  // BTST_P
    jd79661_write_data(0x05);
    jd79661_write_data(0x00);
    jd79661_write_data(0x3F);
    jd79661_write_data(0x0A);
    jd79661_write_data(0x25);
    jd79661_write_data(0x12);
    jd79661_write_data(0x1A);
    k_usleep(100);
    
    jd79661_write_cmd(0x50);  // CDI
    jd79661_write_data(0x37);
    k_usleep(100);
    
    jd79661_write_cmd(0x60);  // TCON
    jd79661_write_data(0x02);
    jd79661_write_data(0x02);
    k_usleep(100);
    
    jd79661_write_cmd(0x61);  // TRES
    jd79661_write_data(EPD_WIDTH / 256);
    jd79661_write_data(EPD_WIDTH % 256);
    jd79661_write_data(EPD_HEIGHT / 256);
    jd79661_write_data(EPD_HEIGHT % 256);
    k_usleep(100);
    
    jd79661_write_cmd(0xE7);
    jd79661_write_data(0x1C);
    k_usleep(100);
    
    jd79661_write_cmd(0xE3);
    jd79661_write_data(0x22);
    k_usleep(100);
    
    jd79661_write_cmd(0xB4);
    jd79661_write_data(0xD0);
    k_usleep(100);
    
    jd79661_write_cmd(0xB5);
    jd79661_write_data(0x03);
    k_usleep(100);
    
    jd79661_write_cmd(0xE9);
    jd79661_write_data(0x01);
    k_usleep(100);
    
    jd79661_write_cmd(0x30);
    jd79661_write_data(0x08);
    k_usleep(100);
    
    jd79661_write_cmd(0x04);  // Power on
    jd79661_wait_busy();
    
    LOG_INF("JD79661 initialized");
    return 0;
}

static void jd79661_display_frame(const uint8_t *buffer, size_t size)
{
    LOG_INF("Sending framebuffer (%d bytes)...", size);
    
    jd79661_write_cmd(0x10);  // Write data
    jd79661_write_data_bulk(buffer, size);
    
    LOG_INF("Refreshing display...");
    jd79661_write_cmd(0x12);  // Display refresh
    jd79661_write_data(0x00);
    jd79661_wait_busy();
    
    LOG_INF("Display update complete");
}

int main(void)
{
    int ret;
    
    LOG_INF("=== The-Tag Firmware ===");
    
    ble_backend_init();
    ble_image_service_init(on_ble_image_ready);
    ble_audio_service_init();

    int mic_err = mic_driver_init();
    if (mic_err) {
        LOG_WRN("Mic driver init failed (%d) – audio streaming unavailable", mic_err);
    }

    /* LED Init */
    if (!gpio_is_ready_dt(&led)) {
        LOG_ERR("LED GPIO not ready");
        return -ENODEV;
    }
    gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);
    
    /* SPI Init */
    spi_dev = DEVICE_DT_GET(DT_NODELABEL(spi00));
    if (!device_is_ready(spi_dev)) {
        LOG_ERR("SPI device not ready");
        return -ENODEV;
    }
    
    spi_cfg.frequency = 4000000;  // 4 MHz
    spi_cfg.operation = SPI_WORD_SET(8) | SPI_TRANSFER_MSB | SPI_OP_MODE_MASTER;
    spi_cfg.slave = 0;
    spi_cfg.cs = (struct spi_cs_control) {
        .gpio = {0},  // No auto CS
        .delay = 0,
    };
    
    /* GPIO Init */
    dc_gpio.port = DEVICE_DT_GET(DC_NODE);
    dc_gpio.pin = DC_PIN;
    dc_gpio.dt_flags = GPIO_ACTIVE_HIGH;
    
    reset_gpio.port = DEVICE_DT_GET(RESET_NODE);
    reset_gpio.pin = RESET_PIN;
    reset_gpio.dt_flags = GPIO_ACTIVE_HIGH;
    
    busy_gpio.port = DEVICE_DT_GET(BUSY_NODE);
    busy_gpio.pin = BUSY_PIN;
    busy_gpio.dt_flags = GPIO_ACTIVE_HIGH;
    
    cs_gpio.port = DEVICE_DT_GET(CS_NODE);
    cs_gpio.pin = CS_PIN;
    cs_gpio.dt_flags = GPIO_ACTIVE_LOW;
    
    if (!device_is_ready(dc_gpio.port)) {
        LOG_ERR("GPIO not ready");
        return -ENODEV;
    }
    
    ret = gpio_pin_configure_dt(&dc_gpio, GPIO_OUTPUT_INACTIVE);
    ret |= gpio_pin_configure_dt(&reset_gpio, GPIO_OUTPUT_ACTIVE);
    ret |= gpio_pin_configure_dt(&busy_gpio, GPIO_INPUT);
    ret |= gpio_pin_configure_dt(&cs_gpio, GPIO_OUTPUT_INACTIVE);
    
    if (ret < 0) {
        LOG_ERR("Failed to configure GPIO: %d", ret);
        return ret;
    }
    
    LOG_INF("GPIO configured");
    
    /* Initialize Display */
    ret = jd79661_init();
    if (ret < 0) {
        LOG_ERR("Failed to init display");
        return ret;
    }
    
    /* Display default image on boot */
    LOG_INF("Loading default image (%u bytes)...", BUFFER_SIZE);
    memcpy(frame_buffer, image_image_boaviet, BUFFER_SIZE);
    jd79661_display_frame(frame_buffer, sizeof(frame_buffer));
    LOG_INF("Default image displayed. Waiting for BLE images...");

    while (1) {
        if (k_sem_take(&image_ready_sem, K_MSEC(500)) == 0) {
            LOG_INF("BLE image received (%u bytes), updating display...", pending_image_size);
            memcpy(frame_buffer, pending_image_data, pending_image_size);
            jd79661_display_frame(frame_buffer, sizeof(frame_buffer));
            ble_image_notify_display_done();
            LOG_INF("BLE image displayed successfully");
        }
        gpio_pin_toggle_dt(&led);
    }

    return 0;
}
