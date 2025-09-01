#!/bin/bash

# ==============================================================================
# Fully Automated Raspberry Pi Kiosk Setup Script (Wayland/labwc Version)
#
# Description:
# This script automates setting up a Raspberry Pi with Pi OS Lite as a
# dedicated web kiosk using Wayland and labwc instead of X11.
# ==============================================================================

# --- Script Configuration ---
set -e # Exit immediately if a command exits with a non-zero status.

# The URL for your kiosk dashboard
KIOSK_URL="http://localhost:9002/?mqtt_address=localhost&mqtt_port=9001"

# --- System Setup ---

# Ensure the script is run as root/sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Get the username of the user who invoked sudo
if [ -n "$SUDO_USER" ]; then
        PI_USER=$SUDO_USER
else
        # Fallback for running as root directly
        PI_USER=$(whoami)
fi
PI_HOME=$(eval echo ~$PI_USER)
CONFIG_TXT_FILE="/boot/firmware/config.txt"
CMDLINE_TXT_FILE="/boot/firmware/cmdline.txt"

# --- Main Setup ---

echo "--- Raspberry Pi Wayland Kiosk Setup ---"
echo "Setting up for user: $PI_USER"
echo "Kiosk URL: $KIOSK_URL"
echo ""

# Step 1: Update and Install Packages
echo "--> Step 1: Updating and installing required packages..."
apt-get update
apt-get install libwayland-client0 libwayland-server0 libwayland-dev wlr-randr weston labwc chromium swayidle wtype -y
# Install additional dependencies that might be needed
apt-get install libdrm2 libgbm1 libegl1-mesa libgl1-mesa-dri -y
# Install polkit for proper seat management (required for labwc)
apt-get install policykit-1 -y
echo "--> Package installation complete."
echo ""

# Step 2: Configure User Permissions for Display Access
echo "--> Step 2: Adding user '$PI_USER' to required groups..."
usermod -a -G video,input,render,weston-launch,tty $PI_USER
# Install and configure seatd for proper session management
apt-get install seatd -y
# Create seat group if it doesn't exist
groupadd -f seat
systemctl enable seatd
systemctl start seatd
usermod -a -G seat $PI_USER
echo "--> Permissions configured."
echo ""

# Step 3: Create labwc Configuration
echo "--> Step 3: Creating labwc configuration..."
mkdir -p $PI_HOME/.config/labwc

cat > $PI_HOME/.config/labwc/rc.xml << EOF
<?xml version="1.0"?>
<labwc_config>
    <core>
        <gap>0</gap>
    </core>
    <keyboard>
        <keybind key="A-W-h">
            <action name="HideCursor" />
            <action name="WarpCursor" x="-1" y="-1" />
        </keybind>
    </keyboard>
    <windowRules>
        <windowRule identifier="chromium-browser">
            <action name="Maximize"/>
        </windowRule>
    </windowRules>
</labwc_config>
EOF

# Create autostart file for labwc
mkdir -p $PI_HOME/.config/labwc
cat > $PI_HOME/.config/labwc/autostart << EOF
#!/bin/bash
# Set Resolution
wlr-randr --output HDMI-A-1 --custom-mode 1920x1080 &

# Reconfigure labwc
labwc --reconfigure

# Disable screen blanking and power management
swayidle -w timeout 10000 'echo "keepalive"' &

# Kill any existing Chromium processes before starting new one
pkill -f chromium || true

# Hide cursor using labwc keybind (Alt+Win+H)
wtype -M alt -M logo -k h -m logo -m alt

# Start a 'keep-alive' process to prevent monitor sleep
(
    while true; do
        # Every 4 minutes, simulate activity
        wtype -M alt -M logo -k h -m logo -m alt
        sleep 240
    done
) &

# Chromium will be started by the kiosk-chromium.service
# This ensures better process management and automatic restart capabilities
EOF
chmod +x $PI_HOME/.config/labwc/autostart
chown -R $PI_USER:$PI_USER $PI_HOME/.config

# Step 4: Create Wayland session startup script
echo "--> Step 4: Creating Wayland startup script..."
cat > $PI_HOME/.wayland-session << EOF
#!/bin/bash

# Start labwc Wayland compositor
exec labwc
EOF
chmod +x $PI_HOME/.wayland-session
chown $PI_USER:$PI_USER $PI_HOME/.wayland-session

# Step 5: Configure Auto-Start on Login
echo "--> Step 5: Configuring Wayland session to auto-start in .profile..."
if ! grep -q "labwc" "$PI_HOME/.profile"; then
        cat >> $PI_HOME/.profile << EOF

# If on tty1, start the Wayland session (fallback if systemd service fails)
if [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    # Check if kiosk service is already running
    if ! systemctl is-active --quiet kiosk-labwc.service; then
        # Set up environment for Wayland
        export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        export XDG_SESSION_TYPE=wayland
        export QT_QPA_PLATFORM=wayland
        export GDK_BACKEND=wayland
        export MOZ_ENABLE_WAYLAND=1
        export WLR_RENDERER=pixman
        
        # Create runtime directory
        mkdir -p \$XDG_RUNTIME_DIR
        chmod 0700 \$XDG_RUNTIME_DIR
        
        # Log startup attempt
        echo "Starting labwc fallback at \$(date)" >> /tmp/labwc-startup.log
        
        # Start labwc with error logging and software renderer
        exec labwc 2>&1 | tee -a /tmp/labwc-startup.log
    fi
fi
EOF
        echo "--> Auto-start configured."
        # Comment out any startx command in .profile to prevent X11 startup
        if grep -qE '^\s*startx' "$PI_HOME/.profile"; then
            sed -i 's/^\s*startx/#&/' "$PI_HOME/.profile"
            echo "--> Commented out 'startx' in $PI_HOME/.profile to prevent X11 startup."
        fi
else
        echo "--> Auto-start configuration already exists. Skipping."
fi
echo ""

# Hardware settings remain the same
echo "--> Step 6: Applying kernel, firmware, and hardware settings..."

# 6a. Disable kernel console blanking
if ! grep -q "consoleblank=0" "${CMDLINE_TXT_FILE}"; then
        sed -i 's/$/ consoleblank=0/' "${CMDLINE_TXT_FILE}"
        echo "--> Console blanking disabled in ${CMDLINE_TXT_FILE}"
else
        echo "--> Console blanking already disabled. Skipping."
fi

# 6b. Add stability settings to config.txt
echo "--> Applying stability settings to ${CONFIG_TXT_FILE}..."
declare -a settings_to_add=(
    "disable_overscan=1"
    "hdmi_force_hotplug=1"
    "hdmi_boost=7"
    "hdmi_ignore_cec=1"
    "hdmi_group=1"
    "hdmi_mode=16"
    "gpu_mem=128"
    "dtoverlay=vc4-kms-v3d"
)

# Disable specific firmware settings that can cause display issues
declare -a settings_to_disable=(
    "max_framebuffers"
    "disable_fw_kms_setup"
)

# Use sed to ensure desired settings are enabled and unwanted ones are commented
for setting in "${settings_to_add[@]}"; do
    key=$(echo "$setting" | cut -d '=' -f 1)
    value=$(echo "$setting" | cut -d '=' -f 2-)
    # Replace any line (commented or not) with the correct setting, or append if not present
    if grep -qE "^\s*#?\s*${key}\s*=" "${CONFIG_TXT_FILE}"; then
        sed -i "s|^\s*#\?\s*${key}\s*=.*|${key}=${value}|g" "${CONFIG_TXT_FILE}"
        echo "--> Set '${key}=${value}'"
    else
        echo "${key}=${value}" >> "${CONFIG_TXT_FILE}"
        echo "--> Added '${key}=${value}'"
    fi
done

for setting in "${settings_to_disable[@]}"; do
    # Comment out any line starting with the unwanted setting (even if already commented)
    sed -i "s|^\s*${setting}|#${setting}|g" "${CONFIG_TXT_FILE}"
    echo "--> Disabled '${setting}' by commenting it out"
done

echo "--> Hardware settings applied."
echo ""

# Console auto-login (same as before)
echo "--> Step 7: Configuring console auto-login for user '$PI_USER'..."
SYSTEMD_DIR="/etc/systemd/system/getty@tty1.service.d"
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/autologin.conf" << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $PI_USER --noclear %I \$TERM
EOF
systemctl daemon-reload
echo "--> Auto-login configured."
echo ""

# Step 8: Create diagnostic script
echo "--> Step 8: Creating Wayland diagnostic script..."
cat > $PI_HOME/check-wayland.sh << 'EOF'
#!/bin/bash
echo "=== Wayland Diagnostic Script ==="
echo "Date: $(date)"
echo ""

echo "1. Environment Variables:"
echo "   WAYLAND_DISPLAY: $WAYLAND_DISPLAY"
echo "   XDG_SESSION_TYPE: $XDG_SESSION_TYPE"
echo "   XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"
echo ""

echo "2. Running Processes:"
ps aux | grep -E "(labwc|wayland|weston|chromium)" | grep -v grep
echo ""

echo "3. Session Information:"
loginctl show-session $(loginctl | grep $(whoami) | awk '{print $1}') -p Type 2>/dev/null || echo "No session found"
echo ""

echo "4. Runtime Directory Contents:"
ls -la $XDG_RUNTIME_DIR/ 2>/dev/null || echo "XDG_RUNTIME_DIR not accessible"
echo ""

echo "5. Wayland Socket Check:"
if [ -n "$WAYLAND_DISPLAY" ] && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    echo "   Wayland socket found: $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
else
    echo "   No Wayland socket found"
fi
echo ""

echo "6. labwc startup log:"
if [ -f /tmp/labwc-startup.log ]; then
    echo "   Recent entries:"
    tail -10 /tmp/labwc-startup.log
else
    echo "   No startup log found"
fi
echo ""

echo "7. Test labwc availability:"
which labwc >/dev/null 2>&1 && echo "   labwc command found" || echo "   labwc command NOT found"
echo ""

echo "8. Graphics/DRM check:"
ls -la /dev/dri/ 2>/dev/null || echo "   No DRI devices found"
echo ""
EOF
chmod +x $PI_HOME/check-wayland.sh
chown $PI_USER:$PI_USER $PI_HOME/check-wayland.sh
echo "--> Diagnostic script created at $PI_HOME/check-wayland.sh"

# Create manual start script for testing
echo "--> Creating manual start script..."
cat > $PI_HOME/start-kiosk-manual.sh << 'EOF'
#!/bin/bash
echo "=== Manual Kiosk Startup Script ==="
echo "This will try to start labwc manually for testing."
echo ""

# Set up environment
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_SESSION_TYPE=wayland
export WLR_RENDERER=pixman
export WLR_BACKENDS=drm,libinput

# Create runtime directory
mkdir -p $XDG_RUNTIME_DIR
chmod 0700 $XDG_RUNTIME_DIR

echo "Starting labwc with software renderer..."
echo "Check the physical display (HDMI) to see if it works."
echo ""

# Start labwc with logging
labwc 2>&1 | tee /tmp/labwc-manual.log
EOF
chmod +x $PI_HOME/start-kiosk-manual.sh
chown $PI_USER:$PI_USER $PI_HOME/start-kiosk-manual.sh
echo "--> Manual start script created at $PI_HOME/start-kiosk-manual.sh"
echo ""

# Step 9: Create systemd service for reliable kiosk startup
echo "--> Step 9: Creating systemd service for kiosk mode..."
cat > /etc/systemd/system/kiosk-labwc.service << EOF
[Unit]
Description=Kiosk Mode with labwc
After=seatd.service multi-user.target
Wants=seatd.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=$PI_USER
Group=$PI_USER
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $PI_USER)
Environment=XDG_SESSION_TYPE=wayland
Environment=WLR_RENDERER=pixman
Environment=WLR_BACKENDS=drm,libinput
Environment=WLR_LIBINPUT_NO_DEVICES=1
WorkingDirectory=$PI_HOME
ExecStartPre=/bin/mkdir -p /run/user/$(id -u $PI_USER)
ExecStartPre=/bin/chown $PI_USER:$PI_USER /run/user/$(id -u $PI_USER)
ExecStartPre=/bin/chmod 0700 /run/user/$(id -u $PI_USER)
ExecStart=/usr/bin/labwc
Restart=always
RestartSec=5
TTYPath=/dev/tty1
StandardOutput=append:/var/log/ucollect-box/kiosk/labwc.log
StandardError=append:/var/log/ucollect-box/kiosk/labwc.log
PAMName=login

[Install]
WantedBy=graphical.target
EOF

# Enable the service but don't start it yet (will start after reboot)
systemctl daemon-reload
systemctl enable kiosk-labwc.service
echo "--> Systemd service created and enabled."
echo ""

# Step 10: Create ucollect-box directories
echo "--> Step 10: Creating ucollect-box directories..."
mkdir -p /opt/ucollect-box/kiosk
mkdir -p /var/log/ucollect-box/kiosk
chown -R $PI_USER:$PI_USER /opt/ucollect-box
chown -R $PI_USER:$PI_USER /var/log/ucollect-box
chmod 755 /opt/ucollect-box/kiosk
chmod 755 /var/log/ucollect-box/kiosk
echo "--> ucollect-box directories created"

# Create logrotate configuration for kiosk logs
echo "--> Setting up logrotate for kiosk logs..."
cat > /etc/logrotate.d/ucollect-box-kiosk << EOF
/var/log/ucollect-box/kiosk/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 $PI_USER $PI_USER
    copytruncate
}
EOF
echo "--> Logrotate configuration created"
echo ""

# Step 11: Create Chromium launch script
echo "--> Step 11: Creating Chromium launch script..."
cat > /opt/ucollect-box/kiosk/start-chromium.sh << EOF
#!/bin/bash

# ==============================================================================
# Chromium Kiosk Launch Script
#
# Description:
# This script launches Chromium in kiosk mode with all necessary flags.
# Modify this file to customize Chromium behavior without editing systemd service.
# ==============================================================================

# Configuration
KIOSK_URL="$KIOSK_URL"
USER_DATA_DIR="/tmp/chromium_kiosk_profile"
LOG_FILE="/var/log/ucollect-box/kiosk/chromium.log"

# Logging function
log_message() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1"
}

log_message "Starting Chromium kiosk..."
log_message "Target URL: \$KIOSK_URL"

# Clean up any existing profile
if [ -d "\$USER_DATA_DIR" ]; then
    log_message "Cleaning up existing profile directory"
    rm -rf "\$USER_DATA_DIR"
fi

# Ensure we have proper Wayland environment
export XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}
export XDG_SESSION_TYPE=\${XDG_SESSION_TYPE:-wayland}

# Auto-detect Wayland display or use fallback
if [ -z "\$WAYLAND_DISPLAY" ]; then
    # Look for existing Wayland sockets
    if [ -S "\$XDG_RUNTIME_DIR/wayland-0" ]; then
        export WAYLAND_DISPLAY=wayland-0
        log_message "Auto-detected WAYLAND_DISPLAY=wayland-0"
    elif [ -S "\$XDG_RUNTIME_DIR/wayland-1" ]; then
        export WAYLAND_DISPLAY=wayland-1
        log_message "Auto-detected WAYLAND_DISPLAY=wayland-1"
    else
        export WAYLAND_DISPLAY=wayland-0
        log_message "No Wayland socket found, using fallback WAYLAND_DISPLAY=wayland-0"
    fi
fi

log_message "Environment: XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR, WAYLAND_DISPLAY=\$WAYLAND_DISPLAY"

# Check if Wayland socket exists before proceeding
if [ ! -S "\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY" ]; then
    log_message "ERROR: Wayland socket \$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY does not exist!"
    log_message "Available sockets in \$XDG_RUNTIME_DIR:"
    ls -la "\$XDG_RUNTIME_DIR/" | grep -E "(wayland|socket)" || log_message "No Wayland sockets found"
    log_message "Waiting 5 seconds for compositor to initialize..."
    sleep 5
    
    if [ ! -S "\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY" ]; then
        log_message "FATAL: Wayland compositor is not running or socket is not available"
        exit 1
    fi
fi

log_message "Wayland socket found: \$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY"

# Chromium flags for kiosk mode
CHROMIUM_FLAGS=(
    --kiosk
    --ozone-platform=wayland
    --enable-features=UseOzonePlatform 
    --noerrdialogs 
    --disable-infobars 
    --disable-session-crashed-bubble 
    --disable-component-update 
    --disable-features=Translate 
    --no-first-run 
    --user-data-dir=/tmp/chromium_kiosk_profile 
    --ignore-gpu-blocklist 
    --enable-gpu-rasterization 
    --enable-zero-copy 
    --use-gl=egl 
)

log_message "Launching Chromium with \${#CHROMIUM_FLAGS[@]} flags"

# Function to check if compositor is ready
wait_for_compositor() {
    local timeout=30
    local count=0
    while [ \$count -lt \$timeout ]; do
        # Check if Wayland socket exists and is accessible
        if [ -S "\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY" ]; then
            # Quick test to see if we can connect
            if timeout 3 wlr-randr > /dev/null 2>&1; then
                log_message "Wayland display ready after \${count}s"
                return 0
            else
                log_message "Wayland socket exists but not yet responsive..."
            fi
        else
            log_message "Waiting for Wayland socket \$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY..."
        fi
        sleep 2
        count=\$((count + 2))
    done
    log_message "Timeout waiting for Wayland display after \${timeout}s"
    return 1
}

# Wait for Wayland display to be ready
log_message "Checking Wayland display readiness..."
if ! wait_for_compositor; then
    log_message "ERROR: Wayland display not ready, exiting"
    exit 1
fi

# Launch Chromium with retry logic
RETRY_COUNT=0
MAX_RETRIES=3

while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
    log_message "Launch attempt \$((RETRY_COUNT + 1)) of \$MAX_RETRIES"
    
    # Start Chromium
    chromium "\${CHROMIUM_FLAGS[@]}" "\$KIOSK_URL" &
    CHROMIUM_PID=\$!
    
    # Wait a bit to see if it crashes immediately
    sleep 5
    
    # Check if process is still running
    if kill -0 \$CHROMIUM_PID 2>/dev/null; then
        log_message "Chromium started successfully (PID: \$CHROMIUM_PID)"
        wait \$CHROMIUM_PID  # Wait for the process to exit
        EXIT_CODE=\$?
        log_message "Chromium exited with code \$EXIT_CODE"
        break
    else
        log_message "Chromium failed to start or crashed immediately"
        RETRY_COUNT=\$((RETRY_COUNT + 1))
        if [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; then
            log_message "Retrying in 10 seconds..."
            sleep 10
        fi
    fi
done

if [ \$RETRY_COUNT -ge \$MAX_RETRIES ]; then
    log_message "ERROR: All retry attempts failed"
    exit 1
fi
EOF

chmod +x /opt/ucollect-box/kiosk/start-chromium.sh
chown $PI_USER:$PI_USER /opt/ucollect-box/kiosk/start-chromium.sh
echo "--> Chromium launch script created at /opt/ucollect-box/kiosk/start-chromium.sh"
echo ""

# Step 12: Create systemd service for Chromium kiosk
echo "--> Step 12: Creating systemd service for Chromium kiosk..."
cat > /etc/systemd/system/kiosk-chromium.service << EOF
[Unit]
Description=Chromium Kiosk Browser
After=kiosk-labwc.service
Wants=kiosk-labwc.service
BindsTo=kiosk-labwc.service
PartOf=kiosk-labwc.service

[Service]
Type=simple
User=$PI_USER
Group=$PI_USER
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $PI_USER)
Environment=XDG_SESSION_TYPE=wayland
Environment=DISPLAY=
Environment=DBUS_SESSION_BUS_ADDRESS=
Environment=LIBGL_ALWAYS_SOFTWARE=1
WorkingDirectory=$PI_HOME
ExecCondition=/bin/systemctl --quiet is-active kiosk-labwc.service
ExecStartPre=/bin/rm -rf /tmp/chromium_kiosk_profile
ExecStart=/opt/ucollect-box/kiosk/start-chromium.sh
Restart=always
RestartSec=5
StandardOutput=append:/var/log/ucollect-box/kiosk/chromium.log
StandardError=append:/var/log/ucollect-box/kiosk/chromium.log

[Install]
WantedBy=kiosk-labwc.service
EOF

# Enable both services
systemctl daemon-reload
systemctl enable kiosk-chromium.service
echo "--> Chromium kiosk service created and enabled."
echo ""

# Step 13: Create daily restart timer for kiosk services
echo "--> Step 13: Creating daily restart timer for kiosk services..."
cat > /etc/systemd/system/kiosk-daily-restart.service << EOF
[Unit]
Description=Daily Kiosk Service Restart
After=kiosk-labwc.service

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart kiosk-labwc.service
# Note: kiosk-chromium.service will restart automatically due to BindsTo dependency
EOF

cat > /etc/systemd/system/kiosk-daily-restart.timer << EOF
[Unit]
Description=Daily Kiosk Service Restart Timer
Requires=kiosk-daily-restart.service

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
WakeSystem=true

[Install]
WantedBy=timers.target
EOF

# Enable and start the timer
systemctl daemon-reload
systemctl enable kiosk-daily-restart.timer
systemctl start kiosk-daily-restart.timer
echo "--> Daily restart timer created and enabled for 02:00 AM"
echo ""

# Step 14: Final completion message
echo "--> Step 13: Setup complete!"

echo "========================================================================"
echo "                      SETUP IS COMPLETE!                                "
echo "========================================================================"
echo ""
echo "The system is now configured for Wayland with labwc and separate services:"
echo "  1. kiosk-labwc.service: Runs the labwc compositor"
echo "  2. kiosk-chromium.service: Runs Chromium kiosk (auto-restarts if it crashes)"
echo "  3. kiosk-daily-restart.timer: Automatically restarts kiosk at 02:00 AM daily"
echo "  4. Auto-login fallback in .profile (backup method)"
echo ""
echo "Logs are stored in /var/log/ucollect-box/kiosk/ with automatic rotation:"
echo "  - labwc.log: Compositor logs (rotated daily, 7 days retained)"
echo "  - chromium.log: Browser logs (rotated daily, 7 days retained)"
echo ""
echo "Scripts are stored in /opt/ucollect-box/kiosk/:"
echo "  - start-chromium.sh: Chromium launch script (edit to customize behavior)"
echo ""
echo "To start the kiosk immediately, you can:"
echo "  - Reboot: sudo reboot (recommended)"
echo "  - Or start labwc service: sudo systemctl start kiosk-labwc.service"
echo "  - Note: Chromium service will start automatically with labwc"
echo ""
echo "To check if it's working:"
echo "  - Run the diagnostic: ~/check-wayland.sh"
echo "  - Check compositor: sudo systemctl status kiosk-labwc.service"
echo "  - Check browser: sudo systemctl status kiosk-chromium.service"
echo "  - Check daily timer: sudo systemctl status kiosk-daily-restart.timer"
echo "  - View compositor logs: tail -f /var/log/ucollect-box/kiosk/labwc.log"
echo "  - View browser logs: tail -f /var/log/ucollect-box/kiosk/chromium.log"
echo "  - Edit Chromium config: nano /opt/ucollect-box/kiosk/start-chromium.sh"
echo ""
echo "Troubleshooting commands:"
echo "  - Restart compositor: sudo systemctl restart kiosk-labwc.service"
echo "  - Restart browser: sudo systemctl restart kiosk-chromium.service"
echo "  - Stop services: sudo systemctl stop kiosk-labwc.service kiosk-chromium.service"
echo "  - Check system logs: sudo journalctl -f"
echo "  - Manual labwc test: ~/start-kiosk-manual.sh"
echo "  - Debug Chromium: sudo journalctl -u kiosk-chromium.service -f"
echo "  - Test Chromium script: sudo -u $PI_USER /opt/ucollect-box/kiosk/start-chromium.sh"
echo ""
echo "Daily restart timer management:"
echo "  - Check timer status: sudo systemctl status kiosk-daily-restart.timer"
echo "  - View next restart time: sudo systemctl list-timers kiosk-daily-restart.timer"
echo "  - Disable daily restart: sudo systemctl disable --now kiosk-daily-restart.timer"
echo "  - Enable daily restart: sudo systemctl enable --now kiosk-daily-restart.timer"
echo "  - Trigger restart now: sudo systemctl start kiosk-daily-restart.service"
echo ""
echo "Configuration files:"
echo "  - Kiosk URL: Edit KIOSK_URL in /opt/ucollect-box/kiosk/start-chromium.sh"
echo "  - labwc config: ~/.config/labwc/rc.xml"
echo "  - labwc autostart: ~/.config/labwc/autostart"
echo "  - Log rotation: /etc/logrotate.d/ucollect-box-kiosk"
echo ""
echo "========================================================================"