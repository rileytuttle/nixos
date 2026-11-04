# shellcheck shell=bash
# shic -- SHare Internet Connection.
#
# Creates a NetworkManager "shared" connection on an output interface
# (ethernet, or a WiFi AP) and adds the forward + MASQUERADE rules that let
# traffic out through an input interface.
#
# Every privileged action is built as an argument ARRAY and run directly,
# never through `eval` on a concatenated string (which is what this script
# used to do). That is what makes an SSID or passphrase containing a space,
# a quote or a `$` safe here.
#
# PATH note for the packaging: the nmcli/iptables/sysctl calls below go
# through sudo, which resets PATH to its own secure_path, so the runtimeInputs
# in pkgs/scripts.nix cannot reach them -- those exist for the unprivileged
# calls (iw, `nmcli connection show`, grep -P, awk, qrencode).
set -euo pipefail

show_help() {
  cat <<'EOF'
SHare Internet Connection - SHIC
This utility is for managing a shared internet or network connection.
NOTE: currently shares over the default route so we maybe don't need to give a FROM_INTERFACE
Usage: sudo shic [options]

Options:
  -h, --help                                              Show this help message
  --from-interface, -f FROM_INTERFACE                     the interface to share from
  --to-interface, -t TO_INTERFACE [WIFI_SSID] [WIFI_PASS] the interface to share to. wifi ssid and pass are required if the interface is wireless
  --addresses ADDRESSES                                   the address to have on the TO_INTERFACE and subnet to assign address
  --dry-run                                               print every command without running any of them
  --teardown                                              just an alias for iptables --flush. for now it seems like the best option as opposed to removing specific rules

Examples:
  shic -f eth0 -t wlan0 --wifi my_hotspot password123 --tailscale tailscale0
  shic -f eth0 -t enp0s31f6 --addresses 192.168.168.1/24
EOF
}

dry_run=false
is_wifi=false
iface=""
oface=""
addresses=""
wifi_ssid=""
wifi_pass=""

# Print a command, then run it unless this is a dry run.
run_or_show() {
  printf '%s\n' "$*"
  if [[ $dry_run == false ]]; then
    "$@"
  fi
}

# True when $1 is a wireless interface whose phy advertises AP mode.
is_ap_capable() {
  local iface=$1 phy
  phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/{print $2}' || true)
  [[ -n $phy ]] || return 1
  iw "phy$phy" info 2>/dev/null | grep -A 20 'Supported interface modes' | grep -qF '* AP'
}

if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --teardown)
      read -r -p "will flush all iptable rules... Continue y/n " answer
      if [[ ${answer:-n} =~ ^[Yy]$ ]]; then
        sudo iptables --flush
      fi
      exit 0
      ;;
    --help | -h)
      show_help
      exit 0
      ;;
    --from-interface | -f)
      [[ $# -ge 2 ]] || {
        echo "shic: $1 needs an interface" >&2
        exit 1
      }
      iface=$2
      shift 2
      echo "[+] sharing from interface: $iface"
      ;;
    --to-interface | -t)
      [[ $# -ge 2 ]] || {
        echo "shic: $1 needs an interface" >&2
        exit 1
      }
      oface=$2
      shift 2
      echo "[+] sharing to interface: $oface"
      wireless_check=/sys/class/net/$oface/wireless
      echo "checking $wireless_check"
      if [[ -d $wireless_check ]]; then
        echo "[+] is wireless interface"
        if ! is_ap_capable "$oface"; then
          echo "output interface not access point capable"
          show_help
          exit 1
        fi
        is_wifi=true
        # SSID and passphrase follow the interface for a wireless target.
        if [[ $# -lt 2 ]]; then
          echo "shic: a wireless target needs WIFI_SSID and WIFI_PASS" >&2
          exit 1
        fi
        wifi_ssid=$1
        wifi_pass=$2
        shift 2
      else
        echo "not a wireless interface"
      fi
      ;;
    --addresses)
      [[ $# -ge 2 ]] || {
        echo "shic: $1 needs an address/prefix" >&2
        exit 1
      }
      addresses=$2
      shift 2
      echo "ipv4.addresses = $addresses"
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    *)
      echo "shic: unknown argument: $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

if [[ -z $iface || -z $oface ]]; then
  show_help
  exit 1
fi

con_name="shared-$iface-to-$oface"

# --- Create or reuse connection ---
if nmcli connection show "$con_name" >/dev/null 2>&1; then
  echo "[+] Reusing existing connection $con_name"
else
  echo "[+] Creating shared connection $con_name"

  if [[ $is_wifi == true ]]; then
    echo "[+] Configuring WiFi AP mode"
    add_cmd=(
      sudo nmcli connection add
      type wifi
      ifname "$oface"
      con-name "$con_name"
      autoconnect yes
      ssid "$wifi_ssid"
      802-11-wireless.mode ap
      802-11-wireless.band bg
      ipv4.method shared
    )
  else
    add_cmd=(
      sudo nmcli connection add
      type ethernet
      ifname "$oface"
      con-name "$con_name"
      ipv4.method shared
    )
  fi
  if [[ -n $addresses ]]; then
    add_cmd+=(ipv4.addresses "$addresses")
  fi
  run_or_show "${add_cmd[@]}"

  if [[ $is_wifi == true ]]; then
    run_or_show sudo nmcli connection modify "$con_name" \
      wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "$wifi_pass" \
      connection.autoconnect no
  fi
fi

echo "[+] Bringing up shared connection"
run_or_show sudo nmcli connection up "$con_name"

# --- Wait for IP ---
echo "[+] Waiting for IP ON $oface"
if [[ $dry_run == false ]]; then
  sleep 3

  # `|| true` on both: a missing address is reported below as a friendly
  # error, and under `set -o pipefail` a non-matching grep would otherwise
  # abort the script before reaching that check.
  lan_ip=$(sudo ip -4 addr show "$oface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
  lan_subnet=$(sudo ip -4 route show dev "$oface" | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' || true)

  if [[ -z $lan_ip ]]; then
    echo "[!] Failed to detect LAN IP"
    exit 1
  fi

  echo "[+] LAN IP: $lan_ip"
  echo "[+] LAN subnet: $lan_subnet"
fi

# --- Enable forwarding ---
echo "[+] Enabling IP forwarding"
if [[ $dry_run == true ]]; then
  echo 'sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null'
else
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi

# Append a rule unless it is already present.
#
# The -C probe runs under sudo. The original ran a bare `iptables -C`, which
# fails with a permission error for a non-root caller -- so the check always
# reported "absent" and every re-run appended another copy of all three rules.
add_rule() {
  if [[ $dry_run == true ]]; then
    printf 'sudo iptables -A %s\n' "$*"
    return
  fi
  if ! sudo iptables -C "$@" 2>/dev/null; then
    run_or_show sudo iptables -A "$@"
  fi
}

# LAN -> WAN
add_rule FORWARD -i "$oface" -o "$iface" -j ACCEPT
# Return traffic
add_rule FORWARD -i "$iface" -o "$oface" -m state --state ESTABLISHED,RELATED -j ACCEPT
# adding nat
add_rule POSTROUTING -t nat -o "$iface" -j MASQUERADE

echo ""
echo "[+] Setup complete"
echo ""

if [[ $is_wifi == true ]]; then
  echo "📡 WiFi AP details:"
  echo "  SSID: $wifi_ssid"
  echo "  Password: $wifi_pass"
  # Guarded by dry_run: the original wrote /tmp/wifi.png and launched an
  # image viewer even for --dry-run, which is a side effect a dry run should
  # not have.
  if [[ $dry_run == false ]]; then
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -o /tmp/wifi.png "WIFI:T:WPA;S:$wifi_ssid;P:$wifi_pass;;"
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open /tmp/wifi.png
      fi
    else
      echo "install qrencode to get qrcode of wifi credentials"
    fi
  fi
fi
