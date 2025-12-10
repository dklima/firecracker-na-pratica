#!/bin/bash
# firecracker-network-setup.sh
# Configura rede para microVM Firecracker
#
# Uso:
#   ./firecracker-network-setup.sh up    # Cria interface TAP e configura NAT
#   ./firecracker-network-setup.sh down  # Remove interface TAP
#
# Variaveis de ambiente (opcionais):
#   TAP_DEV   - Nome da interface TAP (default: tap0)
#   TAP_IP    - IP do host na interface TAP (default: 172.16.0.1)
#   TAP_CIDR  - Mascara CIDR (default: 24)

set -e

TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-172.16.0.1}"
TAP_CIDR="${TAP_CIDR:-24}"

ACTION="${1:-up}"

# Cores para output (desabilita se nao for terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Este script precisa ser executado como root"
        exit 1
    fi
}

setup_network() {
    log_info "Configurando rede para microVM..."
    log_info "  TAP Device: $TAP_DEV"
    log_info "  TAP IP: $TAP_IP/$TAP_CIDR"

    # Verifica se ja existe
    if ip link show "$TAP_DEV" &>/dev/null; then
        log_warn "Interface $TAP_DEV ja existe, pulando criacao"
        return 0
    fi

    # Cria interface TAP
    ip tuntap add dev "$TAP_DEV" mode tap
    ip addr add "${TAP_IP}/${TAP_CIDR}" dev "$TAP_DEV"
    ip link set "$TAP_DEV" up

    log_info "Interface $TAP_DEV criada"

    # Habilita IP forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    log_info "IP forwarding habilitado"

    # Configura firewall (detecta firewalld ou iptables)
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        setup_firewalld
    else
        setup_iptables
    fi

    log_info "Rede configurada com sucesso"
}

setup_firewalld() {
    log_info "Configurando firewalld..."

    # Adiciona TAP a zona trusted
    firewall-cmd --zone=trusted --add-interface="$TAP_DEV" 2>/dev/null || true

    # Habilita masquerading (NAT)
    firewall-cmd --add-masquerade 2>/dev/null || true

    # Bloqueia acesso a redes privadas (seguranca)
    # VM pode acessar internet, mas nao a rede local do host
    firewall-cmd --zone=trusted --add-rich-rule="rule family=ipv4 source address=172.16.0.0/24 destination address=10.0.0.0/8 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --add-rich-rule="rule family=ipv4 source address=172.16.0.0/24 destination address=192.168.0.0/16 drop" 2>/dev/null || true

    log_info "firewalld configurado"
}

setup_iptables() {
    log_info "Configurando iptables..."

    # Detecta interface de saida
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

    if [ -z "$DEFAULT_IFACE" ]; then
        log_error "Nao foi possivel detectar interface de saida"
        exit 1
    fi

    log_info "Interface de saida: $DEFAULT_IFACE"

    # NAT/Masquerading
    iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE

    # Forward da TAP para interface de saida
    iptables -C FORWARD -i "$TAP_DEV" -o "$DEFAULT_IFACE" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$TAP_DEV" -o "$DEFAULT_IFACE" -j ACCEPT

    # Forward de pacotes de resposta
    iptables -C FORWARD -i "$DEFAULT_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$DEFAULT_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Bloqueia acesso a redes privadas (seguranca)
    # VM pode acessar internet, mas nao a rede local do host
    iptables -C FORWARD -i "$TAP_DEV" -d 10.0.0.0/8 -j DROP 2>/dev/null || \
        iptables -I FORWARD -i "$TAP_DEV" -d 10.0.0.0/8 -j DROP

    iptables -C FORWARD -i "$TAP_DEV" -d 192.168.0.0/16 -j DROP 2>/dev/null || \
        iptables -I FORWARD -i "$TAP_DEV" -d 192.168.0.0/16 -j DROP

    log_info "iptables configurado"
}

teardown_network() {
    log_info "Removendo configuracao de rede..."

    if ip link show "$TAP_DEV" &>/dev/null; then
        ip link set "$TAP_DEV" down
        ip tuntap del dev "$TAP_DEV" mode tap
        log_info "Interface $TAP_DEV removida"
    else
        log_warn "Interface $TAP_DEV nao existe"
    fi

    # Nota: nao removemos regras de firewall automaticamente
    # pois podem estar sendo usadas por outras VMs

    log_info "Limpeza concluida"
}

show_status() {
    echo ""
    echo "Status da rede:"
    echo ""

    if ip link show "$TAP_DEV" &>/dev/null; then
        echo "Interface $TAP_DEV:"
        ip addr show "$TAP_DEV" | grep -E "inet|state"
        echo ""
    else
        echo "Interface $TAP_DEV: NAO EXISTE"
        echo ""
    fi

    echo "IP Forwarding:"
    sysctl net.ipv4.ip_forward
    echo ""

    echo "Masquerading:"
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --query-masquerade && echo "  firewalld: ATIVO" || echo "  firewalld: INATIVO"
    else
        iptables -t nat -L POSTROUTING -n | grep -q MASQUERADE && echo "  iptables: ATIVO" || echo "  iptables: INATIVO"
    fi
}

show_usage() {
    echo "Uso: $0 {up|down|status}"
    echo ""
    echo "Comandos:"
    echo "  up      Cria interface TAP e configura NAT"
    echo "  down    Remove interface TAP"
    echo "  status  Mostra status da configuracao"
    echo ""
    echo "Variaveis de ambiente:"
    echo "  TAP_DEV=$TAP_DEV"
    echo "  TAP_IP=$TAP_IP"
    echo "  TAP_CIDR=$TAP_CIDR"
}

# Main
check_root

case "$ACTION" in
    up|start)
        setup_network
        ;;
    down|stop)
        teardown_network
        ;;
    status)
        show_status
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
