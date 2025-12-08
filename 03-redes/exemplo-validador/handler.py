#!/usr/bin/env python3
"""
Funcao nano-Lambda: Validador de URLs

Le uma lista de URLs de /functions/input.txt e retorna o status HTTP de cada uma.
Usa requests em paralelo pra performance.
"""

import json
import sys
import ssl
import socket
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
    HAS_REQUESTS = True
except ImportError:
    import urllib.request
    import urllib.error
    HAS_REQUESTS = False


def check_url_requests(url):
    """Verifica URL usando requests."""
    try:
        resp = requests.head(url, timeout=10, allow_redirects=True)
        return {
            "url": url,
            "status": resp.status_code,
            "ok": resp.ok
        }
    except requests.exceptions.SSLError as e:
        return {"url": url, "status": "SSL_ERROR", "ok": False, "error": str(e)}
    except requests.exceptions.ConnectionError:
        return {"url": url, "status": "CONNECTION_ERROR", "ok": False}
    except requests.exceptions.Timeout:
        return {"url": url, "status": "TIMEOUT", "ok": False}
    except Exception as e:
        return {"url": url, "status": "ERROR", "ok": False, "error": str(e)}


def check_url_urllib(url):
    """Verifica URL usando urllib (fallback)."""
    try:
        req = urllib.request.Request(url, method='HEAD')
        with urllib.request.urlopen(req, timeout=10) as resp:
            return {
                "url": url,
                "status": resp.getcode(),
                "ok": 200 <= resp.getcode() < 400
            }
    except urllib.error.HTTPError as e:
        return {"url": url, "status": e.code, "ok": False}
    except urllib.error.URLError as e:
        return {"url": url, "status": "URL_ERROR", "ok": False, "error": str(e.reason)}
    except Exception as e:
        return {"url": url, "status": "ERROR", "ok": False, "error": str(e)}


def check_ssl_expiry(url):
    """Verifica se o certificado SSL vai expirar em 30 dias."""
    try:
        hostname = url.replace("https://", "").replace("http://", "").split("/")[0]
        context = ssl.create_default_context()

        with socket.create_connection((hostname, 443), timeout=10) as sock:
            with context.wrap_socket(sock, server_hostname=hostname) as ssock:
                cert = ssock.getpeercert()

        not_after = cert['notAfter']
        expire_date = datetime.strptime(not_after, '%b %d %H:%M:%S %Y %Z')
        days_left = (expire_date - datetime.now()).days

        return {
            "expires": not_after,
            "days_left": days_left,
            "warning": days_left < 30
        }
    except Exception as e:
        return {"error": str(e)}


def main():
    try:
        with open('/functions/input.txt', 'r') as f:
            content = f.read().strip()
    except FileNotFoundError:
        print("ERRO: /functions/input.txt nao encontrado")
        sys.exit(1)

    # Parseia URLs (uma por linha ou separadas por virgula)
    urls = [u.strip() for u in content.replace(',', '\n').split('\n') if u.strip()]

    if not urls:
        print("ERRO: Nenhuma URL fornecida")
        sys.exit(1)

    print(f"Validando {len(urls)} URLs...")

    check_func = check_url_requests if HAS_REQUESTS else check_url_urllib

    results = []
    with ThreadPoolExecutor(max_workers=5) as executor:
        futures = {executor.submit(check_func, url): url for url in urls}

        for future in as_completed(futures):
            result = future.result()

            if result["url"].startswith("https://") and result.get("ok"):
                result["ssl"] = check_ssl_expiry(result["url"])

            results.append(result)
            status = result['status']
            print(f"  {result['url']}: {status}")

    report = {
        "timestamp": datetime.now().isoformat(),
        "total": len(urls),
        "ok": sum(1 for r in results if r.get("ok")),
        "failed": sum(1 for r in results if not r.get("ok")),
        "results": results
    }

    print("")
    print("JSON_RESULT_START")
    print(json.dumps(report, indent=2))
    print("JSON_RESULT_END")


if __name__ == '__main__':
    main()
