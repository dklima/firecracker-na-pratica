# Artigo 04: Snapshots no Firecracker

Scripts e codigo do artigo **"Snapshots no Firecracker: de 7 segundos para 240ms"**.

## Arquivos

- `build-rootfs-sklearn.sh` - Constroi um rootfs Alpine com scikit-learn
- `test-snapshot.py` - Script que compara cold start vs restore

## Requisitos

- Firecracker e kernel dos artigos anteriores
- Docker ou Podman
- Python 3.8+ com as bibliotecas:

```bash
pip install requests-unixsocket
```

## Uso rapido

```bash
# 1. Constroi o rootfs com scikit-learn (requer root)
sudo ./build-rootfs-sklearn.sh

# 2. Executa o teste de snapshot
sudo python3 test-snapshot.py
```

## Resultado esperado

```
============================================================
RESULTADOS
============================================================
  Cold Start:     ~8s
  Criar Snapshot: ~0.6s
  Restore:        ~0.3s

  Speedup:        ~25x mais rapido
============================================================
```

## O que o teste faz

1. **Cold Start**: Boot completo + import do scikit-learn (~8s)
2. **Snapshot**: Pausa a VM e salva memoria + estado da CPU
3. **Restore**: Carrega o snapshot e resume a VM (~300ms)

Os arquivos de snapshot ficam em `/tmp/fc-snapshot/`:
- `vm_mem` - Dump da memoria (512MB)
- `vm_state` - Estado da CPU (~15KB)

Para instrucoes detalhadas, leia o [artigo completo](https://fogonacaixadagua.com.br/).
