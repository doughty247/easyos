#!/usr/bin/env python3
"""
easeOS Development Server - Wrapper

This script is a convenience wrapper for backwards compatibility.
The actual server is now in webui/server.py and works in both dev and production.

Usage: python3 dev-server.py
  or:  python3 webui/server.py
"""
import os
import sys

# Get the directory containing this script
script_dir = os.path.dirname(os.path.abspath(__file__))
server_path = os.path.join(script_dir, 'webui', 'server.py')

if os.path.exists(server_path):
    # Execute the unified server
    exec(open(server_path).read())
else:
    print(f"Error: Server not found at {server_path}")
    sys.exit(1)
