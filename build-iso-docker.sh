#!/usr/bin/env bash
set -euo pipefail

# Resolve workspace to the directory containing this script so it works from any CWD
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

# EASYOS ISO Builder (Docker/Podman version)
# For use on Bazzite or other non-NixOS systems

# Parse arguments
VENTOY_COPY=false
VM_TEST=false
VM_UPDATE=false
FORCE_BUILD=false
PRUNE_VOLUMES=false
SUPPRESS_XATTR_WARNINGS=true  # Default to suppressing xattr warnings (they're harmless but slow)
EXPORT_ARTIFACTS=true
ARTIFACTS_DIR="iso-output/_artifacts"
NON_INTERACTIVE=false

for arg in "$@"; do
  case $arg in
    --ventoy)
      VENTOY_COPY=true
      ;;
    --vm)
      VM_TEST=true
      ;;
    --update-vm)
      VM_UPDATE=true
      ;;
    --force|--rebuild)
      FORCE_BUILD=true
      ;;
    --prune-volumes)
      PRUNE_VOLUMES=true
      ;;
    --no-xattr-warnings|--quiet-xattr)
      SUPPRESS_XATTR_WARNINGS=true
      ;;
    --no-artifacts)
      EXPORT_ARTIFACTS=false
      ;;
    --artifacts-dir=*)
      EXPORT_ARTIFACTS=true
      ARTIFACTS_DIR="${arg#*=}"
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      ;;
    *)
      echo "Usage: $0 [--ventoy] [--vm] [--update-vm] [--force] [--prune-volumes] [--no-xattr-warnings] [--non-interactive]"
      echo "  --ventoy  Auto-copy ISO to Ventoy USB drive"
      echo "  --vm      Launch ISO in QEMU VM for testing (fresh install)"
      echo "  --update-vm  Boot existing VM disk and auto-update with latest flake"
      echo "  --force   Force a rebuild even if the ISO appears up-to-date"
      echo "  --prune-volumes  Remove stale easyos-nix-* volumes to reclaim space"
      echo "  --no-xattr-warnings  Hide harmless lgetxattr/read_attrs warnings from build logs"
      echo "  --no-artifacts       Skip exporting helper artifacts for inspection"
      echo "  --artifacts-dir=DIR  Export artifacts into DIR (relative to repo root)"
      echo "  --non-interactive    Never prompt (auto-skip flake update prompts)"
      exit 1
      ;;
  esac
done

echo "Building easyos ISO with Docker..."
echo "==================================="
echo ""

# Check if we're in the right directory (where this script lives)
if [ ! -f "flake.nix" ]; then
  echo "ERROR: flake.nix not found next to build script at: $SCRIPT_DIR" >&2
  exit 1
fi

# Detect Docker or Podman
if command -v docker >/dev/null 2>&1; then
  DOCKER_CMD="docker"
elif command -v podman >/dev/null 2>&1; then
  DOCKER_CMD="podman"
else
  echo "ERROR: Neither docker nor podman found. Please install one." >&2
  exit 1
fi

echo "Using: $DOCKER_CMD"
echo ""

# Prune stale easyos-nix-* volumes if requested or on --force
if [ "$PRUNE_VOLUMES" = true ] || [ "$FORCE_BUILD" = true ]; then
  echo "Cleaning up stale easyos-nix-* Docker volumes..."
  STALE_VOLS=$($DOCKER_CMD volume ls -q 2>/dev/null | grep -E '^easyos-nix-(store|cache)' || true)
  if [ -n "$STALE_VOLS" ]; then
    echo "Removing volumes:"
    echo "$STALE_VOLS" | while read -r vol; do
      echo "  - $vol"
      $DOCKER_CMD volume rm "$vol" 2>/dev/null || true
    done
    echo "✓ Volumes cleaned up"
  else
    echo "  No stale volumes found"
  fi
  echo ""
fi

# Preflight: ensure critical sources are tracked by git so Nix flakes include them
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git ls-files --error-unmatch "scripts/easyos-install.sh" >/dev/null 2>&1; then
    echo "ERROR: scripts/easyos-install.sh is not tracked by git."
    echo "       Add and commit it so the ISO includes the latest installer:"
    echo "         git add scripts/easyos-install.sh && git commit -m 'Include installer'"
    echo "       Or build with --force after adding the file."
    exit 1
  fi
fi

# Pull the image if needed (requires internet)
if ! $DOCKER_CMD images nixos/nix:latest | grep -q nixos; then
  echo "Pulling nixos/nix:latest..."
  if ! $DOCKER_CMD pull nixos/nix:latest; then
    echo "ERROR: Failed to pull Docker image. Check your internet connection." >&2
    exit 1
  fi
fi

# Check for existing ISO output directory (build happens inside container)
ISO_OUTPUT_DIR="iso-output"
mkdir -p "$ISO_OUTPUT_DIR"

ARTIFACTS_DIR_HOST=""
ARTIFACTS_DIR_CONTAINER=""
if [ "$EXPORT_ARTIFACTS" = true ]; then
  ARTIFACTS_DIR="${ARTIFACTS_DIR%/}"
  ARTIFACTS_DIR="${ARTIFACTS_DIR#./}"
  if [ -z "$ARTIFACTS_DIR" ] || [ "$ARTIFACTS_DIR" = "." ]; then
    ARTIFACTS_DIR="iso-output/_artifacts"
  fi
  if [[ "$ARTIFACTS_DIR" = /* ]]; then
    echo "ERROR: --artifacts-dir must be relative to the repository root" >&2
    exit 1
  fi
  if [[ "$ARTIFACTS_DIR" = .. || "$ARTIFACTS_DIR" = ../* || "$ARTIFACTS_DIR" = */.. || "$ARTIFACTS_DIR" = */../* ]]; then
    echo "ERROR: --artifacts-dir cannot reference parent directories" >&2
    exit 1
  fi
  ARTIFACTS_DIR_HOST="$ARTIFACTS_DIR"
  ARTIFACTS_DIR_CONTAINER="/workspace/$ARTIFACTS_DIR"
fi

STAMP_FILE="$ISO_OUTPUT_DIR/.easyos-source-hash"

calc_workspace_hash() {
  # Include all sources that can influence the ISO contents, not just *.nix
  # Exclude build outputs and caches to avoid noisy false positives
  mapfile -t files < <(find . \
    -path "./.git" -prune -o \
    -path "./result" -prune -o \
    -path "./iso-output" -prune -o \
    -path "./.nix-bincache" -prune -o \
    -type f \( \
      -name "*.nix" -o \
      -name "flake.lock" -o \
      -name "*.sh" -o \
      -path "./scripts/*" -o \
      -path "./modules/*" -o \
      -path "./webui/*" -o \
      -path "./etc/easy/config.example.json" \
    \) \
    -print | LC_ALL=C sort)
  if [ ${#files[@]} -eq 0 ]; then
    echo "none"
    return 0
  fi
  local hash_accum=""
  local part
  for f in "${files[@]}"; do
    part=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    hash_accum+="$part\n"
  done
  printf "%b" "$hash_accum" | sha256sum | cut -d' ' -f1
}

NEEDS_BUILD=true
BUILD_PERFORMED=false
CURRENT_HASH=""
PREVIOUS_HASH=""
if [ -f "$STAMP_FILE" ]; then
  PREVIOUS_HASH=$(<"$STAMP_FILE") || PREVIOUS_HASH=""
fi

EXISTING_ISO=$(find "$ISO_OUTPUT_DIR" -maxdepth 1 -name "*.iso" -type f 2>/dev/null | head -1)

if [ -n "$EXISTING_ISO" ]; then
  echo "Found existing ISO: $EXISTING_ISO"
  if [ "$FORCE_BUILD" = true ]; then
    echo "Force rebuild requested (--force/--rebuild)."
  else
    CURRENT_HASH=$(calc_workspace_hash || echo "")
    if [ -n "$PREVIOUS_HASH" ] && [ -n "$CURRENT_HASH" ] && [ "$CURRENT_HASH" = "$PREVIOUS_HASH" ]; then
      echo "✓ Workspace hash unchanged since last build. Skipping rebuild."
      NEEDS_BUILD=false
    else
      echo "Checking for file changes since last build..."
      ISO_TIME=$(stat -c %Y "$EXISTING_ISO" 2>/dev/null || stat -f %m "$EXISTING_ISO" 2>/dev/null)
      CHANGED_REPORT=()
      while IFS= read -r candidate; do
        [ -f "$candidate" ] || continue
        FILE_TIME=$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null)
        if [ "$FILE_TIME" -gt "$ISO_TIME" ]; then
          CHANGED_REPORT+=("  Changed: ${candidate#./}")
        fi
      done < <(find . \
        -path "./.git" -prune -o \
        -type f \( -name "*.nix" -o -name "flake.lock" -o -path "./etc/easy/config.example.json" \) \
        -print | LC_ALL=C sort)
      if [ ${#CHANGED_REPORT[@]} -gt 0 ]; then
        printf '%s\n' "${CHANGED_REPORT[@]}"
      else
        echo "  (No obvious timestamp changes detected; hash differs or ISO timestamp may be older.)"
      fi
      echo "Files changed since last build. Rebuilding..."
    fi
  fi
else
  echo "No existing ISO found. Building..."
fi

if [ "$FORCE_BUILD" = true ] && [ "$EXISTING_ISO" = "" ]; then
  echo "Force flag provided but no ISO exists yet; proceeding with full build."
fi

# If --vm is requested and an ISO exists, only skip build when the workspace hash
# matches the last build; otherwise rebuild so the VM test uses fresh bits.
if [ "$VM_TEST" = true ] && [ -n "$EXISTING_ISO" ] && [ "$FORCE_BUILD" != true ]; then
  CURRENT_HASH=${CURRENT_HASH:-}
  if [ -z "$CURRENT_HASH" ]; then
    CURRENT_HASH=$(calc_workspace_hash || echo "")
  fi
  if [ -n "$PREVIOUS_HASH" ] && [ -n "$CURRENT_HASH" ] && [ "$CURRENT_HASH" = "$PREVIOUS_HASH" ]; then
    echo "✓ Using existing ISO for VM test (no changes since last build)"
    NEEDS_BUILD=false
  else
    echo "Changes detected; will rebuild ISO before launching VM."
  fi
fi

if [ "$NEEDS_BUILD" = false ]; then
  BUILD_EXIT=0
elif [ "$VM_UPDATE" = true ]; then
  echo "Skipping ISO build for --update-vm mode."
  BUILD_EXIT=0
else
  # Build the ISO
  echo ""
  echo "Building ISO (this may take 10-20 minutes on first run)..."
  echo ""

  # Ensure persistent volumes for faster rebuilds
  STORE_VOL="easyos-nix-store"
  CACHE_VOL="easyos-nix-cache"
  if [ "$FORCE_BUILD" = true ]; then
    # Use a fresh store on forced rebuild to avoid stale/corrupt outputs
    TS=$(date +%s)
    STORE_VOL="easyos-nix-store-$TS"
    CACHE_VOL="easyos-nix-cache-$TS"
  fi
  $DOCKER_CMD volume create "$STORE_VOL" >/dev/null 2>&1 || true
  $DOCKER_CMD volume create "$CACHE_VOL" >/dev/null 2>&1 || true

  if [ "$EXPORT_ARTIFACTS" = true ] && [ -n "$ARTIFACTS_DIR_HOST" ]; then
    mkdir -p "$ARTIFACTS_DIR_HOST"
    find "$ARTIFACTS_DIR_HOST" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  fi

  # Build docker run args:
  # - Always pass -i so the heredoc is delivered to the container's bash via STDIN
  # - Never pass -t to avoid Docker's "the input device is not a TTY" error in CI/pipes
  DOCKER_RUN_ARGS=("--rm" "-i")

  $DOCKER_CMD run "${DOCKER_RUN_ARGS[@]}" \
    -v "$SCRIPT_DIR:/workspace:Z" \
    -v "$STORE_VOL":/nix \
    -v "$CACHE_VOL":/root/.cache/nix \
    -w /workspace \
    -e SUPPRESS_XATTR_WARNINGS=${SUPPRESS_XATTR_WARNINGS} \
    -e EASYOS_EXPORT_ARTIFACTS=${EXPORT_ARTIFACTS} \
    -e EASYOS_ARTIFACTS_DIR="${ARTIFACTS_DIR_CONTAINER}" \
    -e EASYOS_NONINTERACTIVE=${NON_INTERACTIVE} \
    nixos/nix:latest \
    bash <<'EOS'
set -euo pipefail

STAMP_FILE="/workspace/iso-output/.easyos-source-hash"

calc_source_hash() {
  # Mirror host-side hashing: include all sources that affect ISO content
  mapfile -t files < <(find /workspace \
    -path "/workspace/.git" -prune -o \
    -path "/workspace/result" -prune -o \
    -path "/workspace/iso-output" -prune -o \
    -path "/workspace/.nix-bincache" -prune -o \
    -type f \( \
      -name "*.nix" -o \
      -name "flake.lock" -o \
      -name "*.sh" -o \
      -path "/workspace/scripts/*" -o \
      -path "/workspace/modules/*" -o \
      -path "/workspace/webui/*" -o \
      -path "/workspace/etc/easy/config.example.json" \
    \) \
    -print | LC_ALL=C sort)
  if [ ${#files[@]} -eq 0 ]; then
    echo "none"
    return 0
  fi
  HASH_ACCUM=""
  for f in "${files[@]}"; do
    PART=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    HASH_ACCUM+="$PART\n"
  done
  printf "%b" "$HASH_ACCUM" | sha256sum | cut -d' ' -f1
}

mkdir -p /root/.config/nix
cat > /root/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
filter-syscalls = false
max-jobs = auto
cores = 0
narinfo-cache-negative-ttl = 3600
narinfo-cache-positive-ttl = 432000
http-connections = 50
max-substitution-jobs = 16
substituters = https://cache.nixos.org file:///workspace/.nix-bincache
require-sigs = false
EOF

git config --global --add safe.directory /workspace
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [ -d /workspace/.nix-bincache ]; then
  echo "Using local binary cache: /workspace/.nix-bincache"
fi

echo "Checking GitHub connectivity for flake updates..."
ONLINE=0
if git ls-remote --heads https://github.com/doughty247/easyos.git >/dev/null 2>&1; then
  ONLINE=1
elif curl -s --max-time 5 -I https://github.com/doughty247/easyos >/dev/null 2>&1; then
  ONLINE=1
elif curl -s --max-time 5 -I https://github.com >/dev/null 2>&1; then
  ONLINE=1
fi

if [ "$ONLINE" -eq 1 ]; then
  echo "Online. Checking if updates are available..."
  cd /workspace
  if [ -f flake.lock ]; then
    # Determine flake.lock "age" robustly. Prefer git commit time to avoid stale or skewed mtimes.
    get_flakelock_epoch() {
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
         && git ls-files --error-unmatch flake.lock >/dev/null 2>&1; then
        git log -1 --format=%ct -- flake.lock 2>/dev/null | tr -d '\n'
        return
      fi
      stat -c %Y flake.lock 2>/dev/null || stat -f %m flake.lock 2>/dev/null || echo ""
    }

    LOCAL_TIME=$(get_flakelock_epoch)
    CURRENT_TIME=$(date +%s)
    AGE_SECONDS=0
    AGE_DAYS=0
    if [[ "$LOCAL_TIME" =~ ^[0-9]+$ ]]; then
      AGE_SECONDS=$((CURRENT_TIME - LOCAL_TIME))
      if [ "$AGE_SECONDS" -lt 0 ]; then AGE_SECONDS=0; fi
      AGE_DAYS=$((AGE_SECONDS / 86400))
    else
      echo "WARNING: Could not determine flake.lock age reliably; proceeding without age check."
    fi

    if git diff --quiet flake.nix flake.lock 2>/dev/null; then
      HAS_LOCAL_CHANGES=0
    else
      HAS_LOCAL_CHANGES=1
    fi

    if [ "$HAS_LOCAL_CHANGES" -eq 1 ]; then
      echo "Local flake files have uncommitted changes."
      echo "Skipping update to preserve local modifications."
    elif [ "$AGE_DAYS" -gt 7 ]; then
      if [ "$AGE_DAYS" -eq 1 ]; then
        AGE_MSG="1 day old"
      elif [ "$AGE_DAYS" -lt 30 ]; then
        AGE_MSG="$AGE_DAYS days old"
      elif [ "$AGE_DAYS" -lt 60 ]; then
        AGE_MSG="1 month old"
      else
        AGE_MONTHS=$((AGE_DAYS / 30))
        AGE_MSG="$AGE_MONTHS months old"
      fi
      LAST_DATE="unknown"
      if [[ "$LOCAL_TIME" =~ ^[0-9]+$ ]]; then
        LAST_DATE=$(date -u -d @${LOCAL_TIME} +%Y-%m-%d 2>/dev/null || echo "unknown")
      fi
      echo "Local flake.lock is $AGE_MSG (last change: $LAST_DATE)."
      if [ "${EASYOS_NONINTERACTIVE:-}" = "true" ] || [ ! -t 0 ]; then
        echo "Non-interactive build: skipping flake update."
      else
        printf "Would you like to update from GitHub? (y/N): "
        read -r RESPONSE
        if [ "$RESPONSE" = "y" ] || [ "$RESPONSE" = "Y" ]; then
          echo "Updating flake inputs from GitHub..."
          set +e
          nix flake update --commit-lock-file 2>&1 | grep -v "warning: ignoring untrusted"
          UPDATE_EXIT=$?
          set -e
          if [ "$UPDATE_EXIT" -ne 0 ]; then
            echo "WARNING: Flake update failed; proceeding with local flake.lock."
          else
            echo "✓ Flake inputs updated successfully."
          fi
        else
          echo "Skipping update. Using local flake.lock."
        fi
      fi
    else
      echo "Local flake.lock is current (less than a week old). Skipping update."
    fi
  else
    echo "No local flake.lock found. Fetching latest from GitHub..."
    set +e
    nix flake update --commit-lock-file 2>&1 | grep -v "warning: ignoring untrusted"
    UPDATE_EXIT=$?
    set -e
    if [ "$UPDATE_EXIT" -ne 0 ]; then
      echo "WARNING: Flake update failed."
    fi
  fi
else
  echo "WARNING: No internet (or DNS/HTTP unavailable). Using local flake.lock; may be outdated."
fi

echo "Running preflight checks (installer integrity)..."
OPEN_EON=$(grep -Ec "<<'?E""ON'?" /workspace/flake.nix || true)
CLOSE_EON=$(grep -Ec '^[[:space:]]*EON$' /workspace/flake.nix || true)
OPEN_EOCRED=$(grep -Ec "<<E""OCRED" /workspace/flake.nix || true)
CLOSE_EOCRED=$(grep -Ec '^[[:space:]]*EOCRED$' /workspace/flake.nix || true)
if [ "$OPEN_EON" -ne "$CLOSE_EON" ] || [ "$OPEN_EOCRED" -ne "$CLOSE_EOCRED" ]; then
  echo "" >&2
  echo "ERROR: Preflight failed: heredoc markers mismatch in embedded installer." >&2
  echo "       OPEN_EON=$OPEN_EON CLOSE_EON=$CLOSE_EON OPEN_EOCRED=$OPEN_EOCRED CLOSE_EOCRED=$CLOSE_EOCRED" >&2
  echo "       Please fix the heredoc blocks in flake.nix (easyos-install.sh) and try again." >&2
  exit 1
fi
echo "Preflight passed: installer heredocs OK."

# Extra preflight: validate installer script syntax and catch common heredoc expansion pitfalls
if [ -f /workspace/scripts/easyos-install.sh ]; then
  echo "Preflight: bash -n syntax check for installer..."
  if ! bash -n /workspace/scripts/easyos-install.sh 2>/tmp/easyos-bash-n.err; then
    echo "ERROR: bash syntax check failed for scripts/easyos-install.sh" >&2
    sed -n '1,120p' /tmp/easyos-bash-n.err >&2 || true
    exit 1
  fi
  echo "Preflight: scanning for unescaped variables inside TPM re-enroll heredoc..."
  START_LINE=$(grep -n 'easyos-tpm-reenroll.sh <<' /workspace/scripts/easyos-install.sh | tail -1 | cut -d: -f1 || true)
  if [ -n "$START_LINE" ]; then
    # Extract until closing EOR
    sed -n "$((START_LINE+1)),/^[[:space:]]*EOR$/p" /workspace/scripts/easyos-install.sh > /tmp/easyos-reenroll-block.txt 2>/dev/null || true
    if [ -s /tmp/easyos-reenroll-block.txt ]; then
      # If "$DEV" or "$LOGTAG" appear unescaped, it's a bug (would expand at build time under set -u)
      if grep -q '"$DEV"\| -t "$LOGTAG"' /tmp/easyos-reenroll-block.txt; then
        echo "ERROR: Detected unescaped \$ variables in reenroll heredoc (would expand during build)." >&2
        echo "Offending lines:" >&2
        grep -n '"$DEV"\| -t "$LOGTAG"' /tmp/easyos-reenroll-block.txt >&2 || true
        echo "Fix by escaping as \"\\$DEV\" and \"\\$LOGTAG\" or using a quoted heredoc." >&2
        exit 1
      fi
    fi
  fi
  # Advisory: run shellcheck if available, but don't fail the build on warnings
  if command -v shellcheck >/dev/null 2>&1; then
    echo "Preflight (advisory): shellcheck scripts/easyos-install.sh"
    shellcheck -x -s bash /workspace/scripts/easyos-install.sh || true
  else
    # Skip shellcheck if not available - it's advisory only and nix shell isn't reliable in all containers
    echo "Preflight (advisory): shellcheck not available, skipping"
  fi
fi

cd /workspace
nix build .#nixosConfigurations.iso.config.system.build.isoImage --impure --print-build-logs --accept-flake-config

# Find the ISO file - try multiple methods
ISO_PATH=""

echo "DEBUG: result symlink and target:"
ls -la result 2>/dev/null || true
echo -n "DEBUG: readlink -f result: "
readlink -f result 2>/dev/null || true
TARGET_DBG=$(readlink -f result 2>/dev/null | tr -d '\n' || true)
if [ -n "$TARGET_DBG" ]; then
  echo "DEBUG: target listing (top):"
  ls -la "$TARGET_DBG" 2>/dev/null || true
  echo "DEBUG: search for inner ISO under target:"
  find "$TARGET_DBG" -maxdepth 2 -name "*.iso" -type f 2>/dev/null || true
fi

# If the result target doesn't exist (e.g., previously moved from store), force a rebuild
if [ -n "$TARGET_DBG" ] && [ ! -e "$TARGET_DBG" ]; then
  echo "WARNING: Build output target missing from store; removing stale DB entry and rebuilding..."
  nix store delete "$TARGET_DBG" 2>/dev/null || nix-store --delete "$TARGET_DBG" 2>/dev/null || true
  # Build without linking to force materialization and capture the out path
  OUT_PATH=$(nix build .#nixosConfigurations.iso.config.system.build.isoImage --impure --print-build-logs --accept-flake-config --no-link --print-out-paths | tr -d '\n' || true)
  echo "DEBUG: no-link out path: $OUT_PATH"
  if [ -z "$OUT_PATH" ]; then
    echo "ERROR: nix build returned no output path" >&2
    exit 1
  fi
  if [ ! -e "$OUT_PATH" ]; then
    echo "ERROR: real output path does not exist: $OUT_PATH" >&2
    exit 1
  fi
  # Update result symlink to the new path
  rm -f result 2>/dev/null || true
  ln -s "$OUT_PATH" result
  TARGET_DBG="$OUT_PATH"
  ls -la "$TARGET_DBG" 2>/dev/null || true
fi

# Method 0: If 'result' itself is a symlink to an ISO store path (directory with .iso suffix)
if [ -L "result" ]; then
  TARGET=$(readlink -f result 2>/dev/null | tr -d '\n' || true)
  if [ -n "$TARGET" ] && [[ "$TARGET" == *.iso ]]; then
    ISO_PATH="$TARGET"
  fi
fi

# Method 1: Check if result/iso/ exists and has ISO files
if [ -z "$ISO_PATH" ] && [ -d "result/iso" ]; then
  ISO_PATH=$(find result/iso -name "*.iso" -type f 2>/dev/null | head -1)
fi

# Method 2: If not found, check hydra-build-products
if [ -z "$ISO_PATH" ] && [ -f "result/nix-support/hydra-build-products" ]; then
  # Extract path from hydra-build-products (format: "file iso /path/to/file.iso")
  ISO_PATH=$(cut -d' ' -f3 < result/nix-support/hydra-build-products)
  # Verify the file exists
  if [ ! -f "$ISO_PATH" ]; then
    ISO_PATH=""
  fi
fi

# Method 3: Search the entire result tree
if [ -z "$ISO_PATH" ]; then
  ISO_PATH=$(find result -name "*.iso" -type f 2>/dev/null | head -1)
fi

# Final sanity: ensure the path exists
if [ -n "$ISO_PATH" ] && [ ! -e "$ISO_PATH" ]; then
  # Sometimes the isoImage derivation produces a store dir with .iso suffix.
  # If that path does not exist for some reason, fall back to searching under the dereferenced result.
  if [ -L "result" ]; then
    ALT_TARGET=$(readlink -f result 2>/dev/null | tr -d '\n' || true)
    if [ -d "$ALT_TARGET" ]; then
      CANDIDATE=$(find "$ALT_TARGET" -maxdepth 2 -name "*.iso" -type f 2>/dev/null | head -1)
      if [ -n "$CANDIDATE" ]; then
        ISO_PATH="$CANDIDATE"
      fi
    fi
  fi
fi

if [ -z "$ISO_PATH" ]; then
  echo "ERROR: Could not find ISO file" >&2
  echo "DEBUG: Tried:" >&2
  echo "  - result/iso/*.iso" >&2
  echo "  - hydra-build-products path" >&2
  echo "  - recursive search in result/" >&2
  echo "DEBUG: result structure:" >&2
  find result -type f 2>&1 | head -20 >&2
  exit 1
fi

echo "Preparing iso-output/ (removing previous ISO files)..."
find /workspace/iso-output -maxdepth 1 -type f -name "*.iso" -print -exec rm -f {} + 2>/dev/null || true

echo "Transferring ISO to workspace..."
if [ -d "$ISO_PATH" ]; then
  INNER_ISO=$(find "$ISO_PATH" -maxdepth 2 -name "*.iso" -type f 2>/dev/null | head -1)
  if [ -n "$INNER_ISO" ]; then
    cp -v "$INNER_ISO" /workspace/iso-output/
    echo "ISO copied to iso-output/ from store directory"
  else
    echo "ERROR: ISO directory found but no .iso file inside: $ISO_PATH" >&2
    exit 1
  fi
elif [ -f "$ISO_PATH" ]; then
  if mv -v "$ISO_PATH" /workspace/iso-output/ 2>/dev/null; then
    echo "ISO moved to iso-output/"
  else
    cp -v "$ISO_PATH" /workspace/iso-output/
    echo "ISO copied to iso-output/ (source in nix store retained)"
  fi
else
  echo "ERROR: ISO path is neither file nor directory: $ISO_PATH" >&2
  exit 1
fi

NEW_HASH=$(calc_source_hash || echo "unknown")
if [ -n "$NEW_HASH" ] && [ "$NEW_HASH" != "unknown" ]; then
  echo "$NEW_HASH" > "$STAMP_FILE" 2>/dev/null || true
fi

if [ "${EASYOS_EXPORT_ARTIFACTS:-}" = "true" ] && [ -n "${EASYOS_ARTIFACTS_DIR:-}" ]; then
  ARTIFACT_DIR="${EASYOS_ARTIFACTS_DIR%/}"
  mkdir -p "$ARTIFACT_DIR"
  find "$ARTIFACT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

  BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ISO_BASENAME=$(basename "$ISO_PATH" 2>/dev/null || echo "unknown.iso")
  ISO_BYTES=$(stat -c %s "$ISO_PATH" 2>/dev/null || echo "unknown")
  ISO_SIZE_HUMAN=$(du -h "$ISO_PATH" 2>/dev/null | head -1 | cut -f1 || echo "unknown")
  RESULT_PATH=$(readlink -f result 2>/dev/null || true)
  SYSTEM_TOPLEVEL=$(nix eval --raw '.#nixosConfigurations.iso.config.system.build.toplevel' 2>/dev/null || true)

  {
    echo "Build time (UTC): $BUILD_TIME"
    echo "ISO filename: $ISO_BASENAME"
    echo "ISO size: ${ISO_SIZE_HUMAN} (${ISO_BYTES} bytes)"
    echo "Workspace hash: ${NEW_HASH:-unknown}"
    echo "Result store path: ${RESULT_PATH:-unknown}"
    echo "System toplevel: ${SYSTEM_TOPLEVEL:-unknown}"
  } > "$ARTIFACT_DIR/build-info.txt"

  if [ -n "$RESULT_PATH" ] && [ -e "$RESULT_PATH" ]; then
    nix path-info --json "$RESULT_PATH" > "$ARTIFACT_DIR/result-path-info.json" 2>/dev/null || true
    nix-store -q --tree "$RESULT_PATH" > "$ARTIFACT_DIR/result-tree.txt" 2>/dev/null || true
    nix-store -q --references "$RESULT_PATH" > "$ARTIFACT_DIR/result-references.txt" 2>/dev/null || true
    nix-store -q --requisites "$RESULT_PATH" > "$ARTIFACT_DIR/result-closure.txt" 2>/dev/null || true
  fi

  DRV_PATH=$(nix path-info --derivation result 2>/dev/null || true)
  if [ -n "$DRV_PATH" ]; then
    if nix log "$DRV_PATH" > "$ARTIFACT_DIR/nix-build.log" 2>/dev/null; then
      :
    else
      rm -f "$ARTIFACT_DIR/nix-build.log" 2>/dev/null || true
    fi
  fi

  INSTALLER_SRC=$(nix eval --raw '.#nixosConfigurations.iso.config.environment.etc."easyos-install.sh".source' 2>/dev/null || true)
  if [ -n "$INSTALLER_SRC" ] && [ -f "$INSTALLER_SRC" ]; then
    cp "$INSTALLER_SRC" "$ARTIFACT_DIR/easyos-install.sh"
    chmod 0755 "$ARTIFACT_DIR/easyos-install.sh" 2>/dev/null || true
  fi

  cp /workspace/flake.nix "$ARTIFACT_DIR/flake.nix.snapshot" 2>/dev/null || true
  if [ -f /workspace/flake.lock ]; then
    cp /workspace/flake.lock "$ARTIFACT_DIR/flake.lock.snapshot" 2>/dev/null || true
  fi

  chmod -R a+r "$ARTIFACT_DIR" 2>/dev/null || true
fi
EOS

  BUILD_EXIT=$?
  if [ $BUILD_EXIT -eq 0 ]; then
    BUILD_PERFORMED=true
  fi
fi
echo ""

if [ $BUILD_EXIT -ne 0 ]; then
  echo ""
  echo "ERROR: ISO build failed with exit code $BUILD_EXIT"
  echo "Check the output above for details."
  exit $BUILD_EXIT
fi

if [ $BUILD_EXIT -eq 0 ]; then
  FINAL_HASH=""
  if [ -f "$STAMP_FILE" ]; then
    FINAL_HASH=$(<"$STAMP_FILE") || FINAL_HASH=""
  fi
  # ISO should now be in iso-output/
  ISO=$(find iso-output -name "*.iso" -type f 2>/dev/null | head -1)
  
  if [ -n "$ISO" ]; then
    SIZE=$(du -h "$ISO" | cut -f1)
    echo ""
    if [ "$BUILD_PERFORMED" = true ]; then
      echo "✓ ISO built successfully!"
    else
      echo "✓ ISO already up to date (no rebuild needed)."
    fi
    echo "  Location: $ISO"
    echo "  Size: $SIZE"
    echo ""
    # Persist current source hash stamp for rebuild detection on next run
    if [ -n "$FINAL_HASH" ]; then
      echo "$FINAL_HASH" > "$ISO_OUTPUT_DIR/.easyos-source-hash" 2>/dev/null || true
    fi
    
    # Ventoy auto-copy
    if [ "$VENTOY_COPY" = true ]; then
      echo "Searching for Ventoy USB drives..."
      VENTOY_MOUNT=""
      
      # Portable scan for Ventoy mount without process substitution (works in strict shells)
      # 1) Try to find a mountpoint with "ventoy" in its path from the mount table
      VENTOY_MOUNT=$(mount | cut -d' ' -f3 | grep -i ventoy | head -1)
      # 2) If not found, probe common removable media roots
      if [ -z "$VENTOY_MOUNT" ]; then
        for d in /run/media/*/* /media/* /mnt/*; do
          [ -d "$d" ] || continue
          basename_lower=$(basename "$d" | tr '[:upper:]' '[:lower:]')
          if [[ "$basename_lower" == *"ventoy"* ]] || [ -d "$d/ventoy" ] || [ -d "$d/Ventoy" ]; then
            VENTOY_MOUNT="$d"
            break
          fi
        done
      fi
      
      if [ -n "$VENTOY_MOUNT" ]; then
        ISO_NAME="easyos-$(date +%Y%m%d-%H%M).iso"
        DEST_FILE="$VENTOY_MOUNT/$ISO_NAME"
        
        echo "Found Ventoy at: $VENTOY_MOUNT"
        echo "Copying ISO to: $DEST_FILE"
        
        # Copy to Ventoy (keep local ISO in iso-output for reuse)
        if cp -v "$ISO" "$DEST_FILE" 2>/dev/null; then
          sync
          echo ""
          echo "✓ ISO copied to Ventoy USB!"
          echo "  Location: $DEST_FILE"
          echo "  You can now safely eject the USB and boot from it."
          echo ""
        else
          echo "WARNING: Failed to copy ISO (permission denied?)"
          echo "  Try: sudo cp \"$ISO\" \"$DEST_FILE\""
          exit 1
        fi
      else
        echo "WARNING: No Ventoy USB drive detected."
        echo "  Checked all mounted filesystems for 'Ventoy' in path or ventoy/Ventoy subdirectory"
        echo "  The ISO is available at: $ISO"
        echo ""
        echo "  Manual copy: cp \"$ISO\" /path/to/ventoy/ISOs/"
        echo ""
      fi
    fi
    
    echo "Next steps:"
    if [ "$VENTOY_COPY" = false ]; then
      echo "  1. Copy to Ventoy USB:"
      echo "     cp $ISO /run/media/\$USER/Ventoy/"
      echo ""
      echo "  2. Or write to USB:"
      echo "     sudo dd if=$ISO of=/dev/sdX bs=4M status=progress oflag=sync conv=fsync"
      echo ""
      echo "  3. Or test in VM:"
    else
      echo "  1. Eject Ventoy USB and boot from it"
      echo ""
      echo "  2. Or test in VM first:"
    fi
    echo "     $0 --vm"
    echo ""
    echo "  Inside the booted ISO, run: sudo /etc/easyos-install.sh"
    if [ "$EXPORT_ARTIFACTS" = true ] && [ "$VM_UPDATE" = false ] && [ "$BUILD_PERFORMED" = true ]; then
      echo ""
      echo "Artifacts exported to: $ARTIFACTS_DIR_HOST"
      echo "  Includes: installer script, build metadata, nix logs"
    fi
  else
    echo "ERROR: ISO file not found in iso-output/" >&2
    exit 1
  fi
else
  echo "ERROR: ISO build failed" >&2
  exit 1
fi

# Launch VM if requested (fresh install from ISO)
if [ "$VM_TEST" = true ]; then
  if [ -z "${ISO:-}" ]; then
    ISO=$(find iso-output -name "*.iso" -type f 2>/dev/null | head -1)
  fi
  
  if [ -z "$ISO" ]; then
    echo "ERROR: No ISO found to test. Build first without --vm flag." >&2
    exit 1
  fi
  
  # Check available RAM
  TOTAL_RAM=$(free -m | grep '^Mem:' | tr -s ' ' | cut -d' ' -f2)
  AVAILABLE_RAM=$(free -m | grep '^Mem:' | tr -s ' ' | cut -d' ' -f7)
  VM_RAM=8192  # 8GB for VM
  REQUIRED_HOST_RAM=8192  # 8GB minimum for host
  REQUIRED_TOTAL=$((VM_RAM + REQUIRED_HOST_RAM))
  
  echo ""
  echo "Memory check:"
  echo "  Total RAM: $((TOTAL_RAM / 1024)) GB"
  echo "  Available RAM: $((AVAILABLE_RAM / 1024)) GB"
  echo "  VM allocation: 8 GB"
  echo "  Required for host: 8 GB"
  
  if [ "$TOTAL_RAM" -lt "$REQUIRED_TOTAL" ]; then
    echo ""
    echo "WARNING: System has only $((TOTAL_RAM / 1024)) GB total RAM."
    echo "  Allocating 8 GB to VM may leave insufficient RAM for host."
    echo "  Using 4 GB for VM instead."
    VM_RAM=4096
  fi
  
  VM_DISK="/tmp/easyos-test.img"
  
  echo ""
  echo "================================================================"
  echo "                   Launching QEMU VM                            "
  echo "================================================================"
  echo ""
  
  # Reuse existing disk if ISO hasn't changed and disk exists with reasonable size
  # A disk < 500MB is probably not installed yet (fresh qcow2 is ~200KB)
  REUSE_DISK=false
  if [ -f "$VM_DISK" ]; then
    DISK_SIZE=$(stat -c %s "$VM_DISK" 2>/dev/null || echo 0)
    DISK_SIZE_MB=$((DISK_SIZE / 1024 / 1024))
    if [ "$DISK_SIZE_MB" -gt 500 ] && [ "$BUILD_PERFORMED" = false ]; then
      echo "Reusing existing VM disk ($DISK_SIZE_MB MB) - ISO unchanged"
      REUSE_DISK=true
    else
      echo "Removing existing VM disk (ISO was rebuilt or disk is fresh)"
      rm -f "$VM_DISK"
    fi
  fi
  
  if [ "$REUSE_DISK" = false ]; then
    echo "Creating test disk: $VM_DISK"
    qemu-img create -f qcow2 "$VM_DISK" 20G
  fi
  
  echo ""
  echo "Starting VM with:"
  echo "  ISO: $ISO"
  echo "  RAM: $((VM_RAM / 1024))GB"
  echo "  Disk: $VM_DISK"
  echo ""
  echo "Press Ctrl+Alt+G to release mouse cursor"
  echo "To exit: Close window or press Ctrl+C in terminal"
  echo ""
  sleep 2
  
  # Prefer UEFI boot (systemd-boot). Detect common OVMF paths.
  OVMF_CODE=""
  OVMF_VARS=""
  for p in \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/x64/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do
    [ -f "$p" ] && OVMF_CODE="$p" && break
  done
  for p in \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/x64/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd; do
    [ -f "$p" ] && OVMF_VARS="$p" && break
  done

  # Boot order: if reusing disk (installed system), boot from disk; otherwise boot from ISO
  BOOT_ORDER="d"  # d = CD-ROM first (for fresh install)
  CDROM_ARGS="-cdrom $ISO"
  if [ "$REUSE_DISK" = true ]; then
    BOOT_ORDER="c"  # c = hard disk first (for installed system)
    CDROM_ARGS=""   # Don't attach ISO for installed system boot
    echo "Booting from installed disk (no ISO attached)"
  else
    echo "Booting from ISO for fresh install"
  fi

  if [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    OVMF_VARS_RW="/tmp/OVMF_VARS.easyos.fd"
    # Reuse OVMF vars if disk is being reused (preserves boot entries)
    if [ "$REUSE_DISK" = true ] && [ -f "$OVMF_VARS_RW" ]; then
      echo "Reusing UEFI NVRAM state"
    else
      cp "$OVMF_VARS" "$OVMF_VARS_RW" 2>/dev/null || true
    fi
    echo "Using UEFI firmware: $OVMF_CODE"
    qemu-system-x86_64 \
      -machine type=q35,accel=kvm \
      -cpu host \
      -smp 2 \
      -m "$VM_RAM" \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$OVMF_VARS_RW" \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      $CDROM_ARGS \
      -boot $BOOT_ORDER \
      -net nic,model=virtio \
      -net user,hostfwd=tcp::8088-:8088
  else
    echo "WARNING: Could not find OVMF (UEFI) firmware on host. Falling back to BIOS (GRUB required)."
    qemu-system-x86_64 \
      $CDROM_ARGS \
      -m "$VM_RAM" \
      -enable-kvm \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      -cpu host \
      -smp 2 \
      -boot "$BOOT_ORDER" \
      -net nic,model=virtio \
      -net user,hostfwd=tcp::8088-:8088
  fi
    
  echo ""
  echo "VM closed. Test disk remains at: $VM_DISK"
  echo "To restart VM: qemu-system-x86_64 -drive file=$VM_DISK,format=qcow2,if=virtio -m $VM_RAM -enable-kvm -cpu host"
  echo "To update the VM with latest flake changes: $0 --update-vm"
fi

# Update existing VM disk with latest flake changes
if [ "$VM_UPDATE" = true ]; then
  VM_DISK="/tmp/easyos-test.img"
  
  if [ ! -f "$VM_DISK" ]; then
    echo "ERROR: VM disk not found at $VM_DISK"
    echo "Run '$0 --vm' first to create an installed VM, then use --update-vm to sync changes."
    exit 1
  fi
  
  # Check if QEMU is actually running with this disk
  if pgrep -f "qemu.*easyos-test.img" >/dev/null 2>&1; then
    echo ""
    echo "================================================================"
    echo "         VM Already Running                                     "
    echo "================================================================"
    echo ""
    echo "The VM at $VM_DISK is already in use."
    echo ""
    echo "Options:"
    echo "  1. Close the existing VM window and run this command again"
    echo "  2. Or access the running VM directly:"
    echo "     - Web UI: http://localhost:8088/ (if port forwarding is active)"
    echo "     - Console: Switch to the QEMU window"
    echo ""
    echo "To update the running VM:"
    echo "  - Use the web UI to edit config and click 'Save & Apply'"
    echo "  - Or SSH/console: cd /etc/nixos/easyos && git pull && nixos-rebuild switch --impure --flake .#easyos"
    echo ""
    exit 1
  fi
  
  # Clean up any stale lock files
  LOCK_FILE="$VM_DISK.lock"
  if [ -f "$LOCK_FILE" ]; then
    echo "Removing stale lock file: $LOCK_FILE"
    rm -f "$LOCK_FILE"
  fi
  
  echo ""
  echo "================================================================"
  echo "         Updating Existing VM with Latest Flake                "
  echo "================================================================"
  echo ""
  echo "VM Disk: $VM_DISK"
  echo ""
  echo "This will:"
  echo "  1. Mount the VM disk"
  echo "  2. Sync the current flake to /mnt/etc/nixos/easyos"
  echo "  3. Boot the VM so you can apply changes via the web UI"
  echo ""
  
  # Mount the VM disk
  MOUNT_DIR=$(mktemp -d)
  
  echo "Mounting VM disk..."
  # Simplify: proceed with manual sync flow to avoid host tooling differences
  # Optional optimization with virt-copy-in can be re-enabled later
  if command -v virt-copy-in >/dev/null 2>&1; then
    echo "Note: virt-copy-in detected; manual flow used for portability."
  fi
  SYNC_METHOD="manual"
  
  # Now boot the VM
  echo ""
  echo "Booting VM..."
  if [ "$SYNC_METHOD" = "manual" ]; then
    echo ""
    echo "==================================================================="
    echo "Manual sync required:"
    echo "  1. SSH into the VM or use the console"
    echo "  2. Run: cd /etc/nixos/easyos && git pull"
    echo "  3. Or use the web UI at http://localhost:8088/ to edit & apply"
    echo "==================================================================="
  else
    echo "Web UI available at http://localhost:8088/"
    echo "Click 'Save & Apply' to rebuild with latest changes."
  fi
  echo ""
  sleep 2
  
  # Detect OVMF and boot
  OVMF_CODE=""
  OVMF_VARS=""
  for p in \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/x64/OVMF_CODE.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd; do
    [ -f "$p" ] && OVMF_CODE="$p" && break
  done
  for p in \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/x64/OVMF_VARS.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd; do
    [ -f "$p" ] && OVMF_VARS="$p" && break
  done

  if [ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ]; then
    OVMF_VARS_RW="/tmp/OVMF_VARS.easyos-update.fd"
    # Reuse existing OVMF_VARS if present from previous boots
    [ -f "/tmp/OVMF_VARS.easyos.fd" ] && cp "/tmp/OVMF_VARS.easyos.fd" "$OVMF_VARS_RW" || cp "$OVMF_VARS" "$OVMF_VARS_RW"
    
    qemu-system-x86_64 \
      -machine type=q35,accel=kvm \
      -cpu host \
      -smp 2 \
      -m 8192 \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$OVMF_VARS_RW" \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      -net nic,model=virtio \
      -net user,hostfwd=tcp::8088-:8088
  else
    echo "WARNING: OVMF not found. Falling back to BIOS boot."
    qemu-system-x86_64 \
      -m 8192 \
      -enable-kvm \
      -drive file="$VM_DISK",format=qcow2,if=virtio \
      -cpu host \
      -smp 2 \
      -net nic,model=virtio \
      -net user,hostfwd=tcp::8088-:8088
  fi
  
  echo ""
  echo "VM closed."
fi
 
