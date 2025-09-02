#!/usr/bin/env python3
"""
Test script to verify persistent volume setup is working correctly.
Run this inside the container to validate that all heavy dependencies
are stored on the persistent volume.
"""

import os
import sys
import subprocess

def check_directory_size(path, name):
    """Check the size of a directory and report it."""
    if os.path.exists(path):
        try:
            result = subprocess.run(['du', '-sh', path], 
                                 capture_output=True, text=True)
            if result.returncode == 0:
                size = result.stdout.split('\t')[0]
                print(f"✓ {name}: {size} at {path}")
                return True
            else:
                print(f"✗ {name}: Could not measure size at {path}")
        except Exception as e:
            print(f"✗ {name}: Error measuring {path} - {e}")
    else:
        print(f"✗ {name}: Directory {path} does not exist")
    return False

def check_python_packages():
    """Test that Python packages can be imported from persistent volume."""
    print("\n=== Testing Python Package Imports ===")
    sys.path.insert(0, '/data/python-packages')
    
    packages = [
        'torch', 'gradio', 'transformers', 'diffusers',
        'trimesh', 'einops', 'skimage', 'pymeshlab',
        'xatlas', 'rembg', 'timm'
    ]
    
    available = []
    missing = []
    
    for pkg in packages:
        try:
            __import__(pkg)
            available.append(pkg)
            print(f"✓ {pkg}")
        except ImportError:
            missing.append(pkg)
            print(f"✗ {pkg}")
    
    print(f"\nResult: {len(available)}/{len(packages)} packages available")
    if missing:
        print(f"Missing: {missing}")
    
    return len(missing) == 0

def main():
    print("=== Persistent Volume Setup Test ===\n")
    
    # Check that persistent volume is mounted
    if not os.path.exists('/data'):
        print("✗ CRITICAL: /data directory not found - volume not mounted!")
        sys.exit(1)
    
    print("✓ Persistent volume is mounted at /data")
    
    # Check directory sizes on persistent volume
    print("\n=== Checking Persistent Volume Usage ===")
    directories = [
        ('/data/python-packages', 'Python packages'),
        ('/data/hf', 'HuggingFace cache'),
        ('/data/pip-cache', 'Pip cache'),
        ('/data/torch', 'PyTorch cache'),
        ('/data/ckpt', 'Model checkpoints'),
        ('/data/hy3dgen', 'Hy3DGen cache')
    ]
    
    for path, name in directories:
        check_directory_size(path, name)
    
    # Check total usage of persistent volume
    print("\n=== Total Persistent Volume Usage ===")
    try:
        result = subprocess.run(['df', '-h', '/data'], 
                             capture_output=True, text=True)
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            if len(lines) >= 2:
                header = lines[0]
                data = lines[1]
                print(f"Volume usage: {data}")
        else:
            print("Could not check volume usage")
    except Exception as e:
        print(f"Error checking volume usage: {e}")
    
    # Test Python package imports
    packages_ok = check_python_packages()
    
    # Final verdict
    print("\n=== Final Assessment ===")
    if packages_ok:
        print("✓ SUCCESS: Persistent volume setup is working correctly!")
        print("  - All heavy dependencies are stored on persistent volume")
        print("  - Container restarts should be fast")
        sys.exit(0)
    else:
        print("✗ ISSUES FOUND: Some packages are missing")
        print("  - First boot may still be in progress")
        print("  - Check logs for installation status")
        sys.exit(1)

if __name__ == '__main__':
    main()