#!/usr/bin/env python3
"""
nano-Lambda: Um Lambda caseiro usando Firecracker

Executa funções Python em microVMs isoladas.

Uso:
    sudo python3 nano-lambda.py <função.py> <input>

Exemplo:
    sudo python3 nano-lambda.py exemplo-qrcode/handler.py "https://fogonacaixadagua.com.br"

Requer execução como root (para montar rootfs e executar Firecracker).
"""

import subprocess
import requests_unixsocket
import time
import shutil
import tempfile
import base64
import signal
import sys
import os

# Configurações - ajuste conforme necessário
FIRECRACKER_BIN = "./firecracker"
KERNEL_PATH = "./vmlinux.bin"
ROOTFS_TEMPLATE = "./rootfs-python.ext4"
SOCKET_PATH = "/tmp/firecracker-nanolambda.socket"
VCPU_COUNT = 1
MEM_SIZE_MIB = 256


class NanoLambda:
    """
    Gerencia o ciclo de vida de uma execução Lambda-style:
    - Prepara rootfs com a função e input
    - Inicia Firecracker
    - Configura e executa a microVM
    - Captura output
    - Limpa recursos
    """

    def __init__(self):
        self.socket_path = SOCKET_PATH
        self.fc_process = None
        self.temp_rootfs = None
        self.output_file = "/tmp/firecracker-output.log"

    def _api_url(self, path):
        """Converte path para URL do socket Unix."""
        encoded_socket = self.socket_path.replace("/", "%2F")
        return f"http+unix://{encoded_socket}{path}"

    def _call_api(self, method, path, data=None):
        """Faz chamada para a API REST do Firecracker via socket Unix."""
        session = requests_unixsocket.Session()
        url = self._api_url(path)

        if method == "PUT":
            resp = session.put(url, json=data)
        elif method == "GET":
            resp = session.get(url)
        else:
            raise ValueError(f"Método não suportado: {method}")

        if resp.status_code >= 400:
            raise Exception(f"API error {resp.status_code}: {resp.text}")

        return resp

    def prepare_rootfs(self, function_path, input_data):
        """
        Prepara o rootfs com a função e input.

        Cria uma cópia temporária do rootfs template, monta,
        e copia a função e dados de entrada para dentro.
        """
        # Cria cópia temporária do rootfs
        self.temp_rootfs = tempfile.NamedTemporaryFile(
            suffix='.ext4',
            delete=False
        ).name

        print(f"[*] Copiando rootfs template...")
        shutil.copy(ROOTFS_TEMPLATE, self.temp_rootfs)

        # Monta e copia arquivos
        mount_point = tempfile.mkdtemp()

        try:
            print("[*] Montando rootfs temporario...")
            subprocess.run(
                ["mount", self.temp_rootfs, mount_point],
                check=True
            )

            # Copia a funcao para /functions/handler.py
            print(f"[*] Copiando funcao: {function_path}")
            func_dest = os.path.join(mount_point, "functions", "handler.py")
            shutil.copy(function_path, func_dest)

            # Escreve o input em /functions/input.txt
            input_dest = os.path.join(mount_point, "functions", "input.txt")
            with open(input_dest, 'w') as f:
                f.write(input_data)

        finally:
            subprocess.run(["umount", mount_point], check=True)
            os.rmdir(mount_point)

    def start_firecracker(self):
        """
        Inicia o processo Firecracker.

        O Firecracker escuta em um socket Unix e espera
        comandos via API REST. O output do console serial
        é redirecionado para um arquivo de log.
        """
        # Remove socket antigo se existir
        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)

        # Remove arquivo de output antigo
        if os.path.exists(self.output_file):
            os.remove(self.output_file)

        print("[*] Iniciando Firecracker...")

        # Redireciona stdout e stderr para arquivo
        # Isso captura o console serial da VM
        self.output_handle = open(self.output_file, 'w')
        self.fc_process = subprocess.Popen(
            [FIRECRACKER_BIN, "--api-sock", self.socket_path],
            stdout=self.output_handle,
            stderr=subprocess.STDOUT
        )

        # Espera socket ficar disponível
        for _ in range(50):
            if os.path.exists(self.socket_path):
                break
            time.sleep(0.1)
        else:
            raise Exception("Timeout esperando socket do Firecracker")

        time.sleep(0.2)  # Pausa extra para garantir

    def configure_vm(self):
        """
        Configura a microVM via API REST.

        Define kernel, rootfs e recursos (CPU/memória).
        """
        print(f"[*] Configurando kernel...")
        self._call_api("PUT", "/boot-source", {
            "kernel_image_path": KERNEL_PATH,
            "boot_args": "console=ttyS0 reboot=k panic=1 pci=off quiet"
        })

        print(f"[*] Configurando rootfs...")
        self._call_api("PUT", "/drives/rootfs", {
            "drive_id": "rootfs",
            "path_on_host": self.temp_rootfs,
            "is_root_device": True,
            "is_read_only": False
        })

        print(f"[*] Configurando recursos ({VCPU_COUNT} vCPU, {MEM_SIZE_MIB}MB RAM)...")
        self._call_api("PUT", "/machine-config", {
            "vcpu_count": VCPU_COUNT,
            "mem_size_mib": MEM_SIZE_MIB
        })

    def run_vm(self, timeout=30):
        """
        Inicia a VM e aguarda a execução.

        A VM executa a função e desliga automaticamente.
        Capturamos o output do console serial do arquivo de log.
        """
        print(f"[*] Iniciando microVM...")
        self._call_api("PUT", "/actions", {"action_type": "InstanceStart"})

        print(f"[*] Aguardando execução (timeout: {timeout}s)...")

        # Aguarda VM terminar ou timeout
        start_time = time.time()
        while time.time() - start_time < timeout:
            if self.fc_process.poll() is not None:
                # Processo terminou
                break
            time.sleep(0.5)

        # Fecha o handle do arquivo de output
        self.output_handle.close()

        # Se o processo ainda estiver rodando, mata
        if self.fc_process.poll() is None:
            self.fc_process.terminate()
            try:
                self.fc_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.fc_process.kill()
                self.fc_process.wait()

        # Lê output do arquivo
        if os.path.exists(self.output_file):
            with open(self.output_file, 'r') as f:
                output = f.read()
        else:
            output = ""

        return output

    def cleanup(self):
        """Remove recursos temporários."""
        print(f"[*] Limpando...")

        # Fecha handle do arquivo se ainda estiver aberto
        if hasattr(self, 'output_handle') and not self.output_handle.closed:
            self.output_handle.close()

        # Para o processo Firecracker se ainda estiver rodando
        if self.fc_process and self.fc_process.poll() is None:
            self.fc_process.terminate()
            try:
                self.fc_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.fc_process.kill()

        # Remove rootfs temporário
        if self.temp_rootfs and os.path.exists(self.temp_rootfs):
            os.remove(self.temp_rootfs)

        # Remove socket
        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)

        # Remove arquivo de output
        if os.path.exists(self.output_file):
            os.remove(self.output_file)

    def invoke(self, function_path, input_data):
        """
        Invoca uma função Lambda-style.

        Orquestra todo o ciclo: preparação, execução e limpeza.
        """
        try:
            self.prepare_rootfs(function_path, input_data)
            self.start_firecracker()
            self.configure_vm()
            output = self.run_vm()
            return self.parse_output(output)
        finally:
            self.cleanup()

    def parse_output(self, raw_output):
        """
        Extrai resultado do output bruto.

        Procura por marcadores especiais para dados binários (base64).
        """
        # Procura pelo marcador de imagem base64
        if "BASE64_IMAGE_START" in raw_output and "BASE64_IMAGE_END" in raw_output:
            start = raw_output.find("BASE64_IMAGE_START") + len("BASE64_IMAGE_START")
            end = raw_output.find("BASE64_IMAGE_END")
            base64_data = raw_output[start:end].strip()
            return {
                "success": True,
                "type": "image",
                "data": base64_data
            }

        return {
            "success": False,
            "type": "text",
            "data": raw_output
        }


def main():
    # Verifica se esta rodando como root
    if os.geteuid() != 0:
        print("Erro: Este script precisa ser executado como root.")
        print("Uso: sudo python3 nano-lambda.py <funcao.py> <input>")
        sys.exit(1)

    # Valida argumentos
    if len(sys.argv) < 3:
        print("Uso: sudo python3 nano-lambda.py <funcao.py> <input>")
        print("Exemplo: sudo python3 nano-lambda.py exemplo-qrcode/handler.py 'https://meusite.com'")
        sys.exit(1)

    function_path = sys.argv[1]
    input_data = sys.argv[2]

    # Valida se a funcao existe
    if not os.path.exists(function_path):
        print(f"Erro: funcao nao encontrada: {function_path}")
        sys.exit(1)

    # Valida se os arquivos necessarios existem
    for f, desc in [(FIRECRACKER_BIN, "Firecracker"), (KERNEL_PATH, "Kernel"), (ROOTFS_TEMPLATE, "Rootfs")]:
        if not os.path.exists(f):
            print(f"Erro: {desc} nao encontrado: {f}")
            print("Execute primeiro o build-rootfs.sh e baixe o Firecracker e kernel.")
            sys.exit(1)

    print("=" * 50)
    print("nano-Lambda: Executando funcao em microVM isolada")
    print("=" * 50)
    print(f"Funcao: {function_path}")
    print(f"Input: {input_data}")
    print()

    # Cria o runner
    lambda_runner = NanoLambda()

    # Configura tratamento de sinais para limpeza em caso de Ctrl+C
    def signal_handler(signum, frame):
        print("\n[!] Interrompido pelo usuario. Limpando recursos...")
        lambda_runner.cleanup()
        sys.exit(130)  # 128 + SIGINT(2)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Executa
    result = lambda_runner.invoke(function_path, input_data)

    print()
    print("=" * 50)
    print("Resultado:")
    print("=" * 50)

    if result["success"] and result["type"] == "image":
        # Salva a imagem
        output_file = "resultado-qrcode.png"
        img_data = base64.b64decode(result["data"])
        with open(output_file, "wb") as f:
            f.write(img_data)
        print(f"QR Code salvo em: {output_file}")
        print(f"Tamanho: {len(img_data)} bytes")
        print()
        print("Escaneie com seu celular para testar!")
    else:
        print("Output bruto da VM:")
        print(result["data"])


if __name__ == "__main__":
    main()
