# Daemonizando MicroVMs com systemd

Scripts e unit files para rodar microVMs Firecracker como servicos systemd.

## Arquivos

```
05-systemd/
├── firecracker-network-setup.sh   # Setup/teardown de rede (TAP, NAT)
├── firecracker-vm-start.sh        # Inicia Firecracker e configura via API
├── nano-lambda.service            # Unit file basica
├── nano-lambda-hardened.service   # Unit file com hardening de seguranca
├── firecracker@.service           # Template para multiplas VMs
├── examples/
│   ├── web.conf                   # Configuracao de exemplo (VM web)
│   └── worker.conf                # Configuracao de exemplo (VM worker)
└── README.md
```

## Pre-requisitos

- Firecracker instalado (`/usr/local/bin/firecracker`)
- Kernel Linux (`/var/lib/firecracker/vmlinux.bin`)
- Rootfs com rede configurada (`/var/lib/firecracker/rootfs-network.ext4`)
- curl instalado (para chamadas API)

O rootfs precisa ter:
- IP estatico configurado (172.16.0.2/24)
- Gateway configurado (172.16.0.1)
- DNS configurado (/etc/resolv.conf)

Veja o [artigo 03](https://fogonacaixadagua.com.br/2025/12/redes-no-firecracker-configurando-tap-nat-e-internet-para-seu-nano-lambda/) da serie para detalhes sobre configuracao de rede no rootfs.

## Instalacao

```bash
# Copia os scripts
sudo cp firecracker-network-setup.sh /usr/local/bin/
sudo cp firecracker-vm-start.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/firecracker-network-setup.sh
sudo chmod +x /usr/local/bin/firecracker-vm-start.sh

# Copia a unit file (escolha uma)
sudo cp nano-lambda.service /etc/systemd/system/
# ou para versao com hardening:
sudo cp nano-lambda-hardened.service /etc/systemd/system/nano-lambda.service

# Recarrega o systemd
sudo systemctl daemon-reload
```

## Uso basico

```bash
# Inicia a microVM
sudo systemctl start nano-lambda

# Verifica status
sudo systemctl status nano-lambda

# Ve os logs em tempo real
sudo journalctl -u nano-lambda -f

# Para a microVM
sudo systemctl stop nano-lambda

# Habilita inicio automatico no boot
sudo systemctl enable nano-lambda
```

## Multiplas VMs com templates

Para rodar multiplas VMs, use o template `firecracker@.service`:

```bash
# Instala o template
sudo cp firecracker@.service /etc/systemd/system/
sudo mkdir -p /etc/firecracker

# Copia configuracoes
sudo cp examples/web.conf /etc/firecracker/
sudo cp examples/worker.conf /etc/firecracker/

# Cria rootfs para cada VM
sudo cp /var/lib/firecracker/rootfs-network.ext4 /var/lib/firecracker/rootfs-web.ext4
sudo cp /var/lib/firecracker/rootfs-network.ext4 /var/lib/firecracker/rootfs-worker.ext4

# Recarrega systemd
sudo systemctl daemon-reload

# Inicia VMs
sudo systemctl start firecracker@web
sudo systemctl start firecracker@worker

# Status de todas
sudo systemctl status 'firecracker@*'

# Logs de uma VM especifica
sudo journalctl -u firecracker@web -f
```

**Importante**: Cada VM precisa de sua propria interface TAP com IP diferente. Edite os arquivos `.conf` para configurar:

| VM | TAP_DEV | TAP_IP | GUEST_MAC |
|----|---------|--------|-----------|
| web | tap0 | 172.16.0.1 | AA:FC:00:00:00:01 |
| worker | tap1 | 172.16.1.1 | AA:FC:00:00:00:02 |

## Scripts individuais

Os scripts podem ser usados independentemente do systemd:

### firecracker-network-setup.sh

```bash
# Cria interface TAP e configura NAT
sudo ./firecracker-network-setup.sh up

# Remove interface TAP
sudo ./firecracker-network-setup.sh down

# Mostra status
sudo ./firecracker-network-setup.sh status
```

Variaveis de ambiente:
- `TAP_DEV` - Nome da interface (default: tap0)
- `TAP_IP` - IP do host (default: 172.16.0.1)
- `TAP_CIDR` - Mascara CIDR (default: 24)

### firecracker-vm-start.sh

```bash
# Inicia uma VM (requer rede ja configurada)
sudo VM_NAME=teste ROOTFS_PATH=/path/to/rootfs.ext4 ./firecracker-vm-start.sh
```

Variaveis de ambiente:
- `VM_NAME` - Nome da VM (default: default)
- `SOCKET_PATH` - Caminho do socket API
- `KERNEL_PATH` - Caminho do kernel
- `ROOTFS_PATH` - Caminho do rootfs
- `VCPU_COUNT` - Numero de vCPUs (default: 1)
- `MEM_SIZE_MIB` - Memoria em MiB (default: 256)
- `TAP_DEV` - Interface TAP (default: tap0)
- `GUEST_MAC` - MAC address do guest

## Troubleshooting

### Servico nao inicia

```bash
# Ver logs detalhados
sudo journalctl -u nano-lambda -b --no-pager

# Verificar sintaxe da unit file
sudo systemd-analyze verify /etc/systemd/system/nano-lambda.service
```

### Rede nao funciona

```bash
# Verificar interface TAP
ip addr show tap0

# Verificar IP forwarding
sysctl net.ipv4.ip_forward

# Verificar masquerading (firewalld)
sudo firewall-cmd --query-masquerade

# Verificar masquerading (iptables)
sudo iptables -t nat -L -n | grep MASQUERADE
```

### Firecracker nao encontra socket

```bash
# Verificar diretorio
ls -la /run/firecracker/

# Verificar permissoes
stat /run/firecracker/
```

### VM crashando em loop

```bash
# Ver status detalhado
systemctl status nano-lambda

# Se atingiu limite de restarts, resetar
sudo systemctl reset-failed nano-lambda
sudo systemctl start nano-lambda
```

## Hardening

A versao `nano-lambda-hardened.service` inclui:

- `ProtectSystem=strict` - Filesystem do host read-only
- `ProtectHome=yes` - Sem acesso ao /home
- `PrivateTmp=yes` - /tmp isolado
- `NoNewPrivileges=yes` - Previne escalacao de privilegios
- `PrivateDevices=yes` - Acesso restrito a dispositivos
- `DeviceAllow=/dev/kvm rw` - Whitelist de dispositivos
- `CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW` - Capabilities minimas
- `MemoryMax=512M` - Limite de memoria
- `TasksMax=10` - Limite de processos

## Links

- [Artigo 05: Daemonizando com systemd](https://fogonacaixadagua.com.br/)
- [Artigo 03: Redes no Firecracker](https://fogonacaixadagua.com.br/2025/12/redes-no-firecracker-configurando-tap-nat-e-internet-para-seu-nano-lambda/)
- [Documentacao Firecracker](https://github.com/firecracker-microvm/firecracker)
- [Documentacao systemd](https://www.freedesktop.org/software/systemd/man/)
