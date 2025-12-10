# Artigo 03: Redes no Firecracker

Scripts e codigo do artigo **[Redes no Firecracker: configurando TAP, NAT e internet para seu nano-Lambda](https://fogonacaixadagua.com.br/2025/12/redes-no-firecracker-configurando-tap-nat-e-internet-para-seu-nano-lambda/)**.

## Arquivos

- `setup-network.sh` - Configura interface TAP e NAT no host (suporta iptables e firewalld)
- `cleanup-network.sh` - Remove configuracao de rede
- `build-rootfs-network.sh` - Constroi rootfs com Python e suporte a rede
- `nano-lambda-network.py` - Script principal com suporte a rede
- `exemplo-validador/handler.py` - Funcao de exemplo que valida URLs

## Aviso importante

Se voce ja tem o rootfs do artigo anterior (`rootfs-python.ext4`), **voce precisa construir um novo rootfs** com suporte a rede. O rootfs antigo nao tem as dependencias necessarias (requests, ca-certificates).

```bash
# Remove o rootfs antigo (se existir)
rm -f rootfs-python.ext4

# Constroi o novo rootfs com suporte a rede
sudo ./build-rootfs-network.sh
```

## Requisitos

- Firecracker e kernel do artigo anterior
- Docker ou Podman
- Python 3.8+ com as bibliotecas:

```bash
pip install requests requests-unixsocket
```

## Uso rapido

```bash
# 1. Configura a rede do host (TAP + NAT)
sudo ./setup-network.sh

# 2. Constroi o rootfs com suporte a rede
sudo ./build-rootfs-network.sh

# 3. Executa o validador de URLs
sudo python3 nano-lambda-network.py exemplo-validador/handler.py "https://google.com,https://github.com,https://site-invalido.xyz"

# 4. Limpa a configuracao de rede (opcional)
sudo ./cleanup-network.sh
```

## Configuracao de rede

O script `setup-network.sh` detecta automaticamente o firewall do sistema:
- **Ubuntu/Debian**: usa `iptables`
- **Fedora/RHEL**: usa `firewalld`

Configura:
- Interface TAP (`tap0`) com IP `172.16.0.1`
- NAT (masquerading) para internet
- Bloqueio de acesso a redes privadas (seguranca)

A VM recebe:
- IP: `172.16.0.2`
- Gateway: `172.16.0.1`
- DNS: `8.8.8.8`

### Nota sobre DNS

O DNS esta configurado para usar servidores publicos (8.8.8.8 e 1.1.1.1). Em redes corporativas ou VPNs que bloqueiam DNS externo, voce pode precisar ajustar o `/etc/resolv.conf` dentro do rootfs para usar o DNS da sua rede.

## Criando suas proprias funcoes com rede

Sua funcao pode usar `requests` ou `urllib` normalmente:

```python
#!/usr/bin/env python3
import requests

def main():
    with open('/functions/input.txt', 'r') as f:
        url = f.read().strip()

    resp = requests.get(url)
    print(f"Status: {resp.status_code}")
    print(f"Tamanho: {len(resp.text)} bytes")

if __name__ == '__main__':
    main()
```

Para instrucoes detalhadas, leia o [artigo completo](https://fogonacaixadagua.com.br/).
