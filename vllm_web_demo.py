#!/usr/bin/env python3
"""
vLLM Web Demo Application
========================

A simple Flask web application that provides a web interface
to interact with the vLLM API endpoint.

Usage:
    python vllm_web_demo.py

Features:
    - Web-based chat interface
    - Model information display
    - Health status monitoring
    - Real-time chat with the Qwen model
    - Automatic dependency installation
    - Dynamic vLLM IP detection
"""

import subprocess
import sys
import importlib
import os

def install_system_package(package):
    """Install a system package using apt if it's not already installed."""
    try:
        importlib.import_module(package)
        print(f"✅ {package} is already installed")
        return True
    except ImportError:
        print(f"📦 Installing {package} via system package manager...")
        try:
            # Map Python package names to system package names
            package_map = {
                "flask": "python3-flask",
                "requests": "python3-requests"
            }
            
            system_package = package_map.get(package, f"python3-{package}")
            
            # Install using apt
            subprocess.check_call([
                "apt", "update", "-qq"
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            subprocess.check_call([
                "apt", "install", "-y", system_package
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            print(f"✅ Successfully installed {package} (system package)")
            return True
        except subprocess.CalledProcessError as e:
            print(f"❌ Failed to install {package} via system package manager: {e}")
            print(f"💡 You may need to install {package} manually:")
            print(f"   sudo apt install python3-{package}")
            return False

def ensure_dependencies():
    """Ensure all required dependencies are installed."""
    print("🔍 Checking dependencies...")
    required_packages = ["flask", "requests"]
    
    all_installed = True
    for package in required_packages:
        if not install_system_package(package):
            all_installed = False
    
    if all_installed:
        print("✅ All dependencies are ready!")
    else:
        print("⚠️  Some dependencies failed to install automatically.")
        print("   The script will continue, but you may encounter errors.")
    print()

def get_vllm_base_url():
    """Dynamically determine the vLLM base URL."""
    # Try to get IP from environment variable first
    vllm_ip = os.environ.get("VLLM_IP")
    if vllm_ip:
        base_url = f"http://{vllm_ip}:8080"
        print(f"🌐 Using vLLM IP from environment variable: {vllm_ip}")
    else:
        # Auto-detect the IP from the service
        try:
            result = subprocess.run([
                "kubectl", "get", "svc", "vllm-service", 
                "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}"
            ], capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0 and result.stdout.strip():
                base_url = f"http://{result.stdout.strip()}:8080"
                print(f"🌐 Auto-detected vLLM IP: {result.stdout.strip()}")
            else:
                # Fallback to localhost if kubectl fails
                base_url = "http://localhost:8080"
                print("⚠️  Could not detect vLLM IP, using localhost:8080")
        except Exception as e:
            # Fallback to localhost if kubectl fails
            base_url = "http://localhost:8080"
            print(f"⚠️  Error detecting vLLM IP ({e}), using localhost:8080")
    
    return base_url

# Install dependencies before importing them
ensure_dependencies()

# Now import the required modules
try:
    from flask import Flask, render_template, request, jsonify, session
    import requests
    import json
    import uuid
    from datetime import datetime
except ImportError as e:
    print(f"❌ Failed to import required modules: {e}")
    print("💡 Please install the missing dependencies manually:")
    print("   sudo apt install python3-flask python3-requests")
    sys.exit(1)

app = Flask(__name__)
app.secret_key = 'vllm-demo-secret-key-2024'

# Dynamically determine vLLM API configuration
VLLM_BASE_URL = get_vllm_base_url()
MODEL_NAME = "Qwen/Qwen2.5-1.5B-Instruct"

class VLLMWebClient:
    def __init__(self, base_url: str = None):
        self.base_url = base_url or VLLM_BASE_URL
        self.model = MODEL_NAME
    
    def health_check(self):
        """Check if the vLLM service is healthy."""
        try:
            response = requests.get(f"{self.base_url}/health", timeout=5)
            return response.status_code == 200
        except requests.exceptions.RequestException:
            return False
    
    def get_models(self):
        """Get available models."""
        try:
            response = requests.get(f"{self.base_url}/v1/models", timeout=10)
            response.raise_for_status()
            return response.json()["data"]
        except requests.exceptions.RequestException as e:
            return {"error": str(e)}
    
    def chat_completion(self, messages, max_tokens=200, temperature=0.7):
        """Send a chat completion request."""
        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False
        }
        
        try:
            response = requests.post(
                f"{self.base_url}/v1/chat/completions",
                headers={"Content-Type": "application/json"},
                json=payload,
                timeout=30
            )
            response.raise_for_status()
            result = response.json()
            return {
                "success": True,
                "content": result["choices"][0]["message"]["content"],
                "usage": result.get("usage", {})
            }
        except requests.exceptions.RequestException as e:
            return {"success": False, "error": str(e)}

# Initialize the vLLM client
vllm_client = VLLMWebClient()

@app.route('/')
def index():
    """Main page with chat interface."""
    # Initialize session if not exists
    if 'session_id' not in session:
        session['session_id'] = str(uuid.uuid4())
        session['chat_history'] = []
    
    return render_template('index.html')

@app.route('/api/health')
def api_health():
    """API endpoint to check vLLM service health."""
    is_healthy = vllm_client.health_check()
    return jsonify({
        "healthy": is_healthy,
        "timestamp": datetime.now().isoformat()
    })

@app.route('/api/models')
def api_models():
    """API endpoint to get available models."""
    models = vllm_client.get_models()
    return jsonify(models)

@app.route('/api/chat', methods=['POST'])
def api_chat():
    """API endpoint for chat completion."""
    data = request.get_json()
    message = data.get('message', '').strip()
    
    if not message:
        return jsonify({"error": "Message cannot be empty"}), 400
    
    # Get chat history from session
    chat_history = session.get('chat_history', [])
    
    # Add user message to history
    chat_history.append({"role": "user", "content": message})
    
    # Get AI response
    result = vllm_client.chat_completion(chat_history)
    
    if result["success"]:
        # Add AI response to history
        chat_history.append({"role": "assistant", "content": result["content"]})
        session['chat_history'] = chat_history
        
        return jsonify({
            "success": True,
            "response": result["content"],
            "usage": result.get("usage", {})
        })
    else:
        return jsonify({
            "success": False,
            "error": result["error"]
        }), 500

@app.route('/api/clear', methods=['POST'])
def api_clear():
    """API endpoint to clear chat history."""
    session['chat_history'] = []
    return jsonify({"success": True, "message": "Chat history cleared"})

if __name__ == '__main__':
    print("🚀 Starting vLLM Web Demo Application")
    print("=" * 50)
    print(f"vLLM Endpoint: {VLLM_BASE_URL}")
    print(f"Model: {MODEL_NAME}")
    print("=" * 50)
    print("Access the web interface at: http://localhost:5000")
    print()
    print("📡 SSH TUNNELING INSTRUCTIONS:")
    print("=" * 50)
    print("This app runs on the remote server. To access from your laptop:")
    print()
    print("1. Basic tunnel (forward remote port 5000 to local port 5000):")
    print("   ssh -L 5000:localhost:5000 username@remote-server-ip")
    print()
    print("2. Background tunnel (keeps running after closing terminal):")
    print("   ssh -f -N -L 5000:localhost:5000 username@remote-server-ip")
    print()
    print("3. If port 5000 is busy locally, use a different local port:")
    print("   ssh -L 5001:localhost:5000 username@remote-server-ip")
    print("   Then access via: http://localhost:5001")
    print()
    print("4. Multiple ports (web app + vLLM API):")
    print("   ssh -L 5000:localhost:5000 -L 8080:localhost:8080 username@remote-server-ip")
    print()
    print("5. With SSH key:")
    print("   ssh -i /path/to/your/key.pem -L 5000:localhost:5000 username@remote-server-ip")
    print()
    print("After tunneling, open: http://localhost:5000 in your browser")
    print("=" * 50)
    print("Press Ctrl+C to stop the server")
    print()
    
    app.run(host='0.0.0.0', port=5000, debug=True)
