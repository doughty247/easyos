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
    import json, os, sys, time
    from http.server import HTTPServer, SimpleHTTPRequestHandler
    from urllib.parse import urlparse
    import subprocess

    ROOT = '/etc/easy/webui'
    CONFIG_PATH = '/etc/easy/config.json'
    LOG_PATH = '/var/log/easyos-apply.log'

    class Handler(SimpleHTTPRequestHandler):
        def _set_headers(self, code=200, ctype='application/json'):
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()

        def do_GET(self):
            p = urlparse(self.path).path
            if p == '/':
                self._set_headers(200, 'text/html; charset=utf-8')
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
            else:
                self.send_error(404)

    if __name__ == '__main__':
        os.chdir(ROOT)
        port = 8088
        httpd = HTTPServer(('0.0.0.0', port), Handler)
        print(f'EasyOS web UI listening on http://0.0.0.0:{port}/', flush=True)
        httpd.serve_forever()
  '';

  indexHtml = builtins.readFile ../webui/templates/index.html;
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
    networking.firewall.allowedTCPPorts = lib.mkAfter [ 8088 ];
  };
}
