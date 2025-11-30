# easeOS Project Reference

> A comprehensive handoff document for continuing development on easeOS

**Last Updated:** 30 November 2025  
**Project Status:** Setup wizard with strong password validation, mobile UI polish ongoing  
**Primary Mascot:** Cooper (cute Haworthia succulent in terracotta pot)

---

## Table of Contents

1. [User Preferences & Style Guide](#user-preferences--style-guide)
2. [Project Overview](#project-overview)
3. [Architecture](#architecture)
4. [File Structure](#file-structure)
5. [UI Split: Setup vs Main](#ui-split-setup-vs-main)
6. [Setup Wizard](#setup-wizard)
7. [Password Security](#password-security)
8. [Mobile UI Issues & Fixes](#mobile-ui-issues--fixes)
9. [UI Theming System](#ui-theming-system)
10. [Encryption & Security](#encryption--security)
11. [Dev Server API](#dev-server-api)
12. [NixOS Modules](#nixos-modules)
13. [App Store System](#app-store-system)
14. [Known Issues & TODO](#known-issues--todo)
15. [Development Workflow](#development-workflow)

---

## User Preferences & Style Guide

### ⚠️ CRITICAL: Read This First

The project owner has specific preferences that MUST be followed:

#### No Emojis (Except Specific Exceptions)
- **NEVER use emojis** in the UI text, labels, or descriptions
- **Exceptions allowed:** ✓ (checkmark), ✗ (x mark), ○ (circle) for validation indicators
- Remove any existing emojis found in the codebase
- This applies to: setup.html, index.html, all user-facing text

#### Simplicity Over Options
- **Remove confusing technical options** from user-facing UI
- Example: "Root password" was removed - users don't understand it, just use the same password internally
- Don't expose NixOS internals to end users
- Garden metaphors should be user-friendly, not technically accurate

#### Password UX Preferences
- Password hints should **only appear when the user is typing** (not always visible)
- Use live validation with checkmarks as they type
- **Paste prevention on confirm password field** (`@paste.prevent`)
- Show "Passwords match" confirmation when both fields match

#### UI Design Philosophy
- Garden theme ("Garden User Interface" / GUI pun)
- Friendly, approachable, NOT technical
- Cooper the mascot should feel alive and friendly
- Prefer visual feedback over text explanations

---

## Project Overview

### Philosophy
easeOS is a **"home server you can set and forget"** - built on NixOS 24.11 for declarative, reproducible configuration. The UI follows a "GUI" (Garden Uder Interface) design philosophy - friendly, approachable, and garden-themed.

### Core Principles
- **Simplicity First**: Single-user system, no RBAC complexity
- **Garden Metaphor**: Users are "gardeners", setup is "planting", apps are "seeds"
- **Defensive UX**: Prevent accidental changes, require confirmation for destructive actions
- **Works Offline**: Core functionality shouldn't require internet

### Tech Stack
| Component | Technology |
|-----------|------------|
| OS | NixOS 24.11 |
| UI Framework | Alpine.js 3.x + Tailwind CSS (CDN) |
| Dev Server | Python 3 (http.server) |
| Encryption | AES-256-GCM with PBKDF2 |
| Font | Nunito (Google Fonts) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Browser UI                            │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           Routing based on config.mode               │   │
│  │                                                       │   │
│  │  ┌─────────────────┐     ┌──────────────────────┐    │   │
│  │  │   setup.html    │     │     index.html       │    │   │
│  │  │  (~900 lines)   │     │    (~3660 lines)     │    │   │
│  │  │                 │     │                      │    │   │
│  │  │  Setup Wizard   │     │  Dashboard + Apps    │    │   │
│  │  │  7 Steps        │     │  Main UI             │    │   │
│  │  └─────────────────┘     └──────────────────────┘    │   │
│  │         ↓                       ↓                     │   │
│  │                  Alpine.js State                      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    dev-server.py (Port 8089)                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  / (root)         → Routes to setup.html OR          │   │
│  │                     index.html based on config.mode  │   │
│  │  /api/status      → System status, mode detection    │   │
│  │  /api/config      → GET/POST configuration           │   │
│  │  /api/storage/detect → Detect storage devices        │   │
│  │  /api/wifi/scan   → WiFi network discovery           │   │
│  │  /api/wifi/connect→ Connect to selected network      │   │
│  │  /api/crypto/session → Get AES session key           │   │
│  │  /api/setup/account  → Create user account           │   │
│  │  /api/store/apps  → App store catalog                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      NixOS System                           │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  modules/easyos.nix    → Core system config          │   │
│  │  modules/apps.nix      → App definitions             │   │
│  │  modules/webui.nix     → Web UI service              │   │
│  │  modules/hotspot.nix   → Captive portal hotspot      │   │
│  │  modules/backup.nix    → Backup system               │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## File Structure

### Key Files

```
easyos/
├── dev-server.py          # Development server (~450+ lines)
├── dev-config.json        # Dev config (mode: "first-run" for setup wizard)
│
├── webui/
│   └── templates/
│       ├── setup.html     # Setup wizard (~900 lines, NEW SEPARATE FILE)
│       └── index.html     # Main UI (~3660 lines, dashboard only)
│
├── modules/
│   ├── easyos.nix         # Core module
│   ├── apps.nix           # App management
│   ├── webui.nix          # Web UI systemd service
│   ├── hotspot.nix        # WiFi hotspot/captive portal
│   ├── backup.nix         # Backup configuration
│   ├── network-autodiscovery.nix
│   ├── network-performance.nix
│   └── storage-expansion.nix
│
├── store/
│   ├── SDK.md             # App development guide
│   └── apps/              # App definitions (JSON)
│       ├── homeassistant.json
│       ├── immich.json
│       ├── jellyfin.json
│       ├── nextcloud.json
│       └── vaultwarden.json
│
└── etc/easy/
    └── config.example.json
```

---

## UI Split: Setup vs Main

### Why Split?

The setup wizard was originally embedded in `index.html` (~3481 lines total). It was split into a separate `setup.html` file for:

1. **Cleaner separation** - Setup logic doesn't pollute main dashboard
2. **Easier maintenance** - Each file has single responsibility  
3. **Better testing** - Can test setup flow independently
4. **Performance** - Users don't load setup code after initial configuration

### Routing Logic (dev-server.py)

```python
# In dev-server.py do_GET method (~line 120-145)
def do_GET(self):
    if self.path == '/' or self.path == '/index.html':
        # Route based on config mode
        config = load_config()
        mode = config.get('mode', 'normal')
        
        if mode == 'first-run':
            template_file = 'setup.html'
        else:
            template_file = 'index.html'
        
        self.serve_template(template_file)
```

### Current State

| File | Purpose | Lines | Status |
|------|---------|-------|--------|
| `setup.html` | 7-step setup wizard | ~900 | ✅ Created, needs mobile polish |
| `index.html` | Main dashboard | ~3660 | ✅ Working, needs mobile fixes |

### Switching Between Modes

Edit `dev-config.json`:

```json
// For setup wizard:
{ "mode": "first-run" }

// For main dashboard:
{ "mode": "normal" }
```

---

## Setup Wizard

### Flow Diagram (Now includes Storage step)

```
┌─────────┐    ┌─────────┐    ┌──────────┐    ┌─────────┐    ┌───────────┐    ┌───────────┐    ┌─────────┐
│  wake   │ →  │ account │ →  │ password │ →  │ storage │ →  │   soil    │ →  │ germinate │ →  │  alive  │
│         │    │         │    │          │    │         │    │  (WiFi)   │    │           │    │         │
│ "Hello" │    │ Name +  │    │ Password │    │ Drive   │    │  Network  │    │ Progress  │    │ Success │
│         │    │ Username│    │ Confirm  │    │ Select  │    │  Select   │    │ Bar       │    │         │
└─────────┘    └─────────┘    └──────────┘    └─────────┘    └───────────┘    └───────────┘    └─────────┘
     │              │              │               │              │                │               │
   Step 1        Step 2         Step 3          Step 4        Step 5           Step 6          Complete
```

### Storage Detection

Added in current session - handles storage device selection:

```javascript
// Storage state variables (in setup.html)
storageDevices: [],          // Array of detected drives
storageLoading: true,        // True while scanning
selectedDrive: null,         // User's selected drive path
storageError: false,         // True if no drives found
confirmDataLoss: false,      // Checkbox for data loss warning

// API endpoint
GET /api/storage/detect → { drives: [...] }
```

**Error Handling:**
When no drives are detected, shows error UI with:
- Red alert icon
- "No drives detected" message
- Retry button that calls `scanStorageDevices()`

**Mock API (dev-server.py):**
```python
# Currently returns empty array to simulate no-drives scenario
@route('/api/storage/detect')
def detect_storage():
    return { "drives": [] }
```

### State Variables

```javascript
// In Alpine.js x-data
setupMode: false,           // true when in setup wizard
setupStep: 'wake',          // Current step: 'wake'|'account'|'password'|'storage'|'soil'|'germinate'|'alive'
testMode: false,            // true when running on dev server (port 8089)

// Account creation
setupUsername: '',
setupPassword: '',
setupPasswordConfirm: '',
setupHostname: '',
setupAccountError: null,
setupUsernameError: null,

// Storage detection
storageDevices: [],
storageLoading: true,
selectedDrive: null,
storageError: false,
confirmDataLoss: false,

// WiFi
wifiNetworks: [],
wifiScanning: false,
selectedNetwork: null,
wifiPassword: '',
showAllNetworks: false,

// Germination progress
germinationProgress: 0,     // 0-100
germinationStatus: '',      // "Rooting...", "Germinating...", etc.
germinationDetail: '',      // Detailed status message
germinationError: null,     // Error message if failed
encryptionKey: null,        // Session key from server
```

### Validation Rules

| Field | Rules |
|-------|-------|
| Username | Min 3 chars, must start with letter, only `[a-z0-9_-]` |
| Password | 8+ chars, 1 uppercase, 1 number, 1 symbol, no spaces |
| WiFi Password | Min 8 characters (standard WPA2 requirement) |
| Hostname | Defaults to "easeos" if empty |

---

## Password Security

### Requirements (Enforced Frontend + Backend)

Passwords must meet ALL of the following:
- **8+ characters** minimum length
- **1 uppercase letter** (A-Z)
- **1 number** (0-9)  
- **1 symbol** (!@#$%^&*()_+-=[]{};\':"|,.<>/?~`)
- **No spaces** allowed

### Frontend Validation (setup.html)

```javascript
// Live validation with checkmark indicators
validatePasswordStrength(password) {
    if (!password || password.length < 8) {
        return 'Password must be at least 8 characters';
    }
    if (/\s/.test(password)) {
        return 'Password cannot contain spaces';
    }
    if (!/[A-Z]/.test(password)) {
        return 'Password must contain at least 1 uppercase letter';
    }
    if (!/[0-9]/.test(password)) {
        return 'Password must contain at least 1 number';
    }
    if (!/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?~`]/.test(password)) {
        return 'Password must contain at least 1 symbol';
    }
    return null; // Valid
}
```

### Backend Validation (dev-server.py + webui.nix)

Same validation exists server-side to prevent bypassing frontend:

```python
def validate_password_strength(password: str) -> str:
    """Returns error message if invalid, None if valid."""
    if not password or len(password) < 8:
        return 'Password must be at least 8 characters'
    if ' ' in password or '\t' in password:
        return 'Password cannot contain spaces'
    if not re.search(r'[A-Z]', password):
        return 'Password must contain at least 1 uppercase letter'
    if not re.search(r'[0-9]', password):
        return 'Password must contain at least 1 number'
    if not re.search(r'[!@#$%^&*()_+\-=\[\]{};\':"\\|,.<>\/?~`]', password):
        return 'Password must contain at least 1 symbol'
    return None
```

### UI Behavior

- Password hints **only show when user is typing** (not always visible)
- Live checkmarks (✓) or circles (○) indicate requirement status
- Red ✗ for failures (like spaces detected)
- Confirm password field has **paste prevention** (`@paste.prevent`)
- "Passwords match" shown in green when confirmed
- Root password option **removed** - always uses same password internally

### Password Step Title

- **"Build your fence"** - garden metaphor for security
- No emojis in description text

### Germination Stages

```javascript
const stages = [
    { progress: 10,  status: 'Rooting...',       detail: 'Finding nutrients in the soil' },
    { progress: 25,  status: 'Germinating...',   detail: 'Creating your gardener account' },
    { progress: 40,  status: 'Sprouting...',     detail: 'Encrypting credentials' },
    { progress: 55,  status: 'Growing...',       detail: 'Connecting to ' + ssid },
    { progress: 75,  status: 'Blossoming...',    detail: 'Establishing network roots' },
    { progress: 90,  status: 'Almost there...',  detail: 'Configuring Cooper' },
    { progress: 100, status: 'Planted!',         detail: 'Cooper is taking root' }
];
```

---

## Mobile UI Issues & Fixes

### ⚠️ CRITICAL: Current Mobile Problems

**Status as of last session:** Mobile layout is broken in both files.

#### Problem 1: Desktop Sidebar Visible on Mobile (index.html)

**Symptoms:**
- Desktop sidebar appears alongside mobile bottom nav
- Dual navigation confuses users

**Root Cause:**
The sidebar has conflicting Tailwind classes and CSS media queries:
```html
<!-- Line ~1861 in index.html -->
<aside class="desktop-sidebar hidden lg:flex w-64 ...">
```

The `lg:flex` shows at 1024px+, but CSS at 900px has:
```css
@media (max-width: 900px) {
    .desktop-sidebar { display: none; }
}
```

Tailwind's inline styles override CSS media queries.

**Fix Needed:**
Change Tailwind breakpoint OR remove conflicting CSS:
```html
<!-- Option A: Use CSS-only approach (recommended) -->
<aside class="desktop-sidebar w-64 ...">

<!-- Then CSS controls visibility at 900px -->
```

OR

```html
<!-- Option B: Match Tailwind to CSS breakpoint -->
<aside class="desktop-sidebar hidden md:flex w-64 ...">
<!-- md = 768px, close to 900px but not exact -->
```

#### Problem 2: Status Cards Too Tall on Mobile (index.html)

**Symptoms:**
- Status cards in home view are oversized
- Take up too much vertical space
- Leave no room for bottom nav

**Root Cause:**
The CSS has styles for status cards but they're not aggressive enough:
```css
@media (max-width: 768px) {
    .status-card { flex: 1 !important; padding: 0.875rem !important; }
}
```

**Fix Needed:**
More aggressive mobile sizing:
```css
@media (max-width: 768px) {
    .status-grid {
        flex-direction: row !important;
        gap: 0.5rem !important;
        flex-wrap: nowrap !important;
    }
    .status-card {
        flex: 1 !important;
        min-width: 0 !important;
        padding: 0.5rem !important;
        min-height: auto !important;
        max-height: 80px !important;
    }
}
```

#### Problem 3: Bottom Nav Not Visible (index.html)

**Symptoms:**
- Mobile bottom nav exists but may be hidden under content
- May be cut off by safe area on notched phones

**Location:**
```html
<!-- Line ~2465 in index.html -->
<div class="mobile-bottom-nav fixed bottom-0 left-0 right-0 ...">
```

**Fix Needed:**
- Ensure `z-index` is high enough (currently z-30)
- Add proper padding to main content so it doesn't overlap
- May need `safe-bottom` class for notched devices

#### Problem 4: Setup Card Scaling (setup.html)

**Symptoms:**
- Setup wizard card doesn't scale properly on mobile
- Content cramped or overflow issues

**Current State:**
Some mobile CSS was added at 480px and 400px breakpoints, but needs refinement.

### 🎯 Recommended Fix: YouTube-Style Bottom Bar

User requested a **unified bottom navigation** like YouTube app:

**Design Goals:**
1. Same bottom bar visible in ALL views (home, apps, settings)
2. Taller touch targets (48-56px minimum)
3. Clear active state indication
4. Works on all screen sizes
5. Respects safe area insets

**Implementation Approach:**
```html
<!-- Replace current mobile-bottom-nav -->
<nav class="fixed bottom-0 inset-x-0 bg-white/95 backdrop-blur-xl 
            border-t border-gray-200 safe-bottom z-50"
     style="padding-bottom: env(safe-area-inset-bottom);">
    <div class="flex justify-around items-center h-14 max-w-md mx-auto">
        <!-- Home -->
        <button class="flex flex-col items-center justify-center px-6 py-2"
                :class="currentView === 'home' ? 'text-ease-leaf' : 'text-gray-400'">
            <svg class="w-6 h-6">...</svg>
            <span class="text-xs mt-1">Home</span>
        </button>
        
        <!-- Garden (Apps) -->
        <button>...</button>
        
        <!-- Settings -->
        <button>...</button>
    </div>
</nav>
```

**CSS Changes Needed:**
```css
/* Remove old conditional display */
.mobile-bottom-nav {
    display: flex !important; /* Always visible on mobile */
}

/* Add main content padding */
main {
    padding-bottom: 4.5rem; /* Space for bottom nav */
    padding-bottom: calc(4.5rem + env(safe-area-inset-bottom));
}

/* Hide on desktop */
@media (min-width: 901px) {
    .mobile-bottom-nav {
        display: none !important;
    }
    main {
        padding-bottom: 0;
    }
}
```

### Mobile Breakpoints Reference

| Breakpoint | Tailwind | CSS Variable | Purpose |
|------------|----------|--------------|---------|
| 1024px | lg | - | Large tablets |
| 900px | - | Custom | Switch to mobile nav |
| 768px | md | - | Tablets |
| 480px | - | Custom | Small phones |
| 400px | - | Custom | Extra small |
| 360px | - | Custom | Tiny phones |

---

## UI Theming System

### Color Palette

```javascript
// tailwind.config.theme.extend.colors (in index.html)
colors: {
    // Garden colors (day mode)
    'ease-leaf': '#22C55E',     // Primary green
    'ease-sage': '#4ADE80',     // Light green
    'ease-forest': '#166534',   // Dark green (text)
    'ease-mint': '#86EFAC',     // Accent green
    'ease-cream': '#F0FDF4',    // Background
    'ease-soil': '#78716C',     // Brown/gray text
    
    // Night mode colors
    'night-sky': '#0f172a',     // Deep blue background
    'night-deep': '#1e293b',    // Slightly lighter
    'night-cloud': '#334155',   // Card backgrounds
}
```

### Time-of-Day Modes

```javascript
// Auto-detected based on local time
// 6-9:   sunrise
// 9-17:  day
// 17-20: sunset
// 20-6:  night

timeOfDay: null,              // 'sunrise' | 'day' | 'sunset' | 'night'
manualThemeOverride: null,    // null = auto, or explicit override
```

### Button Styles

```css
.setup-btn {
    background: linear-gradient(to right, #22C55E, #4ADE80);
    /* Hover: slight scale + shadow */
}

.setup-btn-secondary {
    background: white/70;
    border: 2px solid #22C55E;
}
```

### Animations

| Animation | Location | Description |
|-----------|----------|-------------|
| `cloud-drift` | Day mode | Clouds floating across sky |
| `wifi-pulse` | WiFi scan | Pulsing WiFi icon |
| `water-level` | Germination | Water filling pot |
| `shooting-star` | Night mode | Rare shooting star effect |

---

## Encryption & Security

### Overview

WiFi credentials are encrypted client-side before transmission, even over the local network. This provides defense-in-depth for the captive portal scenario where the hotspot itself may be unencrypted.

### Implementation

**Algorithm:** AES-256-GCM with PBKDF2 key derivation

```javascript
// Key derivation (client-side)
{
    name: 'PBKDF2',
    salt: 'easeOS-wifi-salt',  // Fixed salt
    iterations: 100000,
    hash: 'SHA-256'
}
```

**Server Session Key:**
```python
# Generated on server startup (dev-server.py)
SESSION_KEY = secrets.token_hex(32)  # 256 bits
```

### Flow

1. Client fetches session key from `/api/crypto/session`
2. Client derives AES key using PBKDF2
3. Data encrypted with AES-256-GCM (12-byte random IV)
4. Ciphertext sent as base64: `IV (12 bytes) + ciphertext`
5. Server decrypts with same key derivation

### API Endpoints Using Encryption

| Endpoint | Data Encrypted |
|----------|----------------|
| `/api/wifi/connect` | `{ ssid, password }` |
| `/api/setup/account` | `{ username, password, hostname }` |

---

## Dev Server API

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/status` | System status (mode, hostname, LED) |
| GET | `/api/config` | Current configuration |
| POST | `/api/config` | Update configuration |
| GET | `/api/crypto/session` | Get encryption session key |
| GET | `/api/wifi/scan` | Scan available WiFi networks |
| POST | `/api/wifi/connect` | Connect to WiFi network |
| POST | `/api/setup/account` | Create user account |
| GET | `/api/store/apps` | Get app catalog |

### Test Mode Features

When running on `localhost:8089`:
- `testMode` flag is set to `true` in UI
- Test mode banner appears on setup screens
- WiFi connection is simulated

**Special Test SSIDs:**
| SSID | Behavior |
|------|----------|
| `fail` or `test-fail` | Returns error immediately |
| `timeout` | Delays 10 seconds before success |
| Any other | Instant success |

### Starting Dev Server

```bash
cd /home/bazzite/Documents/easy/easyos
python3 dev-server.py
# Open http://localhost:8089
```

### Config File

`dev-config.json`:
```json
{
    "mode": "first-run",    // Triggers setup wizard
    "hostname": "easeos",
    "apps": {}
}
```

Set `mode` to `"normal"` to skip setup wizard and go directly to dashboard.

---

## NixOS Modules

### Module Overview

| Module | Purpose |
|--------|---------|
| `easyos.nix` | Core system configuration |
| `apps.nix` | App enable/disable management |
| `webui.nix` | Web UI systemd service |
| `hotspot.nix` | WiFi hotspot for initial setup |
| `backup.nix` | Backup configuration |
| `network-autodiscovery.nix` | mDNS/Avahi setup |
| `network-performance.nix` | Network optimizations |
| `storage-expansion.nix` | USB storage handling |

### App Module Pattern

Apps are defined in `store/apps/*.json` and follow this structure:

```json
{
    "id": "jellyfin",
    "name": "Jellyfin",
    "nixModule": {
        "services.jellyfin": {
            "enable": true
        }
    }
}
```

The `nixModule` object maps directly to NixOS configuration.

---

## App Store System

### Store Loading

Apps load from GitHub first (for updates), with local fallback:

```javascript
githubStoreUrl: 'https://raw.githubusercontent.com/doughty247/easyos/main/store/apps'
storeAppFiles: ['homeassistant', 'immich', 'jellyfin', 'nextcloud', 'vaultwarden']
```

### App JSON Schema

See `/store/SDK.md` for complete documentation.

**Required Fields:**
- `id` - Unique identifier (lowercase)
- `name` - Display name
- `version` - Semantic version
- `description` - Brief description
- `category` - media|productivity|security|automation|networking|other
- `icon` - Icon configuration
- `nixModule` - NixOS configuration

### Current Apps

| App | Category | Status |
|-----|----------|--------|
| Home Assistant | automation | Defined |
| Immich | media | Defined |
| Jellyfin | media | Defined |
| Nextcloud | productivity | Defined |
| Vaultwarden | security | Defined |

---

## Known Issues & TODO

### 🔴 CRITICAL: Mobile UI Broken (Current Priority)

See [Mobile UI Issues & Fixes](#mobile-ui-issues--fixes) section above.

**Summary:**
1. Desktop sidebar visible on mobile (conflicting Tailwind/CSS)
2. Status cards too tall on mobile
3. Bottom nav hidden/cut off
4. Setup card scaling broken

**Next developer should:**
1. Fix sidebar visibility (choose Tailwind OR CSS approach)
2. Implement YouTube-style unified bottom bar
3. Test on actual mobile device or DevTools mobile view
4. Ensure safe-area-inset support for notched phones

### Other Issues (from instructions.md)

#### 1. Deceptive App Tiles

**Problem:** App store tiles only show "installed" or "not installed", but don't show pending changes.

**Solution Needed:**
```javascript
// 3-state logic:
// - NOT_INSTALLED: Not in config, not pending
// - PENDING: User clicked install, not yet applied
// - INSTALLED: Actually in system config
```

#### 2. Button Clutter

**Problem:** Multiple action buttons without clear commit workflow.

**Solution Needed:**
- Staged changes model
- Dirty state tracking
- Single "Apply Changes" action
- Confirmation before destructive actions

### UI Polish Needed

- [x] Split setup wizard into separate file (DONE)
- [x] Add storage detection error handling (DONE)
- [ ] **Fix mobile bottom nav (CRITICAL)**
- [ ] **Fix desktop sidebar mobile visibility (CRITICAL)**
- [ ] **Implement YouTube-style bottom bar (USER REQUEST)**
- [ ] Sunset mode gradient needs refinement
- [ ] Mobile bottom nav spacing on notched phones
- [ ] Loading states for app installation

### Feature Gaps

- [ ] App uninstall flow
- [ ] Settings persistence
- [ ] Backup/restore UI
- [ ] Log viewer functionality
- [ ] Network status indicator
- [ ] Storage detection with real hardware (currently mock)

---

## Development Workflow

### Quick Start

```bash
# 1. Navigate to project
cd /home/bazzite/Documents/easy/easyos

# 2. Start dev server
python3 dev-server.py

# 3. Open browser
# http://localhost:8089

# 4. For setup wizard, ensure dev-config.json has:
#    "mode": "first-run"

# 5. For main dashboard:
#    "mode": "normal"
```

### Hot Reload

The dev server serves files directly from disk:
- Edit `webui/templates/setup.html` for setup wizard
- Edit `webui/templates/index.html` for main dashboard
- Refresh browser to see changes
- No build step required

### Testing Storage Flow

1. Set `dev-config.json` → `"mode": "first-run"`
2. Start dev server
3. Go through setup wizard to storage step
4. Currently mock API returns empty `drives: []` to test error state
5. Modify `dev-server.py` `/api/storage/detect` to return drives for testing

### Testing WiFi Flow

1. Set `dev-config.json` → `"mode": "first-run"`
2. Start dev server
3. Go through setup wizard
4. WiFi networks are either real (if nmcli available) or mock

**Test failure scenarios:**
- Select network named "fail" → triggers error
- Select network named "timeout" → 10-second delay

### Resetting to Setup Wizard

```bash
# Edit dev-config.json
{
    "mode": "first-run"
}

# Restart dev server
```

### File Locations for Common Tasks

| Task | File(s) |
|------|---------|
| Add new app | `store/apps/newapp.json` |
| Modify setup flow | `webui/templates/index.html` (lines 1500-1900) |
| Change colors | `webui/templates/index.html` (lines 50-100, Tailwind config) |
| Add API endpoint | `dev-server.py` |
| Add NixOS feature | `modules/easyos.nix` or new module |

---

## Cooper - The Mascot

Cooper is a cute Haworthia succulent in a terracotta pot. Key design elements:

- **Pot:** Terracotta orange (`#EA580C`)
- **Soil:** Dark green (`#365314`)
- **Leaves:** Rosette pattern with translucent tips
- **Face:** Chibi style - dots for eyes, rosy cheeks, curved smile
- **Expressions:**
  - Normal: Open dot eyes, small smile
  - Happy: Closed `^‿^` eyes, big smile, extra rosy cheeks
  - Watering: Happy face, water droplet animation

---

## Session Notes

### What Was Completed This Session (30 Nov 2025)

1. ✅ **Strong password validation** - 8+ chars, uppercase, number, symbol, no spaces
2. ✅ **Frontend password validation** - Live hints with checkmarks in setup.html
3. ✅ **Backend password validation** - Added to dev-server.py and webui.nix
4. ✅ **Password UX improvements:**
   - Hints only show when typing (not always visible)
   - Paste prevention on confirm password field
   - "Passwords match" confirmation message
   - Removed root password option (confusing for users)
5. ✅ **Removed all emojis** from setup.html (per user requirement)
6. ✅ **Garden-themed password step** - "Build your fence" title
7. ✅ **Updated REFERENCE.md** with user preferences and style guide

### User Preferences Documented

- **No emojis** except ✓ ✗ ○ for validation
- **Simplicity over options** - remove confusing technical choices
- **Password hints on focus only** - not always visible
- **Paste prevention** on confirm password
- **No root password UI** - use same password internally

### Previous Session Completions

1. ✅ Split setup wizard into separate file (`setup.html`)
2. ✅ Updated dev-server.py routing based on `config.mode`
3. ✅ Added storage detection step to setup wizard
4. ✅ Added storage error handling with retry button
5. ✅ Added mock storage API endpoint
6. ✅ Implemented YouTube-style bottom bar
7. ✅ Fixed desktop sidebar mobile visibility
8. ✅ Added compact status cards for mobile

### What Needs To Be Done Next

1. 🟡 **Test on real mobile device** - Current testing only in desktop browser DevTools
2. 🟡 **Implement real storage detection** - Currently returns mock empty array
3. 🟡 **Polish setup.html mobile layout** - Needs similar compact treatment
4. 🟡 **Safe area inset testing** - Test on notched phones (iPhone X+)
5. 🟡 **Fix /api/system/info 404** - Endpoint exists but returns 404 in logs

### Things That Work

- Full setup wizard flow (7 steps with storage)
- Strong password validation (frontend + backend)
- Config-based routing (first-run → setup, normal → dashboard)
- WiFi scanning (real via nmcli or mock)
- AES-256-GCM encryption for credentials
- Test mode with failure simulation
- Day/night/sunrise/sunset themes
- App store loading from GitHub
- Storage error handling with retry
- Desktop layout
- YouTube-style mobile bottom navigation
- Proper sidebar hiding on mobile (CSS-only)
- Compact status cards on mobile

### Things That May Need Polish

- 🟡 Setup card scaling on mobile devices (setup.html)
- 🟡 Safe area insets for notched phones
- 🟡 Floating action bar positioning with bottom nav
- 🟡 App grid responsiveness on very small screens

### State of the Codebase

| File | Lines | Status |
|------|-------|--------|
| `setup.html` | ~1206 | Password validation, no emojis |
| `index.html` | ~3760 | Mobile fixes applied, test needed |
| `dev-server.py` | ~670 | Password validation + routing + storage API |
| `webui.nix` | - | Production server with password validation |
| `dev-config.json` | - | Currently set to `"mode": "first-run"` |

### Key Code Locations

| What | File | Lines |
|------|------|-------|
| Password validation (frontend) | setup.html | ~720 (validatePasswordStrength) |
| Password validation (backend) | dev-server.py | ~89-107 |
| Password step UI | setup.html | ~340-400 |
| Routing logic | dev-server.py | ~145-165 |
| Storage API mock | dev-server.py | ~180-200 |
| Desktop sidebar CSS | index.html | ~1363 |
| Mobile bottom nav CSS | index.html | ~1372-1430 |
| 900px breakpoint | index.html | ~1500-1545 |

### Password Validation Locations

| Component | File | Location |
|-----------|------|----------|
| Frontend validation | setup.html | `validatePasswordStrength()` function |
| Frontend UI hints | setup.html | Lines ~360-380 (live checklist) |
| Backend validation | dev-server.py | `validate_password_strength()` function |
| Production backend | webui.nix | `validate_password_strength()` function |
| Paste prevention | setup.html | `@paste.prevent` on confirm input |

### Mobile Bottom Nav Implementation

The new YouTube-style bottom bar is implemented as:

```html
<!-- In index.html at ~line 2547 -->
<nav class="mobile-bottom-nav">
    <div class="nav-container">
        <button class="nav-item" :class="currentView === 'home' ? 'active' : 'inactive'">
            <svg>...</svg>
            <span>Home</span>
        </button>
        <!-- Garden, Settings buttons -->
    </div>
</nav>
```

```css
/* CSS at ~line 1372 */
.mobile-bottom-nav {
    display: none;  /* Hidden by default */
    position: fixed;
    bottom: 0;
    /* ... frosted glass styling */
}

/* At 900px, becomes visible */
@media (max-width: 900px) {
    .mobile-bottom-nav { display: block !important; }
    .desktop-sidebar { display: none !important; }
}
```

---

*This document was created for project handoff. For questions or context, review the git history and inline comments in the source files.*

*Last updated: 30 November 2025 - Password security, emoji removal, user preferences documented*
