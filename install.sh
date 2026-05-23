#!/usr/bin/env bash
set -euo pipefail

# Configuration
REPO_BASE="https://raw.githubusercontent.com/oszuidwest/rpi-audio-distributor/main"

# Set up the functions library
FUNCTIONS_LIB_PATH=$(mktemp)
FUNCTIONS_LIB_URL="https://raw.githubusercontent.com/oszuidwest/bash-functions/main/common-functions.sh"

trap 'rm -f "$FUNCTIONS_LIB_PATH"' EXIT

if ! curl -s -o "$FUNCTIONS_LIB_PATH" "$FUNCTIONS_LIB_URL"; then
  echo -e "*** Failed to download functions library. Please check your network connection! ***"
  exit 1
fi

# shellcheck source=/dev/null
source "$FUNCTIONS_LIB_PATH"

# Validate environment
assert_user_privileged "regular"
assert_os_linux
assert_os_64bit
assert_hw_rpi 4
assert_tool curl grep systemctl

# Display banner
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  rpi-audio-distributor installer${NC}"
echo -e "${BLUE}  Audio distribution system for Raspberry Pi${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

# Interactive prompts
prompt_user "DEVICE_HOSTNAME" "$(hostname)" "Enter a hostname for this device (e.g. audio-lobby)" "str"
prompt_user "DO_UPDATES" "y" "Do you want to perform all OS updates? (y/n)" "y/n"
prompt_user "STREAM_URL" "https://icecast.zuidwest.cloud/zuidwest.stl" "Enter the Icecast/HTTP stream URL" "str"
prompt_user "VOLUME" "75" "Enter the default volume (0-100)" "num"

# Detect and list ALSA audio devices
echo -e "\n${BLUE}►► Detecting audio devices...${NC}"
declare -a CARD_NAMES=()

while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]*\[([^]]+)\] ]]; then
    read -r card_name <<< "${BASH_REMATCH[1]}"
    CARD_NAMES+=("$card_name")
  fi
done < /proc/asound/cards

if [ ${#CARD_NAMES[@]} -eq 0 ]; then
  echo -e "${RED}No audio devices found!${NC}"
  exit 1
fi

echo -e "${GREEN}Available audio devices:${NC}"
for i in "${!CARD_NAMES[@]}"; do
  echo -e "  $((i + 1))) ${CARD_NAMES[$i]}"
done

# Let user pick a device
if [ ${#CARD_NAMES[@]} -eq 1 ]; then
  SELECTED_INDEX=0
  echo -e "${YELLOW}Only one device found, selecting: ${CARD_NAMES[0]}${NC}"
else
  while true; do
    read -r -p "Select an audio device [1-${#CARD_NAMES[@]}]: " DEVICE_CHOICE
    if [[ "$DEVICE_CHOICE" =~ ^[0-9]+$ ]] && [ "$DEVICE_CHOICE" -ge 1 ] && [ "$DEVICE_CHOICE" -le ${#CARD_NAMES[@]} ]; then
      SELECTED_INDEX=$((DEVICE_CHOICE - 1))
      break
    fi
    echo -e "${RED}Invalid selection. Please enter a number between 1 and ${#CARD_NAMES[@]}.${NC}"
  done
fi

AUDIO_DEVICE="alsa/plughw:CARD=${CARD_NAMES[$SELECTED_INDEX]}"
echo -e "${GREEN}✓ Selected: ${CARD_NAMES[$SELECTED_INDEX]} (${AUDIO_DEVICE})${NC}\n"

prompt_user "ENABLE_HEARTBEAT" "n" "Do you want to enable heartbeat monitoring? (y/n)" "y/n"
if [ "$ENABLE_HEARTBEAT" = "y" ]; then
  prompt_user "HEARTBEAT_URL" "https://heartbeat.uptimerobot.com/xxx" "Enter the heartbeat URL" "str"
fi

# Set timezone
echo -e "\n${BLUE}►► Setting timezone to Europe/Amsterdam...${NC}"
set_timezone "Europe/Amsterdam"
echo -e "${GREEN}✓ Timezone set${NC}"

# Set hostname
echo -e "${BLUE}►► Setting hostname to ${DEVICE_HOSTNAME}...${NC}"
sudo raspi-config nonint do_hostname "$DEVICE_HOSTNAME"
echo -e "${GREEN}✓ Hostname set${NC}"

# OS updates
if [ "$DO_UPDATES" = "y" ]; then
  echo -e "${BLUE}►► Performing OS updates...${NC}"
  apt_update --silent
  echo -e "${GREEN}✓ OS updated${NC}"
fi

if declare -F set_system_hardening_baseline > /dev/null; then
  set_system_hardening_baseline --silent
fi

# Install dependencies
echo -e "${BLUE}►► Installing required packages...${NC}"
apt_install --silent mpv socat jq
echo -e "${GREEN}✓ Packages installed${NC}"

# Create config directory and write config
echo -e "${BLUE}►► Writing configuration...${NC}"
mkdir -p ~/.config/audio-distributor
cat > ~/.config/audio-distributor/config <<EOF
STREAM_URL="${STREAM_URL}"
VOLUME="${VOLUME}"
AUDIO_DEVICE="${AUDIO_DEVICE}"
EOF
echo -e "${GREEN}✓ Configuration saved to ~/.config/audio-distributor/config${NC}"

# Install mpv-stream service
echo -e "${BLUE}►► Installing mpv-stream service...${NC}"
mkdir -p ~/.config/systemd/user
file_download "${REPO_BASE}/mpv-stream.service" ~/.config/systemd/user/mpv-stream.service "mpv-stream service"
systemctl --user daemon-reload
systemctl --user enable mpv-stream
echo -e "${GREEN}✓ mpv-stream service installed and enabled${NC}"

# Enable lingering so user services start at boot
echo -e "${BLUE}►► Enabling user service lingering...${NC}"
sudo loginctl enable-linger "$USER"
echo -e "${GREEN}✓ Lingering enabled for ${USER}${NC}"

# Install audio-ctl
echo -e "${BLUE}►► Installing audio-ctl...${NC}"
AUDIO_CTL_TMP=$(mktemp)
file_download "${REPO_BASE}/audio-ctl" "$AUDIO_CTL_TMP" "audio-ctl"
sudo install -m 755 "$AUDIO_CTL_TMP" /usr/local/bin/audio-ctl
rm -f "$AUDIO_CTL_TMP"
echo -e "${GREEN}✓ audio-ctl installed to /usr/local/bin/audio-ctl${NC}"

# Install health-check script
echo -e "${BLUE}►► Installing health check script...${NC}"
mkdir -p ~/.local/bin
file_download "${REPO_BASE}/health-check.sh" ~/.local/bin/health-check.sh "health-check script"
chmod 755 ~/.local/bin/health-check.sh
echo -e "${GREEN}✓ Health check installed to ~/.local/bin/health-check.sh${NC}"

# Set up cron job for health check
echo -e "${BLUE}►► Setting up health check cron job...${NC}"

if [ "$ENABLE_HEARTBEAT" = "y" ]; then
  HEALTH_CRONJOB="* * * * * ${HOME}/.local/bin/health-check.sh '${HEARTBEAT_URL}'"
else
  HEALTH_CRONJOB="* * * * * ${HOME}/.local/bin/health-check.sh"
fi

{ crontab -l 2>/dev/null | grep -v "health-check.sh" || true; echo "$HEALTH_CRONJOB"; } | crontab -
echo -e "${GREEN}✓ Health check cron job configured${NC}"

# Validate installation
echo -e "\n${BLUE}►► Validating installation...${NC}"
VALIDATION_PASSED=true

if [ ! -f ~/.config/audio-distributor/config ]; then
  echo -e "${RED}✗ Config file missing${NC}"
  VALIDATION_PASSED=false
fi

if [ ! -f ~/.config/systemd/user/mpv-stream.service ]; then
  echo -e "${RED}✗ Service file missing${NC}"
  VALIDATION_PASSED=false
fi

if [ ! -x /usr/local/bin/audio-ctl ]; then
  echo -e "${RED}✗ audio-ctl not found or not executable${NC}"
  VALIDATION_PASSED=false
fi

if [ ! -x ~/.local/bin/health-check.sh ]; then
  echo -e "${RED}✗ health-check.sh not found or not executable${NC}"
  VALIDATION_PASSED=false
fi

if [ "$VALIDATION_PASSED" = true ]; then
  echo -e "${GREEN}✓ Installation validated successfully${NC}"
else
  echo -e "${RED}Installation validation failed. Please check the errors above.${NC}"
  exit 1
fi

# Post-installation summary
echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "${YELLOW}▸ Configuration:${NC}"
echo -e "  Hostname:     ${BLUE}${DEVICE_HOSTNAME}${NC}"
echo -e "  Stream URL:   ${BLUE}${STREAM_URL}${NC}"
echo -e "  Volume:       ${BLUE}${VOLUME}${NC}"
echo -e "  Audio device: ${BLUE}${AUDIO_DEVICE}${NC}"

echo -e "\n${YELLOW}▸ Service Management:${NC}"
echo -e "  Status:  ${BLUE}systemctl --user status mpv-stream${NC}"
echo -e "  Start:   ${BLUE}systemctl --user start mpv-stream${NC}"
echo -e "  Stop:    ${BLUE}systemctl --user stop mpv-stream${NC}"
echo -e "  Restart: ${BLUE}systemctl --user restart mpv-stream${NC}"
echo -e "  Logs:    ${BLUE}journalctl --user -u mpv-stream -f${NC}"

echo -e "\n${YELLOW}▸ audio-ctl:${NC}"
echo -e "  ${BLUE}audio-ctl status${NC}         Show playback status"
echo -e "  ${BLUE}audio-ctl volume [0-100]${NC} Get or set volume"
echo -e "  ${BLUE}audio-ctl stream [url]${NC}   Get or change stream URL"
echo -e "  ${BLUE}audio-ctl restart${NC}        Restart the service"

# Reboot
echo -e "\n${YELLOW}The system will reboot in 10 seconds to apply all changes...${NC}"
echo -e "${YELLOW}Press Ctrl+C to cancel.${NC}\n"
sleep 10
sudo reboot
