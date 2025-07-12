# Modular companion script for adding, listing, tailing, and managing services

set -e

COMPOSE_FILE="docker-compose.yml"
ACCESS_DIR=".access"
STATE_DIR=".state"
BASE_SUBNET="192.168"
SUBNET_OFFSET=110
BRIDGE_PREFIX="kewnet"
TOR_GW_IP="192.168.100.2"

mkdir -p "$ACCESS_DIR" "$STATE_DIR"

function list_services() {
  echo "[+] Listing configured services:"
  if [[ ! -d "$STATE_DIR" ]]; then
    echo "[!] No services found."
    return
  fi
  for state in "$STATE_DIR"/*.state; do
    [[ -e "$state" ]] || continue
    svc=$(basename "$state" .state)
    echo " - $svc"
  done
}

function get_next_index() {
  local max=0
  for f in "$STATE_DIR"/*.state; do
    [[ -e "$f" ]] || continue
    idx=$(grep '^index=' "$f" | cut -d= -f2)
    (( idx > max )) && max=$idx
  done
  echo $((max + 1))
}

function add_service() {
  echo "[+] Adding new service..."
  read -p "Enter name of new service: " svc_name

  if [[ -f "$STATE_DIR/$svc_name.state" ]]; then
    echo "[!] Service $svc_name already exists."
    return 1
  fi

  index=$(get_next_index)
  net_name="$BRIDGE_PREFIX-$svc_name"
  subnet="$BASE_SUBNET.$((SUBNET_OFFSET + index)).0/24"
  ip="$BASE_SUBNET.$((SUBNET_OFFSET + index)).10"
  gateway="$BASE_SUBNET.$((SUBNET_OFFSET + index)).1"

  read -p "[*] Use registry image for $svc_name? (y/n) [y]: " use_registry
  use_registry=${use_registry:-y}
  if [[ "$use_registry" == "y" ]]; then
    read -p "    Enter image name (e.g. alpine, nginx:latest): " image_name
    image_directive="image: $image_name"
  else
    mkdir -p "$svc_name"
    echo -e "FROM alpine\nCMD [\"sleep\", \"infinity\"]" > "$svc_name/Dockerfile"
    echo "[+] Created $svc_name/Dockerfile"
    image_directive="build: ./$svc_name"
  fi

  for other_state in "$STATE_DIR"/*.state; do
    [[ -e "$other_state" ]] || continue
    other_svc=$(basename "$other_state" .state)
    [[ "$other_svc" == "$svc_name" ]] && continue
    read -p "[*] Should $svc_name be able to talk to $other_svc? (y/n) [n]: " ans
    echo "${ans:-n}" > "$ACCESS_DIR/${svc_name}_to_${other_svc}"
  done

  cat > "$STATE_DIR/$svc_name.state" <<EOF
index=$index
subnet=$subnet
ip=$ip
gateway=$gateway
net=$net_name
EOF

  docker network create \
    --subnet="$subnet" \
    --gateway="$gateway" \
    --driver=bridge "$net_name" || true

  echo "[+] Updating $COMPOSE_FILE..."
  if ! grep -q "$svc_name:" "$COMPOSE_FILE" 2>/dev/null; then
    cat >> "$COMPOSE_FILE" <<EOF
  $svc_name:
    $image_directive
    container_name: $svc_name
    command: ["sleep", "infinity"]
    read_only: true
    networks:
      $net_name:
        ipv4_address: $ip
    dns:
      - $TOR_GW_IP
EOF
    echo "  $net_name:" >> "$COMPOSE_FILE"
    echo "    driver: bridge" >> "$COMPOSE_FILE"
    echo "    ipam:" >> "$COMPOSE_FILE"
    echo "      config:" >> "$COMPOSE_FILE"
    echo "        - subnet: $subnet" >> "$COMPOSE_FILE"
    echo "          gateway: $gateway" >> "$COMPOSE_FILE"
  fi

  docker compose up -d "$svc_name"
  echo "[✓] Service $svc_name added and started."
}

function tail_service_logs() {
  echo "[+] Tailing iptables logs for TOR_ORCH chains..."
  journalctl -f -k | grep --line-buffered -Ei 'TOR_ORCH'
}

function usage() {
  echo "Usage: $0 [list-services | add-service | tail-service-logs]"
  exit 1
}

case "$1" in
  list-services)
    list_services
    ;;
  add-service)
    add_service
    ;;
  tail-service-logs)
    tail_service_logs
    ;;
  *)
    usage
    ;;
esac
