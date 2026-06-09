#!/usr/bin/env python3
"""
test-snapshot.py - Compara cold start vs restore no Firecracker

Mede tempos de:
1. Cold start (boot completo + carga sklearn)
2. Criar snapshot
3. Restore do snapshot

Uso:
    sudo python3 test-snapshot.py

Requer:
    - Firecracker binario (./firecracker)
    - Kernel Linux (./vmlinux.bin)
    - Rootfs com sklearn (./rootfs-sklearn.ext4)

Sem dependencias externas: usa so a biblioteca padrao do Python
(socket + http.client falam com o socket Unix da API do Firecracker).
"""

import subprocess
import time
import shutil
import tempfile
import os
import sys
import json
import socket
import http.client

# Configuracoes
FIRECRACKER_BIN = "./firecracker"
KERNEL_PATH = "./vmlinux.bin"
ROOTFS_TEMPLATE = "./rootfs-sklearn.ext4"
SOCKET_PATH = "/tmp/fc-snapshot-test.socket"
SNAPSHOT_PATH = "/tmp/fc-snapshot"
MEM_FILE = "/tmp/fc-snapshot/vm_mem"
SNAPSHOT_FILE = "/tmp/fc-snapshot/vm_state"
VCPU_COUNT = 1
MEM_SIZE_MIB = 512

# Marcador de handshake - VM imprime isso quando esta pronta
READY_MARKER = "SNAPSHOT_READY"


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection que fala por um socket Unix em vez de TCP."""

    def __init__(self, socket_path):
        super().__init__("localhost")
        self.socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(self.socket_path)
        self.sock = sock


def call_api(method, path, data=None):
    conn = UnixHTTPConnection(SOCKET_PATH)
    body = json.dumps(data) if data is not None else None
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    status = resp.status
    text = resp.read().decode("utf-8", "replace")
    conn.close()
    if status >= 400:
        raise Exception(f"API error {status}: {text}")
    return status, text


def check_dependencies():
    """Verifica se todos os arquivos necessarios existem."""
    missing = []
    for path, desc in [
        (FIRECRACKER_BIN, "Firecracker"),
        (KERNEL_PATH, "Kernel"),
        (ROOTFS_TEMPLATE, "Rootfs sklearn")
    ]:
        if not os.path.exists(path):
            missing.append(f"  - {desc}: {path}")

    if missing:
        print("Erro: Arquivos necessarios nao encontrados:")
        print("\n".join(missing))
        print("\nExecute primeiro:")
        print("  1. Baixe o Firecracker e kernel (ver artigo 01)")
        print("  2. Execute: ./build-rootfs-sklearn.sh")
        sys.exit(1)


def cleanup():
    """Limpa processos e arquivos de execucoes anteriores."""
    subprocess.run(["pkill", "-9", "-x", "firecracker"], capture_output=True)
    time.sleep(1)
    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)
    if os.path.exists(SNAPSHOT_PATH):
        shutil.rmtree(SNAPSHOT_PATH)


def wait_for_ready(log_file, timeout=60):
    """
    Aguarda a VM sinalizar que esta pronta para snapshot.

    O handshake e importante: sem ele, voce pode tirar snapshot
    com a VM ainda carregando bibliotecas.
    """
    start = time.time()
    while time.time() - start < timeout:
        if os.path.exists(log_file):
            with open(log_file, "r") as f:
                if READY_MARKER in f.read():
                    return True
        time.sleep(0.1)
    return False


def prepare_rootfs_for_snapshot():
    """Copia rootfs para uso temporario (init.sh ja incluso no rootfs)."""
    temp_rootfs = tempfile.NamedTemporaryFile(suffix=".ext4", delete=False).name
    shutil.copy(ROOTFS_TEMPLATE, temp_rootfs)
    return temp_rootfs


def start_firecracker(log_file=None):
    if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)

    stdout = open(log_file, "w") if log_file else subprocess.DEVNULL

    proc = subprocess.Popen(
        [FIRECRACKER_BIN, "--api-sock", SOCKET_PATH],
        stdout=stdout,
        stderr=subprocess.STDOUT
    )

    for _ in range(50):
        if os.path.exists(SOCKET_PATH):
            break
        time.sleep(0.1)
    else:
        raise Exception("Timeout esperando socket")

    time.sleep(0.2)
    return proc


def configure_vm(rootfs_path):
    call_api("PUT", "/boot-source", {
        "kernel_image_path": KERNEL_PATH,
        "boot_args": "console=ttyS0 reboot=k panic=1 pci=off init=/init.sh"
    })

    call_api("PUT", "/drives/rootfs", {
        "drive_id": "rootfs",
        "path_on_host": rootfs_path,
        "is_root_device": True,
        "is_read_only": False
    })

    call_api("PUT", "/machine-config", {
        "vcpu_count": VCPU_COUNT,
        "mem_size_mib": MEM_SIZE_MIB
    })


def main():
    print("=" * 60)
    print("Teste de Snapshot/Restore do Firecracker")
    print("=" * 60)
    print()
    print("NOTA: Esta VM esta isolada (sem rede).")
    print("      Para acesso a internet, veja o artigo sobre networking.")
    print()

    check_dependencies()
    cleanup()

    # Variaveis para cleanup em caso de erro
    rootfs = None
    fc_proc = None
    fc_proc2 = None

    try:
        # PARTE 1: Cold Start
        print("\n[1] COLD START (boot + sklearn)")
        print("-" * 40)

        cold_start = time.time()

        rootfs = prepare_rootfs_for_snapshot()
        print(f"    Rootfs preparado ({time.time() - cold_start:.3f}s)")

        log_file = "/tmp/fc-boot.log"
        fc_proc = start_firecracker(log_file)
        print(f"    Firecracker iniciado ({time.time() - cold_start:.3f}s)")

        configure_vm(rootfs)
        print(f"    VM configurada ({time.time() - cold_start:.3f}s)")

        call_api("PUT", "/actions", {"action_type": "InstanceStart"})
        print("    VM iniciada - aguardando SNAPSHOT_READY...")

        # Aguarda a VM sinalizar que esta pronta (handshake)
        if not wait_for_ready(log_file, timeout=60):
            print("    ERRO: Timeout esperando a VM ficar pronta")
            return

        cold_time = time.time() - cold_start
        print(f"\n    >>> COLD START TOTAL: {cold_time:.3f}s")

        # Mostra timing do sklearn
        with open(log_file, "r") as f:
            for line in f:
                if "[TIMING]" in line or "[READY]" in line:
                    print(f"    {line.strip()}")

        # PARTE 2: Criar Snapshot
        print("\n[2] CRIANDO SNAPSHOT")
        print("-" * 40)

        snapshot_start = time.time()

        call_api("PATCH", "/vm", {"state": "Paused"})
        print(f"    VM pausada ({time.time() - snapshot_start:.3f}s)")

        os.makedirs(SNAPSHOT_PATH, exist_ok=True)

        call_api("PUT", "/snapshot/create", {
            "snapshot_type": "Full",
            "snapshot_path": SNAPSHOT_FILE,
            "mem_file_path": MEM_FILE
        })

        snapshot_time = time.time() - snapshot_start
        print(f"    Snapshot criado ({snapshot_time:.3f}s)")

        # Tamanhos
        mem_size = os.path.getsize(MEM_FILE) / (1024 * 1024)
        state_size = os.path.getsize(SNAPSHOT_FILE) / 1024
        print(f"    Memoria: {mem_size:.1f} MB | Estado: {state_size:.1f} KB")

        # Para a VM original
        fc_proc.terminate()
        fc_proc.wait()
        fc_proc = None  # Marca como ja limpo

        if os.path.exists(SOCKET_PATH):
            os.remove(SOCKET_PATH)

        print("    VM original terminada")

        # PARTE 3: Restore
        print("\n[3] RESTORE DO SNAPSHOT")
        print("-" * 40)

        restore_start = time.time()

        fc_proc2 = start_firecracker()
        print(f"    Firecracker iniciado ({time.time() - restore_start:.3f}s)")

        call_api("PUT", "/snapshot/load", {
            "snapshot_path": SNAPSHOT_FILE,
            "mem_backend": {
                "backend_type": "File",
                "backend_path": MEM_FILE
            },
            "enable_diff_snapshots": False,
            "resume_vm": True
        })

        restore_time = time.time() - restore_start
        print(f"\n    >>> RESTORE TOTAL: {restore_time:.3f}s")

        # RESUMO
        print("\n" + "=" * 60)
        print("RESULTADOS")
        print("=" * 60)
        print(f"  Cold Start:     {cold_time:.3f}s")
        print(f"  Criar Snapshot: {snapshot_time:.3f}s")
        print(f"  Restore:        {restore_time:.3f}s")
        print()
        print(f"  Speedup:        {cold_time / restore_time:.1f}x mais rapido")
        print(f"  Economia:       {cold_time - restore_time:.3f}s por execucao")
        print("=" * 60)

        return {
            "cold_start": cold_time,
            "snapshot": snapshot_time,
            "restore": restore_time,
            "speedup": cold_time / restore_time
        }

    finally:
        # Cleanup robusto: libera recursos mesmo em caso de erro
        if fc_proc2:
            try:
                fc_proc2.terminate()
                fc_proc2.wait(timeout=5)
            except Exception:
                pass
        if fc_proc:
            try:
                fc_proc.terminate()
                fc_proc.wait(timeout=5)
            except Exception:
                pass
        if rootfs and os.path.exists(rootfs):
            try:
                os.remove(rootfs)
            except Exception:
                pass
        if os.path.exists(SOCKET_PATH):
            try:
                os.remove(SOCKET_PATH)
            except Exception:
                pass


if __name__ == "__main__":
    if os.geteuid() != 0:
        print("Erro: Execute como root (sudo)")
        sys.exit(1)
    main()
