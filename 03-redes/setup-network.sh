#!/usr/bin/env bash
#
# setup-network.sh
# Configura rede TAP e NAT para microVMs Firecracker
# Suporta tanto iptables (Ubuntu) quanto firewalld (Fedora)
#
set -e

TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-172.16.0.1}"
TAP_CIDR="${TAP_CIDR:-24}"
GUEST_NETWORK="172.16.0.0/24"

echo "Configurando rede para Firecracker"
echo "  TAP: ${TAP_DEV}"
echo "  IP: ${TAP_IP}/${TAP_CIDR}"
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

get_default_iface() {
    ip route show default | awk '/default/ {print $5; exit}'
}

DEFAULT_IFACE=$(get_default_iface)

if [ -z "${DEFAULT_IFACE}" ]; then
    echo "[ERRO] Nao foi possivel detectar interface de saida"
    echo "       Verifique sua conexao de rede"
    exit 1
fi

echo "[INFO] Interface de saida: ${DEFAULT_IFACE}"

echo "[1/5] Criando interface TAP..."
if ip link show "${TAP_DEV}" &>/dev/null; then
    echo "      TAP ${TAP_DEV} ja existe, reconfigurando..."
    ip link set "${TAP_DEV}" down 2>/dev/null || true
    ip addr flush dev "${TAP_DEV}" 2>/dev/null || true
else
    ip tuntap add dev "${TAP_DEV}" mode tap
fi

echo "[2/5] Configurando IP..."
ip addr add "${TAP_IP}/${TAP_CIDR}" dev "${TAP_DEV}" 2>/dev/null || true
ip link set "${TAP_DEV}" up

echo "[3/5] Habilitando IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null

if [ "${FIREWALL_TYPE}" = "firewalld" ]; then
    # (Fedora)
    echo "[4/5] Configurando firewalld..."

    firewall-cmd --zone=trusted --add-interface="${TAP_DEV}" 2>/dev/null || true
    firewall-cmd --add-masquerade 2>/dev/null || true

    echo "[5/5] Configurando isolamento de rede..."
    # Bloqueia acesso a redes privadas via rich rules
    # Remove regras antigas primeiro
    firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=10.0.0.0/8 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=192.168.0.0/16 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --add-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=10.0.0.0/8 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --add-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=192.168.0.0/16 drop" 2>/dev/null || true

    echo "      Regras aplicadas (runtime, nao persistente)"
    echo "      Para persistir: adicione --permanent aos comandos"

else
    # (Ubuntu e outros)
    echo "[4/5] Configurando NAT..."

    # Remove regras antigas se existirem
    iptables -t nat -D POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -o "${DEFAULT_IFACE}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${DEFAULT_IFACE}" -o "${TAP_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    iptables -t nat -A POSTROUTING -o "${DEFAULT_IFACE}" -j MASQUERADE
    iptables -A FORWARD -i "${TAP_DEV}" -o "${DEFAULT_IFACE}" -j ACCEPT
    iptables -A FORWARD -i "${DEFAULT_IFACE}" -o "${TAP_DEV}" -m state --state RELATED,ESTABLISHED -j ACCEPT

    echo "[5/5] Configurando isolamento de rede local..."

    # Remove regras antigas
    iptables -D FORWARD -i "${TAP_DEV}" -d 172.16.0.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i "${TAP_DEV}" -d 192.168.0.0/16 -j DROP 2>/dev/null || true

    # Permite subnet da VM
    iptables -I FORWARD -i "${TAP_DEV}" -d 172.16.0.0/24 -j ACCEPT

    # Bloqueia redes privadas
    iptables -I FORWARD 2 -i "${TAP_DEV}" -d 10.0.0.0/8 -j DROP
    iptables -I FORWARD 3 -i "${TAP_DEV}" -d 172.16.0.0/12 -j DROP
    iptables -I FORWARD 4 -i "${TAP_DEV}" -d 192.168.0.0/16 -j DROP
fi

echo
echo "Rede configurada com sucesso!"
echo
echo "Configuracao da VM:"
echo "  IP: 172.16.0.2"
echo "  Gateway: ${TAP_IP}"
echo "  DNS: 8.8.8.8"
echo
echo "Para limpar: sudo ./cleanup-network.sh"
