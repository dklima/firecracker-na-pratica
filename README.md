# Firecracker: MicroVMs na Prática

Repositório com código e scripts da série de artigos sobre Firecracker no blog [Fogo na Caixa D'Água](https://fogonacaixadagua.com.br).

## Artigos

1. **[Firecracker: A tecnologia por trás do AWS Lambda que você pode rodar no seu Linux](https://fogonacaixadagua.com.br/2025/12/firecracker-a-tecnologia-por-tras-do-aws-lambda-que-voce-pode-rodar-no-seu-linux/)** - Introdução ao Firecracker e Hello World com microVMs

2. **[Construindo um nano-Lambda: como serverless funciona por dentro](https://fogonacaixadagua.com.br/2025/12/construindo-um-nano-lambda-como-serverless-funciona-por-dentro/)** - Implementação de um Lambda caseiro usando Firecracker

3. **[Redes no Firecracker: configurando TAP, NAT e internet para seu nano-Lambda](https://fogonacaixadagua.com.br/2025/12/redes-no-firecracker-configurando-tap-nat-e-internet-para-seu-nano-lambda/)** - Configuração de rede para microVMs com acesso à internet

4. **[Snapshots no Firecracker: de 7 segundos para 240ms](https://fogonacaixadagua.com.br/2025/12/snapshots-no-firecracker-de-7-segundos-para-240ms/)** - Otimização de cold start com snapshots (~25x mais rápido)

5. **Firecracker em produção: systemd, restart automático e a diferença entre demo e serviço de verdade** - Transformando microVMs em serviços de produção com restart automático, logs centralizados e hardening

## Estrutura

```
.
├── 01-firecracker-introducao/   # Código do primeiro artigo
│   ├── check-kvm.sh             # Script para verificar suporte a KVM
│   ├── firecracker.json         # Configuração mínima do Firecracker
│   └── README.md
│
├── 02-nano-lambda/              # Código do segundo artigo
│   ├── build-rootfs.sh          # Script para construir rootfs com Python
│   ├── nano-lambda.py           # Script principal do nano-Lambda
│   ├── exemplo-qrcode/
│   │   └── handler.py           # Função de exemplo (gerador de QR Code)
│   └── README.md
│
├── 03-redes/                    # Código do terceiro artigo
│   ├── build-rootfs-network.sh  # Script para construir rootfs com rede
│   ├── nano-lambda-network.py   # nano-Lambda com suporte a rede
│   ├── setup-network.sh         # Configura TAP e NAT
│   ├── cleanup-network.sh       # Remove configuração de rede
│   ├── exemplo-validador/
│   │   └── handler.py           # Validador de URLs
│   └── README.md
│
├── 04-snapshot/                 # Código do quarto artigo
│   ├── build-rootfs-sklearn.sh  # Script para construir rootfs com sklearn
│   ├── test-snapshot.py         # Script de teste cold start vs restore
│   └── README.md
│
└── 05-systemd/                  # Código do quinto artigo
    ├── firecracker-network-setup.sh   # Setup/teardown de rede (TAP, NAT)
    ├── firecracker-vm-start.sh        # Inicia Firecracker e configura via API
    ├── nano-lambda.service            # Unit file básica
    ├── nano-lambda-hardened.service   # Unit file com hardening
    ├── firecracker@.service           # Template para múltiplas VMs
    ├── examples/
    │   ├── web.conf                   # Configuração exemplo (VM web)
    │   └── worker.conf                # Configuração exemplo (VM worker)
    └── README.md
```

## Requisitos

- Linux com KVM habilitado (nativo ou VM com nested virtualization)
- Acesso root/sudo
- Docker ou Podman (para construir o rootfs)
- Python 3.8+ (para o nano-Lambda)
- curl (para os scripts do artigo 05)

## Início rápido

```bash
# Clone o repositório
git clone https://github.com/dklima/firecracker-na-pratica.git
cd firecracker-na-pratica

# Verifique se KVM está disponível
./01-firecracker-introducao/check-kvm.sh

# Baixe o Firecracker e kernel
# (instruções detalhadas nos READMEs de cada artigo)
```

## Licença

MIT
