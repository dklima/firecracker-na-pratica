#!/usr/bin/env bash
#
# build-rootfs-service.sh
# Constroi um rootfs Alpine que sobe a rede e fica vivo como servico.
#
# Diferenca para o rootfs do artigo 03: aquele rodava a funcao uma vez e
# dava reboot (modelo Lambda). Um servico de verdade precisa ficar no ar,
# entao aqui o init configura a rede e depois mantem a VM rodando.
#
set -e

ROOTFS_FILE="rootfs-service.ext4"
ROOTFS_SIZE_MB=500
MOUNT_POINT="/tmp/rootfs-mount-$$"
ALPINE_VERSION="3.21"

echo "Construindo rootfs de servico persistente para Firecracker"
echo

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

if ! command -v mkfs.ext4 &> /dev/null; then
    echo "[ERRO] mkfs.ext4 nao encontrado (instale e2fsprogs)"
    exit 1
fi

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
    echo "nano-lambda" > /etc/hostname

    echo "127.0.0.1 localhost" > /etc/hosts
    echo "::1 localhost" >> /etc/hosts

    cat > /etc/inittab << "INITTAB"
# /etc/inittab - microVM de servico persistente

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Sobe a rede e mantem a VM viva (servico, nao Lambda)
::wait:/usr/local/bin/vm-service.sh

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
INITTAB

    # DNS
    cat > /etc/resolv.conf << "DNS"
nameserver 8.8.8.8
nameserver 1.1.1.1
DNS

    mkdir -p /usr/local/bin

    # Script de servico: configura rede e fica no ar
    cat > /usr/local/bin/vm-service.sh << "SCRIPT"
#!/bin/sh
echo ""
echo "=== nano-lambda: configurando rede ==="

ip link set eth0 up
ip addr add 172.16.0.2/24 dev eth0
ip route add default via 172.16.0.1

# Relatorio de conectividade (aparece no journal do host)
if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
    echo "[net] internet: OK"
else
    echo "[net] internet: FALHOU"
fi

echo "=== nano-lambda: servico no ar ==="
echo "READY"

# Mantem a microVM viva. Em producao, aqui rodaria seu worker ou servidor.
while true; do
    sleep 3600
done
SCRIPT
    chmod +x /usr/local/bin/vm-service.sh
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
