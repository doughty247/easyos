#!/usr/bin/env python3
"""
easeOS Web UI Server
Works in both development and production (ISO/installed) modes.

Usage:
  Development: python3 webui/server.py (from easyos directory)
  Production:  Runs via systemd on port 1234
"""

import json
import os
import sys
import glob
import secrets
import base64
import hashlib
import re
import subprocess
import threading
import time
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# =============================================================================
# ENVIRONMENT DETECTION
# =============================================================================

# Detect running environment based on multiple signals
def detect_environment():
    """Detect if we're running in dev, ISO, or installed mode"""
    # Check for production markers first
    if os.path.exists('/etc/easy/iso-mode'):
        return 'iso'
    if os.path.exists('/etc/easy/installed'):
        return 'installed'
    
    # Check for dev mode - look for dev-config.json in various locations
    script_path = os.path.abspath(__file__) if '__file__' in dir() else os.getcwd()
    
    # Try to find dev-config.json by walking up directories
    check_dirs = [
        os.path.dirname(os.path.dirname(script_path)),  # webui/../
        os.path.dirname(script_path),  # current dir
        os.getcwd(),  # working directory
        os.path.join(os.getcwd(), '..'),  # parent of cwd
    ]
    
    for d in check_dirs:
        if os.path.exists(os.path.join(d, 'dev-config.json')):
            return 'dev'
    
    # Default to production if nothing found
    return 'production'

ENV_MODE = detect_environment()
IS_DEV = ENV_MODE == 'dev'
IS_ISO = ENV_MODE == 'iso'
IS_INSTALLED = ENV_MODE == 'installed'

if IS_DEV:
    # Development mode - find the repo root
    script_path = os.path.abspath(__file__) if '__file__' in dir() else os.getcwd()
    # Walk up to find dev-config.json
    ROOT = os.path.dirname(os.path.dirname(script_path))
    if not os.path.exists(os.path.join(ROOT, 'dev-config.json')):
        ROOT = os.getcwd()
        if not os.path.exists(os.path.join(ROOT, 'dev-config.json')):
            # Try parent
            ROOT = os.path.dirname(ROOT)
    
    WEBUI_DIR = os.path.join(ROOT, 'webui', 'templates')
    STORE_DIR = os.path.join(ROOT, 'store', 'apps')
    CONFIG_FILE = os.path.join(ROOT, 'dev-config.json')
    PORT = 8089
    MUTABLE_DIR = '/tmp/easyos-dev'
    print(f"[MODE] Development mode")
    print(f"[MODE] ROOT: {ROOT}")
else:
    # Production mode - running on ISO or installed system
    ROOT = '/etc/easy'
    WEBUI_DIR = '/etc/easy/webui/templates'
    STORE_DIR = '/etc/easy/store/apps'
    CONFIG_FILE = '/etc/easy/config.json'
    PORT = 1234
    MUTABLE_DIR = '/var/lib/easyos'
    if IS_ISO:
        print(f"[MODE] ISO installer mode")
    elif IS_INSTALLED:
        print(f"[MODE] Installed system mode")
    else:
        print(f"[MODE] Production mode")
os.makedirs(MUTABLE_DIR, exist_ok=True)

# =============================================================================
# ENCRYPTION (AES-256-GCM)
# =============================================================================

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    HAS_CRYPTO = True
except ImportError:
    print("[WARN] 'cryptography' package not installed")
    print("[WARN] WiFi/credential encryption will be disabled")
    HAS_CRYPTO = False

# Session encryption key
SESSION_KEY = secrets.token_urlsafe(12)[:16]
print(f"[CRYPTO] Session key: {SESSION_KEY[:4]}{'*' * 8}{SESSION_KEY[-4:]}")

SALT = b'easeOS-wifi-salt'
ITERATIONS = 100000

def derive_aes_key(secret: str) -> bytes:
    """Derive AES-256 key from secret using PBKDF2-SHA256"""
    return hashlib.pbkdf2_hmac('sha256', secret.encode('utf-8'), SALT, ITERATIONS, dklen=32)

def aes_encrypt(data: str, key_string: str) -> str:
    """AES-256-GCM encryption"""
    if not HAS_CRYPTO:
        return None
    key = derive_aes_key(key_string)
    iv = secrets.token_bytes(12)
    aesgcm = AESGCM(key)
    ciphertext = aesgcm.encrypt(iv, data.encode('utf-8'), None)
    return base64.b64encode(iv + ciphertext).decode('utf-8')

def aes_decrypt(encrypted_b64: str, key_string: str) -> str:
    """AES-256-GCM decryption"""
    if not HAS_CRYPTO:
        return None
    key = derive_aes_key(key_string)
    combined = base64.b64decode(encrypted_b64)
    iv = combined[:12]
    ciphertext = combined[12:]
    aesgcm = AESGCM(key)
    plaintext = aesgcm.decrypt(iv, ciphertext, None)
    return plaintext.decode('utf-8')

# =============================================================================
# VALIDATION
# =============================================================================

def validate_password_strength(password: str) -> str:
    """Validate password strength. Returns error message or None if valid."""
    if not password or len(password) < 8:
        return 'Password must be at least 8 characters'
    if ' ' in password or '\t' in password:
        return 'Password cannot contain spaces'
    if not re.search(r'[A-Z]', password):
        return 'Password must contain at least 1 uppercase letter'
    if not re.search(r'[0-9]', password):
        return 'Password must contain at least 1 number'
    if not re.search(r'[!@#$%^&*()_+\-=\[\]{};\':"\\|,.<>\/?~`]', password):
        return 'Password must contain at least 1 symbol (!@#$%^&* etc.)'
    return None

# =============================================================================
# CONFIGURATION
# =============================================================================

def load_config():
    """Load config from file"""
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_config(cfg):
    """Save config to file"""
    with open(CONFIG_FILE, 'w') as f:
        json.dump(cfg, f, indent=2)

# Initialize dev config if needed
if IS_DEV and not os.path.exists(CONFIG_FILE):
    save_config({'mode': 'first-run', 'apps': {'immich': {'enable': True}}})

# =============================================================================
# INSTALL PROGRESS (shared state)
# =============================================================================

INSTALL_PROGRESS = {
    'running': False,
    'progress': 0,
    'stage': 'idle',
    'message': '',
    'complete': False,
    'error': None
}

PROGRESS_FILE = os.path.join(MUTABLE_DIR, 'install-progress.json')

def get_install_progress():
    """Get current install progress"""
    # In production, read from progress file written by install script
    if not IS_DEV and os.path.exists(PROGRESS_FILE):
        try:
            with open(PROGRESS_FILE, 'r') as f:
                return json.load(f)
        except:
            pass
    return INSTALL_PROGRESS

# =============================================================================
# HTTP HANDLER
# =============================================================================

class EasyOSHandler(SimpleHTTPRequestHandler):
    def _set_headers(self, code=200, ctype='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_OPTIONS(self):
        self._set_headers(200)

    def log_message(self, format, *args):
        """Custom logging"""
        print(f"{self.client_address[0]} - {format % args}")

    def do_GET(self):
        parsed = urlparse(self.path)
        p = parsed.path
        query = parse_qs(parsed.query)

        # ---------------------------------------------------------------------
        # Static files / HTML
        # ---------------------------------------------------------------------
        if p == '/':
            config = load_config()
            mode = config.get('mode', 'first-run')
            template = 'setup.html' if mode == 'first-run' else 'index.html'
            self._serve_html(template)

        elif p in ['/index.html', '/setup.html']:
            self._serve_html(p.lstrip('/'))

        elif p.startswith('/static/'):
            self._serve_static(p)

        # ---------------------------------------------------------------------
        # API: Crypto
        # ---------------------------------------------------------------------
        elif p == '/api/crypto/session':
            self._set_headers()
            self.wfile.write(json.dumps({
                'key': SESSION_KEY,
                'algorithm': 'aes-256-gcm',
                'kex': 'kyber-1024-simulation'
            }).encode())

        # ---------------------------------------------------------------------
        # API: System Info
        # ---------------------------------------------------------------------
        elif p == '/api/system/info':
            self._set_headers()
            self.wfile.write(json.dumps({
                'isISO': IS_ISO,
                'isInstalled': IS_INSTALLED,
                'isDev': IS_DEV,
                'channel': self._get_channel(),
                'mode': 'live-installer' if IS_ISO else 'installed',
                'version': '1.0.0',
                'hostname': self._get_hostname()
            }).encode())

        # ---------------------------------------------------------------------
        # API: Config
        # ---------------------------------------------------------------------
        elif p == '/api/config':
            self._set_headers()
            self.wfile.write(json.dumps(load_config()).encode())

        elif p == '/api/status':
            self._set_headers()
            status = {'active': 'inactive', 'log': ''}
            # Check for greenhouse mode
            if os.path.exists('/run/easyos-greenhouse-active'):
                status['greenhouseMode'] = True
            self.wfile.write(json.dumps(status).encode())

        # ---------------------------------------------------------------------
        # API: Storage Detection
        # ---------------------------------------------------------------------
        elif p == '/api/storage/detect':
            self._set_headers()
            self.wfile.write(json.dumps(self._detect_storage()).encode())

        # ---------------------------------------------------------------------
        # API: TPM Detection
        # ---------------------------------------------------------------------
        elif p == '/api/tpm/detect':
            self._set_headers()
            self.wfile.write(json.dumps(self._detect_tpm()).encode())

        # ---------------------------------------------------------------------
        # API: Install Progress
        # ---------------------------------------------------------------------
        elif p == '/api/install/status':
            self._set_headers()
            self.wfile.write(json.dumps(get_install_progress()).encode())

        # ---------------------------------------------------------------------
        # API: Store
        # ---------------------------------------------------------------------
        elif p == '/api/store/apps':
            apps = self._load_store_apps()
            # Filter by category
            category = query.get('category', [None])[0]
            if category:
                apps = [a for a in apps if a.get('category') == category]
            # Search
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
            for app in self._load_store_apps():
                if 'category' in app:
                    categories.add(app['category'])
            self._set_headers()
            self.wfile.write(json.dumps(list(categories)).encode())

        # ---------------------------------------------------------------------
        # API: WiFi Scan
        # ---------------------------------------------------------------------
        elif p == '/api/wifi/scan':
            want_plain = query.get('plain', ['0'])[0] == '1'
            networks = self._scan_wifi()
            
            if HAS_CRYPTO and not want_plain:
                encrypted = aes_encrypt(json.dumps(networks), SESSION_KEY)
                self._set_headers()
                self.wfile.write(json.dumps({'encrypted': True, 'data': encrypted}).encode())
            else:
                self._set_headers()
                self.wfile.write(json.dumps(networks).encode())

        else:
            self.send_error(404)

    def do_POST(self):
        p = urlparse(self.path).path
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode() if length else ""

        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._set_headers(400)
            self.wfile.write(json.dumps({'error': 'Invalid JSON'}).encode())
            return

        # ---------------------------------------------------------------------
        # API: Config Save
        # ---------------------------------------------------------------------
        if p == '/api/config':
            save_config(data)
            self._set_headers()
            self.wfile.write(json.dumps({'ok': True}).encode())

        # ---------------------------------------------------------------------
        # API: Apply Config
        # ---------------------------------------------------------------------
        elif p == '/api/apply':
            if IS_DEV:
                print("[DEV] Apply triggered")
                self._set_headers(202)
                self.wfile.write(json.dumps({'started': True, 'dev': True}).encode())
            else:
                # Run the apply script in background
                subprocess.Popen(['/etc/easy/apply.sh'],
                    stdout=open('/var/log/easyos-apply.log', 'a'),
                    stderr=subprocess.STDOUT)
                self._set_headers(202)
                self.wfile.write(json.dumps({'started': True}).encode())

        # ---------------------------------------------------------------------
        # API: WiFi Connect
        # ---------------------------------------------------------------------
        elif p == '/api/wifi/connect':
            result = self._handle_wifi_connect(data)
            self._set_headers(200 if result.get('success') else 400)
            self.wfile.write(json.dumps(result).encode())

        # ---------------------------------------------------------------------
        # API: Account Setup
        # ---------------------------------------------------------------------
        elif p == '/api/setup/account':
            result = self._handle_account_setup(data)
            self._set_headers(200 if result.get('success') else 400)
            self.wfile.write(json.dumps(result).encode())

        # ---------------------------------------------------------------------
        # API: Install Start
        # ---------------------------------------------------------------------
        elif p == '/api/install/start':
            result = self._handle_install_start(data)
            code = 202 if result.get('success') else 400
            self._set_headers(code)
            self.wfile.write(json.dumps(result).encode())

        # ---------------------------------------------------------------------
        # API: Reboot
        # ---------------------------------------------------------------------
        elif p == '/api/system/reboot':
            if IS_DEV:
                print("[DEV] Reboot requested (simulated)")
                self._set_headers()
                self.wfile.write(json.dumps({'rebooting': True, 'dev': True}).encode())
            else:
                self._set_headers()
                self.wfile.write(json.dumps({'rebooting': True}).encode())
                subprocess.Popen(['sh', '-c', 'sleep 2 && systemctl reboot'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        else:
            self.send_error(404)

    # =========================================================================
    # HELPER METHODS
    # =========================================================================

    def _serve_html(self, filename):
        """Serve an HTML template"""
        filepath = os.path.join(WEBUI_DIR, filename)
        if os.path.exists(filepath):
            self._set_headers(200, 'text/html; charset=utf-8')
            with open(filepath, 'rb') as f:
                self.wfile.write(f.read())
        else:
            self.send_error(404, f'Template not found: {filename}')

    def _serve_static(self, path):
        """Serve static files (css, js)"""
        # Map /static/... to webui/static/...
        if IS_DEV:
            filepath = os.path.join(ROOT, 'webui', path.lstrip('/'))
        else:
            filepath = os.path.join('/etc/easy/webui', path.lstrip('/'))
        
        if os.path.exists(filepath) and os.path.isfile(filepath):
            ext = os.path.splitext(filepath)[1].lower()
            ctypes = {
                '.css': 'text/css',
                '.js': 'application/javascript',
                '.png': 'image/png',
                '.jpg': 'image/jpeg',
                '.svg': 'image/svg+xml',
                '.ico': 'image/x-icon'
            }
            ctype = ctypes.get(ext, 'application/octet-stream')
            self._set_headers(200, ctype)
            with open(filepath, 'rb') as f:
                self.wfile.write(f.read())
        else:
            self.send_error(404)

    def _get_channel(self):
        """Get current channel (stable/beta/edge)"""
        try:
            with open('/etc/easy/channel', 'r') as f:
                return f.read().strip()
        except:
            return 'stable'

    def _get_hostname(self):
        """Get system hostname"""
        try:
            return subprocess.check_output(['hostname'], text=True).strip()
        except:
            return 'easyos'

    def _detect_storage(self):
        """Detect storage devices"""
        if IS_DEV:
            # Return empty in dev mode, or set simulate_drives = True for testing
            return {'drives': [], 'isVM': False, 'autoInstallDrive': None}
        
        drives = []
        try:
            result = subprocess.run(
                ['lsblk', '-J', '-o', 'NAME,SIZE,MODEL,TYPE,FSTYPE,MOUNTPOINT,SERIAL,TRAN,RM'],
                capture_output=True, text=True, timeout=10
            )
            data = json.loads(result.stdout)
            
            for device in data.get('blockdevices', []):
                if device.get('type') != 'disk':
                    continue
                name = device.get('name', '')
                if name.startswith('loop') or name.startswith('ram') or name.startswith('zram'):
                    continue
                
                # Check for partitions with data
                partitions = []
                has_data = False
                for child in device.get('children', []):
                    fstype = child.get('fstype')
                    mountpoint = child.get('mountpoint')
                    if fstype and fstype not in ['', 'swap']:
                        has_data = True
                        partitions.append({
                            'name': child.get('name', ''),
                            'size': child.get('size', ''),
                            'fstype': fstype,
                            'mountpoint': mountpoint or ''
                        })
                
                transport = device.get('tran', '')
                is_virtual = transport in ['virtio', ''] and device.get('model', '') == ''
                
                drives.append({
                    'name': name,
                    'path': f'/dev/{name}',
                    'model': (device.get('model') or 'Unknown Drive').strip(),
                    'serial': device.get('serial', ''),
                    'transport': transport,
                    'size': device.get('size', ''),
                    'hasData': has_data,
                    'isBlank': not has_data and len(partitions) == 0,
                    'isVirtual': is_virtual,
                    'partitions': partitions
                })
        except Exception as e:
            print(f"[ERROR] Storage detection failed: {e}")
        
        return {
            'drives': drives,
            'isVM': any(d.get('isVirtual') for d in drives),
            'autoInstallDrive': drives[0]['path'] if len(drives) == 1 and drives[0].get('isBlank') else None
        }

    def _detect_tpm(self):
        """Detect TPM2 device"""
        if IS_DEV:
            return {'available': True, 'device': '/dev/tpmrm0', 'version': '2.0', 'canEnroll': True}
        
        tpm_device = '/dev/tpmrm0'
        if os.path.exists(tpm_device):
            return {
                'available': True,
                'device': tpm_device,
                'version': '2.0',
                'canEnroll': True
            }
        return {'available': False, 'canEnroll': False}

    def _load_store_apps(self):
        """Load app definitions from store"""
        apps = []
        try:
            for filepath in glob.glob(os.path.join(STORE_DIR, '*.json')):
                try:
                    with open(filepath, 'r') as f:
                        apps.append(json.load(f))
                except Exception as e:
                    print(f"[WARN] Failed to load {filepath}: {e}")
        except Exception as e:
            print(f"[ERROR] Store scan failed: {e}")
        return apps

    def _scan_wifi(self):
        """Scan for WiFi networks"""
        networks = []
        try:
            # Rescan
            subprocess.run(['nmcli', 'dev', 'wifi', 'rescan'], capture_output=True, timeout=10)
            time.sleep(1)
            
            # Get list
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
            
            networks.sort(key=lambda x: x['signal'], reverse=True)
        except Exception as e:
            print(f"[WARN] WiFi scan failed: {e}")
            if IS_DEV:
                # Fallback mock for dev
                networks = [
                    {'ssid': 'HomeNetwork', 'signal': 92, 'security': 'WPA2'},
                    {'ssid': 'FamilyWifi_5G', 'signal': 78, 'security': 'WPA2'},
                ]
        
        return networks

    def _decrypt_if_needed(self, data):
        """Decrypt data if encrypted"""
        if data.get('encrypted') and HAS_CRYPTO:
            decrypted = aes_decrypt(data.get('data', ''), SESSION_KEY)
            return json.loads(decrypted)
        return data

    def _handle_wifi_connect(self, data):
        """Handle WiFi connection request"""
        try:
            creds = self._decrypt_if_needed(data)
            ssid = creds.get('ssid', '')
            password = creds.get('password', '')
            
            if not ssid:
                return {'success': False, 'error': 'SSID required'}
            
            print(f"[WiFi] Connecting to: {ssid}")
            
            if IS_DEV:
                # Simulate connection
                time.sleep(2)
                if ssid.lower() in ['fail', 'test-fail']:
                    return {'success': False, 'error': 'Connection failed: incorrect password'}
                return {'success': True, 'ssid': ssid, 'ip': '192.168.1.42'}
            else:
                # Real connection via nmcli
                cmd = ['nmcli', 'dev', 'wifi', 'connect', ssid]
                if password:
                    cmd.extend(['password', password])
                
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                
                if result.returncode == 0:
                    return {'success': True, 'ssid': ssid}
                else:
                    error = result.stderr.strip() or 'Connection failed'
                    return {'success': False, 'error': error}
        
        except Exception as e:
            return {'success': False, 'error': str(e)}

    def _handle_account_setup(self, data):
        """Handle account creation"""
        try:
            creds = self._decrypt_if_needed(data)
            username = creds.get('username', '')
            password = creds.get('password', '')
            hostname = creds.get('hostname', 'easyos')
            
            if not username or not password:
                return {'success': False, 'error': 'Username and password required'}
            
            # Validate password
            pwd_error = validate_password_strength(password)
            if pwd_error:
                return {'success': False, 'error': pwd_error}
            
            print(f"[Account] Creating: {username}@{hostname}")
            
            # Save to config
            cfg = load_config()
            cfg['admin'] = {
                'username': username,
                'hostname': hostname,
                'created': True
            }
            cfg['hostName'] = hostname
            save_config(cfg)
            
            if not IS_DEV:
                # Hash password and save to credentials file
                result = subprocess.run(
                    ['openssl', 'passwd', '-6', '-stdin'],
                    input=password, capture_output=True, text=True
                )
                if result.returncode == 0:
                    hash_value = result.stdout.strip()
                    cred_path = '/etc/easy/credentials.json'
                    creds_data = {'passwordHash': hash_value, 'username': username}
                    with open(cred_path, 'w') as f:
                        json.dump(creds_data, f)
                    os.chmod(cred_path, 0o600)
            
            return {'success': True, 'username': username, 'hostname': hostname}
        
        except Exception as e:
            return {'success': False, 'error': str(e)}

    def _handle_install_start(self, data):
        """Handle installation start"""
        global INSTALL_PROGRESS
        
        try:
            install_data = self._decrypt_if_needed(data)
            
            drive = install_data.get('drive', '')
            encrypt = install_data.get('encrypt', False)
            username = install_data.get('username', '')
            password = install_data.get('password', '')
            hostname = install_data.get('hostname', 'easyos')
            encryption_password = install_data.get('encryptionPassword', '')
            wifi = install_data.get('wifi', {})
            
            if not drive:
                return {'success': False, 'error': 'No drive specified'}
            if not username or not password:
                return {'success': False, 'error': 'Username and password required'}
            
            pwd_error = validate_password_strength(password)
            if pwd_error:
                return {'success': False, 'error': pwd_error}
            
            print(f"[Install] Starting on {drive}")
            print(f"          User: {username}@{hostname}")
            print(f"          Encrypt: {encrypt}")
            
            install_id = f"install_{int(time.time())}"
            
            if IS_DEV:
                # Simulate installation in background thread
                def simulate():
                    global INSTALL_PROGRESS
                    stages = [
                        ('preparing', 5, 'Initializing...'),
                        ('partitioning', 15, 'Creating partitions...'),
                        ('formatting', 25, 'Formatting filesystem...'),
                        ('mounting', 35, 'Mounting partitions...'),
                        ('cloning', 50, 'Cloning easeOS...'),
                        ('configuring', 65, 'Generating configuration...'),
                        ('installing', 80, 'Installing NixOS...'),
                        ('finalizing', 95, 'Finishing up...'),
                        ('complete', 100, 'Installation complete!'),
                    ]
                    for stage, progress, message in stages:
                        INSTALL_PROGRESS = {
                            'running': stage != 'complete',
                            'stage': stage,
                            'progress': progress,
                            'message': message,
                            'complete': stage == 'complete',
                            'error': None
                        }
                        time.sleep(2)
                
                thread = threading.Thread(target=simulate, daemon=True)
                thread.start()
            else:
                # Real installation - call the install script
                # Save install config
                install_cfg = {
                    'drive': drive,
                    'encrypt': encrypt,
                    'username': username,
                    'hostname': hostname,
                    'wifiSSID': wifi.get('ssid', ''),
                    'wifiPassword': wifi.get('password', '')
                }
                
                install_cfg_path = '/tmp/easyos-install-config.json'
                with open(install_cfg_path, 'w') as f:
                    json.dump(install_cfg, f)
                os.chmod(install_cfg_path, 0o600)
                
                # Hash and save password
                result = subprocess.run(
                    ['openssl', 'passwd', '-6', '-stdin'],
                    input=password, capture_output=True, text=True
                )
                if result.returncode == 0:
                    with open('/tmp/easyos-password-hash', 'w') as f:
                        f.write(result.stdout.strip())
                    os.chmod('/tmp/easyos-password-hash', 0o600)
                
                if encrypt and encryption_password:
                    with open('/tmp/easyos-encryption-password', 'w') as f:
                        f.write(encryption_password)
                    os.chmod('/tmp/easyos-encryption-password', 0o600)
                
                # Launch install script
                subprocess.Popen(
                    ['/etc/easy/webinstall.sh'],
                    stdout=open('/var/log/easyos-install.log', 'a'),
                    stderr=subprocess.STDOUT,
                    start_new_session=True
                )
            
            return {'success': True, 'started': True, 'installId': install_id}
        
        except Exception as e:
            return {'success': False, 'error': str(e)}


# =============================================================================
# MAIN
# =============================================================================

if __name__ == '__main__':
    print(f"╔═══════════════════════════════════════════════════════════════╗")
    print(f"║              easeOS Web UI Server                             ║")
    print(f"╠═══════════════════════════════════════════════════════════════╣")
    print(f"║  URL:      http://0.0.0.0:{PORT}/{'':>36}║")
    print(f"║  Mode:     {'Development' if IS_DEV else 'Production':<46}║")
    print(f"║  Config:   {CONFIG_FILE:<46}║")
    print(f"║  Store:    {STORE_DIR:<46}║")
    print(f"╚═══════════════════════════════════════════════════════════════╝")
    
    try:
        httpd = HTTPServer(('0.0.0.0', PORT), EasyOSHandler)
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
    except Exception as e:
        print(f"[ERROR] Server failed to start: {e}")
        sys.exit(1)
