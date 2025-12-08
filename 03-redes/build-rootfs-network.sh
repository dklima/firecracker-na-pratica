#!/usr/bin/env bash
#
# build-rootfs-network.sh
# Constroi um rootfs Alpine Linux com Python e suporte a rede para Firecracker
#
set -e

ROOTFS_FILE="rootfs-network.ext4"
ROOTFS_SIZE_MB=500
MOUNT_POINT="/tmp/rootfs-mount-$$"
ALPINE_VERSION="3.21"

echo "Construindo rootfs com Python e rede para Firecracker"
echo

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="${ID}"
        DISTRO_FAMILY="${ID_LIKE:-${ID}}"
    elif [ -f /etc/fedora-release ]; then
        DISTRO="fedora"
        DISTRO_FAMILY="fedora"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
        DISTRO_FAMILY="debian"
    else
        DISTRO="unknown"
        DISTRO_FAMILY="unknown"
    fi
}

detect_distro
echo "[INFO] Distribuicao detectada: ${DISTRO}"

if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
else
    echo "[ERRO] Docker ou Podman nao encontrado!"
    exit 1
fi

echo "[INFO] Usando ${CONTAINER_CMD}"
echo

if [ "${EUID}" -ne 0 ]; then
    echo "[ERRO] Este script precisa ser executado como root ou com sudo"
    exit 1
fi

check_deps() {
    local missing=()

    if ! command -v mkfs.ext4 &> /dev/null; then
        missing+=("e2fsprogs")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "[ERRO] Dependencias faltando: ${missing[*]}"
        exit 1
    fi
}

check_deps

echo "[1/6] Criando imagem de disco (${ROOTFS_SIZE_MB}MB)..."
dd if=/dev/zero of="${ROOTFS_FILE}" bs=1M count="${ROOTFS_SIZE_MB}" status=progress
mkfs.ext4 -F "${ROOTFS_FILE}"

echo "[2/6] Montando..."
mkdir -p "${MOUNT_POINT}"
mount "${ROOTFS_FILE}" "${MOUNT_POINT}"

cleanup() {
    echo "[*] Limpando..."
    umount "${MOUNT_POINT}" 2>/dev/null || true
    rmdir "${MOUNT_POINT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[3/6] Instalando Alpine Linux ${ALPINE_VERSION} com Python e rede..."
${CONTAINER_CMD} run --rm -v "${MOUNT_POINT}:/rootfs:Z" "alpine:${ALPINE_VERSION}" sh -c '
    mkdir -p /rootfs/etc/apk
    cp -a /etc/apk/keys /rootfs/etc/apk/
    cp /etc/apk/repositories /rootfs/etc/apk/
    apk add --root /rootfs --initdb --no-cache \
        alpine-base \
        openrc \
        python3 \
        py3-requests \
        py3-urllib3 \
        ca-certificates
'

echo "[4/6] Configurando sistema..."
chroot "${MOUNT_POINT}" /bin/sh -c '
    echo "nano-lambda-net" > /etc/hostname

    echo "127.0.0.1 localhost" > /etc/hosts
    echo "::1 localhost" >> /etc/hosts

    cat > /etc/inittab << "INITTAB"
# /etc/inittab - Configurado para microVM Lambda-style com rede

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Executa a funcao Lambda apos o boot
::wait:/run-function.sh

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
INITTAB

    mkdir -p /functions /output

    # DNS
    cat > /etc/resolv.conf << "DNS"
nameserver 8.8.8.8
nameserver 1.1.1.1
DNS

    # Script de execucao com rede
    cat > /run-function.sh << "SCRIPT"
#!/bin/sh
echo ""
echo "======================================"
echo "=== Configurando rede... ==="
echo "======================================"

# Configura interface de rede
ip link set eth0 up
ip addr add 172.16.0.2/24 dev eth0
ip route add default via 172.16.0.1

# Testa conectividade
echo ""
echo "Testando conectividade..."
if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
    echo "Internet: OK"
else
    echo "Internet: FALHOU"
fi

echo ""
echo "======================================"
echo "=== nano-Lambda executando... ==="
echo "======================================"
echo ""

if [ -f /functions/handler.py ]; then
    cd /functions
    python3 handler.py
    RETVAL=$?
    echo ""
    echo "======================================"
    echo "=== Execucao finalizada (exit: $RETVAL) ==="
    echo "======================================"
else
    echo "ERRO: handler.py nao encontrado"
fi

echo ""
sync
sleep 1
poweroff -f
SCRIPT
    chmod +x /run-function.sh
'

echo "[5/6] Limpando caches..."
chroot "${MOUNT_POINT}" /bin/sh -c '
    rm -rf /var/cache/apk/*
    rm -rf /tmp/*
'

echo "[6/6] Finalizando..."
umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
trap - EXIT

echo
echo "${ROOTFS_FILE} criado com sucesso!"
echo "    Tamanho: $(du -h ${ROOTFS_FILE} | cut -f1)"
