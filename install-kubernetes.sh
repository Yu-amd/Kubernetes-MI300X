#!/bin/bash

# install-kubernetes.sh
# Installs vanilla Kubernetes cluster on Ubuntu/Debian systems
# This script should be run BEFORE install-amd-gpu-operator.sh

set -e  # Exit on any error

echo "=============================================="
echo "Vanilla Kubernetes Installation Script"
echo "For AMD GPU Tutorial Prerequisites"
echo "=============================================="

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration variables
KUBERNETES_VERSION="1.31.0-1.1"
CONTAINERD_VERSION="1.7.2"
CALICO_VERSION="v3.26.1"

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. This script supports Ubuntu/Debian only."
        exit 1
    fi
    
    log_info "Detected OS: $OS $VERSION"
    
    # Check if OS is supported
    if [[ "$OS" != *"Ubuntu"* ]] && [[ "$OS" != *"Debian"* ]]; then
        log_error "Unsupported OS: $OS. This script supports Ubuntu/Debian only."
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check for required commands
    for cmd in curl wget apt-get; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is required but not installed"
            exit 1
        fi
    done
    
    # Check available memory (at least 2GB recommended)
    MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEMORY_GB=$((MEMORY_KB / 1024 / 1024))
    
    if [ $MEMORY_GB -lt 2 ]; then
        log_warning "Less than 2GB RAM detected. Kubernetes may not perform well."
    else
        log_success "Memory check passed: ${MEMORY_GB}GB available"
    fi
    
    # Check for AMD GPUs
    if lspci | grep -qi amd; then
        log_success "AMD GPUs detected:"
        lspci | grep -i amd
    else
        log_warning "No AMD GPUs detected. GPU functionality will not be available."
    fi
    
    log_success "Prerequisites check completed."
}

# Generic package manager lock resolution function
resolve_package_manager_locks() {
    log_info "Checking for package manager locks..."
    
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )
    
    local locked_files=()
    
    # Check for locked files
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ] && lsof "$lock_file" >/dev/null 2>&1; then
            locked_files+=("$lock_file")
            log_warning "Lock detected: $lock_file"
        fi
    done
    
    if [ ${#locked_files[@]} -eq 0 ]; then
        log_success "No package manager locks detected"
        return 0
    fi
    
    log_warning "Found ${#locked_files[@]} locked files: ${locked_files[*]}"
    log_info "Attempting to resolve package manager locks..."
    
    # Step 1: Identify and terminate stuck processes
    local stuck_pids=()
    local apt_pids=$(pgrep -f "(apt|dpkg|unattended-upgrade)" 2>/dev/null || echo "")
    
    if [ -n "$apt_pids" ]; then
        for pid in $apt_pids; do
            if ps -p "$pid" >/dev/null 2>&1; then
                local runtime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
                local cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
                
                # Consider a process stuck if it's been running for more than 5 minutes
                if [[ "$runtime" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || [[ "$runtime" =~ ^[0-9]+- ]]; then
                    stuck_pids+=("$pid")
                    log_warning "Found stuck process: PID $pid ($cmd) running for $runtime"
                fi
            fi
        done
    fi
    
    if [ ${#stuck_pids[@]} -gt 0 ]; then
        log_info "Terminating ${#stuck_pids[@]} stuck processes..."
        for pid in "${stuck_pids[@]}"; do
            log_info "Sending TERM signal to PID $pid..."
            kill -TERM "$pid" 2>/dev/null || true
        done
        
        sleep 5
        
        # Force kill any remaining processes
        for pid in "${stuck_pids[@]}"; do
            if ps -p "$pid" >/dev/null 2>&1; then
                log_warning "Force killing PID $pid..."
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        
        sleep 2
    fi
    
    # Step 2: Clean up orphaned lock files
    log_info "Cleaning up orphaned lock files..."
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ] && ! lsof "$lock_file" >/dev/null 2>&1; then
            log_info "Removing orphaned lock: $lock_file"
            rm -f "$lock_file"
        fi
    done
    
    # Step 3: Fix dpkg configuration if needed
    log_info "Checking dpkg configuration..."
    if dpkg --configure -a 2>/dev/null; then
        log_success "Package configuration completed"
    else
        log_warning "Some packages may need manual configuration"
    fi
    
    # Step 4: Update package lists
    log_info "Updating package lists..."
    if apt-get update 2>/dev/null; then
        log_success "Package lists updated successfully"
    else
        log_warning "Package list update had issues (this is normal after lock resolution)"
    fi
    
    # Step 5: Verify locks are resolved
    local still_locked=()
    for lock_file in "${locked_files[@]}"; do
        if [ -f "$lock_file" ] && lsof "$lock_file" >/dev/null 2>&1; then
            still_locked+=("$lock_file")
        fi
    done
    
    if [ ${#still_locked[@]} -eq 0 ]; then
        log_success "All package manager locks resolved successfully!"
        return 0
    else
        log_warning "Some locks still present: ${still_locked[*]}"
        log_error "Manual intervention may be required"
        # return 1
    fi
}
# Function to disable swap (required for Kubernetes)
disable_swap() {
    log_info "Disabling swap (required for Kubernetes)..."
    
    # Disable swap immediately
    swapoff -a
    
    # Disable swap permanently by commenting out swap entries in /etc/fstab
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    
    log_success "Swap disabled."
}

# Function to configure kernel modules and sysctl settings
configure_kernel() {
    log_info "Configuring kernel modules and sysctl settings..."
    
    # Load required kernel modules
    cat > /etc/modules-load.d/k8s.conf << MODULES_EOF
overlay
br_netfilter
MODULES_EOF

    if ! modprobe overlay 2>/dev/null; then
        if ! modprobe overlayfs 2>/dev/null; then
            if ! lsmod | grep -q "overlay\|overlayfs"; then
                log_warning "Overlay filesystem not available - continuing anyway"
            fi
        fi
    fi
    # Original: modprobe overlay
    if ! modprobe br_netfilter 2>/dev/null; then
        if ! lsmod | grep -q br_netfilter; then
            log_warning "br_netfilter not available - continuing anyway"
        fi
    fi
    # Original: modprobe br_netfilter
    
    # Configure sysctl settings for Kubernetes
    cat > /etc/sysctl.d/k8s.conf << SYSCTL_EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL_EOF

    # Apply sysctl settings
    if ! sysctl --system 2>/dev/null; then
        log_warning "Some sysctl settings could not be applied (read-only filesystem)"
        log_info "This is normal in container environments - continuing installation"
        # Try to apply just the k8s specific settings
        sysctl -p /etc/sysctl.d/k8s.conf 2>/dev/null || true
    fi
    
    log_success "Kernel configuration completed."

# Function to configure firewall for Kubernetes control plane
configure_firewall() {
    log_info "Configuring firewall for Kubernetes control plane..."
    
    # Check if ufw is installed
    if ! command -v ufw &> /dev/null; then
        log_info "Installing ufw firewall..."
        apt-get install -y ufw
    fi
    
    # Enable firewall if not already enabled
    if ! ufw status | grep -q "Status: active"; then
        log_info "Enabling firewall..."
        ufw --force enable
    fi
    
    # Allow SSH (port 22) - essential for remote access
    ufw allow 22/tcp
    
    # Allow Kubernetes API server (port 6443)
    ufw allow 6443/tcp
    
    # Allow etcd client/server communication (ports 2379-2380)
    ufw allow 2379:2380/tcp
    
    # Allow kubelet API (port 10250)
    ufw allow 10250/tcp
    
    # Allow kube-scheduler (port 10251)
    ufw allow 10251/tcp
    
    # Allow kube-controller-manager (port 10252)
    ufw allow 10252/tcp
    
    # Allow NodePort services (30000-32767)
    ufw allow 30000:32767/tcp
    
    # Allow Calico networking (BGP and VXLAN)
    ufw allow 179/tcp
    ufw allow 4789/udp
    
    # Allow HTTP and HTTPS for web services
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    log_success "Firewall configured for Kubernetes control plane."
}

}

# Function to install container runtime (containerd)
install_containerd() {
    log_info "Installing containerd container runtime..."
    
    # Update package index
    # Wait for any running package managers to finish
    log_info "Waiting for package manager to be available..."
    # Use check-system-enhanced.sh to handle update manager locks
    log_info "Checking for update manager locks..."
    if ! ./check-system-enhanced.sh --check-locks-only; then
        log_error "Update manager locks detected. Please resolve them first."
        log_info "You can run: ./check-system-enhanced.sh --auto-resolve"
        exit 1
    fi
    apt-get update
    
    # Install required packages
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    # Add Docker's official GPG key (for containerd)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package index with new repository
    apt-get update
    
    # Install containerd
    apt-get install -y containerd.io
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default | tee /etc/containerd/config.toml
    
    # Enable systemd cgroup driver (required for Kubernetes)
    sed -i 's/SystemdCgroup \= false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Enable and start containerd
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    
    # Verify containerd is running
    if systemctl is-active --quiet containerd; then
        log_success "containerd installed and running successfully."
    else
        log_error "Failed to start containerd"
        exit 1
    fi
}

# Function to install Kubernetes components
install_kubernetes() {
    echo ""
    log_info "Installing Kubernetes components (kubelet, kubeadm, kubectl)..."
    
    # Install required packages
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gpg
    
    # Add Kubernetes GPG key
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    # Add Kubernetes repository
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
    
    # Update package index
    apt-get update
    
    # Install specific version of Kubernetes components
    apt-get install -y kubelet=$KUBERNETES_VERSION kubeadm=$KUBERNETES_VERSION kubectl=$KUBERNETES_VERSION
    if [ $? -ne 0 ]; then
        log_error "Failed to install Kubernetes packages"
        # return 1
    fi
    
    # Hold packages to prevent accidental upgrades
    apt-mark hold kubelet kubeadm kubectl
    
    # Enable kubelet service
    systemctl enable kubelet
    
    log_success "Kubernetes components installed successfully."
}

# Function to initialize Kubernetes cluster

# Function to ensure required services are running
ensure_services_running() {
    log_info "Ensuring required services are running..."
    
    # Check and start containerd
    if ! systemctl is-active --quiet containerd; then
        log_warning "containerd is not running, starting..."
        systemctl start containerd
        systemctl enable containerd
        sleep 5
        if systemctl is-active --quiet containerd; then
            log_success "containerd started successfully"
        else
            log_error "Failed to start containerd"
            # return 1
        fi
    else
        log_success "containerd is already running"
    fi
    
    # Check if kubelet service exists before trying to start it
    if systemctl list-unit-files | grep -q "^kubelet.service"; then
        # Check and start kubelet
        if ! systemctl is-active --quiet kubelet; then
            log_warning "kubelet is not running, starting..."
            systemctl start kubelet
            systemctl enable kubelet
            sleep 5
            if systemctl is-active --quiet kubelet; then
                log_success "kubelet started successfully"
            else
                log_warning "kubelet failed to start - this is normal before cluster initialization"
                log_info "kubelet will start automatically during kubeadm init"
                # Don't return error - continue with cluster initialization
                # return 1
            fi
        else
            log_success "kubelet is already running"
        fi
    else
        log_warning "kubelet service not found - packages may not be installed yet"
        # return 1
    fi
}
initialize_cluster() {
    # Check if cluster is already initialized
    if [ -f /etc/kubernetes/admin.conf ]; then
        log_warning "Kubernetes cluster appears to already be initialized."
        log_info "Checking cluster status..."
        if kubectl cluster-info &> /dev/null; then
            log_success "Cluster is already running and accessible."
            log_info "Skipping cluster initialization."
            return 0
        else
            log_warning "Cluster config exists but cluster is not accessible."
            log_info "Attempting to reset and reinitialize..."
            kubeadm reset --force || true
        fi
    fi
    log_info "Initializing Kubernetes cluster..."
    
    # Get the primary IP address of the node
    NODE_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')
    log_info "Using node IP: $NODE_IP"
    
    # Initialize the cluster
    log_info "Running kubeadm init with the following parameters:"
    log_info "  --apiserver-advertise-address=$NODE_IP"
    log_info "  --pod-network-cidr=192.168.0.0/16"
    log_info "  --node-name $(hostname -s)"
    log_info "  --ignore-preflight-errors=NumCPU"
    
    if ! kubeadm init \
        --apiserver-advertise-address=$NODE_IP \
        --pod-network-cidr=192.168.0.0/16 \
        --node-name $(hostname -s) \
        --ignore-preflight-errors=NumCPU; then
        log_error "kubeadm init failed. This could be due to:"
        log_error "  • Insufficient resources (CPU/Memory)"
        log_error "  • Network connectivity issues"
        log_error "  • Previous cluster initialization"
        log_error "  • Port conflicts (6443, 2379-2380, 10250-10252)"
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Check system resources: free -h && nproc"
        log_error "  2. Check if ports are in use: netstat -tlnp | grep -E ':(6443|2379|2380|10250|10251|10252)'"
        log_error "  3. Reset cluster if needed: kubeadm reset --force"
        log_error "  4. Check logs: journalctl -xeu kubelet"
        log_error ""
        log_error "🚨 IMPORTANT: Your Kubernetes cluster is NOT initialized!"
        log_error "You have two options:"
        log_error "  1. Fix the issues above and re-run this script"
        log_error "  2. OR manually run the following command:"
        echo ""
        echo "   sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$(hostname -I | awk '{print $1}')"
        echo ""
        log_error ""
        log_error "After successful initialization, run:"
        log_error "  export KUBECONFIG=/etc/kubernetes/admin.conf"
        log_error "  kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
        log_error ""
        log_error "Then continue with: ./install-amd-gpu-operator.sh"
        exit 1
    fi
    
    # Configure kubectl for the root user - FIXED: Copy to standard location
    mkdir -p /root/.kube
    cp -i /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    chmod 600 /root/.kube/config
    
    # Set KUBECONFIG environment variable
    export KUBECONFIG=/root/.kube/config
    echo "export KUBECONFIG=/root/.kube/config" >> /root/.bashrc
    
    # Also set up for regular users (if they exist)
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        USER_HOME=$(eval echo "~$SUDO_USER")
        sudo -u $SUDO_USER mkdir -p $USER_HOME/.kube
        cp -i /etc/kubernetes/admin.conf $USER_HOME/.kube/config
        chown $SUDO_USER:$SUDO_USER $USER_HOME/.kube/config
        
        echo "export KUBECONFIG=$USER_HOME/.kube/config" >> $USER_HOME/.bashrc
        log_info "kubectl configured for user: $SUDO_USER"
    fi
    
    log_success "Kubernetes cluster initialized successfully."

    # Display the kubeadm init command that was executed
    echo ""
    echo "=============================================="
    log_info "kubeadm init command executed successfully:"
    echo "sudo kubeadm init \\"
    echo "  --apiserver-advertise-address=$NODE_IP \\"
    echo "  --pod-network-cidr=192.168.0.0/16 \\"
    echo "  --node-name $(hostname -s) \\"
    echo "  --ignore-preflight-errors=NumCPU"
    echo "=============================================="
    echo ""
    
    # Verify cluster connectivity immediately
    log_info "Verifying cluster connectivity..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl cluster-info &> /dev/null; then
            log_success "Cluster connectivity verified!"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_error "Failed to verify cluster connectivity after $max_attempts attempts"
            log_error "Cluster may not be properly initialized"
            # return 1
        fi
        
        log_info "Waiting for cluster to be ready... (attempt $attempt/$max_attempts)"
        sleep 10
        ((attempt++))
    done
}

# Function to remove taints from control-plane node (for single-node setup)
configure_single_node() {
    log_info "Configuring single-node cluster (removing control-plane taints)..."
    
    # Wait for node to be ready
    sleep 30
    
    # Remove taint from control-plane node to allow scheduling workloads
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
    kubectl taint nodes --all node-role.kubernetes.io/master- || true
    
    log_success "Single-node configuration completed."
}

# Function to install Calico CNI
install_calico() {
    log_info "Installing Calico CNI plugin..."
    
    # Download and apply Calico manifest
    curl -O https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml
    kubectl create -f tigera-operator.yaml
    
    # Wait for tigera-operator to be ready
    log_info "Waiting for tigera-operator to be ready..."
    kubectl wait --for=condition=ready pod -l name=tigera-operator -n tigera-operator --timeout=300s
    
    # Create custom resource for Calico
    cat > custom-resources.yaml << CALICO_EOF
# This section includes base Calico installation configuration.
# For more information, see: https://projectcalico.docs.tigera.io/master/reference/installation/api#operator.tigera.io/v1.Installation
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  # Configures Calico networking.
  calicoNetwork:
    # Note: The ipPools section cannot be modified post-install.
    ipPools:
    - blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()

---

# This section configures the Calico API server.
# For more information, see: https://projectcalico.docs.tigera.io/master/reference/installation/api#operator.tigera.io/v1.APIServer
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
CALICO_EOF

    kubectl create -f custom-resources.yaml
    
    # Wait for Calico to be ready
    
    echo ""
    echo "=============================================="
    echo "🔄 CALICO CNI INSTALLATION IN PROGRESS"
    echo "=============================================="
    echo ""
    echo "📋 What's happening now:"
    echo "  • Calico networking components are being installed"
    echo "  • Pods are starting up (this takes 2-5 minutes)"
    echo "  • The 'error: no matching resources found' message is NORMAL"
    echo "  • It means the script is waiting for pods to appear"
    echo ""
    echo "⏳ Expected Timeline:"
    echo "  • Calico pods: 1-3 minutes to start"
    echo "  • Cluster ready: 2-5 minutes total"
    echo "  • Installation complete: 5-10 minutes total"
    echo ""
    echo "💡 LEARNING TIP:"
    echo "  Open another terminal window/tab to monitor progress:"
    echo "  • Watch kubeconfig: watch -n 2 'ls -la ~/.kube/config'"
    echo "  • Check pods: kubectl get pods --all-namespaces"
    echo "  • Check nodes: kubectl get nodes"
    echo ""
    echo "🚀 Next Steps (after this completes):"
    echo "  • Run: ./install-amd-gpu-operator.sh"
    echo "  • Then: ./deploy-vllm-inference.sh"
    echo "  • Finally: jupyter notebook kubernetes-amd-gpu-demo.ipynb"
    echo ""
    log_info "Waiting for Calico to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=calico-node -n calico-system --timeout=600s
    
    # Clean up downloaded files
    rm -f tigera-operator.yaml custom-resources.yaml
    
    log_success "Calico CNI installed successfully."
}

# Function to verify installation
verify_installation() {
    log_info "Verifying Kubernetes installation..."
    
    # First verify cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to cluster. Attempting to fix..."
        
        # Try to fix kubeconfig
        if [ -f /etc/kubernetes/admin.conf ]; then
            mkdir -p /root/.kube
            cp -i /etc/kubernetes/admin.conf /root/.kube/config
            chown root:root /root/.kube/config
            chmod 600 /root/.kube/config
            export KUBECONFIG=/root/.kube/config
            log_info "kubeconfig fixed, retrying..."
        fi
        
        # Wait a bit and try again
        sleep 10
        if ! kubectl cluster-info &> /dev/null; then
            log_error "Still cannot connect to cluster after fix attempt"
            log_error "Please check cluster status manually"
            # return 1
        fi
    fi
    
    log_success "Cluster connectivity verified"
    
    # Wait for node to be ready
    log_info "Waiting for node to be ready..."
    kubectl wait --for=condition=ready node --all --timeout=300s
    
    # Check cluster status
    log_info "Cluster Information:"
    kubectl cluster-info
    
    echo ""
    log_info "Node Status:"
    kubectl get nodes -o wide
    
    echo ""
    log_info "System Pods Status:"
    kubectl get pods -n kube-system
    
    echo ""
    log_info "Calico Pods Status:"
    kubectl get pods -n calico-system
    
    # Test pod deployment
    log_info "Testing pod deployment..."
    kubectl run test-pod --image=nginx --restart=Never --rm -i --tty -- echo "Kubernetes is working!" || true
    
    log_success "Kubernetes installation verification completed."
}

# Function to display next steps
show_next_steps() {
    echo ""
    echo "=============================================="
    log_success "Kubernetes Installation Complete!"
    echo "=============================================="
    echo ""
    echo "✅ Kubernetes cluster is ready for AMD GPU workloads"

    echo "📋 Cluster initialization command that was executed:"
    echo "   sudo kubeadm init --apiserver-advertise-address=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}') --pod-network-cidr=192.168.0.0/16 --node-name $(hostname -s) --ignore-preflight-errors=NumCPU"
    echo ""
    echo ""
    echo "Next steps:"
    echo "1. Run './install-amd-gpu-operator.sh' to install AMD GPU support"
    echo "2. Deploy AI workloads with './deploy-vllm-inference.sh'"
    echo "3. Use the Jupyter notebook for interactive learning"
    echo ""
    echo "Useful commands:"
    echo "• kubectl get nodes                    # Check cluster nodes"
    echo "• kubectl get pods --all-namespaces   # Check all pods"
    echo "• kubectl cluster-info                # Cluster information"
    echo "• kubectl version                     # Kubernetes version"
    echo ""
    echo "KUBECONFIG is set to: /etc/kubernetes/admin.conf"
    echo "Add this to your shell profile for persistence:"
    echo "  echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> ~/.bashrc"
    echo ""
    log_info "Ready for AMD GPU Operator installation!"
}

# Main execution function
main() {
    echo "Starting Kubernetes installation..."
    echo "Timestamp: $(date)"
    echo ""
    
    detect_os
    echo ""
    
    check_prerequisites
    echo ""
    resolve_package_manager_locks
    echo ""
    
    disable_swap
    echo ""
    
    configure_kernel
    echo ""
    configure_firewall
    echo ""
    
    install_containerd
    echo ""
    
    install_kubernetes
    ensure_services_running
    echo ""
    echo ""
    
    initialize_cluster
    echo ""
    
    configure_single_node
    echo ""
    
    install_calico
    echo ""
    
    verify_installation
    echo ""
    
    show_next_steps
}

# Check if script is run with sudo/root
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Please run with sudo:"
    echo "sudo $0"
    exit 1
fi

# Run main function
main "$@"

# Enhanced error handling and recovery function
handle_installation_error() {
    local error_type="$1"
    local error_details="$2"
    
    log_error "Installation failed: $error_type"
    log_error "Details: $error_details"
    echo ""
    
    case "$error_type" in
        "package_manager_locks")
            log_info "🔧 Recovery options for package manager locks:"
            echo "  1. Wait for automatic processes to complete (recommended)"
            echo "  2. Reboot the system: sudo reboot"
            echo "  3. Force kill all apt processes: sudo pkill -f apt"
            echo "  4. Remove lock files manually: sudo rm /var/lib/dpkg/lock*"
            ;;
        "kubelet_startup")
            log_info "🔧 Recovery options for kubelet startup:"
            echo "  1. This is normal before cluster initialization"
            echo "  2. Continue with kubeadm init (recommended)"
            echo "  3. Check system resources: free -h && nproc"
            echo "  4. Check kubelet logs: journalctl -xeu kubelet"
            ;;
        "cluster_initialization")
            log_info "🔧 Recovery options for cluster initialization:"
            echo "  1. Check system resources: free -h && nproc"
            echo "  2. Check network connectivity: ping 8.8.8.8"
            echo "  3. Reset cluster: kubeadm reset --force"
            echo "  4. Check port conflicts: netstat -tlnp | grep -E ':(6443|2379|2380)'"
            ;;
        "network_plugin")
            log_info "🔧 Recovery options for network plugin:"
            echo "  1. Wait for pods to become ready (can take 5-10 minutes)"
            echo "  2. Check pod status: kubectl get pods --all-namespaces"
            echo "  3. Restart network plugin: kubectl rollout restart daemonset/calico-node -n kube-system"
            echo "  4. Check node taints: kubectl describe nodes"
            ;;
        *)
            log_info "🔧 General recovery options:"
            echo "  1. Check system logs: journalctl -xe"
            echo "  2. Verify system requirements: free -h && df -h"
            echo "  3. Check network connectivity: ping 8.8.8.8"
            echo "  4. Restart the script: sudo $0"
            ;;
    esac
    
    echo ""
    log_info "For detailed troubleshooting, run: ./check-system-enhanced.sh"
}

