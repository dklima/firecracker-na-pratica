#!/usr/bin/env python3
"""
nano-Lambda com suporte a rede

Executa funcoes Python em microVMs isoladas com acesso a internet.

Uso:
    sudo python3 nano-lambda-network.py <funcao.py> <input>

Exemplo:
    sudo python3 nano-lambda-network.py exemplo-validador/handler.py "https://google.com,https://github.com"

Requer execucao como root (para montar rootfs, configurar rede e executar Firecracker).
Nao precisa de nenhuma biblioteca externa no host: usa so a stdlib do Python.
"""

import subprocess
import socket
import http.client
import time
import shutil
import tempfile
import json
import signal
import sys
import os

# Configuracoes
FIRECRACKER_BIN = "./firecracker"
KERNEL_PATH = "./vmlinux.bin"
ROOTFS_TEMPLATE = "./rootfs-network.ext4"
SOCKET_PATH = "/tmp/firecracker-nanolambda.socket"
VCPU_COUNT = 1
MEM_SIZE_MIB = 256

# Configuracoes de rede
TAP_DEV = "tap0"
TAP_IP = "172.16.0.1"
GUEST_IP = "172.16.0.2"
GUEST_MAC = "AA:FC:00:00:00:01"
GUEST_NETWORK = "172.16.0.0/24"


class UnixHTTPConnection(http.client.HTTPConnection):
    """
    Conexao HTTP sobre um socket Unix.

    A API do Firecracker fala HTTP, mas escuta num socket Unix em vez
    de uma porta TCP. A stdlib do Python nao conversa com socket Unix
    direto, entao estendemos HTTPConnection e trocamos so o connect().
    """

    def __init__(self, socket_path):
        super().__init__("localhost")
        self.socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(self.socket_path)
        self.sock = sock


class NanoLambdaNetwork:
    """
    Gerencia o ciclo de vida de uma execucao Lambda-style com rede.
    """

    def __init__(self):
        self.socket_path = SOCKET_PATH
        self.fc_process = None
        self.temp_rootfs = None
        self.output_file = "/tmp/firecracker-output.log"
        self.network_configured = False

    def _call_api(self, method, path, data=None):
        """Faz chamada para a API REST do Firecracker via socket Unix."""
        conn = UnixHTTPConnection(self.socket_path)
        body = json.dumps(data) if data is not None else None
        headers = {"Content-Type": "application/json", "Accept": "application/json"}

        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        payload = resp.read().decode("utf-8", "replace")
        conn.close()

        if resp.status >= 400:
            raise Exception(f"API error {resp.status}: {payload}")

        return payload

    def _firewalld_active(self):
        """Detecta se o firewalld esta ativo (Fedora/RHEL)."""
        try:
            result = subprocess.run(
                ["systemctl", "is-active", "--quiet", "firewalld"]
            )
            return result.returncode == 0
        except FileNotFoundError:
            return False

    def _check_iptables_rule(self, args):
        """Verifica se uma regra iptables ja existe (-C = check)."""
        result = subprocess.run(["iptables"] + args, capture_output=True)
        return result.returncode == 0

    def _add_iptables_rule_if_missing(self, check_args, add_args):
        """Adiciona regra iptables apenas se nao existir."""
        if not self._check_iptables_rule(check_args):
            subprocess.run(["iptables"] + add_args, check=False)

    def _firewalld_direct(self, args):
        """Adiciona uma regra direta do firewalld (idempotente)."""
        subprocess.run(
            ["firewall-cmd", "--direct", "--add-rule", "ipv4", "filter"] + args,
            check=False
        )

    def _setup_firewalld(self):
        """Configura NAT e isolamento via firewalld (Fedora)."""
        print("    Firewall: firewalld")
        subprocess.run(
            ["firewall-cmd", "--zone=trusted", f"--add-interface={TAP_DEV}"],
            check=False
        )
        subprocess.run(["firewall-cmd", "--add-masquerade"], check=False)

        # Rich rules: bloqueiam o trafego destinado ao proprio host (cadeia INPUT).
        for net in ("10.0.0.0/8", "192.168.0.0/16"):
            subprocess.run([
                "firewall-cmd", "--zone=trusted",
                f"--add-rich-rule=rule family=ipv4 source address={GUEST_NETWORK} "
                f"destination address={net} drop"
            ], check=False)

        # Direct rules na cadeia FORWARD: bloqueiam o que a VM tenta ROTEAR pra LAN.
        # As rich rules acima so filtram trafego destinado ao host; o trafego
        # encaminhado pra outros hosts da rede local passa pela cadeia FORWARD,
        # entao precisamos de regras diretas nela.
        self._firewalld_direct(
            ["FORWARD", "0", "-i", TAP_DEV, "-d", GUEST_NETWORK, "-j", "ACCEPT"]
        )
        for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"):
            self._firewalld_direct(
                ["FORWARD", "1", "-i", TAP_DEV, "-d", net, "-j", "DROP"]
            )

    def _setup_iptables(self):
        """Configura NAT e isolamento via iptables (Ubuntu e outros)."""
        print("    Firewall: iptables")
        result = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True, text=True
        )
        if "dev " not in result.stdout:
            raise Exception("Nao foi possivel detectar interface de saida")

        output_iface = result.stdout.split("dev ")[1].split()[0]
        print(f"    Interface de saida: {output_iface}")

        # NAT (apenas se a regra nao existir)
        self._add_iptables_rule_if_missing(
            ["-t", "nat", "-C", "POSTROUTING", "-o", output_iface, "-j", "MASQUERADE"],
            ["-t", "nat", "-A", "POSTROUTING", "-o", output_iface, "-j", "MASQUERADE"]
        )
        self._add_iptables_rule_if_missing(
            ["-C", "FORWARD", "-i", TAP_DEV, "-o", output_iface, "-j", "ACCEPT"],
            ["-A", "FORWARD", "-i", TAP_DEV, "-o", output_iface, "-j", "ACCEPT"]
        )
        self._add_iptables_rule_if_missing(
            ["-C", "FORWARD", "-i", output_iface, "-o", TAP_DEV,
             "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"],
            ["-A", "FORWARD", "-i", output_iface, "-o", TAP_DEV,
             "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"]
        )

        # Isolamento: inserido no TOPO da FORWARD pra ter prioridade sobre o ACCEPT
        # generico acima. Libera a subnet da propria VM e bloqueia o resto das
        # redes privadas.
        subprocess.run(
            ["iptables", "-I", "FORWARD", "-i", TAP_DEV, "-d", GUEST_NETWORK, "-j", "ACCEPT"],
            check=False
        )
        subprocess.run(
            ["iptables", "-I", "FORWARD", "2", "-i", TAP_DEV, "-d", "10.0.0.0/8", "-j", "DROP"],
            check=False
        )
        subprocess.run(
            ["iptables", "-I", "FORWARD", "3", "-i", TAP_DEV, "-d", "172.16.0.0/12", "-j", "DROP"],
            check=False
        )
        subprocess.run(
            ["iptables", "-I", "FORWARD", "4", "-i", TAP_DEV, "-d", "192.168.0.0/16", "-j", "DROP"],
            check=False
        )

    def setup_network(self):
        """Configura interface TAP, NAT e isolamento no host."""
        # Verifica se ja foi configurado (evita duplicar regras)
        if os.path.exists(f"/sys/class/net/{TAP_DEV}"):
            print("[*] Rede ja configurada, verificando...")
            subprocess.run(
                ["ip", "link", "set", TAP_DEV, "up"],
                check=False, capture_output=True
            )
            self.network_configured = True
            return

        print("[*] Configurando rede do host...")

        subprocess.run(
            ["ip", "tuntap", "add", "dev", TAP_DEV, "mode", "tap"],
            check=True
        )
        subprocess.run(
            ["ip", "addr", "add", f"{TAP_IP}/24", "dev", TAP_DEV],
            check=True
        )
        subprocess.run(["ip", "link", "set", TAP_DEV, "up"], check=True)
        subprocess.run(
            ["sysctl", "-w", "net.ipv4.ip_forward=1"],
            check=True, capture_output=True
        )

        # Detecta o firewall e configura NAT + isolamento na sintaxe correta
        if self._firewalld_active():
            self._setup_firewalld()
        else:
            self._setup_iptables()

        self.network_configured = True
        print("    Rede configurada")

    def prepare_rootfs(self, function_path, input_data):
        """Prepara o rootfs com a funcao e input."""
        self.temp_rootfs = tempfile.NamedTemporaryFile(
            suffix='.ext4',
            delete=False
        ).name

        print("[*] Copiando rootfs template...")
        shutil.copy(ROOTFS_TEMPLATE, self.temp_rootfs)

        mount_point = tempfile.mkdtemp()

        try:
            print("[*] Montando rootfs temporario...")
            subprocess.run(
                ["mount", self.temp_rootfs, mount_point],
                check=True
            )

            print(f"[*] Copiando funcao: {function_path}")
            func_dest = os.path.join(mount_point, "functions", "handler.py")
            shutil.copy(function_path, func_dest)

            input_dest = os.path.join(mount_point, "functions", "input.txt")
            with open(input_dest, 'w') as f:
                f.write(input_data)

        finally:
            subprocess.run(["umount", mount_point], check=True)
            os.rmdir(mount_point)

    def start_firecracker(self):
        """Inicia o processo Firecracker."""
        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)

        if os.path.exists(self.output_file):
            os.remove(self.output_file)

        print("[*] Iniciando Firecracker...")

        self.output_handle = open(self.output_file, 'w')
        self.fc_process = subprocess.Popen(
            [FIRECRACKER_BIN, "--api-sock", self.socket_path],
            stdout=self.output_handle,
            stderr=subprocess.STDOUT
        )

        for _ in range(50):
            if os.path.exists(self.socket_path):
                break
            time.sleep(0.1)
        else:
            raise Exception("Timeout esperando socket do Firecracker")

        time.sleep(0.2)

    def configure_vm(self):
        """Configura a microVM via API REST."""
        print("[*] Configurando kernel...")
        self._call_api("PUT", "/boot-source", {
            "kernel_image_path": KERNEL_PATH,
            "boot_args": "console=ttyS0 reboot=k panic=1 pci=off quiet"
        })

        print("[*] Configurando rootfs...")
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

        print("[*] Configurando rede da VM...")
        self._call_api("PUT", "/network-interfaces/eth0", {
            "iface_id": "eth0",
            "guest_mac": GUEST_MAC,
            "host_dev_name": TAP_DEV
        })

    def run_vm(self, timeout=60):
        """Inicia a VM e aguarda a execucao."""
        print("[*] Iniciando microVM...")
        self._call_api("PUT", "/actions", {"action_type": "InstanceStart"})

        print(f"[*] Aguardando execucao (timeout: {timeout}s)...")

        start_time = time.time()
        while time.time() - start_time < timeout:
            if self.fc_process.poll() is not None:
                break
            time.sleep(0.5)

        self.output_handle.close()

        if self.fc_process.poll() is None:
            self.fc_process.terminate()
            try:
                self.fc_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.fc_process.kill()
                self.fc_process.wait()

        if os.path.exists(self.output_file):
            with open(self.output_file, 'r') as f:
                output = f.read()
        else:
            output = ""

        return output

    def cleanup(self):
        """Remove recursos temporarios."""
        print("[*] Limpando...")

        if hasattr(self, 'output_handle') and not self.output_handle.closed:
            self.output_handle.close()

        if self.fc_process and self.fc_process.poll() is None:
            self.fc_process.terminate()
            try:
                self.fc_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.fc_process.kill()

        if self.temp_rootfs and os.path.exists(self.temp_rootfs):
            os.remove(self.temp_rootfs)

        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)

        if os.path.exists(self.output_file):
            os.remove(self.output_file)

    def invoke(self, function_path, input_data):
        """Invoca uma funcao Lambda-style com rede."""
        try:
            self.setup_network()
            self.prepare_rootfs(function_path, input_data)
            self.start_firecracker()
            self.configure_vm()
            output = self.run_vm()
            return self.parse_output(output)
        finally:
            self.cleanup()

    def parse_output(self, raw_output):
        """Extrai resultado do output bruto."""
        if "JSON_RESULT_START" in raw_output and "JSON_RESULT_END" in raw_output:
            start = raw_output.find("JSON_RESULT_START") + len("JSON_RESULT_START")
            end = raw_output.find("JSON_RESULT_END")
            json_data = raw_output[start:end].strip()
            try:
                return {
                    "success": True,
                    "type": "json",
                    "data": json.loads(json_data)
                }
            except json.JSONDecodeError:
                pass

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
    if os.geteuid() != 0:
        print("Erro: Este script precisa ser executado como root.")
        print("Uso: sudo python3 nano-lambda-network.py <funcao.py> <input>")
        sys.exit(1)

    if len(sys.argv) < 3:
        print("Uso: sudo python3 nano-lambda-network.py <funcao.py> <input>")
        print("Exemplo: sudo python3 nano-lambda-network.py exemplo-validador/handler.py 'https://google.com,https://github.com'")
        sys.exit(1)

    function_path = sys.argv[1]
    input_data = sys.argv[2]

    if not os.path.exists(function_path):
        print(f"Erro: funcao nao encontrada: {function_path}")
        sys.exit(1)

    for f, desc in [(FIRECRACKER_BIN, "Firecracker"), (KERNEL_PATH, "Kernel"), (ROOTFS_TEMPLATE, "Rootfs")]:
        if not os.path.exists(f):
            print(f"Erro: {desc} nao encontrado: {f}")
            print("Execute primeiro o build-rootfs-network.sh e baixe o Firecracker e kernel.")
            sys.exit(1)

    print("=" * 50)
    print("nano-Lambda Network: Funcao em microVM com internet")
    print("=" * 50)
    print(f"Funcao: {function_path}")
    print(f"Input: {input_data[:50]}..." if len(input_data) > 50 else f"Input: {input_data}")
    print()

    lambda_runner = NanoLambdaNetwork()

    def signal_handler(signum, frame):
        print("\n[!] Interrompido pelo usuario. Limpando recursos...")
        lambda_runner.cleanup()
        sys.exit(130)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    result = lambda_runner.invoke(function_path, input_data)

    print()
    print("=" * 50)
    print("Resultado:")
    print("=" * 50)

    if result["success"] and result["type"] == "json":
        print(json.dumps(result["data"], indent=2))
    elif result["success"] and result["type"] == "image":
        import base64
        output_file = "resultado.png"
        img_data = base64.b64decode(result["data"])
        with open(output_file, "wb") as f:
            f.write(img_data)
        print(f"Imagem salva em: {output_file}")
        print(f"Tamanho: {len(img_data)} bytes")
    else:
        print("Output bruto da VM:")
        print(result["data"])


if __name__ == "__main__":
    main()
