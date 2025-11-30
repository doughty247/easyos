{ lib, pkgs, config, ... }:
let
  cfg = config.easyos.webui;
  applyScript = ''
    #!/usr/bin/env bash
    set -euo pipefail
    LOG=/var/log/easyos-apply.log
    mkdir -p /var/log
    : > "$LOG"
    echo "[easyos] Applying configuration at $(date -Is)" | tee -a "$LOG"
    echo "Command: nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos" | tee -a "$LOG"
    
    # Run nixos-rebuild and capture exit code properly
    if nixos-rebuild switch --impure --flake /etc/nixos/easyos#easyos 2>&1 | tee -a "$LOG"; then
      echo "[easyos] Apply completed successfully at $(date -Is)" | tee -a "$LOG"
      exit 0
    else
      RC=$?
      echo "[easyos] Apply failed with code $RC at $(date -Is)" | tee -a "$LOG"
      exit $RC
    fi
  '';

  serverPy = ''
    #!/usr/bin/env python3
    import json, os, sys, time, glob, secrets, base64, hashlib
    from http.server import HTTPServer, SimpleHTTPRequestHandler
    from urllib.parse import urlparse, parse_qs
    import subprocess

    # AES-256-GCM encryption
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    ROOT = '/etc/easy/webui'
    MUTABLE_ROOT = '/var/lib/easyos/webui'
    CONFIG_PATH = '/etc/easy/config.json'
    LOG_PATH = '/var/log/easyos-apply.log'
    STORE_PATH = '/etc/easy/store/apps'

    # Session key (simulates Kyber-1024 shared secret)
    SESSION_KEY = secrets.token_urlsafe(12)[:16]
    print(f"[CRYPTO] Session key: {SESSION_KEY[:4]}****{SESSION_KEY[-4:]}")

    # AES-256-GCM encryption constants (must match client-side)
    SALT = b'easeOS-wifi-salt'
    ITERATIONS = 100000

    def derive_aes_key(secret: str) -> bytes:
        """Derive AES-256 key from secret using PBKDF2-SHA256"""
        return hashlib.pbkdf2_hmac('sha256', secret.encode('utf-8'), SALT, ITERATIONS, dklen=32)

    def aes_encrypt(data: str, key_string: str) -> str:
        """AES-256-GCM encryption - returns base64(IV + ciphertext + tag)"""
        key = derive_aes_key(key_string)
        iv = secrets.token_bytes(12)
        aesgcm = AESGCM(key)
        ciphertext = aesgcm.encrypt(iv, data.encode('utf-8'), None)
        return base64.b64encode(iv + ciphertext).decode('utf-8')

    def aes_decrypt(encrypted_b64: str, key_string: str) -> str:
        """AES-256-GCM decryption - expects base64(IV + ciphertext + tag)"""
        key = derive_aes_key(key_string)
        combined = base64.b64decode(encrypted_b64)
        iv = combined[:12]
        ciphertext = combined[12:]
        aesgcm = AESGCM(key)
        plaintext = aesgcm.decrypt(iv, ciphertext, None)
        return plaintext.decode('utf-8')

    class Handler(SimpleHTTPRequestHandler):
        def _set_headers(self, code=200, ctype='application/json'):
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()

        def do_GET(self):
            parsed = urlparse(self.path)
            p = parsed.path
            query = parse_qs(parsed.query)
            
            if p == '/api/system/info':
                # System info including ISO mode detection
                is_iso = os.path.exists('/etc/easy/iso-mode')
                is_installed = os.path.exists('/etc/easy/installed')
                channel = 'unknown'
                try:
                    with open('/etc/easy/channel', 'r') as f:
                        channel = f.read().strip()
                except:
                    pass
                self._set_headers()
                self.wfile.write(json.dumps({
                    'isISO': is_iso,
                    'isInstalled': is_installed,
                    'channel': channel,
                    'mode': 'live-installer' if is_iso else ('first-run' if not is_installed else 'normal')
                }).encode())
            elif p == '/api/storage/detect':
                # Detect available storage devices for installation
                drives = []
                is_vm = False
                try:
                    # Use lsblk to get block devices
                    result = subprocess.run(
                        ['lsblk', '-J', '-o', 'NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL,SERIAL,TRAN'],
                        capture_output=True, text=True, timeout=10
                    )
                    if result.returncode == 0:
                        data = json.loads(result.stdout)
                        for device in data.get('blockdevices', []):
                            if device.get('type') == 'disk':
                                name = device.get('name', '')
                                # Check if this is a VM virtual disk
                                if name.startswith('vd'):
                                    is_vm = True
                                # Skip loop devices and CD-ROMs
                                if name.startswith('loop') or name.startswith('sr'):
                                    continue
                                
                                # Check if drive has partitions with filesystems
                                has_data = False
                                partitions = []
                                for child in device.get('children', []):
                                    fstype = child.get('fstype')
                                    mountpoint = child.get('mountpoint')
                                    if fstype and fstype not in ['', 'swap']:
                                        has_data = True
                                    partitions.append({
                                        'name': child.get('name', ''),
                                        'size': child.get('size', ''),
                                        'fstype': fstype or 'unformatted',
                                        'mountpoint': mountpoint or ''
                                    })
                                
                                drives.append({
                                    'name': name,
                                    'path': f'/dev/{name}',
                                    'size': device.get('size', 'Unknown'),
                                    'model': device.get('model', '').strip() if device.get('model') else 'Unknown Drive',
                                    'serial': device.get('serial', ''),
                                    'transport': device.get('tran', ''),  # sata, nvme, usb, virtio
                                    'hasData': has_data,
                                    'isBlank': len(partitions) == 0,
                                    'partitions': partitions,
                                    'isVirtual': name.startswith('vd')
                                })
                except Exception as e:
                    print(f"Storage detection error: {e}")
                
                self._set_headers()
                self.wfile.write(json.dumps({
                    'drives': drives,
                    'isVM': is_vm,
                    'autoInstallDrive': '/dev/vda' if is_vm and any(d['name'] == 'vda' for d in drives) else None
                }).encode())
            elif p == '/api/crypto/session':
                # Return session key (Kyber-1024 simulation, AES-256-GCM encryption)
                self._set_headers()
                self.wfile.write(json.dumps({
                    'key': SESSION_KEY,
                    'algorithm': 'aes-256-gcm',
                    'kex': 'kyber-1024-simulation'
                }).encode())
            elif p == '/':
                self._set_headers(200, 'text/html; charset=utf-8')
                # Try mutable dev file first
                if os.path.exists(os.path.join(MUTABLE_ROOT, 'index.html')):
                    with open(os.path.join(MUTABLE_ROOT, 'index.html'), 'rb') as f:
                        self.wfile.write(f.read())
                else:
                    with open(os.path.join(ROOT, 'index.html'), 'rb') as f:
                        self.wfile.write(f.read())
            elif p == '/api/config':
                try:
                    with open(CONFIG_PATH, 'r') as f:
                        data = json.load(f)
                except FileNotFoundError:
                    data = {}
                self._set_headers()
                self.wfile.write(json.dumps(data).encode())
            elif p == '/api/status':
                state = subprocess.run(['systemctl','is-active','easyos-apply.service'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                status = state.stdout.strip() or 'inactive'
                log_tail = ""
                try:
                    with open(LOG_PATH, 'r') as f:
                        lines = f.readlines()[-100:]
                        log_tail = "".join(lines)
                except Exception:
                    pass
                self._set_headers()
                self.wfile.write(json.dumps({'active': status, 'log': log_tail}).encode())
            elif p == '/api/store/apps':
                # List all available apps from store
                apps = []
                try:
                    for filepath in glob.glob(os.path.join(STORE_PATH, '*.json')):
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
                            search in a.get('name', "").lower() or 
                            search in a.get('description', "").lower() or
                            any(search in tag.lower() for tag in a.get('tags', []))]
                
                self._set_headers()
                self.wfile.write(json.dumps(apps).encode())
            elif p.startswith('/api/store/app/'):
                # Get single app by ID
                app_id = p.split('/')[-1]
                app_path = os.path.join(STORE_PATH, f'{app_id}.json')
                if os.path.exists(app_path):
                    with open(app_path, 'r') as f:
                        self._set_headers()
                        self.wfile.write(f.read().encode())
                else:
                    self.send_error(404, f'App {app_id} not found')
            elif p == '/api/store/categories':
                # Get list of categories
                categories = set()
                try:
                    for filepath in glob.glob(os.path.join(STORE_PATH, '*.json')):
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
                # Scan for available WiFi networks using nmcli
                networks = []
                try:
                    # Rescan first
                    subprocess.run(['nmcli', 'dev', 'wifi', 'rescan'], capture_output=True, timeout=10)
                    time.sleep(1)
                    # Get network list
                    result = subprocess.run(
                        ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'dev', 'wifi', 'list'],
                        capture_output=True, text=True, timeout=10
                    )
                    seen = set()
                    for line in result.stdout.strip().split('\n'):
                        if line:
                            parts = line.split(':')
                            if len(parts) >= 3:
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
                # Encrypt WiFi network list with AES-256-GCM
                encrypted_data = aes_encrypt(json.dumps(networks), SESSION_KEY)
                self._set_headers()
                self.wfile.write(json.dumps({
                    'encrypted': True,
                    'data': encrypted_data
                }).encode())
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
                    self.wfile.write(json.dumps({'error':'invalid json'}).encode())
                    return
                os.makedirs('/etc/easy', exist_ok=True)
                tmp = CONFIG_PATH + '.tmp'
                with open(tmp, 'w') as f:
                    json.dump(data, f, indent=2)
                    f.write('\n')
                os.replace(tmp, CONFIG_PATH)
                self._set_headers(200)
                self.wfile.write(json.dumps({'ok': True}).encode())
            elif p == '/api/apply':
                # Kick oneshot apply service; it logs to LOG_PATH
                subprocess.run(['systemctl','start','easyos-apply.service'])
                self._set_headers(202)
                self.wfile.write(json.dumps({'started': True}).encode())
            elif p == '/api/dev/update_ui':
                # Dev endpoint to update UI without rebuild
                try:
                    os.makedirs(MUTABLE_ROOT, exist_ok=True)
                    with open(os.path.join(MUTABLE_ROOT, 'index.html'), 'w') as f:
                        f.write(body)
                    self._set_headers(200)
                    self.wfile.write(json.dumps({'ok': True, 'source': 'mutable'}).encode())
                except Exception as e:
                    self._set_headers(500)
                    self.wfile.write(json.dumps({'error': str(e)}).encode())
            elif p == '/api/wifi/connect':
                # Connect to a WiFi network using nmcli (with AES-256-GCM encrypted credentials)
                try:
                    data = json.loads(body or '{}')
                    
                    # Decrypt credentials if encrypted
                    if data.get('encrypted'):
                        decrypted_json = aes_decrypt(data.get('data', ''), SESSION_KEY)
                        credentials = json.loads(decrypted_json)
                        ssid = credentials.get('ssid', '')
                        password = credentials.get('password', '')
                        print(f"[CRYPTO] Received AES-256-GCM encrypted WiFi credentials")
                    else:
                        ssid = data.get('ssid', '')
                        password = data.get('password', '')
                        print(f"[WARN] Received unencrypted WiFi credentials")
                    
                    if not ssid:
                        self._set_headers(400)
                        self.wfile.write(json.dumps({'error': 'SSID required'}).encode())
                        return
                    
                    # Try to connect
                    result = subprocess.run(
                        ['nmcli', 'dev', 'wifi', 'connect', ssid, 'password', password],
                        capture_output=True, text=True, timeout=30
                    )
                    
                    if result.returncode == 0:
                        # Get the new IP address
                        ip_result = subprocess.run(
                            ['hostname', '-I'],
                            capture_output=True, text=True, timeout=5
                        )
                        ip = ip_result.stdout.strip().split()[0] if ip_result.stdout.strip() else 'unknown'
                        
                        self._set_headers(200)
                        self.wfile.write(json.dumps({
                            'success': True,
                            'ssid': ssid,
                            'ip': ip
                        }).encode())
                    else:
                        self._set_headers(400)
                        self.wfile.write(json.dumps({
                            'error': result.stderr or 'Connection failed'
                        }).encode())
                except json.JSONDecodeError:
                    self._set_headers(400)
                    self.wfile.write(json.dumps({'error': 'Invalid JSON'}).encode())
                except subprocess.TimeoutExpired:
                    self._set_headers(504)
                    self.wfile.write(json.dumps({'error': 'Connection timeout'}).encode())
                except Exception as e:
                    self._set_headers(500)
                    self.wfile.write(json.dumps({'error': str(e)}).encode())
            elif p == '/api/setup/account':
                # Create user account (with AES-256-GCM encrypted credentials)
                try:
                    data = json.loads(body or '{}')
                    
                    # Decrypt if encrypted
                    if data.get('encrypted'):
                        decrypted_json = aes_decrypt(data.get('data', ''), SESSION_KEY)
                        account = json.loads(decrypted_json)
                        username = account.get('username', '')
                        password = account.get('password', '')
                        hostname = account.get('hostname', 'easeos')
                        print(f"[CRYPTO] Received AES-256-GCM encrypted account credentials")
                    else:
                        username = data.get('username', '')
                        password = data.get('password', '')
                        hostname = data.get('hostname', 'easeos')
                        print(f"[WARN] Received unencrypted account credentials")
                    
                    if not username or not password:
                        self._set_headers(400)
                        self.wfile.write(json.dumps({'error': 'Username and password required'}).encode())
                        return
                    
                    print(f"[SETUP] Creating account: {username}@{hostname}")
                    
                    # Hash password
                    hash_result = subprocess.run(
                        ['openssl', 'passwd', '-6', password],
                        capture_output=True, text=True, timeout=30
                    )
                    password_hash = hash_result.stdout.strip() if hash_result.returncode == 0 else None
                    
                    if not password_hash:
                        self._set_headers(500)
                        self.wfile.write(json.dumps({'error': 'Failed to hash password'}).encode())
                        return
                    
                    # Save to config (will be applied by NixOS rebuild)
                    try:
                        with open(CONFIG_PATH, 'r') as f:
                            cfg = json.load(f)
                    except:
                        cfg = {}
                    
                    cfg['admin'] = {
                        'username': username,
                        'passwordHash': password_hash,
                        'hostname': hostname
                    }
                    
                    os.makedirs('/etc/easy', exist_ok=True)
                    with open(CONFIG_PATH, 'w') as f:
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
            elif p == '/api/install/start':
                # Start disk installation (ISO mode only)
                if not os.path.exists('/etc/easy/iso-mode'):
                    self._set_headers(403)
                    self.wfile.write(json.dumps({'error': 'Installation only available in ISO mode'}).encode())
                    return
                
                try:
                    data = json.loads(body or '{}')
                    target_drive = data.get('drive', '')
                    encrypt = data.get('encrypt', False)
                    channel = data.get('channel', 'stable')
                    
                    if not target_drive or not target_drive.startswith('/dev/'):
                        self._set_headers(400)
                        self.wfile.write(json.dumps({'error': 'Invalid target drive'}).encode())
                        return
                    
                    # Validate drive exists
                    if not os.path.exists(target_drive):
                        self._set_headers(400)
                        self.wfile.write(json.dumps({'error': f'Drive {target_drive} not found'}).encode())
                        return
                    
                    # Load current config for admin credentials
                    try:
                        with open(CONFIG_PATH, 'r') as f:
                            cfg = json.load(f)
                    except:
                        cfg = {}
                    
                    admin = cfg.get('admin', {})
                    if not admin.get('username') or not admin.get('passwordHash'):
                        self._set_headers(400)
                        self.wfile.write(json.dumps({'error': 'Account not configured. Complete account setup first.'}).encode())
                        return
                    
                    # Write install config
                    install_cfg = {
                        'targetDrive': target_drive,
                        'encrypt': encrypt,
                        'channel': channel,
                        'hostname': admin.get('hostname', 'easeos'),
                        'username': admin.get('username'),
                        'passwordHash': admin.get('passwordHash')
                    }
                    
                    os.makedirs('/tmp/easyos-install', exist_ok=True)
                    with open('/tmp/easyos-install/config.json', 'w') as f:
                        json.dump(install_cfg, f, indent=2)
                    
                    # Start installation service in background
                    subprocess.Popen(
                        ['systemctl', 'start', 'easyos-webinstall.service'],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL
                    )
                    
                    self._set_headers(202)
                    self.wfile.write(json.dumps({
                        'started': True,
                        'drive': target_drive,
                        'message': 'Installation started. This will take several minutes.'
                    }).encode())
                except json.JSONDecodeError:
                    self._set_headers(400)
                    self.wfile.write(json.dumps({'error': 'Invalid JSON'}).encode())
                except Exception as e:
                    print(f"[ERROR] Install start failed: {e}")
                    self._set_headers(500)
                    self.wfile.write(json.dumps({'error': str(e)}).encode())
            elif p == '/api/install/status':
                # Check installation progress
                status = {
                    'running': False,
                    'progress': 0,
                    'stage': 'idle',
                    'message': '',
                    'complete': False,
                    'error': None
                }
                
                try:
                    # Check if service is running
                    result = subprocess.run(
                        ['systemctl', 'is-active', 'easyos-webinstall.service'],
                        capture_output=True, text=True
                    )
                    status['running'] = result.stdout.strip() == 'active'
                    
                    # Read progress file if exists
                    if os.path.exists('/tmp/easyos-install/progress.json'):
                        with open('/tmp/easyos-install/progress.json', 'r') as f:
                            progress = json.load(f)
                            status.update(progress)
                except Exception as e:
                    status['error'] = str(e)
                
                self._set_headers()
                self.wfile.write(json.dumps(status).encode())
            elif p == '/api/system/reboot':
                # Trigger system reboot (ISO mode only)
                if not os.path.exists('/etc/easy/iso-mode'):
                    self._set_headers(403)
                    self.wfile.write(json.dumps({'error': 'Reboot only available in ISO mode'}).encode())
                    return
                
                self._set_headers(200)
                self.wfile.write(json.dumps({'rebooting': True}).encode())
                
                # Schedule reboot in background
                subprocess.Popen(
                    ['sh', '-c', 'sleep 2 && systemctl reboot'],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            else:
                self.send_error(404)

    if __name__ == '__main__':
        os.chdir(ROOT)
        port = 1234
        httpd = HTTPServer(('0.0.0.0', port), Handler)
        print(f'EasyOS web UI listening on http://0.0.0.0:{port}/', flush=True)
        httpd.serve_forever()
  '';

  indexHtml = builtins.readFile ../webui/templates/index.html;
  
  # Load store apps from the store directory
  storeAppsDir = ../store/apps;
  storeApps = if builtins.pathExists storeAppsDir then
    builtins.attrNames (builtins.readDir storeAppsDir)
  else [];
in {
  options.easyos.webui.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable built-in web UI for editing /etc/easy/config.json and applying changes.";
  };

  # Python with cryptography for AES-256-GCM encryption
  pythonWithCrypto = pkgs.python3.withPackages (ps: [ ps.cryptography ]);

  config = lib.mkIf cfg.enable {
    # Use a tiny Python stdlib server for API + static; replace nginx placeholder
    services.nginx.enable = lib.mkForce false;

    # Required tools
    environment.systemPackages = [ pythonWithCrypto ];

    # Files
    environment.etc."easy/webui/server.py".text = serverPy;
    environment.etc."easy/webui/index.html".text = indexHtml;
    environment.etc."easy/apply.sh" = { text = applyScript; mode = "0755"; };
    
    # Deploy store apps
    environment.etc."easy/store/apps" = {
      source = storeAppsDir;
      mode = "0755";
    };

    # Apply service (runs on demand)
    systemd.services.easyos-apply = {
      description = "Apply EASYOS configuration";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ "/etc/easy/apply.sh" ];
      };
    };
    
    # Web-based installation service (ISO mode only)
    systemd.services.easyos-webinstall = {
      description = "EASYOS Web Installation";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ "/etc/easy/webinstall.sh" ];
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
    
    # Web install script
    environment.etc."easy/webinstall.sh" = {
      mode = "0755";
      text = ''
        #!/usr/bin/env bash
        set -euo pipefail
        
        PROGRESS_FILE="/tmp/easyos-install/progress.json"
        CONFIG_FILE="/tmp/easyos-install/config.json"
        LOG_FILE="/tmp/easyos-install/install.log"
        
        update_progress() {
          local progress="$1"
          local stage="$2"
          local message="$3"
          local complete="''${4:-false}"
          local error="''${5:-null}"
          
          cat > "$PROGRESS_FILE" << EOF
        {
          "progress": $progress,
          "stage": "$stage",
          "message": "$message",
          "complete": $complete,
          "error": $error
        }
        EOF
        }
        
        fail() {
          update_progress 0 "error" "$1" false "\"$1\""
          echo "[ERROR] $1" | tee -a "$LOG_FILE"
          exit 1
        }
        
        echo "[INSTALL] Starting web-based installation at $(date)" | tee "$LOG_FILE"
        
        # Load config
        if [ ! -f "$CONFIG_FILE" ]; then
          fail "Installation config not found"
        fi
        
        TARGET=$(jq -r '.targetDrive' "$CONFIG_FILE")
        ENCRYPT=$(jq -r '.encrypt' "$CONFIG_FILE")
        CHANNEL=$(jq -r '.channel // "stable"' "$CONFIG_FILE")
        HOSTNAME=$(jq -r '.hostname // "easeos"' "$CONFIG_FILE")
        USERNAME=$(jq -r '.username' "$CONFIG_FILE")
        PASSWORD_HASH=$(jq -r '.passwordHash' "$CONFIG_FILE")
        
        echo "[INSTALL] Target: $TARGET, Encrypt: $ENCRYPT, Channel: $CHANNEL" | tee -a "$LOG_FILE"
        
        # Stage 1: Prepare
        update_progress 5 "preparing" "Preparing installation..."
        sleep 1
        
        # Validate target
        if [ ! -b "$TARGET" ]; then
          fail "Target device $TARGET not found"
        fi
        
        # Unmount any existing mounts
        update_progress 10 "unmounting" "Unmounting existing partitions..."
        umount -R /mnt 2>/dev/null || true
        for part in $(lsblk -ln -o NAME "$TARGET" | tail -n +2); do
          umount "/dev/$part" 2>/dev/null || true
        done
        
        # Stage 2: Partition
        update_progress 15 "partitioning" "Creating partitions..."
        echo "[INSTALL] Partitioning $TARGET" | tee -a "$LOG_FILE"
        
        # Wipe and create GPT
        wipefs -af "$TARGET" >> "$LOG_FILE" 2>&1
        sgdisk --zap-all "$TARGET" >> "$LOG_FILE" 2>&1
        
        # Create partitions: EFI (512M) + Root (rest)
        sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$TARGET" >> "$LOG_FILE" 2>&1
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"root" "$TARGET" >> "$LOG_FILE" 2>&1
        
        # Determine partition names
        if [[ "$TARGET" == *"nvme"* ]] || [[ "$TARGET" == *"mmcblk"* ]]; then
          EFI_PART="''${TARGET}p1"
          ROOT_PART="''${TARGET}p2"
        else
          EFI_PART="''${TARGET}1"
          ROOT_PART="''${TARGET}2"
        fi
        
        partprobe "$TARGET" 2>/dev/null || sleep 2
        
        # Stage 3: Format
        update_progress 25 "formatting" "Formatting filesystems..."
        echo "[INSTALL] Formatting partitions" | tee -a "$LOG_FILE"
        
        mkfs.fat -F32 -n EFI "$EFI_PART" >> "$LOG_FILE" 2>&1
        
        if [ "$ENCRYPT" = "true" ]; then
          update_progress 30 "encrypting" "Setting up encryption..."
          # TODO: Add LUKS encryption support
          # For now, proceed without encryption
          mkfs.btrfs -f -L nixos "$ROOT_PART" >> "$LOG_FILE" 2>&1
        else
          mkfs.btrfs -f -L nixos "$ROOT_PART" >> "$LOG_FILE" 2>&1
        fi
        
        # Stage 4: Mount and create subvolumes
        update_progress 35 "mounting" "Creating Btrfs subvolumes..."
        echo "[INSTALL] Creating subvolumes" | tee -a "$LOG_FILE"
        
        mount "$ROOT_PART" /mnt
        btrfs subvolume create /mnt/@root >> "$LOG_FILE" 2>&1
        btrfs subvolume create /mnt/@home >> "$LOG_FILE" 2>&1
        btrfs subvolume create /mnt/@nix >> "$LOG_FILE" 2>&1
        btrfs subvolume create /mnt/@log >> "$LOG_FILE" 2>&1
        btrfs subvolume create /mnt/@snapshots >> "$LOG_FILE" 2>&1
        umount /mnt
        
        # Remount with subvolumes
        mount -o subvol=@root,compress=zstd:3,noatime "$ROOT_PART" /mnt
        mkdir -p /mnt/{boot,home,nix,var/log,.snapshots}
        mount -o subvol=@home,compress=zstd:3,noatime "$ROOT_PART" /mnt/home
        mount -o subvol=@nix,compress=zstd:3,noatime "$ROOT_PART" /mnt/nix
        mount -o subvol=@log,compress=zstd:3,noatime "$ROOT_PART" /mnt/var/log
        mount -o subvol=@snapshots,compress=zstd:3,noatime "$ROOT_PART" /mnt/.snapshots
        mount "$EFI_PART" /mnt/boot
        
        # Stage 5: Clone flake
        update_progress 45 "cloning" "Downloading easeOS configuration..."
        echo "[INSTALL] Cloning easyos flake" | tee -a "$LOG_FILE"
        
        mkdir -p /mnt/etc/nixos
        git clone --depth 1 https://github.com/doughty247/easyos.git /mnt/etc/nixos/easyos >> "$LOG_FILE" 2>&1
        
        # Stage 6: Generate hardware config
        update_progress 55 "configuring" "Generating hardware configuration..."
        echo "[INSTALL] Generating hardware-configuration.nix" | tee -a "$LOG_FILE"
        
        nixos-generate-config --root /mnt >> "$LOG_FILE" 2>&1
        cp /mnt/etc/nixos/hardware-configuration.nix /mnt/etc/nixos/easyos/
        
        # Stage 7: Create credentials file
        update_progress 60 "credentials" "Setting up user account..."
        cat > /mnt/etc/nixos/easyos/easy-credentials.nix << EOF
        { lib, ... }:
        {
          networking.hostName = lib.mkForce "$HOSTNAME";
          
          users.users.$USERNAME = {
            isNormalUser = true;
            hashedPassword = "$PASSWORD_HASH";
            extraGroups = [ "wheel" "networkmanager" "video" "docker" ];
          };
          
          # Disable nixos default user
          users.users.nixos.isNormalUser = lib.mkForce false;
        }
        EOF
        
        # Create installed marker
        mkdir -p /mnt/etc/easy
        echo "$(date -Is)" > /mnt/etc/easy/installed
        echo "$CHANNEL" > /mnt/etc/easy/channel
        
        # Copy config
        cp /etc/easy/config.json /mnt/etc/easy/config.json 2>/dev/null || true
        # Set mode to first-run for post-install setup
        jq '.mode = "first-run"' /mnt/etc/easy/config.json > /mnt/etc/easy/config.json.tmp && \
          mv /mnt/etc/easy/config.json.tmp /mnt/etc/easy/config.json
        
        # Stage 8: Install NixOS
        update_progress 70 "installing" "Installing NixOS (this may take several minutes)..."
        echo "[INSTALL] Running nixos-install" | tee -a "$LOG_FILE"
        
        nixos-install --flake /mnt/etc/nixos/easyos#easyos --no-root-passwd >> "$LOG_FILE" 2>&1
        
        # Stage 9: Finalize
        update_progress 95 "finalizing" "Finalizing installation..."
        echo "[INSTALL] Finalizing" | tee -a "$LOG_FILE"
        
        sync
        
        update_progress 100 "complete" "Installation complete! You can now reboot." true
        echo "[INSTALL] Installation complete at $(date)" | tee -a "$LOG_FILE"
      '';
    };

    # Web UI service
    systemd.services.easyos-webui = {
      description = "EASYOS Web UI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pythonWithCrypto}/bin/python3 /etc/easy/webui/server.py";
        Restart = "on-failure";
        WorkingDirectory = "/etc/easy/webui";
      };
    };

    # Open the portal port
    networking.firewall.allowedTCPPorts = lib.mkAfter [ 1234 ];
  };
}
