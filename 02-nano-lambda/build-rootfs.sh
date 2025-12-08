#!/usr/bin/env bash
#
# build-rootfs.sh
# Constrói um rootfs Alpine Linux com Python para usar com Firecracker
#
set -e

# Configurações
ROOTFS_FILE="rootfs-python.ext4"
ROOTFS_SIZE_MB=500
MOUNT_POINT="/tmp/rootfs-mount-$$"
ALPINE_VERSION="3.21"

echo "Construindo rootfs com Python para Firecracker"
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
echo "[INFO] Distribuição detectada: ${DISTRO}"

# Detecta se tem Docker ou Podman
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
else
    echo "[ERRO] Docker ou Podman não encontrado!"
    echo

    case "${DISTRO}" in
        fedora|rhel|centos|rocky|alma)
            echo "       No Fedora/RHEL, instale Podman com:"
            echo "       sudo dnf install podman"
            ;;
        ubuntu|debian|linuxmint|pop)
            echo "       No Ubuntu/Debian, instale Docker com:"
            echo "       sudo apt install docker.io"
            echo "       Ou Podman com:"
            echo "       sudo apt install podman"
            ;;
        *)
            echo "       Instale Docker ou Podman para continuar."
            ;;
    esac
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
        echo "[ERRO] Dependências faltando: ${missing[*]}"
        echo

        case "${DISTRO}" in
            fedora|rhel|centos|rocky|alma)
                echo "       Instale com: sudo dnf install ${missing[*]}"
                ;;
            ubuntu|debian|linuxmint|pop)
                echo "       Instale com: sudo apt install ${missing[*]}"
                ;;
        esac
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

echo "[3/6] Instalando Alpine Linux ${ALPINE_VERSION} com Python..."
# Copia keys e repositórios primeiro (necessário para Podman)
# Usa :Z para SELinux no Fedora/RHEL
${CONTAINER_CMD} run --rm -v "${MOUNT_POINT}:/rootfs:Z" "alpine:${ALPINE_VERSION}" sh -c '
    mkdir -p /rootfs/etc/apk
    cp -a /etc/apk/keys /rootfs/etc/apk/
    cp /etc/apk/repositories /rootfs/etc/apk/
    apk add --root /rootfs --initdb --no-cache \
        alpine-base \
        openrc \
        python3 \
        py3-pillow \
        py3-qrcode
'

echo "[4/6] Configurando sistema..."
chroot "${MOUNT_POINT}" /bin/sh -c '
    # Hostname
    echo "nano-lambda" > /etc/hostname

    # Rede básica
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "::1 localhost" >> /etc/hosts

    # Inittab configurado para Lambda-style
    # Executa a função diretamente via inittab, sem getty
    cat > /etc/inittab << "INITTAB"
# /etc/inittab - Configurado para microVM Lambda-style
# Executa função e desliga automaticamente

::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Executa a função Lambda após o boot
::wait:/run-function.sh

# Ctrl+Alt+Del
::ctrlaltdel:/sbin/reboot

# Shutdown
::shutdown:/sbin/openrc shutdown
INITTAB

    # Diretórios de trabalho
    mkdir -p /functions /output

    # Script de execução
    cat > /run-function.sh << "SCRIPT"
#!/bin/sh
echo ""
echo "=== nano-Lambda executando... ==="
echo ""

if [ -f /functions/handler.py ]; then
    cd /functions
    python3 handler.py
    RETVAL=$?
    echo ""
    echo "=== Execucao finalizada (exit: $RETVAL) ==="
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
