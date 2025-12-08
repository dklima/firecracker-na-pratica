#!/usr/bin/env bash
#
# check-kvm.sh
# Verifica se o ambiente está pronto para rodar Firecracker
#

echo "=== Verificando ambiente para Firecracker ==="
echo

# Detecta a distribuição
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

# Verifica se /dev/kvm existe
if [ ! -e /dev/kvm ]; then
    echo "[ERRO] /dev/kvm não encontrado!"
    echo "       Verifique se KVM está habilitado e os módulos carregados."
    echo
    echo "       Para carregar os módulos:"
    echo "       sudo modprobe kvm"
    echo "       sudo modprobe kvm_intel  # ou kvm_amd"
    echo

    # Instruções específicas por distro
    case "${DISTRO}" in
        fedora|rhel|centos|rocky|alma)
            echo "       No Fedora/RHEL, você pode instalar as ferramentas de virtualização com:"
            echo "       sudo dnf install @virtualization"
            ;;
        ubuntu|debian|linuxmint|pop)
            echo "       No Ubuntu/Debian, você pode instalar o KVM com:"
            echo "       sudo apt install qemu-kvm libvirt-daemon-system"
            ;;
    esac
    exit 1
fi

echo "[OK] /dev/kvm encontrado"

# Verifica permissões
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "[AVISO] Sem permissão de leitura/escrita em /dev/kvm"

    case "${DISTRO}" in
        fedora|rhel|centos|rocky|alma)
            echo "        No Fedora/RHEL, adicione seu usuário ao grupo 'kvm' ou 'libvirt':"
            echo "        sudo usermod -aG kvm \${USER}"
            echo "        sudo usermod -aG libvirt \${USER}"
            ;;
        *)
            echo "        Adicione seu usuário ao grupo 'kvm':"
            echo "        sudo usermod -aG kvm \${USER}"
            ;;
    esac
    echo "        (depois faça logout e login novamente)"
else
    echo "[OK] Permissões de /dev/kvm corretas"
fi

# Verifica módulos KVM
if lsmod | grep -q "kvm_intel"; then
    echo "[OK] Módulo kvm_intel carregado"
    KVM_MODULE="intel"
elif lsmod | grep -q "kvm_amd"; then
    echo "[OK] Módulo kvm_amd carregado"
    KVM_MODULE="amd"
else
    echo "[AVISO] Módulos kvm_intel ou kvm_amd não encontrados"
    echo "        Virtualização pode não estar habilitada na BIOS"
fi

# Verifica nested virtualization (útil se estiver rodando dentro de VM)
if [ -n "${KVM_MODULE}" ]; then
    NESTED_FILE="/sys/module/kvm_${KVM_MODULE}/parameters/nested"
    if [ -f "${NESTED_FILE}" ]; then
        NESTED=$(cat "${NESTED_FILE}")
        if [ "${NESTED}" = "Y" ] || [ "${NESTED}" = "1" ]; then
            echo "[OK] Nested virtualization habilitada"
        else
            echo "[INFO] Nested virtualization desabilitada"
            echo "       Se você está rodando dentro de uma VM, pode precisar habilitá-la"

            case "${DISTRO}" in
                fedora|rhel|centos|rocky|alma)
                    echo "       No Fedora/RHEL, para habilitar nested virtualization:"
                    echo "       echo 'options kvm_${KVM_MODULE} nested=1' | sudo tee /etc/modprobe.d/kvm.conf"
                    echo "       sudo modprobe -r kvm_${KVM_MODULE} && sudo modprobe kvm_${KVM_MODULE}"
                    ;;
                ubuntu|debian|linuxmint|pop)
                    echo "       No Ubuntu/Debian, para habilitar nested virtualization:"
                    echo "       echo 'options kvm_${KVM_MODULE} nested=1' | sudo tee /etc/modprobe.d/kvm.conf"
                    echo "       sudo modprobe -r kvm_${KVM_MODULE} && sudo modprobe kvm_${KVM_MODULE}"
                    ;;
            esac
        fi
    fi
fi

# Verifica ferramentas necessárias
echo
echo "Verificando programas necessários..."

# curl
if command -v curl &> /dev/null; then
    echo "[OK] curl instalado"
else
    echo "[AVISO] curl não encontrado"
    case "${DISTRO}" in
        fedora|rhel|centos|rocky|alma)
            echo "        Instale com: sudo dnf install curl"
            ;;
        ubuntu|debian|linuxmint|pop)
            echo "        Instale com: sudo apt install curl"
            ;;
    esac
fi

# Docker ou Podman (para o próximo artigo)
if command -v docker &> /dev/null; then
    echo "[OK] Docker instalado"
elif command -v podman &> /dev/null; then
    echo "[OK] Podman instalado"
else
    echo "[INFO] Docker/Podman não encontrado (necessário para construir rootfs customizado)"
    case "${DISTRO}" in
        fedora|rhel|centos|rocky|alma)
            echo "        Instale Podman com: sudo dnf install podman"
            ;;
        ubuntu|debian|linuxmint|pop)
            echo "        Instale Docker com: sudo apt install docker.io"
            echo "        Ou Podman com: sudo apt install podman"
            ;;
    esac
fi

echo
echo "Verificação concluída"
