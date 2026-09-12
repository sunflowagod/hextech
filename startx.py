#!/usr/bin/env bash
# ============================================================
#  startemu.sh — launch N Android emulator containers
#  Auto-relaunches containers that hang or die during boot.
#
#  Usage:
#     ./startemu.sh          # default 2
#     ./startemu.sh 5        # 5 emulators
#     ./startemu.sh 3 13.0   # 3 emulators, Android 13
#
#  Env overrides:
#     BOOT_TIMEOUT=300  seconds per device before relaunch (default 240)
#     MAX_ATTEMPTS=3    retries per device                 (default 2)
# ============================================================
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

COUNT="${1:-2}"
ANDROID_VERSION="${2:-${ANDROID_VERSION:-11.0}}"
IMAGE="budtmo/docker-android:emulator_${ANDROID_VERSION}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-240}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"

DEVICES=(
  "Samsung Galaxy S10"
  "Samsung Galaxy S9"
  "Nexus 5"
  "Pixel 4"
  "Samsung Galaxy S20"
  "Nexus 6"
  "Pixel 6"
  "Samsung Galaxy S21"
)

O='\033[38;5;208m'; A='\033[38;5;214m'; D='\033[38;5;240m'; R='\033[0m'
say()  { printf "%b  >>%b %s\n" "$A" "$R" "$1"; }
ok()   { printf "%b  ok%b %s\n" "$A" "$R" "$1"; }
warn() { printf "%b  !!%b %s\n" "$O" "$R" "$1"; }

if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi

adb_port_for() { local n="$1"; echo $((5554 + 2 * (n - 1))); }
vnc_port_for() { local n="$1"; echo $((8080 + (n - 1))); }

echo ""
echo -e "${O}  =================================================${R}"
echo -e "${O}  #      STARTING ${COUNT} EMULATOR(S)                 #${R}"
echo -e "${O}  =================================================${R}"
echo ""

# ---------- resource check ----------
TOTAL_RAM=$(free -g | awk '/^Mem:/ {print $2}')
TOTAL_CPUS=$(nproc)
NEEDED_RAM=$((COUNT * 2))
say "system: ${TOTAL_CPUS} cores, ${TOTAL_RAM}GB RAM, need ~${NEEDED_RAM}GB"
if [ "$TOTAL_RAM" -lt "$NEEDED_RAM" ]; then
  warn "you have ${TOTAL_RAM}GB — expect swapping and slow boot"
fi

# ---------- KVM ----------
KVM_FLAG=""
if [ -e /dev/kvm ]; then
  KVM_FLAG="--device /dev/kvm"
  ok "/dev/kvm present"
else
  warn "/dev/kvm missing — emulators will run very slowly"
fi

# ---------- reset adb ----------
say "resetting adb server"
adb kill-server >/dev/null 2>&1 || true

# ---------- remove old containers ----------
say "removing any existing clawemu-* containers"
$DOCKER ps -aq --filter "name=clawemu-" 2>/dev/null | xargs -r $DOCKER rm -f >/dev/null 2>&1 || true

# ---------- pull ----------
say "pulling ${IMAGE}"
$DOCKER pull "$IMAGE" >/dev/null

# ============================================================
#  Helper: launch one container (destructive — removes first)
# ============================================================
launch_one() {
  local i="$1"
  local name="clawemu-${i}"
  local adb_port
  local vnc_port
  local device
  adb_port=$(adb_port_for "$i")
  vnc_port=$(vnc_port_for "$i")
  device="${DEVICES[$(( (i - 1) % ${#DEVICES[@]} ))]}"

  # remove any existing container with this name
  $DOCKER rm -f "$name" >/dev/null 2>&1 || true

  # free its ports
  lsof -ti:"$adb_port" 2>/dev/null | xargs -r sudo kill -9 2>/dev/null || true
  lsof -ti:"$vnc_port" 2>/dev/null | xargs -r sudo kill -9 2>/dev/null || true

  say "launching $name  ·  ${device}  ·  adb :${adb_port}  ·  vnc :${vnc_port}"
  $DOCKER run -d \
    --privileged \
    --name "$name" \
    --dns 8.8.8.8 \
    --dns 1.1.1.1 \
    -p "${vnc_port}:6080" \
    -p "${adb_port}:5555" \
    -e EMULATOR_DEVICE="$device" \
    -e WEB_VNC=true \
    $KVM_FLAG \
    "$IMAGE" >/dev/null
}

# ============================================================
#  Helper: wait for one device. Returns:
#     0 = booted    2 = container died    3 = adb never came up
#     4 = sys.boot_completed never reached 1 within BOOT_TIMEOUT
# ============================================================
wait_one() {
  local i="$1"
  local name="clawemu-${i}"
  local port
  port=$(adb_port_for "$i")

  # 1. connect adb (up to ~120s)
  local connected=0
  for _ in $(seq 1 60); do
    if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      return 2
    fi
    if adb connect "localhost:${port}" 2>&1 | grep -qiE "connected|already"; then
      connected=1
      break
    fi
    printf "."
    sleep 2
  done
  [ "$connected" = "0" ] && return 3

  # 2. wait for sys.boot_completed=1
  local deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local val
    val=$(adb -s "localhost:${port}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)
    if [ "$val" = "1" ]; then
      return 0
    fi
    # bail early if container died mid-boot
    if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      return 2
    fi
    printf "."
    sleep 2
  done
  return 4
}

# ============================================================
#  Launch all
# ============================================================
echo ""
for i in $(seq 1 "$COUNT"); do
  launch_one "$i"
done

# ---------- start adb early ----------
echo ""
say "starting adb server"
adb start-server >/dev/null 2>&1 || true
sleep 2

# ---------- wait for each with relaunch ----------
echo ""
say "waiting for ${COUNT} device(s) — up to ${BOOT_TIMEOUT}s each, ${MAX_ATTEMPTS} attempts"
echo ""

BOOTED=()
for _ in $(seq 1 "$COUNT"); do BOOTED+=(0); done

for i in $(seq 1 "$COUNT"); do
  local_name="clawemu-${i}"
  echo ""
  say "[$local_name] starting"

  attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    printf "  [%s] attempt %d/%d  " "$local_name" "$attempt" "$MAX_ATTEMPTS"

    rc=0
    wait_one "$i" || rc=$?
    echo ""

    if [ "$rc" = "0" ]; then
      ok "$local_name fully booted"
      BOOTED[$((i-1))]=1
      break
    fi

    case "$rc" in
      2) warn "$local_name container died" ;;
      3) warn "$local_name adb never came up" ;;
      4) warn "$local_name boot timed out after ${BOOT_TIMEOUT}s" ;;
      *) warn "$local_name unknown error (rc=$rc)" ;;
    esac

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      warn "$local_name gave up after ${MAX_ATTEMPTS} attempt(s)"
      break
    fi

    attempt=$((attempt + 1))
    echo ""
    say "[$local_name] relaunching (attempt ${attempt}/${MAX_ATTEMPTS})"
    launch_one "$i"
    sleep 5
  done
done

# ---------- summary ----------
sleep 1
echo ""
echo -e "${D}  ----------------------------------------------------${R}"
echo -e "${A}  #    container       adb           noVNC${R}"
echo -e "${D}  ----------------------------------------------------${R}"
for i in $(seq 1 "$COUNT"); do
  ADB_PORT=$(adb_port_for "$i")
  VNC_PORT=$(vnc_port_for "$i")
  if [ "${BOOTED[$((i-1))]}" = "1" ]; then
    STATUS="✓"
  else
    STATUS="✗"
  fi
  printf "  %s %-2s %-14s :%-8s      http://localhost:%s\n" \
    "$STATUS" "$i" "clawemu-${i}" "$ADB_PORT" "$VNC_PORT"
done
echo -e "${D}  ----------------------------------------------------${R}"
echo ""

echo -e "${A}  adb devices:${R}"
adb devices -l | sed 's/^/    /'
echo ""

if adb devices | tail -n +2 | grep -q "device$"; then
  ok "ready — now run:  python3 scrcpy_stream.py"
  ok "then open:       http://localhost:3200"
else
  warn "no adb devices found"
  warn "try:  adb kill-server && adb start-server && adb connect localhost:5554"
fi
echo ""
