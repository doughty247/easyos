# easeOS App SDK

Create your own apps for the easeOS Garden! This SDK provides a simple template for adding self-hosted applications.

## Quick Start

1. Create a new JSON file in `/store/apps/your-app.json`
2. Follow the template structure below
3. Your app will automatically appear in the Store

## App Template

```json
{
  "id": "your-app-id",
  "name": "Your App Name",
  "version": "1.0.0",
  "description": "A brief description of what your app does.",
  "category": "media|productivity|security|automation|networking|other",
  "author": "Author Name",
  "website": "https://your-app-website.com",
  "icon": {
    "type": "gradient",
    "colors": ["#hexcolor1", "#hexcolor2"],
    "svg": "<svg viewBox='0 0 24 24' fill='white'>...</svg>"
  },
  "nixModule": {
    "services.your-app": {
      "enable": true,
      "option1": "value1"
    }
  },
  "ports": [8080],
  "requirements": {
    "minRAM": "1GB",
    "storage": "500MB+"
  },
  "tags": ["tag1", "tag2", "tag3"]
}
```

## Field Reference

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier (lowercase, no spaces) |
| `name` | string | Display name for the app |
| `version` | string | Semantic version (e.g., "1.0.0") |
| `description` | string | Brief description (max 100 chars) |
| `category` | string | One of: media, productivity, security, automation, networking, other |
| `icon` | object | Icon configuration (see below) |
| `nixModule` | object | NixOS module configuration |

### Icon Configuration

```json
{
  "type": "gradient",
  "colors": ["#startColor", "#endColor"],
  "svg": "<svg>...</svg>"
}
```

The gradient goes from top-left to bottom-right. SVG should use `fill='white'` for best contrast.

### NixOS Module

The `nixModule` object maps directly to NixOS configuration. Example:

```json
{
  "services.immich": {
    "enable": true,
    "host": "0.0.0.0"
  }
}
```

This generates:

```nix
services.immich = {
  enable = true;
  host = "0.0.0.0";
};
```

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `author` | string | App author or organization |
| `website` | string | Official website URL |
| `ports` | array | Network ports used by the app |
| `requirements` | object | System requirements |
| `tags` | array | Searchable keywords |

## Categories

- `media` - Photos, videos, music, streaming
- `productivity` - Files, documents, collaboration
- `security` - Passwords, encryption, privacy
- `automation` - Home automation, IoT, workflows
- `networking` - VPN, DNS, proxy, monitoring
- `other` - Everything else

## Icon Examples

### Simple Path Icon
```json
{
  "type": "gradient",
  "colors": ["#22c55e", "#16a34a"],
  "svg": "<svg viewBox='0 0 24 24' fill='white'><path d='M12 2L2 22h20L12 2z'/></svg>"
}
```

### Multi-element Icon
```json
{
  "type": "gradient", 
  "colors": ["#6366f1", "#8b5cf6"],
  "svg": "<svg viewBox='0 0 24 24' fill='white'><circle cx='12' cy='12' r='10'/><path d='M8 12h8M12 8v8'/></svg>"
}
```

## Submitting to the Store

1. Fork the easyos repository
2. Add your app JSON to `/store/apps/`
3. Test locally
4. Submit a pull request

## Best Practices

- Keep descriptions concise and clear
- Use appropriate categories and tags
- Test your NixOS module configuration
- Include all required ports
- Provide accurate system requirements
