#!/bin/bash

# Set +e means the script will continue even if a command fails.
# This is useful for firstrun scripts where some commands might fail
# but you want the rest of the script to execute.
set +e

# SSH Key Setup Instructions:
# To enable SSH key authentication, you MUST place an 'authorized_keys' file 
# in the /boot or /boot/firmware directory before first boot.
# This file should contain your static public key(s) that you want to authorize.
# The script will automatically copy it to /home/box/.ssh/authorized_keys
# and set proper permissions. No SSH keys will be generated automatically.

LOGFILE="/boot/firstboot_setup.log"
# Ensure the log file exists and is writable
touch "$LOGFILE"
echo "Starting first boot setup: $(date)" > "$LOGFILE"

# Function to log messages with a timestamp
log() {
    echo "$(date): [firstrun.sh] $1" >> "$LOGFILE"
}

# Function to generate a random alphanumeric string of a given length
generate_random_alphanumeric() {
    local length=$1
    # Use /dev/urandom to get random bytes, then tr to filter for lowercase alphanumeric characters
    # and head to get the desired length.
    # The characters are a-z and 0-9.
    head /dev/urandom | tr -dc a-z0-9 | head -c "${length}"
}

# Function to generate the hostname in the format box-XXXX-XXXX
generate_hostname() {
    local part1=$(generate_random_alphanumeric 4)
    local part2=$(generate_random_alphanumeric 4)
    echo "box-${part1}-${part2}"
}

log "Generating and setting new hostname..."
CURRENT_HOSTNAME=`cat /etc/hostname | tr -d " \t\n\r"`
NEW_HOSTNAME=$(generate_hostname)

# Check if imager_custom tool is available for setting hostname
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
    log "Using imager_custom to set hostname to $NEW_HOSTNAME"
    /usr/lib/raspberrypi-sys-mods/imager_custom set_hostname "$NEW_HOSTNAME" >> "$LOGFILE" 2>&1
else
    log "imager_custom not found, setting hostname manually to $NEW_HOSTNAME"
    echo "$NEW_HOSTNAME" >/etc/hostname
    # Update /etc/hosts to reflect the new hostname
    sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
fi
log "Hostname set to: $NEW_HOSTNAME"

log "Enabling SSH..."
# Get the first user's name and home directory (usually 'pi' or 'box')
FIRSTUSER=`getent passwd 1000 | cut -d: -f1`
FIRSTUSERHOME=`getent passwd 1000 | cut -d: -f6`

# Check if imager_custom tool is available for enabling SSH
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
    log "Using imager_custom to enable SSH"
    /usr/lib/raspberrypi-sys-mods/imager_custom enable_ssh >> "$LOGFILE" 2>&1
else
    log "imager_custom not found, enabling SSH service manually"
    systemctl enable ssh >> "$LOGFILE" 2>&1
fi
log "SSH enabled."

log "Setting up SSH keys..."
# Ensure .ssh directory exists for the box user
BOXUSER_HOME="/home/box"
if [ "$FIRSTUSER" != "box" ]; then
    BOXUSER_HOME="$FIRSTUSERHOME"
fi

# Create .ssh directory with proper permissions
mkdir -p "$BOXUSER_HOME/.ssh"
chmod 700 "$BOXUSER_HOME/.ssh"

# Check for authorized_keys file in /boot or /boot/firmware
AUTHORIZED_KEYS_SOURCE=""
if [ -f "/boot/authorized_keys" ]; then
    AUTHORIZED_KEYS_SOURCE="/boot/authorized_keys"
elif [ -f "/boot/firmware/authorized_keys" ]; then
    AUTHORIZED_KEYS_SOURCE="/boot/firmware/authorized_keys"
fi

# Set up authorized_keys if source file exists
if [ -n "$AUTHORIZED_KEYS_SOURCE" ]; then
    log "Setting up authorized_keys from $AUTHORIZED_KEYS_SOURCE"
    cp "$AUTHORIZED_KEYS_SOURCE" "$BOXUSER_HOME/.ssh/authorized_keys"
    chmod 600 "$BOXUSER_HOME/.ssh/authorized_keys"
    log "Authorized keys configured from static public key"
else
    log "WARNING: No authorized_keys file found in /boot or /boot/firmware"
    log "SSH key authentication will not be available"
fi

# Set proper ownership for .ssh directory and contents
if [ "$FIRSTUSER" != "box" ]; then
    # If user hasn't been renamed yet, use original user
    chown -R "$FIRSTUSER:$FIRSTUSER" "$BOXUSER_HOME/.ssh" >> "$LOGFILE" 2>&1
else
    chown -R "box:box" "$BOXUSER_HOME/.ssh" >> "$LOGFILE" 2>&1
fi

log "SSH key setup complete."

log "Setting user 'box' password and renaming if necessary..."
# Check if userconf-pi tool is available for user configuration
if [ -f /usr/lib/userconf-pi/userconf ]; then
    log "Using userconf-pi to set 'box' user password"
    # The password hash provided: '$5$NtiXk2MaOx$VgtkpYBk3c3AkCuUhIBSlOvegvkBE45JsM8Ak94ihI5'
    /usr/lib/userconf-pi/userconf 'box' '$5$NtiXk2MaOx$VgtkpYBk3c3AkCuUhIBSlOvegvkBE45JsM8Ak94ihI5' >> "$LOGFILE" 2>&1
else
    log "userconf-pi not found, setting 'box' user password manually"
    echo "$FIRSTUSER:"'$5$NtiXk2MaOx$VgtkpYBk3c3AkCuUhIBSlOvegvkBE45JsM8Ak94ihI5' | chpasswd -e >> "$LOGFILE" 2>&1
    # If the first user is not 'box', rename them
    if [ "$FIRSTUSER" != "box" ]; then
        log "Renaming user '$FIRSTUSER' to 'box' and updating home directory"
        usermod -l "box" "$FIRSTUSER" >> "$LOGFILE" 2>&1
        usermod -m -d "/home/box" "box" >> "$LOGFILE" 2>&1
        groupmod -n "box" "$FIRSTUSER" >> "$LOGFILE" 2>&1
        # Update autologin settings if they exist
        if grep -q "^autologin-user=" /etc/lightdm/lightdm.conf ; then
            sed /etc/lightdm/lightdm.conf -i -e "s/^autologin-user=.*/autologin-user=box/" >> "$LOGFILE" 2>&1
        fi
        if [ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then
            sed /etc/systemd/system/getty@tty1.service.d/autologin.conf -i -e "s/$FIRSTUSER/box/" >> "$LOGFILE" 2>&1
        fi
        # Update sudoers if the old user was in it
        if [ -f /etc/sudoers.d/010_pi-nopasswd ]; then
            sed -i "s/^$FIRSTUSER /box /" /etc/sudoers.d/010_pi-nopasswd >> "$LOGFILE" 2>&1
        fi
    fi
fi
log "User configuration complete."

log "Setting up Wi-Fi configuration..."
# Check if imager_custom tool is available for setting WLAN
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
    log "Using imager_custom to set WLAN"
    /usr/lib/raspberrypi-sys-mods/imager_custom set_wlan 'Noovoleum_Provisioning' '55f89fe04c698a12910b1542131d718245b390febaac1bbf27f411598f85f00d' 'ID' >> "$LOGFILE" 2>&1
else
    log "imager_custom not found, configuring wpa_supplicant.conf manually"
    cat >/etc/wpa_supplicant/wpa_supplicant.conf <<'WPAEOF'
country=ID
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
ap_scan=1

update_config=1
network={
    ssid="Noovoleum_Provisioning"
    psk=55f89fe04c698a12910b1542131d718245b390febaac1bbf27f411598f85f00d
}

WPAEOF
    chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
    rfkill unblock wifi >> "$LOGFILE" 2>&1
    # Ensure Wi-Fi is unblocked
    for filename in /var/lib/systemd/rfkill/*:wlan ; do
        echo 0 > "$filename"
    done
fi
log "Wi-Fi configuration complete."

log "Setting keymap and timezone..."
# Check if imager_custom tool is available for setting keymap and timezone
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
    log "Using imager_custom to set keymap and timezone"
    /usr/lib/raspberrypi-sys-mods/imager_custom set_keymap '' >> "$LOGFILE" 2>&1
    /usr/lib/raspberrypi-sys-mods/imager_custom set_timezone 'Asia/Jakarta' >> "$LOGFILE" 2>&1
else
    log "imager_custom not found, setting timezone and keyboard configuration manually"
    rm -f /etc/localtime
    echo "Asia/Jakarta" >/etc/timezone
    dpkg-reconfigure -f noninteractive tzdata >> "$LOGFILE" 2>&1
    cat >/etc/default/keyboard <<'KBEOF'
XKBMODEL="pc105"
XKBLAYOUT=""
XKBVARIANT=""
XKBOPTIONS=""

KBEOF
    dpkg-reconfigure -f noninteractive keyboard-configuration >> "$LOGFILE" 2>&1
fi
log "Keymap and timezone set."

# Determine the correct path for the helper script (either /boot/ or /boot/firmware/)
INSTALL_SCRIPT_PATH="/boot/firstboot-provision.sh"
if [ -f "/boot/firmware/firstboot-provision.sh" ]; then
    INSTALL_SCRIPT_PATH="/boot/firmware/firstboot-provision.sh"
fi

# --- Create and enable a systemd service to run the installation script after network is up ---
log "Creating and enabling systemd service for deferred installations..."
SYSTEMD_SERVICE_FILE="/etc/systemd/system/firstboot-provision.service"
cat <<EOF | tee "$SYSTEMD_SERVICE_FILE" >> "$LOGFILE" 2>&1
[Unit]
Description=First Boot Provisioning Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_SCRIPT_PATH}
Restart=on-failure
RestartSec=90
StandardOutput=append:/boot/firstboot_setup.log
StandardError=append:/boot/firstboot_setup.log

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SYSTEMD_SERVICE_FILE" >> "$LOGFILE" 2>&1
systemctl daemon-reload >> "$LOGFILE" 2>&1
systemctl enable firstboot-provision.service >> "$LOGFILE" 2>&1
log "Systemd service 'firstboot-provision.service' created and enabled."
log "It will run '${INSTALL_SCRIPT_PATH}' after network is online."
# --- End systemd service creation ---

log "First boot setup complete. The system will now reboot (if configured by cmdline.txt) or continue booting."
log "Deferred installations will run on the next boot once network is established."

# Clean up the firstrun.sh script itself and remove the systemd boot arg
rm -f /boot/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/cmdline.txt
exit 0
