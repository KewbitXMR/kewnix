#!/bin/bash

# Hardened TOR-based orchestrator for Docker containers
# Adds optional security features per container (seccomp, AppArmor, cap drop, ICMP block)
# Author: Kewbit

set -e

# Global config
SECURITY_PROFILE_DIR=".security"
mkdir -p "$SECURITY_PROFILE_DIR"

# Prompts the user for container hardening options
declare -A HARDENING_OPTS
function ask_hardening_opts() {
  local service_name="$1"

  echo "[*] Harden container: $service_name"
  read -p "  Apply seccomp profile to restrict syscalls? (y/n) [default: y]: " seccomp
  seccomp=${seccomp:-y}

  read -p "  Apply AppArmor profile? (y/n) [default: y]: " apparmor
  apparmor=${apparmor:-y}

  read -p "  Drop Linux capabilities (CAP_NET_RAW, etc)? (y/n) [default: y]: " cap_drop
  cap_drop=${cap_drop:-y}

  read -p "  Block ICMP (ping) from container? (y/n) [default: y]: " block_icmp
  block_icmp=${block_icmp:-y}

  read -p "  Disable IPv6 inside container? (y/n) [default: y]: " disable_ipv6
  disable_ipv6=${disable_ipv6:-y}

  HARDENING_OPTS["$service_name"]="$seccomp:$apparmor:$cap_drop:$block_icmp:$disable_ipv6"
}

# Emits the hardened YAML fragment for a container
generate_hardening_yaml() {
  local service_name="$1"
  local opts="${HARDENING_OPTS[$service_name]}"
  IFS=":" read -ra split <<< "$opts"
  local seccomp=${split[0]}
  local apparmor=${split[1]}
  local cap_drop=${split[2]}
  local block_icmp=${split[3]}
  local disable_ipv6=${split[4]}

  [[ "$seccomp" == "y" ]] && echo "    security_opt:\n      - seccomp:$SECURITY_PROFILE_DIR/seccomp-default.json"
  [[ "$apparmor" == "y" ]] && echo "    security_opt:\n      - apparmor:docker-default"
  [[ "$cap_drop" == "y" ]] && echo "    cap_drop:\n      - ALL"
  if [[ "$disable_ipv6" == "y" ]]; then
    echo "    sysctls:"
    echo "      net.ipv6.conf.all.disable_ipv6: 1"
    echo "      net.ipv6.conf.default.disable_ipv6: 1"
  fi

  # Optionally block ICMP on host for container
  if [[ "$block_icmp" == "y" ]]; then
    echo "# Host: Will insert rule to block ICMP from $service_name"
    echo "iptables -A TOR_ORCH -s <IP> -p icmp -j DROP -m comment --comment 'tor-orch:block-icmp:$service_name'"
  fi
}

# Install default seccomp if missing
if [[ ! -f "$SECURITY_PROFILE_DIR/seccomp-default.json" ]]; then
  curl -sSL -o "$SECURITY_PROFILE_DIR/seccomp-default.json" \
    https://raw.githubusercontent.com/moby/moby/master/profiles/seccomp/default.json
  echo "[+] Fetched default seccomp profile."
fi

# Example usage:
# ask_hardening_opts "app1"
# generate_hardening_yaml "app1"

# Note: integrate into your orchestrator as needed
