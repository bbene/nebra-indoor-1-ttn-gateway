#!/usr/bin/env python3
"""
Nebra Indoor Gen 1 — TTN/ChirpStack Basics Station launcher

GPIO behaviour:
  LED  (GPIO 25): blink slow during startup, solid when running, fast blink on error
  Button (GPIO 26): hold 3 seconds to restart Station cleanly
  Reset  (GPIO 38): active-low pulse to hardware-reset the SX1301
"""

import gpiod
import time
import subprocess
import threading
import sys
import os
import signal

from gpiod.line_settings import LineSettings, Direction, Bias, Value, Edge

# ---- Config -----------------------------------------------------------------
LED_PIN    = 25
BUTTON_PIN = 26
RESET_PIN  = 38

STATION_BIN  = "/home/ben/basicstation/build-rpi-std/bin/station"
STATION_HOME = "/opt/ttn-station"
SPI_DEVICE   = "/dev/spidev1.2"
SPI_SPEED    = "1000000"

BUTTON_HOLD_SECS = 3   # hold duration to trigger restart
DEBOUNCE_SECS    = 0.05

# ---- State ------------------------------------------------------------------
station_proc  = None
led_mode      = "startup"   # startup | running | error | restarting
stop_event    = threading.Event()

# ---- LED controller ---------------------------------------------------------
def led_thread(chip_path):
    """Drives the status LED based on led_mode."""
    with gpiod.request_lines(chip_path, consumer="nebra-led",
            config={LED_PIN: LineSettings(direction=Direction.OUTPUT)}) as led:
        while not stop_event.is_set():
            mode = led_mode
            if mode == "startup":
                # Slow blink — 1 Hz
                led.set_value(LED_PIN, Value.ACTIVE)
                time.sleep(0.5)
                led.set_value(LED_PIN, Value.INACTIVE)
                time.sleep(0.5)
            elif mode == "running":
                # Solid on
                led.set_value(LED_PIN, Value.ACTIVE)
                time.sleep(0.1)
            elif mode == "error":
                # Fast blink — 4 Hz
                led.set_value(LED_PIN, Value.ACTIVE)
                time.sleep(0.125)
                led.set_value(LED_PIN, Value.INACTIVE)
                time.sleep(0.125)
            elif mode == "restarting":
                # Double blink
                for _ in range(2):
                    led.set_value(LED_PIN, Value.ACTIVE)
                    time.sleep(0.1)
                    led.set_value(LED_PIN, Value.INACTIVE)
                    time.sleep(0.1)
                time.sleep(0.5)
            else:
                led.set_value(LED_PIN, Value.INACTIVE)
                time.sleep(0.1)
        # Turn off LED on exit
        led.set_value(LED_PIN, Value.INACTIVE)

# ---- Button monitor ---------------------------------------------------------
def button_thread(chip_path):
    """Monitors the button — hold BUTTON_HOLD_SECS to restart Station."""
    global led_mode, station_proc
    with gpiod.request_lines(chip_path, consumer="nebra-button",
            config={BUTTON_PIN: LineSettings(
                direction=Direction.INPUT,
                bias=Bias.PULL_UP
            )}) as btn:
        press_start = None
        while not stop_event.is_set():
            val = btn.get_value(BUTTON_PIN)
            if val == Value.INACTIVE:  # PULL_UP: INACTIVE = button pressed (pulled to GND)
                if press_start is None:
                    press_start = time.monotonic()
                elif time.monotonic() - press_start >= BUTTON_HOLD_SECS:
                    print(f"[BTN] Button held {BUTTON_HOLD_SECS}s — restarting Station")
                    led_mode = "restarting"
                    if station_proc and station_proc.poll() is None:
                        station_proc.terminate()
                        try:
                            station_proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            station_proc.kill()
                    press_start = None
                    time.sleep(1)
            else:
                press_start = None
            time.sleep(DEBOUNCE_SECS)

# ---- Hardware reset ---------------------------------------------------------
def hardware_reset(chip_path):
    """Pulse GPIO 38 low to reset the SX1301."""
    print("[RESET] Asserting hardware reset on GPIO 38...")
    with gpiod.request_lines(chip_path, consumer="nebra-reset",
            config={RESET_PIN: LineSettings(direction=Direction.OUTPUT)}) as rst:
        rst.set_value(RESET_PIN, Value.INACTIVE)   # assert reset (active low)
        time.sleep(0.1)
        rst.set_value(RESET_PIN, Value.ACTIVE)      # release
        time.sleep(0.1)
        rst.set_value(RESET_PIN, Value.INACTIVE)
        time.sleep(0.5)                             # stabilise
    print("[RESET] Hardware reset complete")

# ---- Verify SX1301 ----------------------------------------------------------
def verify_sx1301():
    """Use sx1301_softreset binary to verify SX1301 is responding."""
    try:
        result = subprocess.run([f"{STATION_HOME}/sx1301_softreset", SPI_DEVICE],
                                capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            # Extract version from output
            if "0x67" in result.stdout:
                print("[SPI] SX1301 version = 0x67 ✓")
                return True
        # If binary failed or returned wrong version
        stderr = result.stderr.strip() if result.stderr else result.stdout.strip()
        print(f"[SPI] {stderr}")
        return False
    except Exception as e:
        print(f"[SPI] Verification failed: {e}")
        return False

# ---- Main loop --------------------------------------------------------------
def main():
    global led_mode, station_proc

    chip_path = "/dev/gpiochip0"

    # Start LED and button threads
    lt = threading.Thread(target=led_thread,  args=(chip_path,), daemon=True)
    bt = threading.Thread(target=button_thread, args=(chip_path,), daemon=True)
    lt.start()
    bt.start()

    def shutdown(sig, frame):
        print("\n[SYS] Shutting down...")
        stop_event.set()
        if station_proc and station_proc.poll() is None:
            station_proc.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT,  shutdown)

    while not stop_event.is_set():
        led_mode = "startup"
        print("[SYS] Starting up...")

        # Hardware reset
        hardware_reset(chip_path)

        # Verify SX1301
        if not verify_sx1301():
            print("[SYS] SX1301 not responding — retrying in 10s")
            led_mode = "error"
            time.sleep(10)
            continue

        # Launch Basics Station
        print(f"[SYS] Launching Basics Station...")
        env = os.environ.copy()
        env["LORAGW_SPI"]       = SPI_DEVICE
        env["LORAGW_SPI_SPEED"] = SPI_SPEED

        station_proc = subprocess.Popen(
            [STATION_BIN, "--home", STATION_HOME],
            env=env
        )

        led_mode = "running"
        print(f"[SYS] Station running (PID {station_proc.pid})")

        # Wait for Station to exit (or button restart)
        while not stop_event.is_set():
            ret = station_proc.poll()
            if ret is not None:
                print(f"[SYS] Station exited with code {ret}")
                led_mode = "error"
                time.sleep(5)
                break
            time.sleep(1)

    stop_event.set()

if __name__ == "__main__":
    main()
