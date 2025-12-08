#!/usr/bin/env python3
"""
Função nano-Lambda: Gerador de QR Code

Lê o texto de /functions/input.txt e gera um QR Code.
O resultado é salvo em /output/qrcode.png e também
impresso em base64 no stdout para captura externa.
"""

import qrcode
import sys
import base64


def main():
    # Lê o input do arquivo padrão
    try:
        with open('/functions/input.txt', 'r') as f:
            text = f.read().strip()
    except FileNotFoundError:
        print("ERRO: /functions/input.txt não encontrado")
        sys.exit(1)

    # Valida se tem conteúdo
    if not text:
        print("ERRO: input.txt está vazio")
        sys.exit(1)

    print(f"Gerando QR Code para: {text}")

    # Configura o QR Code
    qr = qrcode.QRCode(
        version=1,                              # Tamanho (1 = menor)
        error_correction=qrcode.constants.ERROR_CORRECT_L,  # Correção de erro
        box_size=10,                            # Pixels por "quadradinho"
        border=4,                               # Borda em "quadradinhos"
    )

    # Adiciona os dados e gera
    qr.add_data(text)
    qr.make(fit=True)

    # Cria a imagem
    img = qr.make_image(fill_color="black", back_color="white")

    # Salva no diretório de output
    output_path = '/output/qrcode.png'
    img.save(output_path)

    # Também imprime em base64 no stdout
    # Isso permite capturar o resultado de fora da VM
    with open(output_path, 'rb') as f:
        img_base64 = base64.b64encode(f.read()).decode('utf-8')

    print(f"QR Code gerado com sucesso!")

    # Marcadores para o nano-lambda.py encontrar a imagem
    print(f"BASE64_IMAGE_START")
    print(img_base64)
    print(f"BASE64_IMAGE_END")


if __name__ == '__main__':
    main()
