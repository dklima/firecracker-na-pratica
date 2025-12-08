# Firecracker: MicroVMs na Prática

Repositório com código e scripts da série de artigos sobre Firecracker no blog [Fogo na Caixa D'Água](https://fogonacaixadagua.com.br).

## Artigos

1. **[Firecracker: A tecnologia por trás do AWS Lambda que você pode rodar no seu Linux](https://fogonacaixadagua.com.br/2025/12/firecracker-a-tecnologia-por-tras-do-aws-lambda-que-voce-pode-rodar-no-seu-linux/)** - Introdução ao Firecracker e Hello World com microVMs

2. **[Construindo um nano-Lambda: como serverless funciona por dentro](https://fogonacaixadagua.com.br/2025/12/construindo-um-nano-lambda-como-serverless-funciona-por-dentro/)** - Implementação de um Lambda caseiro usando Firecracker

## Estrutura

```
.
├── 01-firecracker-introducao/   # Código do primeiro artigo
│   ├── check-kvm.sh             # Script para verificar suporte a KVM
│   ├── firecracker.json         # Configuração mínima do Firecracker
│   └── README.md                # Instruções rápidas
│
└── 02-nano-lambda/              # Código do segundo artigo
    ├── build-rootfs.sh          # Script para construir rootfs com Python
    ├── nano-lambda.py           # Script principal do nano-Lambda
    ├── exemplo-qrcode/
    │   └── handler.py           # Função de exemplo (gerador de QR Code)
    └── README.md                # Instruções rápidas
```

## Requisitos

- Linux com KVM habilitado (nativo ou VM com nested virtualization)
- Acesso root/sudo
- Docker ou Podman (para construir o rootfs)
- Python 3.8+ (para o nano-Lambda)

## Licença

MIT
