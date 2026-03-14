/*
 * sx1301_softreset.c
 *
 * Performs a SPI soft reset of the SX1301 concentrator chip before
 * LoRa Basics Station starts. This is required on the Nebra Indoor Gen 1
 * after every power-up: without it, the SX1301 returns 0x03 on the version
 * register instead of the expected 0x67, causing the HAL to fail immediately
 * with "FAIL TO CONNECT BOARD".
 *
 * The fix is to write 0x80 (SOFT_RESET bit) to register 0x00, wait 200ms,
 * then verify the version register reads 0x67.
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
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>
#include <string.h>

#define SX1301_VERSION_EXPECTED  0x67
#define SPI_SPEED_HZ             1000000  /* 1 MHz */

static int spi_fd;

static int spi_transfer(uint8_t *tx, uint8_t *rx, size_t len) {
    struct spi_ioc_transfer tr = {
        .tx_buf        = (unsigned long)tx,
        .rx_buf        = (unsigned long)rx,
        .len           = len,
        .speed_hz      = SPI_SPEED_HZ,
        .bits_per_word = 8,
    };
    return ioctl(spi_fd, SPI_IOC_MESSAGE(1), &tr);
}

static void spi_write(uint8_t addr, uint8_t val) {
    uint8_t tx[2] = { addr | 0x80, val };
    uint8_t rx[2] = { 0, 0 };
    spi_transfer(tx, rx, 2);
}

static uint8_t spi_read(uint8_t addr) {
    uint8_t tx[2] = { addr & 0x7F, 0x00 };
    uint8_t rx[2] = { 0, 0 };
    spi_transfer(tx, rx, 2);
    return rx[1];
}

int main(int argc, char *argv[]) {
    const char *device = (argc > 1) ? argv[1] : "/dev/spidev1.2";
    uint8_t mode  = SPI_MODE_0;
    uint8_t bits  = 8;
    uint32_t speed = SPI_SPEED_HZ;
    uint8_t version;

    spi_fd = open(device, O_RDWR);
    if (spi_fd < 0) {
        fprintf(stderr, "sx1301_softreset: failed to open %s\n", device);
        return 1;
    }

    ioctl(spi_fd, SPI_IOC_WR_MODE,          &mode);
    ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &bits);
    ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ,  &speed);

    /* Write SOFT_RESET bit to register 0x00 */
    spi_write(0x00, 0x80);
    usleep(200000);  /* 200ms stabilisation */

    /* Verify version register */
    version = spi_read(0x01);
    if (version != SX1301_VERSION_EXPECTED) {
        fprintf(stderr,
            "sx1301_softreset: version register = 0x%02x (expected 0x%02x)\n",
            version, SX1301_VERSION_EXPECTED);
        close(spi_fd);
        return 1;
    }

    printf("After soft reset VERSION=0x%02x (expect 0x%02x)\n",
           version, SX1301_VERSION_EXPECTED);

    close(spi_fd);
    return 0;
}
