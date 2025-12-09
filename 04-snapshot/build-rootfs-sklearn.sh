#!/bin/bash
# build-rootfs-sklearn.sh - Cria rootfs Alpine com scikit-learn para Firecracker
#
# Uso: ./build-rootfs-sklearn.sh
#
# Requer: Docker ou Podman, executar como root

set -e

ROOTFS="rootfs-sklearn.ext4"
SIZE_MB=512
MOUNT_POINT="/tmp/rootfs-sklearn-mount"

if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo "Erro: Docker ou Podman nao encontrado"
    exit 1
fi

echo "Criando rootfs com scikit-learn"
echo "Container runtime: $CONTAINER_CMD"
echo "Tamanho: ${SIZE_MB}MB"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Erro: Execute como root (sudo ./build-rootfs-sklearn.sh)"
    exit 1
fi

if [ -f "$ROOTFS" ]; then
    echo "[*] Removendo rootfs anterior..."
    rm -f "$ROOTFS"
fi

echo "[*] Criando imagem de ${SIZE_MB}MB..."
dd if=/dev/zero of=$ROOTFS bs=1M count=$SIZE_MB status=progress
mkfs.ext4 -F $ROOTFS

echo "[*] Montando imagem..."
mkdir -p $MOUNT_POINT
mount $ROOTFS $MOUNT_POINT

# Instala Alpine com sklearn
echo "[*] Instalando Alpine + Python + scikit-learn..."
$CONTAINER_CMD run --rm --privileged -v $MOUNT_POINT:/rootfs alpine:3.21 sh -c '
    # Configura repositorios e chaves no rootfs target
    mkdir -p /rootfs/etc/apk/keys
    cp /etc/apk/repositories /rootfs/etc/apk/
    cp -a /etc/apk/keys/* /rootfs/etc/apk/keys/

    # Inicializa e instala pacotes
    apk add --root /rootfs --initdb --no-scripts \
        alpine-base \
        python3 py3-numpy py3-scikit-learn py3-joblib

    # Cria symlinks do busybox (--no-scripts nao executa os scripts de instalacao)
    # Usa chroot para criar symlinks com paths corretos
    chroot /rootfs /bin/busybox --install -s /bin
    chroot /rootfs /bin/busybox --install -s /sbin
'

echo "[*] Criando estrutura de diretorios..."
mkdir -p $MOUNT_POINT/functions
mkdir -p $MOUNT_POINT/model
mkdir -p $MOUNT_POINT/snapshot

echo "[*] Criando init.sh..."
cat > $MOUNT_POINT/init.sh << 'INIT'
#!/bin/sh
# init.sh - Carrega sklearn, treina modelo e sinaliza pronto para snapshot

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo "=== Inicializando ambiente ML ==="

# PYTHONUNBUFFERED=1 garante que print() aparece imediatamente no console
PYTHONUNBUFFERED=1 python3 << 'PYEOF'
import time
start = time.time()

# Carrega bibliotecas (parte mais lenta)
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.naive_bayes import MultinomialNB
from sklearn.pipeline import Pipeline

import_time = time.time() - start
print(f"[TIMING] sklearn importado em {import_time:.3f}s")

# Dados de treino para classificador de spam
texts = [
    "ganhe dinheiro rapido agora",
    "voce ganhou um premio clique aqui",
    "oferta imperdivel so hoje gratis",
    "parabens voce foi selecionado",
    "clique aqui para ganhar",
    "promocao especial limitada",
    "reuniao amanha as 10h",
    "relatorio do projeto em anexo",
    "ola tudo bem com voce",
    "podemos conversar depois",
    "obrigado pela ajuda ontem",
    "segue documento solicitado"
] * 10

labels = [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0] * 10  # 1=spam, 0=ham

# Treina modelo
train_start = time.time()
model = Pipeline([
    ("tfidf", TfidfVectorizer()),
    ("clf", MultinomialNB())
])
model.fit(texts, labels)
train_time = time.time() - train_start

print(f"[TIMING] modelo treinado em {train_time:.3f}s")
print(f"[READY] VM pronta para snapshot")
PYEOF

# Sinaliza que esta pronto para snapshot
echo "SNAPSHOT_READY"

# Aguarda indefinidamente (sera pausado para snapshot)
while true; do
    sleep 1
done
INIT

chmod +x $MOUNT_POINT/init.sh

# Cria handler de exemplo para uso apos restore
echo "[*] Criando handler de exemplo..."
cat > $MOUNT_POINT/functions/spam_handler.py << 'HANDLER'
#!/usr/bin/env python3
"""
Handler de classificacao de spam - executado apos restore do snapshot
"""
import sys
import json

# sklearn ja esta carregado na memoria (snapshot)
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.naive_bayes import MultinomialNB
from sklearn.pipeline import Pipeline

def handler(text):
    # Recria modelo (rapido, dados pequenos)
    texts = [
        "ganhe dinheiro rapido", "premio gratis clique",
        "reuniao amanha", "relatorio anexo"
    ] * 5
    labels = [1, 1, 0, 0] * 5

    model = Pipeline([
        ("tfidf", TfidfVectorizer()),
        ("clf", MultinomialNB())
    ])
    model.fit(texts, labels)

    # Classifica
    prediction = model.predict([text])[0]
    proba = model.predict_proba([text])[0]

    return {
        "input": text,
        "classification": "SPAM" if prediction == 1 else "HAM",
        "confidence": float(max(proba)),
        "probabilities": {
            "spam": float(proba[1]),
            "ham": float(proba[0])
        }
    }

if __name__ == "__main__":
    # Le input
    if len(sys.argv) > 1:
        text = sys.argv[1]
    else:
        with open("/functions/input.txt", "r") as f:
            text = f.read().strip()

    result = handler(text)

    print("JSON_RESULT_START")
    print(json.dumps(result, indent=2))
    print("JSON_RESULT_END")
HANDLER

chmod +x $MOUNT_POINT/functions/spam_handler.py

echo "[*] Desmontando..."
umount $MOUNT_POINT
rmdir $MOUNT_POINT

SIZE=$(du -h $ROOTFS | cut -f1)
echo ""
echo "=== Rootfs criado com sucesso ==="
echo "Arquivo: $ROOTFS"
echo "Tamanho: $SIZE"
echo ""
echo "Proximo passo: execute test-snapshot.py para testar"
