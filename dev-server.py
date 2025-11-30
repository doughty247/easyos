#!/usr/bin/env python3
"""
Local development server for easeOS webui.
Serves the UI and provides mock API endpoints.

Usage: python3 dev-server.py
Then open http://localhost:8089

Requirements: pip install cryptography
"""

import json
import os
import glob
import secrets
import base64
import hashlib
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# AES-256-GCM encryption using cryptography library
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    HAS_CRYPTO = True
except ImportError:
    print("[WARN] 'cryptography' package not installed. Run: pip install cryptography")
    print("[WARN] WiFi encryption will be disabled.")
    HAS_CRYPTO = False

PORT = 8089
ROOT = os.path.dirname(os.path.abspath(__file__))
WEBUI_DIR = os.path.join(ROOT, 'webui', 'templates')
STORE_DIR = os.path.join(ROOT, 'store', 'apps')
CONFIG_FILE = os.path.join(ROOT, 'dev-config.json')

# Session encryption key (simulates Kyber-1024 shared secret)
# Generate a new 16-character key for each server restart
SESSION_KEY = secrets.token_urlsafe(12)[:16]  # 16 chars
print(f"[CRYPTO] Session key generated: {SESSION_KEY[:4]}{'*' * 8}{SESSION_KEY[-4:]}")

# Derive AES-256 key from session key using PBKDF2 (matches client-side)
SALT = b'easeOS-wifi-salt'  # Must match client-side salt
ITERATIONS = 100000  # Must match client-side iterations

def derive_aes_key(secret: str) -> bytes:
    """Derive AES-256 key from secret using PBKDF2-SHA256 (matches Web Crypto API)"""
    return hashlib.pbkdf2_hmac(
        'sha256',
        secret.encode('utf-8'),
        SALT,
        ITERATIONS,
        dklen=32  # 256 bits for AES-256
    )

def aes_encrypt(data: str, key_string: str) -> str:
    """AES-256-GCM encryption - returns base64(IV + ciphertext + tag)"""
    if not HAS_CRYPTO:
        return None
    key = derive_aes_key(key_string)
    iv = secrets.token_bytes(12)  # 96-bit IV for GCM
    aesgcm = AESGCM(key)
    ciphertext = aesgcm.encrypt(iv, data.encode('utf-8'), None)
    # Combine IV + ciphertext (tag is appended by AESGCM)
    combined = iv + ciphertext
    return base64.b64encode(combined).decode('utf-8')

def aes_decrypt(encrypted_b64: str, key_string: str) -> str:
    """AES-256-GCM decryption - expects base64(IV + ciphertext + tag)"""
    if not HAS_CRYPTO:
        return None
    key = derive_aes_key(key_string)
    combined = base64.b64decode(encrypted_b64)
    iv = combined[:12]  # First 12 bytes are IV
    ciphertext = combined[12:]  # Rest is ciphertext + tag
    aesgcm = AESGCM(key)
    plaintext = aesgcm.decrypt(iv, ciphertext, None)
    return plaintext.decode('utf-8')

# Initialize dev config if not exists
if not os.path.exists(CONFIG_FILE):
    with open(CONFIG_FILE, 'w') as f:
        json.dump({
            "apps": {
                "immich": {"enable": True}
            }
        }, f, indent=2)

class DevHandler(SimpleHTTPRequestHandler):
    def _set_headers(self, code=200, ctype='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_OPTIONS(self):
        # Handle CORS preflight requests
        self._set_headers(200)

    def do_GET(self):
        parsed = urlparse(self.path)
        p = parsed.path
        query = parse_qs(parsed.query)
        
        if p == '/api/crypto/session':
            # Return the session encryption key
            # In production, this would use Kyber-1024 for key exchange
            # The shared secret is then used with AES-256-GCM for actual encryption
            self._set_headers()
            self.wfile.write(json.dumps({
                'key': SESSION_KEY,
                'algorithm': 'aes-256-gcm',
                'kex': 'kyber-1024-simulation'  # Key exchange method
            }).encode())
            return
        
        if p == '/':
            # Check config mode to determine which page to serve
            try:
                with open(CONFIG_FILE, 'r') as f:
                    config = json.load(f)
                mode = config.get('mode', 'first-run')
            except (FileNotFoundError, json.JSONDecodeError):
                mode = 'first-run'
            
            if mode == 'first-run':
                self._set_headers(200, 'text/html; charset=utf-8')
                with open(os.path.join(WEBUI_DIR, 'setup.html'), 'rb') as f:
                    self.wfile.write(f.read())
            else:
                self._set_headers(200, 'text/html; charset=utf-8')
                with open(os.path.join(WEBUI_DIR, 'index.html'), 'rb') as f:
                    self.wfile.write(f.read())
        
        elif p == '/index.html':
            self._set_headers(200, 'text/html; charset=utf-8')
            with open(os.path.join(WEBUI_DIR, 'index.html'), 'rb') as f:
                self.wfile.write(f.read())
        
        elif p == '/setup.html':
            self._set_headers(200, 'text/html; charset=utf-8')
            with open(os.path.join(WEBUI_DIR, 'setup.html'), 'rb') as f:
                self.wfile.write(f.read())
        
        elif p == '/api/storage/detect':
            # DEV MODE: Return empty drives array to test "no drives" UI
            # Set to True to simulate drives being found
            simulate_drives = False
            self._set_headers()
            if simulate_drives:
                self.wfile.write(json.dumps({
                    'drives': [
                        {'path': '/dev/sda', 'model': 'Samsung SSD 870', 'size': '500GB', 'hasData': False},
                        {'path': '/dev/sdb', 'model': 'WD Blue 1TB', 'size': '1TB', 'hasData': True}
                    ]
                }).encode())
            else:
                self.wfile.write(json.dumps({'drives': []}).encode())
        
        elif p == '/api/system/info':
            self._set_headers()
            # DEV MODE: Set isISO to True to test storage selection step
            self.wfile.write(json.dumps({
                'isISO': True,
                'version': '1.0.0-dev',
                'hostname': 'easeos-dev'
            }).encode())
                
        elif p == '/api/config':
            try:
                with open(CONFIG_FILE, 'r') as f:
                    data = json.load(f)
            except FileNotFoundError:
                data = {}
            self._set_headers()
            self.wfile.write(json.dumps(data).encode())
            
        elif p == '/api/status':
            self._set_headers()
            # DEV MODE: Set to True to test Greenhouse UI
            greenhouse_mode = True  # os.path.exists('/run/easyos-greenhouse-active')
            self.wfile.write(json.dumps({
                'active': 'inactive',
                'log': '[DEV MODE] No actual system operations\n',
                'greenhouseMode': greenhouse_mode,
                'greenhouseSSID': 'easeOS-Greenhouse' if greenhouse_mode else None,
                'greenhousePassword': 'greenhouse123' if greenhouse_mode else None,
                'connectedDevices': 3 if greenhouse_mode else 0
            }).encode())
            
        elif p == '/api/store/apps':
            apps = []
            try:
                for filepath in glob.glob(os.path.join(STORE_DIR, '*.json')):
                    try:
                        with open(filepath, 'r') as f:
                            app = json.load(f)
                            apps.append(app)
                    except Exception as e:
                        print(f"Error loading {filepath}: {e}")
            except Exception as e:
                print(f"Error scanning store: {e}")
            
            # Filter by category if specified
            category = query.get('category', [None])[0]
            if category:
                apps = [a for a in apps if a.get('category') == category]
            
            # Search by query if specified
            search = query.get('q', [None])[0]
            if search:
                search = search.lower()
                apps = [a for a in apps if 
                        search in a.get('name', '').lower() or 
                        search in a.get('description', '').lower() or
                        any(search in tag.lower() for tag in a.get('tags', []))]
            
            self._set_headers()
            self.wfile.write(json.dumps(apps).encode())
            
        elif p.startswith('/api/store/app/'):
            app_id = p.split('/')[-1]
            app_path = os.path.join(STORE_DIR, f'{app_id}.json')
            if os.path.exists(app_path):
                with open(app_path, 'r') as f:
                    self._set_headers()
                    self.wfile.write(f.read().encode())
            else:
                self.send_error(404, f'App {app_id} not found')
                
        elif p == '/api/store/categories':
            categories = set()
            try:
                for filepath in glob.glob(os.path.join(STORE_DIR, '*.json')):
                    try:
                        with open(filepath, 'r') as f:
                            app = json.load(f)
                            if 'category' in app:
                                categories.add(app['category'])
                    except Exception:
                        pass
            except Exception:
                pass
            self._set_headers()
            self.wfile.write(json.dumps(list(categories)).encode())
        
        elif p == '/api/wifi/scan':
            # Check if client requests plain (unencrypted) response
            query = parse_qs(urlparse(self.path).query)
            want_plain = query.get('plain', ['0'])[0] == '1'
            
            # Scan for real WiFi networks using nmcli
            networks = []
            try:
                import subprocess
                import time as time_module
                # Rescan first
                subprocess.run(['nmcli', 'dev', 'wifi', 'rescan'], capture_output=True, timeout=10)
                time_module.sleep(1)
                # Get network list
                result = subprocess.run(
                    ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'dev', 'wifi', 'list'],
                    capture_output=True, text=True, timeout=10
                )
                seen = set()
                for line in result.stdout.strip().split('\n'):
                    if line:
                        parts = line.split(':')
                        if len(parts) >= 2:
                            ssid = parts[0].strip()
                            if ssid and ssid not in seen:
                                seen.add(ssid)
                                try:
                                    signal = int(parts[1])
                                except:
                                    signal = 50
                                security = parts[2] if len(parts) > 2 else 'Unknown'
                                networks.append({
                                    'ssid': ssid,
                                    'signal': signal,
                                    'security': security
                                })
                # Sort by signal strength
                networks.sort(key=lambda x: x['signal'], reverse=True)
            except Exception as e:
                print(f"WiFi scan error: {e}")
                # Fallback to mock if nmcli fails
                networks = [
                    {'ssid': 'HomeNetwork', 'signal': 92, 'security': 'WPA2'},
                    {'ssid': 'FamilyWifi_5G', 'signal': 78, 'security': 'WPA2'},
                ]
            
            # Encrypt the network list with AES-256-GCM (unless plain requested)
            if HAS_CRYPTO and not want_plain:
                encrypted_data = aes_encrypt(json.dumps(networks), SESSION_KEY)
                self._set_headers()
                self.wfile.write(json.dumps({
                    'encrypted': True,
                    'data': encrypted_data
                }).encode())
            else:
                # Return unencrypted if crypto unavailable or plain requested
                self._set_headers()
                self.wfile.write(json.dumps(networks).encode())
            
        else:
            self.send_error(404)

    def do_POST(self):
        p = urlparse(self.path).path
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode() if length else ""
        
        if p == '/api/config':
            try:
                data = json.loads(body or '{}')
            except json.JSONDecodeError:
                self._set_headers(400)
                self.wfile.write(json.dumps({'error': 'invalid json'}).encode())
                return
            with open(CONFIG_FILE, 'w') as f:
                json.dump(data, f, indent=2)
            self._set_headers(200)
            self.wfile.write(json.dumps({'ok': True}).encode())
            
        elif p == '/api/apply':
            print("\n[DEV] Apply triggered with config:")
            try:
                with open(CONFIG_FILE, 'r') as f:
                    print(json.dumps(json.load(f), indent=2))
            except:
                pass
            self._set_headers(202)
            self.wfile.write(json.dumps({'started': True, 'dev': True}).encode())
        
        elif p == '/api/wifi/connect':
            # WiFi connection with encrypted credentials
            # In production, this calls `nmcli dev wifi connect <SSID> password <password>`
            try:
                data = json.loads(body or '{}')
                
                # Check if credentials are encrypted (AES-256-GCM)
                if data.get('encrypted') and HAS_CRYPTO:
                    decrypted_json = aes_decrypt(data.get('data', ''), SESSION_KEY)
                    credentials = json.loads(decrypted_json)
                    ssid = credentials.get('ssid', '')
                    password = credentials.get('password', '')
                    print(f"\n[CRYPTO] Received AES-256-GCM encrypted WiFi credentials")
                else:
                    # Fallback for unencrypted (dev only / crypto unavailable)
                    ssid = data.get('ssid', '')
                    password = data.get('password', '')
                    print(f"\n[WARN] Received unencrypted WiFi credentials")
                
                print(f"[DEV] WiFi Connect: {ssid} (password: {'*' * len(password)})")
                
                # Simulate connection delay
                import time as time_module
                time_module.sleep(2)
                
                # TEST MODE: Use special SSIDs to test failure handling
                # - "fail" or "test-fail" SSID simulates connection failure
                # - "timeout" SSID simulates timeout (extra delay)
                if ssid.lower() in ['fail', 'test-fail']:
                    print(f"[DEV] Simulating WiFi failure for SSID: {ssid}")
                    self._set_headers(200)
                    self.wfile.write(json.dumps({
                        'success': False,
                        'error': 'Connection failed: incorrect password or network not found'
                    }).encode())
                elif ssid.lower() == 'timeout':
                    print(f"[DEV] Simulating WiFi timeout for SSID: {ssid}")
                    time_module.sleep(10)  # Extra delay
                    self._set_headers(200)
                    self.wfile.write(json.dumps({
                        'success': False,
                        'error': 'Connection timed out'
                    }).encode())
                else:
                    # Simulate success (in production, check nmcli exit code)
                    self._set_headers(200)
                    self.wfile.write(json.dumps({
                        'success': True,
                        'ssid': ssid,
                        'ip': '192.168.1.42'
                    }).encode())
            except Exception as e:
                print(f"[ERROR] WiFi connect failed: {e}")
                self._set_headers(500)
                self.wfile.write(json.dumps({'error': str(e)}).encode())
        
        elif p == '/api/setup/account':
            # Create user account (with encrypted credentials)
            try:
                data = json.loads(body or '{}')
                
                # Decrypt if encrypted
                if data.get('encrypted') and HAS_CRYPTO:
                    decrypted_json = aes_decrypt(data.get('data', ''), SESSION_KEY)
                    account = json.loads(decrypted_json)
                    username = account.get('username', '')
                    password = account.get('password', '')
                    hostname = account.get('hostname', 'easeos')
                    print(f"\n[CRYPTO] Received AES-256-GCM encrypted account credentials")
                else:
                    username = data.get('username', '')
                    password = data.get('password', '')
                    hostname = data.get('hostname', 'easeos')
                    print(f"\n[WARN] Received unencrypted account credentials")
                
                print(f"[DEV] Create Account:")
                print(f"      Username: {username}")
                print(f"      Password: {'*' * len(password)}")
                print(f"      Hostname: {hostname}")
                
                # In production, this would:
                # 1. Hash the password with openssl passwd -6
                # 2. Write to /etc/easy/config.json or credentials file
                # 3. Update NixOS configuration
                
                # Save to config for dev purposes
                try:
                    with open(CONFIG_FILE, 'r') as f:
                        cfg = json.load(f)
                except:
                    cfg = {}
                
                cfg['admin'] = {
                    'username': username,
                    'hostname': hostname,
                    'created': True
                }
                
                with open(CONFIG_FILE, 'w') as f:
                    json.dump(cfg, f, indent=2)
                
                self._set_headers(200)
                self.wfile.write(json.dumps({
                    'success': True,
                    'username': username,
                    'hostname': hostname
                }).encode())
            except Exception as e:
                print(f"[ERROR] Account creation failed: {e}")
                self._set_headers(500)
                self.wfile.write(json.dumps({'error': str(e)}).encode())
            
        else:
            self.send_error(404)

if __name__ == '__main__':
    print(f"╔═══════════════════════════════════════════════════╗")
    print(f"║        easeOS Development Server                  ║")
    print(f"╠═══════════════════════════════════════════════════╣")
    print(f"║  UI:     http://localhost:{PORT}/                   ║")
    print(f"║  Store:  {STORE_DIR}")
    print(f"║  Config: {CONFIG_FILE}")
    print(f"╚═══════════════════════════════════════════════════╝")
    
    httpd = HTTPServer(('0.0.0.0', PORT), DevHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
