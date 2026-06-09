#!/bin/bash
# firecracker-network-setup.sh
# Configura rede para microVM Firecracker
#
# Uso:
#   ./firecracker-network-setup.sh up    # Cria interface TAP e configura NAT
#   ./firecracker-network-setup.sh down  # Remove interface TAP
#
# Variáveis de ambiente (opcionais):
#   TAP_DEV   - Nome da interface TAP (default: tap0)
#   TAP_IP    - IP do host na interface TAP (default: 172.16.0.1)
#   TAP_CIDR  - Máscara CIDR (default: 24)

set -e

TAP_DEV="${TAP_DEV:-tap0}"
TAP_IP="${TAP_IP:-172.16.0.1}"
TAP_CIDR="${TAP_CIDR:-24}"

# Subnet da VM derivada do TAP_IP (172.16.0.1 -> 172.16.0.0/24)
GUEST_NETWORK="${TAP_IP%.*}.0/${TAP_CIDR}"

ACTION="${1:-up}"

# Cores para output (desabilita se não for terminal)
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

    # Verifica se já existe
    if ip link show "$TAP_DEV" &>/dev/null; then
        log_warn "Interface $TAP_DEV ja existe, pulando criacao"
    else
        # Cria interface TAP
        ip tuntap add dev "$TAP_DEV" mode tap
        ip addr add "${TAP_IP}/${TAP_CIDR}" dev "$TAP_DEV"
        ip link set "$TAP_DEV" up
        log_info "Interface $TAP_DEV criada"
    fi

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

    # Adiciona TAP à zona trusted
    firewall-cmd --zone=trusted --add-interface="$TAP_DEV" 2>/dev/null || true

    # Habilita masquerading (NAT)
    firewall-cmd --add-masquerade 2>/dev/null || true

    # Isolamento - parte 1: rich rules (cadeia INPUT, tráfego destinado ao host)
    firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=10.0.0.0/8 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=192.168.0.0/16 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --add-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=10.0.0.0/8 drop" 2>/dev/null || true
    firewall-cmd --zone=trusted --add-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=192.168.0.0/16 drop" 2>/dev/null || true

    # Isolamento - parte 2: direct rules na cadeia FORWARD (tráfego roteado pra LAN).
    # As rich rules acima só pegam tráfego pro próprio host. O tráfego que a VM
    # tenta encaminhar pra outros hosts da rede local passa pela cadeia FORWARD,
    # então sem estas regras a VM ainda consegue escanear a rede local.
    firewall-cmd --direct --add-rule ipv4 filter FORWARD 0 -i "$TAP_DEV" -d "$GUEST_NETWORK" -j ACCEPT 2>/dev/null || true
    firewall-cmd --direct --add-rule ipv4 filter FORWARD 1 -i "$TAP_DEV" -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    firewall-cmd --direct --add-rule ipv4 filter FORWARD 1 -i "$TAP_DEV" -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    firewall-cmd --direct --add-rule ipv4 filter FORWARD 1 -i "$TAP_DEV" -d 192.168.0.0/16 -j DROP 2>/dev/null || true

    log_info "firewalld configurado (NAT + isolamento INPUT/FORWARD)"
}

setup_iptables() {
    log_info "Configurando iptables..."

    # Detecta interface de saída
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

    if [ -z "$DEFAULT_IFACE" ]; then
        log_error "Nao foi possivel detectar interface de saida"
        exit 1
    fi

    log_info "Interface de saida: $DEFAULT_IFACE"

    # NAT/Masquerading
    iptables -t nat -C POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE

    # Forward da TAP para interface de saída
    iptables -C FORWARD -i "$TAP_DEV" -o "$DEFAULT_IFACE" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$TAP_DEV" -o "$DEFAULT_IFACE" -j ACCEPT

    # Forward de pacotes de resposta
    iptables -C FORWARD -i "$DEFAULT_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$DEFAULT_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Isolamento: a VM acessa a internet, mas não a rede local do host.
    # Permite a própria subnet da VM antes dos blocos (regra entra no topo).
    iptables -C FORWARD -i "$TAP_DEV" -d "$GUEST_NETWORK" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "$TAP_DEV" -d "$GUEST_NETWORK" -j ACCEPT

    iptables -C FORWARD -i "$TAP_DEV" -d 10.0.0.0/8 -j DROP 2>/dev/null || \
        iptables -I FORWARD 2 -i "$TAP_DEV" -d 10.0.0.0/8 -j DROP

    iptables -C FORWARD -i "$TAP_DEV" -d 172.16.0.0/12 -j DROP 2>/dev/null || \
        iptables -I FORWARD 3 -i "$TAP_DEV" -d 172.16.0.0/12 -j DROP

    iptables -C FORWARD -i "$TAP_DEV" -d 192.168.0.0/16 -j DROP 2>/dev/null || \
        iptables -I FORWARD 4 -i "$TAP_DEV" -d 192.168.0.0/16 -j DROP

    log_info "iptables configurado (NAT + isolamento FORWARD)"
}

teardown_network() {
    log_info "Removendo configuracao de rede..."

    # Remove as regras de firewall desta TAP (mantém masquerading, que pode
    # estar sendo usado por outras VMs).
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --zone=trusted --remove-interface="$TAP_DEV" 2>/dev/null || true
        firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=10.0.0.0/8 drop" 2>/dev/null || true
        firewall-cmd --zone=trusted --remove-rich-rule="rule family=ipv4 source address=${GUEST_NETWORK} destination address=192.168.0.0/16 drop" 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 filter FORWARD 0 -i "$TAP_DEV" -d "$GUEST_NETWORK" -j ACCEPT 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 filter FORWARD 1 -i "$TAP_DEV" -d 10.0.0.0/8 -j DROP 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 filter FORWARD 1 -i "$TAP_DEV" -d 172.16.0.0/12 -j DROP 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 filter FORWARD 1 -i "$TAP_DEV" -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    fi

    if ip link show "$TAP_DEV" &>/dev/null; then
        ip link set "$TAP_DEV" down
        ip tuntap del dev "$TAP_DEV" mode tap
        log_info "Interface $TAP_DEV removida"
    else
        log_warn "Interface $TAP_DEV nao existe"
    fi

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
