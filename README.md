# rpi-audio-distributor

An audio distribution system for Raspberry Pi by [Streekomroep ZuidWest](https://www.zuidwesttv.nl/). Plays an Icecast/HTTP audio stream through a HiFiBerry sound card, designed for distributing audio to amplifiers and speakers in buildings (lobbies, restaurants, etc.).

## Hardware Requirements

- Raspberry Pi 4 or newer
- HiFiBerry sound card (DAC+, Digi, etc.)
- Network connection (Ethernet recommended)

## Preparing the Raspberry Pi

### 1. Install Raspberry Pi OS

Install **Raspberry Pi OS Lite (64-bit)** using the [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Enable SSH during setup.

### 2. Configure the HiFiBerry

Add the appropriate dtoverlay line to your `/boot/firmware/config.txt`. Make sure to disable the onboard audio (`dtparam=audio=off`).

**Examples:**

```
# HiFiBerry DAC+ / DAC+ Pro
dtoverlay=hifiberry-dacplus

# HiFiBerry Digi / Digi+
dtoverlay=hifiberry-digi

# HiFiBerry DAC+ ADC
dtoverlay=hifiberry-dacplusadc

# HiFiBerry DAC2 HD
dtoverlay=hifiberry-dacplushd
```

Reboot after making changes to `config.txt`.

### 3. Install

Run the installer as a regular user (not root):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/oszuidwest/rpi-audio-distributor/main/install.sh)"
```

## Configuration Options

During installation, you'll be asked to configure:

| Option | Default | Description |
|--------|---------|-------------|
| Hostname | Current hostname | Device name on the network (e.g. `audio-lobby`) |
| OS Updates | Yes | Whether to update all system packages |
| Stream URL | `https://icecast.zuidwest.cloud/zuidwest.stl` | Icecast/HTTP audio stream URL |
| Volume | 75 | Default playback volume (0-100) |
| Audio Device | — | ALSA audio device (detected automatically) |
| Heartbeat | No | Enable heartbeat monitoring via UptimeRobot or similar |
| Heartbeat URL | — | URL to ping every minute when the stream is healthy |

Configuration is stored in `~/.config/audio-distributor/config`.

## audio-ctl

A CLI tool for managing the audio stream at runtime:

```bash
audio-ctl status           # Show playback state, stream URL, volume, audio device
audio-ctl volume           # Show current volume
audio-ctl volume 50        # Set volume to 50 (persists across restarts)
audio-ctl stream           # Show current stream URL
audio-ctl stream <url>     # Change stream URL and restart service
audio-ctl restart          # Restart the mpv-stream service
```

## Service Management

The audio stream runs as a user-level systemd service:

```bash
systemctl --user status mpv-stream    # Check service status
systemctl --user start mpv-stream     # Start the service
systemctl --user stop mpv-stream      # Stop the service
systemctl --user restart mpv-stream   # Restart the service
journalctl --user -u mpv-stream -f    # Follow live logs
```

## Technical Details

### Architecture

- **mpv** plays the audio stream with a 3-second cache buffer for stability
- An **IPC socket** (`/tmp/mpv-audio.sock`) allows runtime control via `audio-ctl`
- A **cron-based health check** runs every minute to restart mpv if the stream drops
- **User-level systemd** with lingering ensures the service starts at boot without requiring a login session

### Health Check

The health check script (`~/.local/bin/health-check.sh`) runs every minute via cron:

1. Checks if the mpv IPC socket exists
2. Queries mpv for playback status
3. If mpv is not playing, restarts the service
4. If healthy and heartbeat is configured, pings the heartbeat URL

### File Locations

| File | Path |
|------|------|
| Configuration | `~/.config/audio-distributor/config` |
| Service unit | `~/.config/systemd/user/mpv-stream.service` |
| Health check | `~/.local/bin/health-check.sh` |
| CLI tool | `/usr/local/bin/audio-ctl` |
| IPC socket | `/tmp/mpv-audio.sock` |

## Troubleshooting

### No sound output

1. Verify the HiFiBerry is configured in `/boot/firmware/config.txt`
2. Check that the correct audio device was selected during installation
3. Check the service status: `systemctl --user status mpv-stream`
4. Check the logs: `journalctl --user -u mpv-stream -f`

### Stream keeps restarting

1. Verify the stream URL is correct: `audio-ctl stream`
2. Test the URL manually: `curl -I <stream-url>`
3. Check network connectivity

### audio-ctl reports "IPC socket not found"

The mpv-stream service is not running. Start it with:

```bash
systemctl --user start mpv-stream
```

### Service doesn't start at boot

Ensure lingering is enabled:

```bash
sudo loginctl enable-linger "$USER"
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contact

Maintained by [Streekomroep ZuidWest](https://www.zuidwesttv.nl/).
