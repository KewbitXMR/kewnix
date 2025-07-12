# Author: Kewbit
# Description: Hardened TOR-based orchestrator for Docker containers with isolated networking, circuit-level Tor routing, and optional container access control.

set -e

# === GLOBALS ===
TOR_GW_NAME="tor-gateway"
DEFAULT_TOR_IP="192.168.100.2"
BRIDGE_PREFIX="kewnet"  # Changed for consistent prefix
BASE_SUBNET="192.168"
SUBNET_OFFSET=110
COMPOSE_FILE="docker-compose.yml"
SERVICES=()
SERVICE_NETWORKS=()
SERVICE_IMAGES=()
ACCESS_DIR=".access"
STATE_DIR=".state"

# === IMPORT HARDENING MODULE ===
source "$(dirname "$0")/.tor_gateway_hardening.sh"

# === FUNCTIONS ===
function check_docker() {
  if ! command -v docker &>/dev/null; then
    echo "[!] Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker --now
  fi
  if ! command -v docker compose &>/dev/null; then
    echo "[!] docker compose not found. Installing..."
    apt install docker-compose -y
  fi
}

function reserve_network() {
  local index=$1
  local service_name=${SERVICES[$index]}
  local net_name="${BRIDGE_PREFIX}-${service_name//[^a-zA-Z0-9]/_}"
  local subnet="${BASE_SUBNET}.$((SUBNET_OFFSET + index)).0/24"

  echo "[+] Creating isolated Docker network: $net_name ($subnet)"
  docker network create \
    --subnet=$subnet \
    --gateway=${subnet%0/24}1 \
    --driver=bridge \
    $net_name || true

  SERVICE_NETWORKS[$index]="$net_name"
}

function setup_custom_chains() {
  iptables -N TOR_ORCH 2>/dev/null || true
  iptables -t nat -N TOR_ORCH_NAT 2>/dev/null || true
  iptables -C FORWARD -j TOR_ORCH 2>/dev/null || iptables -A FORWARD -j TOR_ORCH
  iptables -t nat -C PREROUTING -j TOR_ORCH_NAT 2>/dev/null || iptables -t nat -A PREROUTING -j TOR_ORCH_NAT
}

function ask_service_details() {
  local service_name=$1
  local index=$2
  declare -A ACCESS_RULES

  echo "\n=== Configuring service: $service_name ==="

  read -p "[*] Use registry image for $service_name? (y/n) [default: y]: " use_registry
  use_registry=${use_registry:-y}

  if [[ "$use_registry" == "y" ]]; then
    read -p "    Enter image name (e.g. alpine, nginx:latest): " image_name
    SERVICE_IMAGES[$index]="$image_name"
  else
    SERVICE_IMAGES[$index]="build: ./$(basename "$PWD")/${service_name}"
    mkdir -p "${service_name}"
    echo -e "FROM alpine\nCMD [\"sleep\", \"infinity\"]" > "${service_name}/Dockerfile"
    echo "[+] Created local Dockerfile scaffold at ./${service_name}/Dockerfile"
  fi

  for other_service in "${SERVICES[@]}"; do
    if [[ "$other_service" == "$service_name" ]]; then continue; fi
    read -p "[*] Should $service_name be able to talk to $other_service? (y/n) [default: n]: " ans
    ans=${ans:-n}
    ACCESS_RULES[$other_service]=$ans
  done

  mkdir -p "$ACCESS_DIR" "$STATE_DIR"
  touch "$STATE_DIR/$service_name.state"

  for target in "${!ACCESS_RULES[@]}"; do
    echo "${ACCESS_RULES[$target]}" > "$ACCESS_DIR/${service_name}_to_${target}"
  done

  reserve_network $index
  ask_hardening_opts "$service_name"
}

function generate_compose() {
  echo "[+] Generating docker-compose.yml..."

  cat > $COMPOSE_FILE <<EOF
version: '3.8'
services:
  $TOR_GW_NAME:
    image: dperson/torproxy
    container_name: $TOR_GW_NAME
    restart: unless-stopped
    command: "-a -S"  # Isolate by source IP
    networks:
      tor-gw:
        ipv4_address: $DEFAULT_TOR_IP
    read_only: true
    dns:
      - 127.0.0.1
EOF

  echo "networks:" >> $COMPOSE_FILE
  echo "  tor-gw:" >> $COMPOSE_FILE
  echo "    driver: bridge" >> $COMPOSE_FILE
  echo "    ipam:" >> $COMPOSE_FILE
  echo "      config:" >> $COMPOSE_FILE
  echo "        - subnet: 192.168.100.0/24" >> $COMPOSE_FILE
  echo "          gateway: 192.168.100.1" >> $COMPOSE_FILE

  for i in "${!SERVICES[@]}"; do
    local svc=${SERVICES[$i]}
    local net="${BRIDGE_PREFIX}-${svc//[^a-zA-Z0-9]/_}"
    local ip="${BASE_SUBNET}.$((SUBNET_OFFSET+i)).10"
    local image=${SERVICE_IMAGES[$i]}

    echo "  $svc:" >> $COMPOSE_FILE
    if [[ "$image" == build:* ]]; then
      echo "    build: ${image#build: }" >> $COMPOSE_FILE
    else
      echo "    image: $image" >> $COMPOSE_FILE
    fi
    cat >> $COMPOSE_FILE <<EOF
    container_name: $svc
    read_only: true
    command: ["sleep", "infinity"]
    networks:
      $net:
        ipv4_address: $ip
    dns:
      - $DEFAULT_TOR_IP
EOF

    generate_hardening_yaml "$svc" >> $COMPOSE_FILE

    echo "  $net:" >> $COMPOSE_FILE
    echo "    driver: bridge" >> $COMPOSE_FILE
    echo "    ipam:" >> $COMPOSE_FILE
    echo "      config:" >> $COMPOSE_FILE
    echo "        - subnet: ${BASE_SUBNET}.$((SUBNET_OFFSET+i)).0/24" >> $COMPOSE_FILE
    echo "          gateway: ${BASE_SUBNET}.$((SUBNET_OFFSET+i)).1" >> $COMPOSE_FILE
  done

  echo "[✓] Docker Compose file generated."
}

function setup_host_iptables() {
  echo "[+] Applying hardened iptables rules..."
  setup_custom_chains

  iptables -F TOR_ORCH
  iptables -t nat -F TOR_ORCH_NAT

  for i in "${!SERVICES[@]}"; do
    ip="${BASE_SUBNET}.$((SUBNET_OFFSET+i)).10"
    svc="${SERVICES[$i]}"

    iptables -t nat -A TOR_ORCH_NAT -s $ip -p udp --dport 53 -j DNAT --to-destination $DEFAULT_TOR_IP:5353 -m comment --comment "tor-orch:dns:$svc"
    iptables -t nat -A TOR_ORCH_NAT -s $ip -p tcp --syn -j DNAT --to-destination $DEFAULT_TOR_IP:9040 -m comment --comment "tor-orch:tcp:$svc"
    iptables -A TOR_ORCH -s $ip -d $DEFAULT_TOR_IP -j ACCEPT -m comment --comment "tor-orch:allow-out:$svc"
    iptables -A TOR_ORCH -d $ip -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "tor-orch:allow-in:$svc"
    iptables -A TOR_ORCH -s $ip -j DROP -m comment --comment "tor-orch:block-other:$svc"
  done

  iptables -A TOR_ORCH -s $DEFAULT_TOR_IP -p udp -j DROP -m comment --comment "tor-orch:block-udp:tor"

  iptables-save > /etc/iptables/rules.v4 || true
  echo "[✓] Host iptables hardened."
}

function remove_service() {
  local svc="$1"
  docker compose stop "$svc" || true
  docker compose rm -f "$svc" || true
  sed -i "/^  $svc:/,/^  [^ ]/d" $COMPOSE_FILE || true
  rm -f $ACCESS_DIR/${svc}_to_* $STATE_DIR/$svc.state
  echo "[✓] Removed $svc and cleaned up access rules."
}

function clean_all() {
  echo "[!] This will remove all containers, networks, iptables rules, and local files created by the orchestrator."
  read -p "Are you sure? (y/n): " confirm
  [[ "$confirm" != "y" ]] && exit 1

  echo "[+] Stopping and removing containers..."
  docker ps -a --format '{{.Names}}' | grep "^$BRIDGE_PREFIX-" | xargs -r docker rm -f

  echo "[+] Removing networks..."
  docker network ls --format '{{.Name}}' | grep "^$BRIDGE_PREFIX-" | xargs -r docker network rm || true

  echo "[+] Removing iptables rules..."
  iptables -F TOR_ORCH || true
  iptables -t nat -F TOR_ORCH_NAT || true
  iptables -D FORWARD -j TOR_ORCH || true
  iptables -t nat -D PREROUTING -j TOR_ORCH_NAT || true
  iptables -X TOR_ORCH || true
  iptables -t nat -X TOR_ORCH_NAT || true
  iptables-save > /etc/iptables/rules.v4 || true

  echo "[+] Removing local files..."
  rm -rf "$COMPOSE_FILE" "$ACCESS_DIR" "$STATE_DIR"
  find . -maxdepth 1 -type d -name "$BRIDGE_PREFIX-*" -exec rm -rf {} +
  echo "[✓] All resources cleaned."
}

# === ENTRYPOINT ===
if [[ "$1" == "clean" ]]; then clean_all; exit 0; fi
if [[ "$1" == "remove-service" ]]; then remove_service "$2"; exit 0; fi
if [[ -f "$COMPOSE_FILE" ]]; then
  echo "Usage: $0 [add-service|remove-service <name>|list-services|clean]"
  exit 0
fi

check_docker
read -p "Enter comma-separated list of service names (e.g., app1,app2,db): " svc_list
IFS=',' read -ra SERVICES <<< "$svc_list"
for i in "${!SERVICES[@]}"; do ask_service_details "${SERVICES[$i]}" "$i"; echo; done
generate_compose
docker compose up -d
setup_host_iptables
echo "[✓] Setup complete. Containers are now transparently routed through Tor."
