#!/bin/bash
# firecracker-vm-start.sh
# Inicia uma microVM Firecracker e configura via API
#
# Este script:
# 1. Inicia o processo Firecracker
# 2. Aguarda o socket API ficar disponivel
# 3. Configura kernel, rootfs, recursos e rede via API
# 4. Inicia a microVM
# 5. Aguarda o processo (mantendo o servico rodando)
#
# Variaveis de ambiente:
#   VM_NAME       - Nome da VM (default: default)
#   SOCKET_PATH   - Caminho do socket API (default: /run/firecracker/${VM_NAME}.socket)
#   KERNEL_PATH   - Caminho do kernel (default: /var/lib/firecracker/vmlinux.bin)
#   ROOTFS_PATH   - Caminho do rootfs (default: /var/lib/firecracker/rootfs-${VM_NAME}.ext4)
#   VCPU_COUNT    - Numero de vCPUs (default: 1)
#   MEM_SIZE_MIB  - Memoria em MiB (default: 256)
#   TAP_DEV       - Interface TAP (default: tap0)
#   GUEST_MAC     - MAC address do guest (default: AA:FC:00:00:00:01)
#   BOOT_ARGS     - Argumentos de boot do kernel (default: console=ttyS0 reboot=k panic=1 pci=off quiet)

set -e

# Configuracoes (podem ser sobrescritas por variaveis de ambiente)
VM_NAME="${VM_NAME:-default}"
SOCKET_PATH="${SOCKET_PATH:-/run/firecracker/${VM_NAME}.socket}"
KERNEL_PATH="${KERNEL_PATH:-/var/lib/firecracker/vmlinux.bin}"
ROOTFS_PATH="${ROOTFS_PATH:-/var/lib/firecracker/rootfs-${VM_NAME}.ext4}"
VCPU_COUNT="${VCPU_COUNT:-1}"
MEM_SIZE_MIB="${MEM_SIZE_MIB:-256}"
TAP_DEV="${TAP_DEV:-tap0}"
GUEST_MAC="${GUEST_MAC:-AA:FC:00:00:00:01}"
BOOT_ARGS="${BOOT_ARGS:-console=ttyS0 reboot=k panic=1 pci=off quiet}"

FIRECRACKER_BIN="${FIRECRACKER_BIN:-/usr/local/bin/firecracker}"

# Cores para output
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

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    log_info "Recebido sinal de parada, limpando..."
    if [ -n "$FC_PID" ] && kill -0 "$FC_PID" 2>/dev/null; then
        kill "$FC_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET_PATH"
}

trap cleanup EXIT SIGTERM SIGINT

# Validacoes
validate_files() {
    if [ ! -x "$FIRECRACKER_BIN" ]; then
        log_error "Firecracker nao encontrado ou nao executavel: $FIRECRACKER_BIN"
        exit 1
    fi

    if [ ! -f "$KERNEL_PATH" ]; then
        log_error "Kernel nao encontrado: $KERNEL_PATH"
        exit 1
    fi

    if [ ! -f "$ROOTFS_PATH" ]; then
        log_error "Rootfs nao encontrado: $ROOTFS_PATH"
        exit 1
    fi

    if ! ip link show "$TAP_DEV" &>/dev/null; then
        log_error "Interface TAP nao existe: $TAP_DEV"
        log_error "Execute primeiro: firecracker-network-setup.sh up"
        exit 1
    fi
}

call_api() {
    local method="$1"
    local path="$2"
    local data="$3"

    local response
    response=$(curl --unix-socket "$SOCKET_PATH" -s -w "\n%{http_code}" -X "$method" \
        "http://localhost$path" \
        -H "Content-Type: application/json" \
        -d "$data" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ge 400 ]; then
        log_error "API error ($http_code): $body"
        return 1
    fi
}

start_firecracker() {
    # Garante que o diretorio do socket existe
    mkdir -p "$(dirname "$SOCKET_PATH")"

    # Remove socket antigo se existir
    rm -f "$SOCKET_PATH"

    log_info "Iniciando Firecracker..."
    log_info "  VM Name: $VM_NAME"
    log_info "  Socket: $SOCKET_PATH"
    log_info "  Kernel: $KERNEL_PATH"
    log_info "  Rootfs: $ROOTFS_PATH"
    log_info "  vCPUs: $VCPU_COUNT"
    log_info "  Memory: ${MEM_SIZE_MIB}MB"
    log_info "  TAP: $TAP_DEV"
    log_info "  MAC: $GUEST_MAC"

    # Inicia Firecracker em background
    $FIRECRACKER_BIN --api-sock "$SOCKET_PATH" &
    FC_PID=$!

    # Aguarda socket ficar disponivel
    local attempts=0
    local max_attempts=50
    while [ $attempts -lt $max_attempts ]; do
        if [ -S "$SOCKET_PATH" ]; then
            break
        fi
        sleep 0.1
        attempts=$((attempts + 1))
    done

    if [ ! -S "$SOCKET_PATH" ]; then
        log_error "Timeout esperando socket do Firecracker"
        exit 1
    fi

    # Pequena pausa pra garantir que o socket esta pronto
    sleep 0.2

    log_info "Firecracker iniciado (PID: $FC_PID)"
}

configure_vm() {
    log_info "Configurando VM via API..."

    # Configura kernel
    log_info "  Configurando kernel..."
    call_api "PUT" "/boot-source" "{
        \"kernel_image_path\": \"$KERNEL_PATH\",
        \"boot_args\": \"$BOOT_ARGS\"
    }"

    # Configura rootfs
    log_info "  Configurando rootfs..."
    call_api "PUT" "/drives/rootfs" "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"$ROOTFS_PATH\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }"

    # Configura recursos
    log_info "  Configurando recursos..."
    call_api "PUT" "/machine-config" "{
        \"vcpu_count\": $VCPU_COUNT,
        \"mem_size_mib\": $MEM_SIZE_MIB
    }"

    # Configura rede
    log_info "  Configurando rede..."
    call_api "PUT" "/network-interfaces/eth0" "{
        \"iface_id\": \"eth0\",
        \"guest_mac\": \"$GUEST_MAC\",
        \"host_dev_name\": \"$TAP_DEV\"
    }"

    log_info "VM configurada"
}

start_vm() {
    log_info "Iniciando microVM..."

    call_api "PUT" "/actions" '{"action_type": "InstanceStart"}'

    log_info "MicroVM iniciada com sucesso"
}

# Main
validate_files
start_firecracker
configure_vm
start_vm

log_info "Aguardando processo Firecracker..."

# Aguarda o processo Firecracker (isso mantem o servico "rodando")
wait $FC_PID
exit_code=$?

log_info "Firecracker encerrou com codigo: $exit_code"
exit $exit_code
