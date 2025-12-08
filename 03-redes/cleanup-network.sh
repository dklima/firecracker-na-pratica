#!/usr/bin/env bash
#
# cleanup-network.sh
# Remove configuracao de rede TAP e NAT
# Suporta tanto iptables (Ubuntu) quanto firewalld (Fedora)
#
set -e

TAP_DEV="${TAP_DEV:-tap0}"
GUEST_NETWORK="172.16.0.0/24"

echo "Limpando configuracao de rede Firecracker"
echo

if [ "${EUID}" -ne 0 ]; then
    echo "[ERRO] Este script precisa ser executado como root"
    exit 1
fi

detect_firewall() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
    elif command -v iptables &>/dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

FIREWALL_TYPE=$(detect_firewall)
echo "[INFO] Firewall detectado: ${FIREWALL_TYPE}"

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')

if [ "${FIREWALL_TYPE}" = "firewalld" ]; then
    # (Fedora)
    echo "[1/3] Removendo regras do firewalld..."

    # Remove interface da zona trusted
    firewall-cmd --zone=trusted --remove-interface="${TAP_DEV}" 2>/dev/null || true

    # Remove rich rules de isolamento
    firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=10.0.0.0/8 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=192.168.0.0/16 drop" 2>/dev/null || true

    # Nota: masquerading e mantido pois pode ser usado por outras VMs
    echo "      Masquerading mantido (pode afetar outras VMs)"
    echo "      Para remover: sudo firewall-cmd --remove-masquerade"

else
    # (Ubuntu e outros)
    echo "[1/3] Removendo regras de iptables..."

    # Remove regras de NAT
    iptables -t nat -D POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -o "${DEFAULT_IFACE}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${DEFAULT_IFACE}" -o "${TAP_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    # Remove regras de isolamento
    iptables -D FORWARD -i "${TAP_DEV}" -d 172.16.0.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -d 192.168.0.0/16 -j DROP 2>/dev/null || true
fi

echo "[2/3] Removendo interface TAP..."
if ip link show "${TAP_DEV}" &>/dev/null; then
    ip link set "${TAP_DEV}" down
    ip tuntap del dev "${TAP_DEV}" mode tap
    echo "      ${TAP_DEV} removida"
else
    echo "      ${TAP_DEV} nao existe"
fi

echo "[3/3] Verificando IP forwarding..."
echo "      IP forwarding mantido (pode afetar outras VMs)"
echo "      Para desabilitar: sudo sysctl -w net.ipv4.ip_forward=0"

echo
echo "Limpeza concluida!"
