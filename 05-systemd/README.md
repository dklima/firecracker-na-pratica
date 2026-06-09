# Daemonizando MicroVMs com systemd

Arquivos para o artigo **[Firecracker em produção: systemd, restart automático e a diferença entre demo e serviço de verdade](https://fogonacaixadagua.com.br/2025/12/firecracker-em-producao-systemd-restart-automatico-e-a-diferenca-entre-demo-e-servico-de-verdade/)**

Scripts e unit files para rodar microVMs Firecracker como serviços systemd.

## Arquivos

```
05-systemd/
├── build-rootfs-service.sh        # Constrói o rootfs de serviço persistente
├── firecracker-network-setup.sh   # Setup/teardown de rede (TAP, NAT)
├── firecracker-vm-start.sh        # Inicia Firecracker e configura via API
├── nano-lambda.service            # Unit file básica
├── nano-lambda-hardened.service   # Unit file com hardening de segurança
├── firecracker@.service           # Template para múltiplas VMs
├── examples/
│   ├── web.conf                   # Configuração de exemplo (VM web)
│   └── worker.conf                # Configuração de exemplo (VM worker)
└── README.md
```

## Pré-requisitos

- Firecracker instalado (`/usr/local/bin/firecracker`)
- Kernel Linux (`/var/lib/firecracker/vmlinux.bin`)
- Docker ou Podman (para construir o rootfs)
- curl instalado (para chamadas API)

O rootfs de serviço (`rootfs-service.ext4`) é construído pelo `build-rootfs-service.sh`.
Diferente do rootfs do artigo 03 (que roda a função uma vez e dá reboot), este sobe a rede
e fica vivo, pra funcionar como serviço de verdade sob o systemd. Dentro da VM ele configura:
- IP estático (172.16.0.2/24)
- Gateway (172.16.0.1)
- DNS (/etc/resolv.conf)

Veja o [artigo 03](https://fogonacaixadagua.com.br/2025/12/redes-no-firecracker-configurando-tap-nat-e-internet-para-seu-nano-lambda/) da série para detalhes sobre configuração de rede no rootfs.

## Instalação

```bash
# Constrói o rootfs de serviço (gera rootfs-service.ext4)
sudo ./build-rootfs-service.sh

# Coloca binário, kernel e rootfs nos lugares certos
sudo mkdir -p /var/lib/firecracker
sudo cp ./firecracker /usr/local/bin/firecracker
sudo cp ./vmlinux.bin /var/lib/firecracker/vmlinux.bin
sudo cp ./rootfs-service.ext4 /var/lib/firecracker/rootfs-service.ext4

# Copia os scripts
sudo cp firecracker-network-setup.sh /usr/local/bin/
sudo cp firecracker-vm-start.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/firecracker-network-setup.sh
sudo chmod +x /usr/local/bin/firecracker-vm-start.sh

# Copia a unit file (escolha uma)
sudo cp nano-lambda.service /etc/systemd/system/
# ou para versão com hardening:
sudo cp nano-lambda-hardened.service /etc/systemd/system/nano-lambda.service

# Recarrega o systemd
sudo systemctl daemon-reload
```

## Uso básico

```bash
# Inicia a microVM
sudo systemctl start nano-lambda

# Verifica status
sudo systemctl status nano-lambda

# Vê os logs em tempo real
sudo journalctl -u nano-lambda -f

# Para a microVM
sudo systemctl stop nano-lambda

# Habilita início automático no boot
sudo systemctl enable nano-lambda
```

## Múltiplas VMs com templates

Para rodar múltiplas VMs, use o template `firecracker@.service`:

```bash
# Instala o template
sudo cp firecracker@.service /etc/systemd/system/
sudo mkdir -p /etc/firecracker

# Copia configurações
sudo cp examples/web.conf /etc/firecracker/
sudo cp examples/worker.conf /etc/firecracker/

# Cria rootfs para cada VM
sudo cp /var/lib/firecracker/rootfs-service.ext4 /var/lib/firecracker/rootfs-web.ext4
sudo cp /var/lib/firecracker/rootfs-service.ext4 /var/lib/firecracker/rootfs-worker.ext4

# Recarrega systemd
sudo systemctl daemon-reload

# Inicia VMs
sudo systemctl start firecracker@web
sudo systemctl start firecracker@worker

# Status de todas
sudo systemctl status 'firecracker@*'

# Logs de uma VM específica
sudo journalctl -u firecracker@web -f
```

**Importante**: Cada VM precisa de sua própria interface TAP com IP diferente. Edite os arquivos `.conf` para configurar:

| VM | TAP_DEV | TAP_IP | GUEST_MAC |
|----|---------|--------|-----------|
| web | tap0 | 172.16.0.1 | AA:FC:00:00:00:01 |
| worker | tap1 | 172.16.1.1 | AA:FC:00:00:00:02 |

**Cuidado com o IP de dentro da VM**: o `rootfs-service.ext4` fixa o IP do guest em
`172.16.0.2`. Uma VM numa subnet diferente (como o `worker` em `172.16.1.0/24`) sobe e fica
no ar, mas sem internet, porque o IP não bate com a subnet da TAP. Pra cada subnet, ajuste o
`172.16.0.2` no `vm-service.sh` (dentro do `build-rootfs-service.sh`) antes de construir.

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

Variáveis de ambiente:
- `TAP_DEV` - Nome da interface (default: tap0)
- `TAP_IP` - IP do host (default: 172.16.0.1)
- `TAP_CIDR` - Máscara CIDR (default: 24)

### firecracker-vm-start.sh

```bash
# Inicia uma VM (requer rede já configurada)
sudo VM_NAME=teste ROOTFS_PATH=/path/to/rootfs.ext4 ./firecracker-vm-start.sh
```

Variáveis de ambiente:
- `VM_NAME` - Nome da VM (default: default)
- `SOCKET_PATH` - Caminho do socket API
- `KERNEL_PATH` - Caminho do kernel
- `ROOTFS_PATH` - Caminho do rootfs
- `VCPU_COUNT` - Número de vCPUs (default: 1)
- `MEM_SIZE_MIB` - Memória em MiB (default: 256)
- `TAP_DEV` - Interface TAP (default: tap0)
- `GUEST_MAC` - MAC address do guest

## Troubleshooting

### Serviço não inicia

```bash
# Ver logs detalhados
sudo journalctl -u nano-lambda -b --no-pager

# Verificar sintaxe da unit file
sudo systemd-analyze verify /etc/systemd/system/nano-lambda.service
```

### Rede não funciona

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

### Firecracker não encontra socket

```bash
# Verificar diretório
ls -la /run/firecracker/

# Verificar permissões
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

A versão `nano-lambda-hardened.service` inclui:

- `ExecStartPre=+...` / `ExecStopPost=+...` - Setup de rede com privilégio total (fora do sandbox)
- `ProtectSystem=strict` - Filesystem do host read-only
- `ProtectHome=yes` - Sem acesso ao /home
- `PrivateTmp=yes` - /tmp isolado
- `NoNewPrivileges=yes` - Previne escalação de privilégios
- `DevicePolicy=closed` + `DeviceAllow` - Nega tudo, libera só /dev/kvm e /dev/net/tun
- `CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW` - Capabilities mínimas
- `MemoryMax=512M` - Limite de memória
- `TasksMax=10` - Limite de processos

Não use `PrivateDevices=yes` aqui: ele esconde `/dev/net/tun` e o Firecracker não consegue
anexar a TAP (o serviço falha com `open: No such file or directory`). Por isso a unit usa
`DevicePolicy=closed` + `DeviceAllow`, que restringe via cgroup mas mantém os devices visíveis.

## Links

- [Artigo 05: Daemonizando com systemd](https://fogonacaixadagua.com.br/2025/12/firecracker-em-producao-systemd-restart-automatico-e-a-diferenca-entre-demo-e-servico-de-verdade/)
- [Artigo 03: Redes no Firecracker](https://fogonacaixadagua.com.br/2025/12/redes-no-firecracker-configurando-tap-nat-e-internet-para-seu-nano-lambda/)
- [Documentação Firecracker](https://github.com/firecracker-microvm/firecracker)
- [Documentação systemd](https://www.freedesktop.org/software/systemd/man/)
