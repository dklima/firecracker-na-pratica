# Artigo 01: Introdução ao Firecracker

Scripts e configurações do artigo **"Firecracker: A tecnologia por trás do AWS Lambda que você pode rodar no seu Linux"**.

## Arquivos

- `check-kvm.sh` - Verifica se seu ambiente está pronto para rodar Firecracker
- `firecracker.json` - Configuração mínima para o Hello World

## Uso rápido

```bash
# 1. Verifica o ambiente
./check-kvm.sh

# 2. Baixa o Firecracker, kernel e rootfs
FIRECRACKER_VERSION="v1.13.0"
ARCH=$(uname -m)

curl -L -o firecracker.tgz \
  "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-${ARCH}.tgz"

tar -xzf firecracker.tgz
mv release-${FIRECRACKER_VERSION}-${ARCH}/firecracker-${FIRECRACKER_VERSION}-${ARCH} firecracker
chmod +x firecracker

curl -L -o vmlinux.bin \
  "https://github.com/dklima/firecracker-na-pratica/releases/download/v1.0.0/vmlinux-5.10.239"

curl -L -o rootfs.ext4 \
  "https://github.com/dklima/firecracker-na-pratica/releases/download/v1.0.0/rootfs.ext4"

# 3. Inicia o Firecracker (terminal 1)
rm -f /tmp/firecracker.socket
sudo ./firecracker --api-sock /tmp/firecracker.socket

# 4. Configura e inicia a VM (terminal 2)
# Kernel
curl --unix-socket /tmp/firecracker.socket -X PUT \
  "http://localhost/boot-source" \
  -H "Content-Type: application/json" \
  -d '{
    "kernel_image_path": "./vmlinux.bin",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
  }'

# Rootfs
curl --unix-socket /tmp/firecracker.socket -X PUT \
  "http://localhost/drives/rootfs" \
  -H "Content-Type: application/json" \
  -d '{
    "drive_id": "rootfs",
    "path_on_host": "./rootfs.ext4",
    "is_root_device": true,
    "is_read_only": false
  }'

# Recursos
curl --unix-socket /tmp/firecracker.socket -X PUT \
  "http://localhost/machine-config" \
  -H "Content-Type: application/json" \
  -d '{
    "vcpu_count": 1,
    "mem_size_mib": 128
  }'

# Inicia!
curl --unix-socket /tmp/firecracker.socket -X PUT \
  "http://localhost/actions" \
  -H "Content-Type: application/json" \
  -d '{"action_type": "InstanceStart"}'
```

Para instruções detalhadas, leia o [artigo completo](https://fogonacaixadagua.com.br/firecracker-introducao).
