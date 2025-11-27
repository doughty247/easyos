#!/usr/bin/env python3
"""
Local development server for easeOS webui.
Serves the UI and provides mock API endpoints.

Usage: python3 dev-server.py
Then open http://localhost:8089
"""

import json
import os
import glob
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORT = 8089
ROOT = os.path.dirname(os.path.abspath(__file__))
WEBUI_DIR = os.path.join(ROOT, 'webui', 'templates')
STORE_DIR = os.path.join(ROOT, 'store', 'apps')
CONFIG_FILE = os.path.join(ROOT, 'dev-config.json')

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
        
        if p == '/' or p == '/index.html':
            self._set_headers(200, 'text/html; charset=utf-8')
            with open(os.path.join(WEBUI_DIR, 'index.html'), 'rb') as f:
                self.wfile.write(f.read())
                
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
            self.wfile.write(json.dumps({
                'active': 'inactive',
                'log': '[DEV MODE] No actual system operations\n'
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
