#include <zephyr/kernel.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/logging/log.h>
#include <lc3.h>
#include <string.h>

#include "mic_driver.h"
#include "ble_audio_service.h"

LOG_MODULE_REGISTER(mic_driver, CONFIG_LOG_DEFAULT_LEVEL);

/* ------------------------------------------------------------------ */
/* Constants                                                            */
/* ------------------------------------------------------------------ */

#define MIC_PCM_BUF_SIZE  (AUDIO_PCM_SAMPLES_PER_FRAME * sizeof(int16_t)) /* 320 bytes */
#define MIC_SLAB_BLOCKS   16 /* enough runway while LC3 encoder runs */
#define MIC_THREAD_STACK_SIZE 4096

/* ------------------------------------------------------------------ */
/* Static storage                                                       */
/* ------------------------------------------------------------------ */

/* Memory slab used by the DMIC driver to deliver PCM blocks.
 * Alignment of 4 is minimum; nRF PDM DMA works with word-aligned buffers. */
K_MEM_SLAB_DEFINE_STATIC(mic_slab, MIC_PCM_BUF_SIZE, MIC_SLAB_BLOCKS, 4);

static const struct device *mic_dev;
static volatile bool running;
static uint16_t frame_seq;

/* LC3 encoder state */
static lc3_encoder_t lc3_encoder;
static lc3_encoder_mem_16k_t lc3_encoder_mem;
static uint8_t lc3_output_buf[AUDIO_FRAME_BYTES];

/* Capture thread */
static struct k_thread mic_thread;
K_THREAD_STACK_DEFINE(mic_thread_stack, MIC_THREAD_STACK_SIZE);

/* ------------------------------------------------------------------ */
/* Capture thread                                                       */
/* ------------------------------------------------------------------ */

static void mic_capture_thread(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    LOG_INF("Mic capture thread started");

    while (running) {
        void *pcm_buf = NULL;
        size_t pcm_size = MIC_PCM_BUF_SIZE;

        int err = dmic_read(mic_dev, 0, &pcm_buf, &pcm_size, 2000);
        if (err) {
            LOG_WRN("DMIC read error: %d", err);
            k_msleep(1);
            continue;
        }

        LOG_DBG("PCM read ok (%u bytes)", (unsigned)pcm_size);

        /* Encode one 10 ms frame of 16-bit mono PCM to LC3 */
        err = lc3_encode(lc3_encoder,
                         LC3_PCM_FORMAT_S16,
                         (const int16_t *)pcm_buf,
                         1 /* stride */,
                         AUDIO_FRAME_BYTES,
                         lc3_output_buf);
        if (err) {
            LOG_WRN("LC3 encode error: %d", err);
        } else {
            LOG_INF("Audio frame %u sent (%u bytes)", frame_seq, AUDIO_FRAME_BYTES);
            ble_audio_service_notify_frame(lc3_output_buf, AUDIO_FRAME_BYTES, frame_seq++);
        }

        k_mem_slab_free(&mic_slab, pcm_buf);
    }

    LOG_INF("Mic capture thread stopped");
}

/* ------------------------------------------------------------------ */
/* Public API                                                           */
/* ------------------------------------------------------------------ */

int mic_driver_init(void)
{
    mic_dev = DEVICE_DT_GET(DT_ALIAS(dmic0));
    if (!device_is_ready(mic_dev)) {
        LOG_ERR("DMIC device not ready");
        return -ENODEV;
    }

    lc3_encoder = lc3_setup_encoder(AUDIO_FRAME_DURATION_US,
                                    AUDIO_SAMPLE_RATE_HZ,
                                    AUDIO_SAMPLE_RATE_HZ,
                                    &lc3_encoder_mem);
    if (!lc3_encoder) {
        LOG_ERR("Failed to initialise LC3 encoder");
        return -ENOMEM;
    }

    running = false;
    frame_seq = 0;

    LOG_INF("Mic driver initialised (16 kHz, 10 ms frames, 32 kbps LC3)");
    return 0;
}

void mic_driver_start(void)
{
    if (running) {
        LOG_WRN("Mic driver already running");
        return;
    }

    struct pcm_stream_cfg streams[] = {
        {
            .pcm_rate  = AUDIO_SAMPLE_RATE_HZ,
            .pcm_width = 16,
            .block_size = MIC_PCM_BUF_SIZE,
            .mem_slab  = &mic_slab,
        },
    };

    struct dmic_cfg cfg = {
        .io = {
            .min_pdm_clk_freq = 1000000,
            .max_pdm_clk_freq = 3500000,
            .min_pdm_clk_dc   = 40,
            .max_pdm_clk_dc   = 60,
        },
        .streams = streams,
        .channel = {
            .req_num_streams = 1,
            .req_num_chan    = AUDIO_CHANNELS,
        },
    };

    int err = dmic_configure(mic_dev, &cfg);
    if (err) {
        LOG_ERR("DMIC configure failed: %d", err);
        return;
    }

    err = dmic_trigger(mic_dev, DMIC_TRIGGER_START);
    if (err) {
        LOG_ERR("DMIC trigger START failed: %d", err);
        return;
    }

    running = true;
    frame_seq = 0;

    k_thread_create(&mic_thread, mic_thread_stack,
                    K_THREAD_STACK_SIZEOF(mic_thread_stack),
                    mic_capture_thread, NULL, NULL, NULL,
                    K_PRIO_PREEMPT(2), K_FP_REGS, K_NO_WAIT);
    k_thread_name_set(&mic_thread, "mic_capture");

    LOG_INF("Microphone recording started");
}

void mic_driver_stop(void)
{
    if (!running) {
        return;
    }

    running = false;

    dmic_trigger(mic_dev, DMIC_TRIGGER_STOP);

    /* Wait for the capture thread to exit cleanly */
    k_thread_join(&mic_thread, K_SECONDS(2));

    LOG_INF("Microphone recording stopped");
}

bool mic_driver_is_running(void)
{
    return running;
}
