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
    import json, os, sys, time, glob
    from http.server import HTTPServer, SimpleHTTPRequestHandler
    from urllib.parse import urlparse, parse_qs
    import subprocess

    ROOT = '/etc/easy/webui'
    MUTABLE_ROOT = '/var/lib/easyos/webui'
    CONFIG_PATH = '/etc/easy/config.json'
    LOG_PATH = '/var/log/easyos-apply.log'
    STORE_PATH = '/etc/easy/store/apps'

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
            
            if p == '/':
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

  config = lib.mkIf cfg.enable {
    # Use a tiny Python stdlib server for API + static; replace nginx placeholder
    services.nginx.enable = lib.mkForce false;

    # Required tools
    environment.systemPackages = [ pkgs.python3 ];

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

    # Web UI service
    systemd.services.easyos-webui = {
      description = "EASYOS Web UI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 /etc/easy/webui/server.py";
        Restart = "on-failure";
        WorkingDirectory = "/etc/easy/webui";
      };
    };

    # Open the portal port
    networking.firewall.allowedTCPPorts = lib.mkAfter [ 1234 ];
  };
}
