# Artigo 02: Construindo um nano-Lambda

Scripts e código do artigo **"Construindo um nano-Lambda: como serverless funciona por dentro"**.

## Arquivos

- `build-rootfs.sh` - Constrói um rootfs Alpine com Python
- `nano-lambda.py` - Script principal que executa funções em microVMs
- `exemplo-qrcode/handler.py` - Função de exemplo que gera QR Codes

## Requisitos

- Firecracker, kernel e rootfs do artigo anterior
- Docker ou Podman
- Python 3.8+ com as bibliotecas:

```bash
pip install requests requests-unixsocket
```

## Uso rápido

```bash
# 1. Constrói o rootfs com Python (requer root)
sudo ./build-rootfs.sh

# 2. Executa o nano-Lambda com a função de exemplo
sudo python3 nano-lambda.py exemplo-qrcode/handler.py "https://fogonacaixadagua.com.br"

# 3. O QR Code será salvo em resultado-qrcode.png
```

## Criando suas próprias funções

Sua função precisa:
1. Ler input de `/functions/input.txt`
2. Escrever output no stdout
3. Opcionalmente salvar arquivos em `/output/`

Exemplo mínimo:

```python
#!/usr/bin/env python3

def main():
    # Lê o input
    with open('/functions/input.txt', 'r') as f:
        texto = f.read().strip()

    # Processa
    resultado = texto.upper()

    # Retorna
    print(f"Resultado: {resultado}")

if __name__ == '__main__':
    main()
```

Para instruções detalhadas, leia o [artigo completo](https://fogonacaixadagua.com.br/).
