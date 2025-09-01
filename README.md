# Raspberry Pi Wayland Kiosk System

A fully automated setup script that transforms a Raspberry Pi with Pi OS Lite into a dedicated web kiosk using modern Wayland display technology.

## Quick Start

Download and run the setup script:

```sh
curl -sSL https://raw.githubusercontent.com/noovoleum/setup-kiosk/refs/heads/main/setup-kiosk.sh -o setup-kiosk.sh
sudo bash setup-kiosk.sh
```

## System Architecture Overview

This kiosk system is built on modern Wayland display technology, providing a robust, self-healing web kiosk that automatically boots into a full-screen browser. The architecture consists of several interconnected components working together to ensure reliable, unattended operation.

### Core Components

#### 1. Wayland Display Server with labwc Compositor

**Purpose**: Replaces traditional X11 with modern Wayland display technology for better performance and security.

**Components**:
- **Wayland**: Modern display protocol that provides better security, performance, and stability compared to X11
- **labwc**: Lightweight Wayland compositor designed for simplicity and reliability
- **wlr-randr**: Tool for configuring display outputs under Wayland

**Configuration**:
- Located at `~/.config/labwc/rc.xml` - defines window management rules and keyboard shortcuts
- Autostart script at `~/.config/labwc/autostart` - handles display configuration and process management
- Configured to maximize Chromium windows and hide cursor for kiosk operation

#### 2. Systemd Service Architecture

The system uses a layered systemd service approach for maximum reliability:

**Primary Service - kiosk-labwc.service**:
- Manages the labwc Wayland compositor
- Runs as the specified user with proper environment setup
- Handles display initialization and session management
- Configured with automatic restart on failure

**Secondary Service - kiosk-chromium.service**:
- Manages the Chromium browser in kiosk mode
- Depends on and binds to the labwc service (BindsTo relationship)
- Automatically restarts if Chromium crashes
- Uses a sophisticated launch script for error handling and retry logic

**Maintenance Service - kiosk-daily-restart.timer**:
- Automatically restarts the entire kiosk stack daily at 2:00 AM
- Prevents memory leaks and ensures fresh startup
- Can be disabled if not needed

#### 3. Browser Configuration

**Chromium Launch Script** (`/opt/ucollect-box/kiosk/start-chromium.sh`):
- Comprehensive Wayland environment detection
- Automatic display socket discovery
- Retry logic for failed launches
- Extensive logging and error handling

**Kiosk Mode Flags**:
- `--kiosk`: Full-screen mode with no browser UI
- `--ozone-platform=wayland`: Native Wayland support
- `--noerrdialogs`: Suppress error dialogs
- `--disable-infobars`: Remove information bars
- GPU acceleration and hardware optimization flags

#### 4. Auto-Login and Session Management

**Console Auto-Login**:
- Configured via systemd getty service override
- Automatically logs in the specified user on tty1
- Provides fallback mechanism if systemd services fail

**Session Startup**:
- Primary: systemd services start automatically on boot
- Fallback: `.profile` script detects tty1 and starts labwc manually
- Environment variables properly configured for Wayland operation

#### 5. Hardware Optimization

**Raspberry Pi Specific Configuration**:
- HDMI output forced and optimized (`hdmi_force_hotplug=1`, `hdmi_boost=7`)
- GPU memory allocation increased (`gpu_mem=128`)
- VC4 KMS video driver enabled (`dtoverlay=vc4-kms-v3d`)
- Console blanking disabled for continuous display

**Power Management**:
- Screen blanking disabled at kernel level
- Swayidle configured with long timeout to prevent sleep
- Keep-alive process simulates activity every 4 minutes

#### 6. User Permissions and Security

**Group Memberships**:
- `video`: Access to GPU and video devices
- `input`: Access to keyboard/mouse devices
- `render`: GPU rendering permissions
- `seat`: Session management permissions

**Seat Management**:
- `seatd` service provides proper session management
- Handles device permissions and session switching
- Required for modern Wayland compositors

#### 7. Logging and Monitoring

**Centralized Logging**:
- All logs stored in `/var/log/ucollect-box/kiosk/`
- Separate logs for compositor (`labwc.log`) and browser (`chromium.log`)
- Automatic log rotation (daily, 7 days retention)

**Diagnostic Tools**:
- `~/check-wayland.sh`: Comprehensive system status checker
- `~/start-kiosk-manual.sh`: Manual startup for troubleshooting
- Real-time log monitoring via `journalctl` and `tail`

## System Flow and Boot Process

### 1. Boot Sequence
1. **Hardware Initialization**: Raspberry Pi firmware applies config.txt settings
2. **Kernel Boot**: Console blanking disabled, optimized for display output
3. **System Services**: seatd starts for session management
4. **Auto-Login**: Getty service automatically logs in the kiosk user
5. **Service Activation**: systemd starts kiosk-labwc.service
6. **Compositor Launch**: labwc starts with Wayland display server
7. **Browser Launch**: kiosk-chromium.service starts Chromium in kiosk mode

### 2. Runtime Operation
- **Display Management**: labwc manages windows, forces Chromium fullscreen
- **Process Monitoring**: systemd monitors both services, restarts on failure
- **Keep-Alive**: Background processes prevent system sleep
- **Logging**: Continuous logging of all operations for diagnostics

### 3. Error Recovery
- **Chromium Crashes**: Automatic restart via systemd
- **Compositor Crashes**: Automatic restart, triggers Chromium restart
- **System Issues**: Daily restart timer provides fresh start
- **Manual Recovery**: Diagnostic scripts and manual startup options

## Configuration and Customization

### Changing the Kiosk URL
Edit the target URL in `/opt/ucollect-box/kiosk/start-chromium.sh`:
```bash
KIOSK_URL="http://your-dashboard-url.com"
```

### Display Configuration
Modify display settings in `~/.config/labwc/autostart`:
```bash
wlr-randr --output HDMI-A-1 --custom-mode 1920x1080 &
```

### Window Management
Customize window behavior in `~/.config/labwc/rc.xml`:
```xml
<windowRules>
    <windowRule identifier="chromium-browser">
        <action name="Maximize"/>
    </windowRule>
</windowRules>
```

## Troubleshooting

### Common Issues and Solutions

**Display Not Showing**:
1. Check compositor status: `sudo systemctl status kiosk-labwc.service`
2. Run diagnostics: `~/check-wayland.sh`
3. Check hardware configuration in `/boot/firmware/config.txt`

**Browser Not Loading**:
1. Check browser service: `sudo systemctl status kiosk-chromium.service`
2. View browser logs: `tail -f /var/log/ucollect-box/kiosk/chromium.log`
3. Test URL accessibility from command line

**Performance Issues**:
1. Monitor system resources: `htop`
2. Check GPU utilization: `vcgencmd measure_temp`
3. Review hardware acceleration flags in start-chromium.sh

### Service Management Commands

```bash
# Start services
sudo systemctl start kiosk-labwc.service

# Stop services
sudo systemctl stop kiosk-labwc.service kiosk-chromium.service

# Restart services
sudo systemctl restart kiosk-labwc.service

# Check service status
sudo systemctl status kiosk-labwc.service kiosk-chromium.service

# View live logs
sudo journalctl -f -u kiosk-labwc.service
sudo journalctl -f -u kiosk-chromium.service

# Daily restart timer management
sudo systemctl status kiosk-daily-restart.timer
sudo systemctl list-timers kiosk-daily-restart.timer
sudo systemctl disable --now kiosk-daily-restart.timer  # Disable daily restart
```

## Directory Structure

```
/opt/ucollect-box/kiosk/
├── start-chromium.sh          # Chromium launch script (customizable)

/var/log/ucollect-box/kiosk/
├── labwc.log                  # Compositor logs
└── chromium.log               # Browser logs

~/.config/labwc/
├── rc.xml                     # labwc configuration
└── autostart                  # Startup script

/etc/systemd/system/
├── kiosk-labwc.service        # Compositor service
├── kiosk-chromium.service     # Browser service
├── kiosk-daily-restart.service # Daily restart service
└── kiosk-daily-restart.timer  # Daily restart timer

~/
├── check-wayland.sh           # Diagnostic script
└── start-kiosk-manual.sh      # Manual startup script
```

## Technical Requirements

### Hardware Requirements
- Raspberry Pi 3B+ or newer
- MicroSD card (16GB minimum, Class 10 recommended)
- HDMI display
- Network connection (Ethernet or WiFi)
- Power supply (official Raspberry Pi power supply recommended)

### Software Requirements
- Raspberry Pi OS Lite (Debian Bookworm or newer)
- Root/sudo access for installation
- Internet connection during setup

### Network Requirements
- Access to the target kiosk URL
- DNS resolution capability
- Stable network connection for continuous operation

## Security Considerations

### System Hardening
- Runs with minimal user privileges
- Wayland provides better security isolation than X11
- No SSH keys or passwords stored in the configuration
- Browser profile is temporary and recreated on each start

### Network Security
- Consider firewall rules for the target network
- Use HTTPS URLs when possible
- Monitor network traffic if security is critical
- Consider VPN for remote dashboard access

## Maintenance and Updates

### Regular Maintenance
- Monitor disk usage of log files
- Check system updates monthly: `sudo apt update && sudo apt upgrade`
- Verify network connectivity to target URL
- Review system logs for any recurring errors

### System Updates
- Test updates in a development environment first
- Consider disabling automatic updates for production kiosks
- Plan maintenance windows for system reboots
- Keep backup images of working configurations

This documentation provides a comprehensive overview of the kiosk system architecture, operation, and maintenance. The system is designed for reliability and ease of management while providing the flexibility needed for various kiosk applications.
