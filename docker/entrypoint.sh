#!/bin/bash
set -euo pipefail

echo "Starting Hunyuan3D-2.1 deployment..."

# Optional: pass space-separated repo IDs via env so you can change without rebuilds
: "${HUNYUAN_REPOS:=}"  # e.g. "Tencent/Hunyuan3D-2.1 Tencent/Hunyuan3D-Shape-v2-1 Tencent/Hunyuan3D-Paint-v2-1"
: "${HF_TOKEN:=}"
: "${PORT:=8080}"

echo "Creating data directories..."
mkdir -p /data/ckpt /data/hf /data/.cache /data/torch /data/gradio_cache /data/models /data/hy3dgen

# Create symlinks to redirect caches to persistent volume
echo "Setting up cache redirects..."
mkdir -p /root/.cache
rm -rf /root/.cache/hy3dgen 2>/dev/null || true
ln -sf /data/hy3dgen /root/.cache/hy3dgen

# Also redirect other HuggingFace cache locations
rm -rf /root/.cache/huggingface 2>/dev/null || true  
ln -sf /data/hf /root/.cache/huggingface

# Symlinks (defensive if Dockerfile is adjusted later)
echo "Setting up symlinks..."
[ -L /app/hy3dpaint/ckpt ] || { rm -rf /app/hy3dpaint/ckpt; ln -s /data/ckpt /app/hy3dpaint/ckpt; }

# Download RealESRGAN model in background to not block startup
if [ ! -f /data/models/RealESRGAN_x4plus.pth ]; then
  echo "Downloading RealESRGAN model in background..."
  (
    mkdir -p /data/models
    curl -L -o /data/models/RealESRGAN_x4plus.pth \
      https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth || true
  ) &
fi
ln -sf /data/models/RealESRGAN_x4plus.pth /app/hy3dpaint/ckpt/RealESRGAN_x4plus.pth || true

# Download HF repos in background to not block startup
if [ -n "${HUNYUAN_REPOS}" ]; then
  echo "Downloading HuggingFace models in background..."
  (
    python - <<'PY'
import os
from huggingface_hub import snapshot_download

repos = os.environ.get("HUNYUAN_REPOS","").split()
token = os.environ.get("HF_TOKEN") or None
base = "/data/ckpt"

for r in repos:
    dest = os.path.join(base, r.replace("/", "__"))
    if not os.path.exists(dest) or not os.listdir(dest):
        print(f"Downloading {r} -> {dest}")
        try:
            snapshot_download(repo_id=r, local_dir=dest, local_dir_use_symlinks=False, token=token)
        except Exception as e:
            print(f"Failed to download {r}: {e}")
    else:
        print(f"Already present: {r}")
PY
  ) &
fi

# Check if dependencies are actually working, not just marked as installed
deps_working=false
if [ -f /data/.deps_installed ]; then
  echo "Checking if previously installed dependencies are working..."
  if PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import torch, gradio, xatlas, rembg, timm; print('Dependencies verified')" 2>/dev/null; then
    deps_working=true
    echo "Dependencies are working correctly."
  else
    echo "Dependencies marked as installed but not working, reinstalling..."
    rm -f /data/.deps_installed /data/.installing
  fi
fi

# Install essential dependencies for startup, defer others to background
if [ "$deps_working" != "true" ]; then
  # Check if there's a stuck installation from before
  if [ -f /data/.installing ]; then
    echo "Previous installation was interrupted, cleaning up..."
    rm -f /data/.installing
    pkill -f pip || true
    sleep 2
  fi
  
  echo "Installing minimal dependencies for startup..."
  
  # Create pip directories on persistent volume
  mkdir -p /data/pip-cache /data/pip-tmp
  export TMPDIR=/data/pip-tmp
  export PIP_CACHE_DIR=/data/pip-cache
  
  # Install only essential packages for basic functionality to persistent volume  
  pip install gradio fastapi uvicorn --cache-dir /data/pip-cache --target /data/python-packages || true
  
  # Mark that we're installing
  touch /data/.installing
  
  # Start background installation with better error handling
  echo "Starting background dependency installation..."
  (
    # Use persistent volume for ALL pip operations to avoid space issues
    mkdir -p /data/pip-cache /data/pip-tmp /data/python-packages
    export TMPDIR=/data/pip-tmp
    export PIP_CACHE_DIR=/data/pip-cache
    export PYTHONPATH="/data/python-packages:${PYTHONPATH:-}"
    
    # Check available space
    echo "Available space on /data:"
    df -h /data
    echo "Available space on root:"
    df -h /
    
    # Aggressive cleanup
    rm -rf /data/pip-tmp/* /tmp/* /var/tmp/* || true
    
    # Install packages to persistent volume to save container space
    PIP_TARGET="/data/python-packages"
    
    echo "Background: Installing PyTorch to persistent volume..."
    if pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124 --timeout 1800 --cache-dir /data/pip-cache --target $PIP_TARGET 2>&1; then
      echo "PyTorch installation to persistent volume completed successfully"
    else
      echo "PyTorch installation failed, trying without CUDA index..."
      pip install torch torchvision --timeout 1800 --cache-dir /data/pip-cache --target $PIP_TARGET || echo "PyTorch installation failed completely"
    fi
    
    # Install ONLY most critical packages to avoid space issues
    echo "Installing only critical dependencies to avoid space issues..."
    
    # Core essentials - expanded list
    pip install gradio fastapi uvicorn --cache-dir /data/pip-cache --target $PIP_TARGET || true
    pip install transformers diffusers --cache-dir /data/pip-cache --target $PIP_TARGET || true
    pip install trimesh pygltflib --cache-dir /data/pip-cache --target $PIP_TARGET || true
    pip install numpy opencv-python --cache-dir /data/pip-cache --target $PIP_TARGET || true
    pip install einops scikit-image --cache-dir /data/pip-cache --target $PIP_TARGET || true
    pip install pymeshlab omegaconf tqdm --cache-dir /data/pip-cache --target $PIP_TARGET || true
    pip install xatlas rembg --cache-dir /data/pip-cache --target $PIP_TARGET || true
    pip install timm --cache-dir /data/pip-cache --target $PIP_TARGET || true
    # Try installing bpy through different methods
    echo "Attempting to install bpy (Blender Python module)..."
    pip install bpy --cache-dir /data/pip-cache --target $PIP_TARGET || \
    pip install --pre bpy --cache-dir /data/pip-cache --target $PIP_TARGET || \
    echo "bpy installation failed, GLB export will be disabled"
    
    # Clean up after each install to save space
    echo "Cleaning up to save space..."
    rm -rf /tmp/* /var/tmp/* /data/pip-tmp/* || true
    
    # Try to install remaining packages one by one (stop on space error)
    echo "Installing remaining packages (will stop on space error)..."
    for pkg in accelerate safetensors pandas imageio configargparse pyyaml psutil pydantic onnxruntime open3d huggingface-hub; do
      echo "Installing $pkg..."
      if ! pip install $pkg --cache-dir /data/pip-cache --target $PIP_TARGET 2>/dev/null; then
        echo "Failed to install $pkg (likely space issue), skipping remaining packages"
        break
      fi
      # Clean after each package
      rm -rf /tmp/* /var/tmp/* || true
    done
    
    # Try to install missing critical packages separately if they failed - all to persistent volume
    if ! PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import trimesh" 2>/dev/null; then
      echo "Trimesh missing, installing separately to persistent volume..."
      pip install trimesh --cache-dir /data/pip-cache --target $PIP_TARGET || true
    fi
    
    if ! PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import einops" 2>/dev/null; then
      echo "Einops missing, installing separately to persistent volume..."
      pip install einops --cache-dir /data/pip-cache --target $PIP_TARGET || true
    fi
    
    if ! PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import skimage" 2>/dev/null; then
      echo "Scikit-image missing, installing separately to persistent volume..."
      pip install scikit-image --cache-dir /data/pip-cache --target $PIP_TARGET || true
    fi
    
    if ! PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import pymeshlab" 2>/dev/null; then
      echo "Pymeshlab missing, installing separately to persistent volume..."
      pip install pymeshlab --cache-dir /data/pip-cache --target $PIP_TARGET || true
    fi
    
    if ! PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import pygltflib" 2>/dev/null; then
      echo "Pygltflib missing, installing separately to persistent volume..."
      pip install pygltflib --cache-dir /data/pip-cache --target $PIP_TARGET || true
    fi
    
    if ! PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import xatlas" 2>/dev/null; then
      echo "Xatlas missing, installing separately to persistent volume..."
      pip install xatlas --cache-dir /data/pip-cache --target $PIP_TARGET || true
    fi
    
    if ! PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import rembg" 2>/dev/null; then
      echo "Rembg missing, installing separately to persistent volume..."
      pip install rembg --cache-dir /data/pip-cache --target $PIP_TARGET || true
    fi
    
    echo "Background: Installing custom wheels to persistent volume..."
    if [ -f /wheels/*.whl ]; then
      pip install /wheels/*.whl --cache-dir /data/pip-cache --target $PIP_TARGET || echo "Custom wheels installation failed"
    fi
    
    # Check which packages are available 
    echo "Checking what packages are available..."
    PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "
packages = ['torch', 'trimesh', 'gradio', 'einops', 'skimage', 'pymeshlab', 'pygltflib', 'transformers', 'diffusers', 'xatlas', 'rembg']
available = []
missing = []
for pkg in packages:
    try:
        __import__(pkg)
        available.append(pkg)
        print(f'✓ {pkg} available')
    except ImportError:
        missing.append(pkg)
        print(f'✗ {pkg} missing')

print(f'Available: {len(available)}/{len(packages)} packages')
if missing:
    print(f'Missing: {missing}')
" || echo "Package check failed"

    # Only mark as complete if core packages are available (bpy is optional for GLB export)
    if PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "import torch, gradio, xatlas, rembg, timm; print('All critical dependencies ready')" 2>/dev/null; then
      touch /data/.deps_installed
      echo "Background: All critical dependencies installation completed successfully!"
    else
      echo "Background: Dependencies installation failed - missing critical dependencies"
      python3 -c "
try:
    import torch
    print('✓ PyTorch available')
except: print('✗ PyTorch missing')
try:
    import trimesh  
    print('✓ Trimesh available')
except: print('✗ Trimesh missing')
try:
    import gradio
    print('✓ Gradio available') 
except: print('✗ Gradio missing')
try:
    import einops
    print('✓ Einops available') 
except: print('✗ Einops missing')
try:
    import skimage
    print('✓ Scikit-image available') 
except: print('✗ Scikit-image missing')
try:
    import pymeshlab
    print('✓ Pymeshlab available') 
except: print('✗ Pymeshlab missing')
try:
    import pygltflib
    print('✓ Pygltflib available') 
except: print('✗ Pygltflib missing')
try:
    import transformers
    print('✓ Transformers available') 
except: print('✗ Transformers missing')
try:
    import diffusers
    print('✓ Diffusers available') 
except: print('✗ Diffusers missing')
try:
    import bpy
    print('✓ Bpy available') 
except: print('✗ Bpy missing')
" || true
    fi
    
    # Clean up temporary files but keep cache
    rm -rf /wheels /data/pip-tmp /data/.installing
  ) &
  
  echo "Essential dependencies installed, continuing with startup..."
else
  echo "Dependencies already installed, skipping installation."
fi

# Quick verification without stopping startup
echo "Verifying basic Python setup..."
python3 -c "
import sys
print(f'Python version: {sys.version}')

try:
    import gradio
    print(f'Gradio version: {gradio.__version__}')
    print('Basic web server dependencies available')
except Exception as e:
    print(f'Gradio not yet available: {e}')
    print('Will attempt to start with basic server')

try:
    import torch
    print(f'PyTorch version: {torch.__version__}')
    print(f'CUDA available: {torch.cuda.is_available()}')
except Exception as e:
    print(f'PyTorch not yet available: {e} (may be installing in background)')
"

# Start the server
echo "Starting server on port ${PORT}..."
cd /app

# Simple immediate startup approach
if [ "$deps_working" != "true" ]; then
    echo "Dependencies not yet installed. Starting simple server immediately..."
    
    # Create a simple HTTP server that responds on port 8080
    cat > /tmp/loading_server.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import os
import subprocess
import json
from datetime import datetime

class LoadingHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/status':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            # Check installation status - verify deps actually work
            deps_installed = False
            if os.path.exists('/data/.deps_installed'):
                try:
                    import sys
                    sys.path.insert(0, '/data/python-packages')
                    import torch, gradio, xatlas, rembg, timm
                    deps_installed = True
                except ImportError:
                    deps_installed = False
            
            # Check if pip is running
            try:
                result = subprocess.run(['pgrep', '-f', 'pip'], capture_output=True, text=True)
                pip_running = bool(result.stdout.strip())
            except:
                pip_running = False
            
            status = {
                'deps_installed': deps_installed,
                'pip_running': pip_running,
                'timestamp': datetime.now().isoformat()
            }
            
            self.wfile.write(json.dumps(status).encode())
        else:
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            html_content = '''
<html>
<head>
    <title>Hunyuan3D Loading</title>
    <meta http-equiv="refresh" content="10">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .status { background: #f0f0f0; padding: 20px; border-radius: 5px; margin: 20px 0; }
        .loading { color: #666; }
    </style>
</head>
<body>
<h1>Hunyuan3D is Loading...</h1>
<div class="status">
    <p><strong>Status:</strong> <span id="status" class="loading">Installing dependencies...</span></p>
    <p><strong>Progress:</strong> This may take 10-15 minutes on first startup</p>
    <p><strong>Last updated:</strong> <span id="timestamp">Loading...</span></p>
</div>

<p><strong>What's happening:</strong></p>
<ul>
    <li>PyTorch and CUDA libraries are being downloaded and installed</li>
    <li>This only happens once - future startups will be much faster</li>
    <li>The page will automatically refresh every 10 seconds</li>
</ul>

<p><a href="/">Refresh now</a> | <a href="/status">Check status (JSON)</a></p>

<script>
    async function updateStatus() {
        try {
            const response = await fetch('/status');
            const data = await response.json();
            
            document.getElementById('timestamp').textContent = new Date(data.timestamp).toLocaleTimeString();
            
            if (data.deps_installed) {
                document.getElementById('status').innerHTML = '<span style="color: green;">Dependencies installed! App should start soon...</span>';
                setTimeout(() => location.reload(), 5000);
            } else if (data.pip_running) {
                document.getElementById('status').innerHTML = '<span style="color: orange;">Installing packages...</span>';
            } else {
                document.getElementById('status').innerHTML = '<span style="color: blue;">Preparing installation...</span>';
            }
        } catch (e) {
            console.log('Status check failed:', e);
        }
    }
    
    updateStatus();
    setInterval(updateStatus, 5000);
</script>
</body>
</html>
            '''
            self.wfile.write(html_content.encode('utf-8'))

PORT = int(os.environ.get('PORT', 8080))
print(f"Loading server starting on port {PORT}")

with socketserver.TCPServer(('0.0.0.0', PORT), LoadingHandler) as httpd:
    httpd.serve_forever()
EOF
    
    # Start the loading server and keep it running until dependencies are ready
    python3 /tmp/loading_server.py &
    SERVER_PID=$!
    
    # Wait for dependencies to actually work - with timeout
    echo "Waiting for dependencies to install (max 30 minutes)..."
    WAIT_COUNT=0
    MAX_WAIT=360  # 30 minutes * 60 seconds / 5 second intervals
    
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        # Check core dependencies AND critical app-specific packages (bpy is optional)
        if [ -f /data/.deps_installed ] && PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "
import torch, gradio, xatlas, rembg, timm
print('All critical deps ready')
" 2>/dev/null; then
            echo "Dependencies are ready and working!"
            break
        fi
        
        WAIT_COUNT=$((WAIT_COUNT + 1))
        MINUTES_WAITED=$((WAIT_COUNT * 5 / 60))
        
        if [ $((WAIT_COUNT % 12)) -eq 0 ]; then  # Every minute
            echo "Still waiting for dependencies... ($MINUTES_WAITED minutes elapsed)"
            # Show which packages are still missing
            PYTHONPATH="/data/python-packages:${PYTHONPATH:-}" python3 -c "
for pkg in ['torch', 'gradio', 'xatlas', 'rembg', 'timm']:
    try:
        __import__(pkg)
        print(f'✓ {pkg}')
    except ImportError:
        print(f'✗ {pkg} missing')
print('Checking optional packages:')
for pkg in ['bpy']:
    try:
        __import__(pkg)
        print(f'✓ {pkg} (optional)')
    except ImportError:
        print(f'✗ {pkg} missing (optional - GLB export disabled)')
" 2>/dev/null || echo "Package check failed"
        fi
        
        sleep 5
    done
    
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "Timeout waiting for dependencies after 30 minutes. Starting app anyway..."
    fi
    
    # Kill loading server and start real app immediately
    echo "Dependencies ready! Stopping loading server..."
    kill $SERVER_PID 2>/dev/null || true
    
    # Give loading server time to shut down, but keep activity
    for i in {1..3}; do
        echo "Transitioning to main application... ($i/3)"
        sleep 1
    done
fi

# Start the real application
echo "Starting Hunyuan3D application..."

# Set PYTHONPATH to include packages installed to persistent volume
export PYTHONPATH="/data/python-packages:${PYTHONPATH:-}"

if python3 -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    echo "GPU detected, running with CUDA support"
    exec python3 gradio_app.py --port "${PORT}" --host 0.0.0.0 --device cuda
else
    echo "No GPU detected, running in CPU mode (will be slow)"
    exec python3 gradio_app.py --port "${PORT}" --host 0.0.0.0 --device cpu
fi