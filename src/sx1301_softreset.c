/*
 * sx1301_softreset.c
 *
 * Performs a hardware reset of the SX1301 concentrator on the
 * Nebra Indoor Gen 1 by pulsing GPIO 38 (LORA_RS1, active low).
 *
 * GPIO 38 is the dedicated hardware reset line for the SX1301 on this board,
 * confirmed from the Nebra firmware hardware definitions (NEBHNT-IN1 RESET: 38).
 *
 * After the GPIO pulse the SX1301 version register is verified via SPI
 * to confirm the chip initialised correctly (should return 0x67).
 *
 * Usage: ./sx1301_softreset [spi_device]
 *   spi_device defaults to /dev/spidev1.2 (Nebra Indoor Gen 1)
 *
 * Returns 0 on success, 1 on failure.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/gpio.h>
#include <linux/spi/spidev.h>

#define GPIO_CHIP               "/dev/gpiochip0"
#define RESET_PIN               38
#define SPI_SPEED_HZ            1000000
#define SX1301_VERSION_EXPECTED 0x67

/* ---- GPIO reset ---------------------------------------------------------- */
static int gpio_pulse_reset(void) {
    int chip_fd, ret;
    struct gpio_v2_line_request req = {0};
    struct gpio_v2_line_values vals = {0};

    chip_fd = open(GPIO_CHIP, O_RDONLY);
    if (chip_fd < 0) { perror("open gpiochip0"); return -1; }

    req.num_lines    = 1;
    req.offsets[0]   = RESET_PIN;
    req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
    strncpy(req.consumer, "sx1301-reset", sizeof(req.consumer) - 1);

    ret = ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &req);
    close(chip_fd);
    if (ret < 0) { perror("GPIO_V2_GET_LINE_IOCTL"); return -1; }

    vals.mask = 1;

    /* Assert reset LOW */
    vals.bits = 0;
    ioctl(req.fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals);
    usleep(100000);

    /* Release HIGH */
    vals.bits = 1;
    ioctl(req.fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals);
    usleep(100000);

    /* Back to LOW */
    vals.bits = 0;
    ioctl(req.fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals);
    usleep(500000);  /* 500ms stabilise */

    close(req.fd);
    return 0;
}

/* ---- SPI verify ---------------------------------------------------------- */
static uint8_t verify_sx1301(const char *device) {
    int fd;
    uint8_t mode = SPI_MODE_0, bits = 8;
    uint32_t speed = SPI_SPEED_HZ;
    uint8_t tx[2] = { 0x01 & 0x7F, 0x00 };
    uint8_t rx[2] = { 0, 0 };
    struct spi_ioc_transfer tr = {
        .tx_buf        = (unsigned long)tx,
        .rx_buf        = (unsigned long)rx,
        .len           = 2,
        .speed_hz      = SPI_SPEED_HZ,
        .bits_per_word = 8,
    };

    fd = open(device, O_RDWR);
    if (fd < 0) { perror("open spi"); return 0; }

    ioctl(fd, SPI_IOC_WR_MODE,          &mode);
    ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits);
    ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ,  &speed);
    ioctl(fd, SPI_IOC_MESSAGE(1), &tr);
    close(fd);

    return rx[1];
}

/* ---- Main ---------------------------------------------------------------- */
int main(int argc, char *argv[]) {
    const char *device = (argc > 1) ? argv[1] : "/dev/spidev1.2";
    uint8_t version;

    printf("Pulsing hardware reset on GPIO %d...\n", RESET_PIN);
    if (gpio_pulse_reset() < 0) {
        fprintf(stderr, "sx1301_softreset: GPIO reset failed\n");
        return 1;
    }

    version = verify_sx1301(device);
    if (version != SX1301_VERSION_EXPECTED) {
        fprintf(stderr,
            "sx1301_softreset: version = 0x%02x (expected 0x%02x)\n",
            version, SX1301_VERSION_EXPECTED);
        return 1;
    }

    printf("After reset VERSION=0x%02x (expect 0x%02x)\n",
           version, SX1301_VERSION_EXPECTED);
    return 0;
}
