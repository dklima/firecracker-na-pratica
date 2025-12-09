# Firecracker: MicroVMs na Prática

Repositório com código e scripts da série de artigos sobre Firecracker no blog [Fogo na Caixa D'Água](https://fogonacaixadagua.com.br).

## Artigos

1. **[Firecracker: A tecnologia por trás do AWS Lambda que você pode rodar no seu Linux](https://fogonacaixadagua.com.br/2025/12/firecracker-a-tecnologia-por-tras-do-aws-lambda-que-voce-pode-rodar-no-seu-linux/)** - Introdução ao Firecracker e Hello World com microVMs

2. **[Construindo um nano-Lambda: como serverless funciona por dentro](https://fogonacaixadagua.com.br/2025/12/construindo-um-nano-lambda-como-serverless-funciona-por-dentro/)** - Implementação de um Lambda caseiro usando Firecracker

3. **[Redes no Firecracker: configurando TAP, NAT e internet para seu nano-Lambda](https://fogonacaixadagua.com.br/2025/12/redes-no-firecracker-configurando-tap-nat-e-internet-para-seu-nano-lambda/)** - Configuração de rede para microVMs com acesso à internet

4. **Snapshots no Firecracker: de 7 segundos para 240ms** - Otimização de cold start com snapshots (~25x mais rápido)

## Estrutura

```
.
├── 01-firecracker-introducao/   # Código do primeiro artigo
│   ├── check-kvm.sh             # Script para verificar suporte a KVM
│   ├── firecracker.json         # Configuração mínima do Firecracker
│   └── README.md                # Instruções rápidas
│
├── 02-nano-lambda/              # Código do segundo artigo
│   ├── build-rootfs.sh          # Script para construir rootfs com Python
│   ├── nano-lambda.py           # Script principal do nano-Lambda
│   ├── exemplo-qrcode/
│   │   └── handler.py           # Função de exemplo (gerador de QR Code)
│   └── README.md                # Instruções rápidas
│
└── 04-snapshot/                 # Código do quarto artigo
    ├── build-rootfs-sklearn.sh  # Script para construir rootfs com sklearn
    ├── test-snapshot.py         # Script de teste cold start vs restore
    └── README.md                # Instruções rápidas
```

## Requisitos

- Linux com KVM habilitado (nativo ou VM com nested virtualization)
- Acesso root/sudo
- Docker ou Podman (para construir o rootfs)
- Python 3.8+ (para o nano-Lambda)

## Licença

MIT
