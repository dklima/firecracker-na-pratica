# Artigo 04: Snapshots no Firecracker

Scripts e codigo do artigo **[Snapshots no Firecracker: de 9 segundos para 300ms](https://fogonacaixadagua.com.br/2025/12/snapshots-no-firecracker-de-7-segundos-para-240ms/)**.

## Arquivos

- `build-rootfs-sklearn.sh` - Constroi um rootfs Alpine com scikit-learn
- `test-snapshot.py` - Script que compara cold start vs restore

## Requisitos

- Firecracker e kernel dos artigos anteriores
- Docker ou Podman
- Python 3.8+ (o `test-snapshot.py` usa so a biblioteca padrao, sem `pip install`)

O `test-snapshot.py` fala com o socket Unix da API do Firecracker usando
`socket` + `http.client` da biblioteca padrao, entao nao precisa instalar nada
no host.

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
  Cold Start:     ~9s
  Criar Snapshot: ~0.2s
  Restore:        ~0.3s

  Speedup:        ~30x mais rapido
============================================================
```

## O que o teste faz

1. **Cold Start**: Boot completo + import do scikit-learn (~9s)
2. **Snapshot**: Pausa a VM e salva memoria + estado da CPU
3. **Restore**: Carrega o snapshot e resume a VM (~300ms)

Os arquivos de snapshot ficam em `/tmp/fc-snapshot/`:
- `vm_mem` - Dump da memoria (512MB)
- `vm_state` - Estado da CPU (~14KB)

Para instrucoes detalhadas, leia o [artigo completo](https://fogonacaixadagua.com.br/).
