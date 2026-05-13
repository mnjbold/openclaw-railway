#!/bin/bash
set -e

# ==============================================================================
# OpenClaw Railway Template - Entrypoint Script
# Handles Railway PORT binding and graceful startup
# ==============================================================================

# ------------------------------------------------------------------------------
# PHASE 1: Quick synchronous setup (must complete before server starts)
# ------------------------------------------------------------------------------

# Ensure /data mount point exists
mkdir -p /data || true

# Decode base64-encoded helper scripts
echo "[entrypoint] Starting decode of helper scripts..."
if [ -n "$GIT_SYNC_B64" ]; then
    printf "%s" "$GIT_SYNC_B64" | base64 -d > /data/git-sync.js || true
    chmod 644 /data/git-sync.js || true
    echo "[entrypoint] git-sync.js decoded and chmod'd"
fi
if [ -n "$ADMIN_SKILL_B64" ]; then
    mkdir -p /data/.openclaw/state/skills
    printf "%s" "$ADMIN_SKILL_B64" | base64 -d > /data/.openclaw/state/skills/openclaw-admin.md || true
fi
# Decode and run Infisical boot script (pulls secrets from vault at startup)
if [ -n "$INFISICAL_BOOT_B64" ]; then
    echo "[entrypoint] Decoding Infisical boot script..."
    printf "%s" "$INFISICAL_BOOT_B64" | base64 -d > /data/infisical-boot.sh || true
    chmod +x /data/infisical-boot.sh || true
    bash /data/infisical-boot.sh || echo "[entrypoint] Infisical boot script failed (non-fatal)"
    echo "[entrypoint] Infisical boot complete"
fi

# Railway provides PORT environment variable
if [ -n "$PORT" ]; then
    echo "Railway environment detected"
    echo "Binding wrapper server to port $PORT"

    # Show available access points if private networking is available
    if [ -n "$RAILWAY_PRIVATE_DOMAIN" ]; then
        echo ""
        echo "Service accessible at:"
        echo "  - Public: via your Railway public domain"
        echo "  - Private: http://$RAILWAY_PRIVATE_DOMAIN:$PORT"
        echo ""
        echo "IMPORTANT: Always include :$PORT when connecting via private networking!"
        echo ""
    fi
else
    # Fallback for local development
    export PORT=8080
    echo "Local development mode"
    echo "Using default port $PORT"
fi

# Ensure Playwright browser is accessible by openclaw user
if [ -d "/ms-playwright" ]; then
    chmod -R o+rx /ms-playwright 2>/dev/null || true
fi

# Ensure data directories exist with correct permissions
mkdir -p "$OPENCLAW_STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" "$OPENCLAW_WORKSPACE_DIR/memory" "$OPENCLAW_STATE_DIR/workspace/memory"
chmod 700 "$OPENCLAW_STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" 2>/dev/null || true

# Create symlinks from openclaw home into the persistent volume
# so $HOME/.openclaw resolves to /data/.openclaw and tool data persists
ln -sfn "$OPENCLAW_STATE_DIR" /home/openclaw/.openclaw
mkdir -p /data/.local /data/.npm
ln -sfn /data/.local /home/openclaw/.local
ln -sfn /data/.npm /home/openclaw/.npm
chown -h openclaw:openclaw /home/openclaw/.openclaw /home/openclaw/.local /home/openclaw/.npm 2>/dev/null || true
chown openclaw:openclaw /data/.local /data/.npm 2>/dev/null || true

# ------------------------------------------------------------------------------
# Install OpenCLAW OS dashboard plugin from bundled image artifacts
# https://github.com/thesysdev/openclaw-os
# Plugin is pre-built in Docker image Stage 1b, copied to /bundled-plugins/openclaw-os
# Registered with OpenCLAW on first boot, persisted to /data volume
# ------------------------------------------------------------------------------
PLUGIN_SRC="/bundled-plugins/openclaw-os"
PLUGIN_DST="$OPENCLAW_STATE_DIR/openui/openclaw-os/packages/claw-plugin"
if [ -d "$PLUGIN_SRC/dist" ] && [ -d "$PLUGIN_SRC/static" ]; then
    if [ ! -f "$PLUGIN_DST/dist/index.js" ]; then
        echo "[entrypoint] Installing OpenCLAW OS dashboard plugin..."
        mkdir -p "$(dirname "$PLUGIN_DST")"
        cp -r "$PLUGIN_SRC" "$PLUGIN_DST"
        chown -R openclaw:openclaw "$OPENCLAW_STATE_DIR/openui" 2>/dev/null || true

        # Register plugin with OpenCLAW CLI if config exists
        if [ -f "$OPENCLAW_STATE_DIR/openclaw.json" ]; then
            openclaw plugins install "$PLUGIN_DST" --force 2>&1 || \
                echo "[entrypoint] Plugin CLI registration deferred to gateway start"

            # Ensure plugin tools are accessible (patch tools.alsoAllow if restrictive profile)
            node -e "
              const fs = require('fs'), f = process.argv[1];
              try {
                const c = JSON.parse(fs.readFileSync(f, 'utf8'));
                const p = c.tools && c.tools.profile || '';
                const a = c.tools && c.tools.alsoAllow || [];
                if (p && p !== 'full' && !a.includes('group:plugins')) {
                  c.tools = c.tools || {};
                  c.tools.alsoAllow = a.concat(['group:plugins']);
                  fs.writeFileSync(f, JSON.stringify(c, null, 2));
                  console.log('[entrypoint] Added group:plugins to tools.alsoAllow');
                }
              } catch(e) { /* config parse error, skip */ }
            " "$OPENCLAW_STATE_DIR/openclaw.json" 2>/dev/null || true
        fi
        echo "[entrypoint] OpenCLAW OS dashboard plugin installed"
    else
        echo "[entrypoint] OpenCLAW OS dashboard plugin already installed"
    fi
else
    echo "[entrypoint] OpenCLAW OS plugin not bundled in image, skipping"
fi

# Log startup info
echo ""
echo "OpenClaw Railway Template"
echo "========================"
echo "State directory: $OPENCLAW_STATE_DIR"
echo "Workspace directory: $OPENCLAW_WORKSPACE_DIR"
echo "Internal gateway port: $INTERNAL_GATEWAY_PORT"
echo "External port: $PORT"
if [ -d "/ms-playwright" ] && [ -n "$(ls /ms-playwright 2>/dev/null)" ]; then
    echo "Browser: Chromium (Playwright) available"
else
    echo "Browser: Not available"
fi
if [ -f "$PLUGIN_DST/dist/index.js" ]; then
    echo "OpenCLAW OS: installed (dashboard at /plugins/openclawos)"
else
    echo "OpenCLAW OS: not installed"
fi
echo ""

# ------------------------------------------------------------------------------
# PHASE 2: Background maintenance (expensive operations, non-blocking)
# Runs concurrently with the server so /health responds immediately.
# ------------------------------------------------------------------------------

(
    # Resolve npm prefix variables needed by seed_persistent_openclaw
    NPM_PREFIX="${NPM_CONFIG_PREFIX:-/data/.npm-global}"
    NPM_MODULE_DIR="$NPM_PREFIX/lib/node_modules/openclaw"
    NPM_ENTRY="$NPM_MODULE_DIR/dist/entry.js"
    NPM_BIN_DIR="$NPM_PREFIX/bin"
    NPM_BIN="$NPM_BIN_DIR/openclaw"
    BAKED_MODULE_DIR="/usr/local/lib/node_modules/openclaw"
    BAKED_ENTRY="$BAKED_MODULE_DIR/dist/entry.js"
    SEED_MARKER="$NPM_PREFIX/.openclaw-seeded-version"

    mkdir -p "$NPM_PREFIX" || true

    # Fix ownership of /data volume (Railway mounts volumes as root).
    # Runs first so subsequent operations by the openclaw user succeed.
    # Skips node_modules trees to avoid touching thousands of files.
    if [ "$(id -u)" = "0" ]; then
        echo "[background] Fixing /data ownership (shallow pass)..."
        find /data -maxdepth 2 -not -path "*/node_modules/*" -exec chown openclaw:openclaw {} + 2>/dev/null || true
        echo "[background] Shallow ownership fix complete; starting deep pass..."
        find /data -not -path "*/node_modules/*" -exec chown openclaw:openclaw {} + 2>/dev/null || true
        echo "[background] Deep ownership fix complete"
    fi

    # Seed the persistent npm prefix from the Docker-baked install on first boot.
    # If the prefix was auto-seeded previously and still matches that seeded
    # version, refresh it on redeploys so new image versions become active.
    # If the runtime version differs from the seed marker, treat it as user-managed
    # and leave it alone.
    SEEDED_NPM_PREFIX="false"
    BAKED_VERSION="$(node -e "try{const p=require(process.argv[1]);process.stdout.write(p.version||'')}catch{}" "$BAKED_MODULE_DIR/package.json")"
    RUNTIME_VERSION=""
    SEEDED_VERSION=""

    seed_persistent_openclaw() {
        local temp_module_dir="$NPM_PREFIX/lib/node_modules/.openclaw-seed-$$"
        local temp_bin="$NPM_BIN_DIR/.openclaw-seed-bin-$$"
        local backup_module_dir="$NPM_PREFIX/lib/node_modules/.openclaw-backup-$$"
        local backup_bin="$NPM_BIN_DIR/.openclaw-backup-bin-$$"

        mkdir -p "$NPM_PREFIX/lib/node_modules" "$NPM_BIN_DIR"
        rm -rf "$temp_module_dir" "$backup_module_dir"
        rm -f "$temp_bin" "$backup_bin"

        if ! cp -a "$BAKED_MODULE_DIR" "$temp_module_dir"; then
            rm -rf "$temp_module_dir"
            rm -f "$temp_bin"
            return 1
        fi

        if ! cat > "$temp_bin" <<'EOF'
#!/bin/bash
PREFIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$PREFIX_DIR/lib/node_modules/openclaw/dist/entry.js" "$@"
EOF
        then
            rm -rf "$temp_module_dir"
            rm -f "$temp_bin"
            return 1
        fi

        if ! chmod +x "$temp_bin"; then
            rm -rf "$temp_module_dir"
            rm -f "$temp_bin"
            return 1
        fi

        if [ -e "$NPM_MODULE_DIR" ] && ! mv "$NPM_MODULE_DIR" "$backup_module_dir"; then
            rm -rf "$temp_module_dir"
            rm -f "$temp_bin"
            return 1
        fi

        if [ -e "$NPM_BIN" ] && ! mv "$NPM_BIN" "$backup_bin"; then
            if [ -e "$backup_module_dir" ]; then
                mv "$backup_module_dir" "$NPM_MODULE_DIR" || true
            fi
            rm -rf "$temp_module_dir"
            rm -f "$temp_bin"
            return 1
        fi

        if mv "$temp_module_dir" "$NPM_MODULE_DIR" && mv "$temp_bin" "$NPM_BIN"; then
            if ! printf '%s\n' "$BAKED_VERSION" > "$SEED_MARKER"; then
                echo "WARNING: Failed to write OpenClaw seed marker at $SEED_MARKER" >&2
            fi
            rm -rf "$backup_module_dir"
            rm -f "$backup_bin"
            return 0
        fi

        rm -rf "$NPM_MODULE_DIR"
        rm -f "$NPM_BIN"
        if [ -e "$backup_module_dir" ]; then
            mv "$backup_module_dir" "$NPM_MODULE_DIR" || true
        fi
        if [ -e "$backup_bin" ]; then
            mv "$backup_bin" "$NPM_BIN" || true
        fi
        rm -rf "$temp_module_dir"
        rm -f "$temp_bin"
        return 1
    }

    if [ -f "$NPM_MODULE_DIR/package.json" ]; then
        RUNTIME_VERSION="$(node -e "try{const p=require(process.argv[1]);process.stdout.write(p.version||'')}catch{}" "$NPM_MODULE_DIR/package.json")"
    fi
    if [ -f "$SEED_MARKER" ]; then
        SEEDED_VERSION="$(tr -d '\n' < "$SEED_MARKER")"
    fi

    SEED_ACTION=""
    if [ ! -f "$NPM_ENTRY" ] && [ -f "$BAKED_ENTRY" ]; then
        echo "[background] Seeding persistent OpenClaw install into $NPM_PREFIX"
        SEED_ACTION="seed"
    elif [ -f "$NPM_ENTRY" ] && [ -n "$BAKED_VERSION" ] && [ -n "$SEEDED_VERSION" ] && [ "$RUNTIME_VERSION" = "$SEEDED_VERSION" ] && [ "$RUNTIME_VERSION" != "$BAKED_VERSION" ]; then
        echo "[background] Refreshing auto-seeded OpenClaw install to baked version $BAKED_VERSION"
        SEED_ACTION="refresh"
    fi

    if [ -n "$SEED_ACTION" ] && [ -f "$BAKED_ENTRY" ]; then
        if seed_persistent_openclaw; then
            SEEDED_NPM_PREFIX="true"
            echo "[background] OpenClaw $SEED_ACTION complete"
        else
            echo "[background] WARNING: Failed to $SEED_ACTION persistent OpenClaw install; falling back to Docker-baked runtime" >&2
        fi
    fi

    if [ "$SEEDED_NPM_PREFIX" = "true" ] && [ "$(id -u)" = "0" ]; then
        chown -R openclaw:openclaw "$NPM_PREFIX" 2>/dev/null || true
    fi

    # Sync pre-bundled skills into the skills directory.
    # Always overwrites bundled skill files to ensure Railway-aware instructions
    # are current (e.g. replaces upstream SKILL.md that references localhost
    # with our $SEARXNG_URL version).
    SKILLS_DIR="$OPENCLAW_STATE_DIR/skills"
    if [ -d "/bundled-skills" ]; then
        mkdir -p "$SKILLS_DIR" || true
        for skill_dir in /bundled-skills/*/; do
            skill_name=$(basename "$skill_dir")
            cp -r "$skill_dir" "$SKILLS_DIR/$skill_name" || true
            echo "[background] Synced bundled skill: $skill_name"
        done
    fi

    echo "[background] Volume maintenance complete"
) &

# ------------------------------------------------------------------------------
# PHASE 3: Start the Node.js server immediately
# exec replaces this shell so signals are forwarded directly to Node.js.
# ------------------------------------------------------------------------------

if [ "$(id -u)" = "0" ]; then
    exec su -s /bin/bash openclaw -c "exec node /app/src/server.js"
else
    exec node /app/src/server.js
fi
