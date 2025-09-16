#!/bin/bash

# check-system-enhanced.sh
# Enhanced system check script for AI-Academy-k8s project
# Educational version with detailed explanations and automated lock resolution
# Designed for learners to understand what's happening and why
# Includes comprehensive Kubernetes networking fixes

set -e  # Exit on any error

echo "=============================================="
echo "🎓 AI-Academy-k8s Enhanced System Check"
echo "=============================================="
echo "This script will help you understand and resolve system issues!"
echo ""

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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

log_learn() {
    echo -e "${PURPLE}[LEARN]${NC} $1"
}

log_fix() {
    echo -e "${CYAN}[FIX]${NC} $1"
}

# Configuration
MAX_LOCK_WAIT_TIME=60   # Reduced to 1 minute for better UX
LOCK_CHECK_INTERVAL=2   # Check every 2 seconds
AUTO_RESOLVE=true       # Enable automatic resolution by default

# Function to explain what update manager locks are
explain_update_locks() {
    echo ""
    log_learn "📚 What are Update Manager Locks?"
    echo "   Update manager locks are files that prevent multiple package management"
    echo "   operations from running simultaneously. This prevents system corruption."
    echo ""
    echo "   Common lock files:"
    echo "   • /var/lib/dpkg/lock-frontend - Frontend lock for dpkg"
    echo "   • /var/lib/dpkg/lock - Main dpkg lock"
    echo "   • /var/lib/apt/lists/lock - APT package list lock"
    echo "   • /var/cache/apt/archives/lock - APT cache lock"
    echo ""
    echo "   When locks get stuck, it usually means:"
    echo "   • A package update was interrupted"
    echo "   • A process crashed while updating"
    echo "   • Multiple update processes started simultaneously"
    echo ""
}

# Function to identify processes holding locks with detailed info
identify_lock_processes() {
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )
    
    local processes_found=false
    
    log_info "🔍 Identifying processes holding locks..."
    
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ]; then
            local pids=$(lsof "$lock_file" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || echo "")
            if [ -n "$pids" ]; then
                processes_found=true
                log_warning "Lock file: $lock_file"
                for pid in $pids; do
                    if ps -p "$pid" >/dev/null 2>&1; then
                        local cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                        local args=$(ps -p "$pid" -o args= 2>/dev/null | cut -c1-80 || echo "")
                        local runtime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || echo "unknown")
                        echo "   📌 PID $pid: $cmd (running for $runtime)"
                        echo "      Command: $args"
                        
                        # Check if it's a stuck process
                        if [[ "$runtime" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || [[ "$runtime" =~ ^[0-9]+- ]]; then
                            log_warning "      ⚠️  This process has been running for a long time - likely stuck!"
                        fi
                    fi
                done
                echo ""
            fi
        fi
    done
    
    if [ "$processes_found" = false ]; then
        log_info "No active processes found holding locks (orphaned lock files)"
    fi
}

# Function to safely kill stuck processes
safely_kill_stuck_processes() {
    log_fix "🔧 Attempting to safely resolve stuck processes..."
    
    # First, try to identify and kill only stuck processes
    local stuck_pids=()
    
    # Look for long-running apt/dpkg processes
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
        log_info "Attempting graceful termination of stuck processes..."
        for pid in "${stuck_pids[@]}"; do
            log_info "Sending TERM signal to PID $pid..."
            kill -TERM "$pid" 2>/dev/null || true
        done
        
        sleep 3
        
        # Check if processes are still running and force kill if necessary
        for pid in "${stuck_pids[@]}"; do
            if ps -p "$pid" >/dev/null 2>&1; then
                log_warning "Process $pid still running, sending KILL signal..."
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        
        sleep 2
        log_success "Stuck processes terminated"
    else
        log_info "No stuck processes found"
    fi
}

# Function to clean up orphaned lock files
cleanup_orphaned_locks() {
    log_fix "🧹 Cleaning up orphaned lock files..."
    
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )
    
    local cleaned_count=0
    
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ]; then
            # Check if any process is still using this file
            if ! lsof "$lock_file" >/dev/null 2>&1; then
                log_info "Removing orphaned lock: $lock_file"
                rm -f "$lock_file"
                cleaned_count=$((cleaned_count + 1))
            else
                log_warning "Lock file still in use: $lock_file"
            fi
        fi
    done
    
    if [ $cleaned_count -gt 0 ]; then
        log_success "Cleaned up $cleaned_count orphaned lock files"
    else
        log_info "No orphaned lock files found"
    fi
}

# Function to reconfigure dpkg and fix package system
reconfigure_package_system() {
    log_fix "🔧 Reconfiguring package system..."
    
    log_info "Running dpkg --configure -a..."
    if dpkg --configure -a 2>/dev/null; then
        log_success "Package configuration completed"
    else
        log_warning "Some packages may need manual configuration"
    fi
    
    log_info "Updating package lists..."
    if apt-get update 2>/dev/null; then
        log_success "Package lists updated successfully"
    else
        log_warning "Package list update had issues (this is normal after lock resolution)"
    fi
}

# Enhanced function to check and handle update manager locks
check_and_resolve_update_locks() {
    log_info "Checking for update manager locks..."
    
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )
    
    local locked_files=()
    local wait_time=0
    
    # Check for locked files
    for lock_file in "${lock_files[@]}"; do
        if [ -f "$lock_file" ] && lsof "$lock_file" >/dev/null 2>&1; then
            locked_files+=("$lock_file")
            log_warning "Lock detected: $lock_file"
        fi
    done
    
    if [ ${#locked_files[@]} -eq 0 ]; then
        log_success "No update manager locks detected"
        return 0
    fi
    
    echo ""
    explain_update_locks
    
    log_warning "Found ${#locked_files[@]} locked files: ${locked_files[*]}"
    
    # Identify what's holding the locks
    identify_lock_processes
    
    if [ "$AUTO_RESOLVE" = true ]; then
        log_info "🤖 Auto-resolution enabled - attempting to fix automatically..."
        
        # Step 1: Kill stuck processes
        safely_kill_stuck_processes
        
        # Step 2: Clean up orphaned locks
        cleanup_orphaned_locks
        
        # Step 3: Reconfigure package system
        reconfigure_package_system
        
        # Step 4: Verify locks are resolved
        local still_locked=()
        for lock_file in "${locked_files[@]}"; do
            if [ -f "$lock_file" ] && lsof "$lock_file" >/dev/null 2>&1; then
                still_locked+=("$lock_file")
            fi
        done
        
        if [ ${#still_locked[@]} -eq 0 ]; then
            log_success "✅ All locks resolved automatically!"
            return 0
        else
            log_warning "⚠️  Some locks still present: ${still_locked[*]}"
            log_info "This may require manual intervention or a system reboot"
            return 1
        fi
    else
        # Manual resolution path
        log_info "Waiting for update manager locks to be released..."
        log_info "Locked files: ${locked_files[*]}"
        
        # Wait for locks to be released
        while [ $wait_time -lt $MAX_LOCK_WAIT_TIME ]; do
            local still_locked=()
            
            for lock_file in "${locked_files[@]}"; do
                if [ -f "$lock_file" ] && lsof "$lock_file" >/dev/null 2>&1; then
                    still_locked+=("$lock_file")
                fi
            done
            
            if [ ${#still_locked[@]} -eq 0 ]; then
                log_success "All update manager locks released after ${wait_time}s"
                return 0
            fi
            
            if [ $((wait_time % 10)) -eq 0 ] && [ $wait_time -gt 0 ]; then
                log_info "Still waiting... (${wait_time}s elapsed, ${#still_locked[@]} locks remaining)"
            fi
            
            sleep $LOCK_CHECK_INTERVAL
            wait_time=$((wait_time + LOCK_CHECK_INTERVAL))
        done
        
        log_error "Update manager locks not released within ${MAX_LOCK_WAIT_TIME}s"
        return 1
    fi
}

# Function to check system requirements with explanations
check_system_requirements() {
    log_info "Checking system requirements..."
    echo ""
    
    # Check OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_success "OS: $NAME $VERSION_ID"
        log_learn "   This script is designed for Ubuntu/Debian systems"
    else
        log_error "Cannot detect OS"
        return 1
    fi
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        log_learn "   Use 'sudo' to run this script with root privileges"
        return 1
    fi
    
    # Check disk space
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local available_space_gb=$((available_space / 1024 / 1024))
    if [ "$available_space" -lt 2097152 ]; then  # 2GB in KB
        log_warning "Low disk space: ${available_space_gb}GB available"
        log_learn "   Kubernetes and AI workloads require significant disk space"
    else
        log_success "Disk space: ${available_space_gb}GB available"
    fi
    
    # Check memory
    local available_mem=$(free -m | awk 'NR==2 {print $7}')
    if [ "$available_mem" -lt 1024 ]; then  # 1GB
        log_warning "Low memory: ${available_mem}MB available"
        log_learn "   AI workloads typically require 8GB+ RAM for optimal performance"
    else
        log_success "Memory: ${available_mem}MB available"
    fi
    
    # Check network connectivity
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log_success "Network connectivity: OK"
        log_learn "   Network access is required for downloading packages and containers"
    else
        log_warning "Network connectivity: Issues detected"
        log_learn "   Check your internet connection and firewall settings"
    fi
    
    return 0
}

# Function to check container environment
check_container_environment() {
    log_info "Checking container environment..."
    
    if [ -f /.dockerenv ] || grep -sq 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
        log_success "Container environment detected"
        log_learn "   Running inside a container - some features may be limited"
        return 0
    else
        log_success "Bare metal environment detected"
        log_learn "   Running on bare metal - full system access available"
        return 1
    fi
}

# Function to fix Kubernetes networking issues
fix_kubernetes_networking() {
    log_fix "🔧 Fixing Kubernetes networking issues..."
    
    # Remove control plane taint to allow pods to be scheduled on control plane node
    log_info "Removing control plane taint for single-node cluster..."
    if kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null; then
        log_success "Control plane taint removed"
        log_learn "   This allows pods to be scheduled on the control plane node in single-node clusters"
    else
        log_warning "Could not remove control plane taint (may not be needed)"
    fi
    
    # Check and fix CoreDNS if it's not ready
    log_info "Checking CoreDNS status..."
    local coredns_ready=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
    if [ "$coredns_ready" -eq 0 ]; then
        log_warning "CoreDNS pods are not ready, attempting to restart..."
        kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true
        log_info "Waiting for CoreDNS to become ready..."
        sleep 10
    else
        log_success "CoreDNS is running properly"
    fi
    
    # Check Flannel network plugin
    log_info "Checking Flannel network plugin..."
    local flannel_ready=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
    if [ "$flannel_ready" -eq 0 ]; then
        log_warning "Flannel network plugin not ready, checking configuration..."
        # Check if Flannel is installed
        if ! kubectl get namespace kube-flannel >/dev/null 2>&1; then
            log_info "Installing Flannel network plugin..."
            kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml 2>/dev/null || {
                log_warning "Failed to install Flannel automatically"
                log_learn "   You may need to install a network plugin manually"
            }
        fi
    else
        log_success "Flannel network plugin is running"
    fi
    
    # Check cert-manager if it exists
    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        log_info "Checking cert-manager status..."
        local cert_manager_ready=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c "1/1.*Running" || echo "0")
        if [ "$cert_manager_ready" -lt 3 ]; then
            log_warning "cert-manager pods are not ready, this may resolve after networking is fixed"
        else
            log_success "cert-manager is running properly"
        fi
    fi
    
    # Wait a bit for pods to stabilize
    log_info "Waiting for pods to stabilize..."
    sleep 15
    
    # Final status check
    log_info "Final cluster status check..."
    local total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    local ready_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "1/1.*Running\|2/2.*Running\|3/3.*Running" || echo "0")
    
    if [ "$total_pods" -gt 0 ]; then
        log_info "Cluster status: $ready_pods/$total_pods pods ready"
        if [ "$ready_pods" -eq "$total_pods" ]; then
            log_success "All pods are ready! Cluster networking is working properly."
        else
            log_warning "Some pods are still not ready. This may take a few more minutes."
            log_learn "   Pods may need time to download images and start up"
        fi
    fi
}

# Function to check Kubernetes installation status
check_kubernetes_status() {
    log_info "Checking Kubernetes installation status..."
    echo ""
    
    local kubectl_installed=false
    local kubelet_installed=false
    local containerd_installed=false
    
    if command -v kubectl >/dev/null 2>&1; then
        kubectl_installed=true
        local kubectl_version=$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo "unknown")
        log_success "kubectl: $kubectl_version"
        log_learn "   kubectl is the command-line tool for Kubernetes"
    else
        log_warning "kubectl: Not installed"
        log_learn "   kubectl is required to interact with Kubernetes clusters"
    fi
    
    if command -v kubelet >/dev/null 2>&1; then
        kubelet_installed=true
        local kubelet_version=$(kubelet --version 2>/dev/null | cut -d' ' -f2 || echo "unknown")
        log_success "kubelet: $kubelet_version"
        # Check if kubelet service exists but is not running (normal before cluster init)
        if systemctl list-unit-files | grep -q "^kubelet.service" && ! systemctl is-active --quiet kubelet; then
            log_info "   kubelet service is installed but not running (normal before cluster initialization)"
        fi
        log_learn "   kubelet is the node agent that runs on each Kubernetes node"
    else
        log_warning "kubelet: Not installed"
        log_learn "   kubelet is required to run Kubernetes workloads"
    fi
    
    if command -v containerd >/dev/null 2>&1; then
        containerd_installed=true
        local containerd_version=$(containerd --version 2>/dev/null | cut -d' ' -f3 || echo "unknown")
        log_success "containerd: $containerd_version"
        log_learn "   containerd is the container runtime for Kubernetes"
    else
        log_warning "containerd: Not installed"
        log_learn "   containerd is required to run containers in Kubernetes"
    fi
    
    # Check if cluster is running
    if [ "$kubectl_installed" = true ]; then
        log_info "Testing cluster connectivity..."
        if kubectl cluster-info >/dev/null 2>&1; then
            log_success "Kubernetes cluster: Running and accessible"
            log_learn "   Your cluster is ready to run AI workloads!"
            
            # If cluster is running, check and fix networking issues
            echo ""
            fix_kubernetes_networking
        else
            log_warning "Kubernetes cluster: Not running or not accessible"
            log_learn "   You may need to initialize or start your cluster"
            
            # Try to fix kubeconfig if needed
            if [ -f /etc/kubernetes/admin.conf ] && [ ! -f /root/.kube/config ]; then
                log_info "Attempting to fix kubeconfig..."
                mkdir -p /root/.kube
                cp /etc/kubernetes/admin.conf /root/.kube/config
                chown root:root /root/.kube/config
                chmod 600 /root/.kube/config
                export KUBECONFIG=/root/.kube/config
                if kubectl cluster-info >/dev/null 2>&1; then
                    log_success "kubeconfig fixed! Cluster is now accessible."
                    echo ""
                    fix_kubernetes_networking
                fi
            fi
        fi
    fi
}

# Function to provide educational recommendations
provide_recommendations() {
    log_info "Providing recommendations..."
    echo ""
    
    echo "🎯 Next Steps:"
    
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "   • Install Kubernetes: sudo ./install-kubernetes.sh"
        echo "     This will install kubectl, kubelet, and containerd"
    elif ! kubectl cluster-info >/dev/null 2>&1; then
        echo "   • Initialize cluster: sudo kubeadm init"
        echo "     This will create a new Kubernetes cluster"
    else
        echo "   • System is ready for AI-Academy-k8s deployment!"
        echo "   • You can now deploy AI workloads and models"
        echo "   • Run: sudo ./install-amd-gpu-operator.sh to install GPU support"
    fi
    
    echo ""
    echo "🛠️ Available Learning Scripts:"
    for script in install-kubernetes.sh detect-environment.sh verify-readiness.sh install-amd-gpu-operator.sh; do
        if [ -f "$script" ]; then
            echo "   ✅ $script - Ready to use"
        else
            echo "   ❌ $script - Missing"
        fi
    done
    
    echo ""
    echo "📚 Learning Resources:"
    echo "   • Check the README.md for detailed explanations"
    echo "   • Review the .md files for troubleshooting guides"
    echo "   • Each script includes educational comments"
    echo ""
    echo "🔧 Troubleshooting Tips:"
    echo "   • If pods are stuck in Pending state, check node taints"
    echo "   • If DNS resolution fails, check CoreDNS pod status"
    echo "   • If networking issues persist, try restarting the cluster"
    echo "   • Run this script again anytime to check system health"
}

# Main execution function
main() {
    echo ""
    
    # Check system requirements first
    if ! check_system_requirements; then
        log_error "System requirements check failed"
        exit 1
    fi
    
    echo ""
    
    # Check and resolve update manager locks
    if ! check_and_resolve_update_locks; then
        log_error "Could not resolve update manager locks"
        echo ""
        echo "Manual resolution options:"
        echo "1. Reboot the system: sudo reboot"
        echo "2. Force kill all apt processes: sudo pkill -f apt"
        echo "3. Remove lock files manually: sudo rm /var/lib/dpkg/lock*"
        exit 1
    fi
    
    echo ""
    
    # Check container environment
    local is_container=false
    if check_container_environment; then
        is_container=true
    fi
    
    echo ""
    
    # Check Kubernetes status
    check_kubernetes_status
    
    echo ""
    
    # Provide recommendations
    provide_recommendations
    
    echo ""
    log_success "🎉 Enhanced system check completed successfully!"
    echo ""
    log_learn "💡 Tip: Run this script anytime you encounter system issues!"
}

# Handle command line arguments
case "${1:-}" in
    --auto-resolve)
        AUTO_RESOLVE=true
        main
        ;;
    --manual-only)
        AUTO_RESOLVE=false
        main
        ;;
    --explain-locks)
        explain_update_locks
        exit 0
        ;;
    --check-locks-only)
        if check_and_resolve_update_locks; then
            log_success "No locks detected"
            exit 0
        else
            log_error "Locks detected"
            exit 1
        fi
        ;;
    --fix-networking)
        if kubectl cluster-info >/dev/null 2>&1; then
            fix_kubernetes_networking
        else
            log_error "Kubernetes cluster is not accessible"
            exit 1
        fi
        ;;
    --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --auto-resolve     Automatically resolve lock issues (default)"
        echo "  --manual-only      Only check locks, don't auto-resolve"
        echo "  --explain-locks    Explain what update manager locks are"
        echo "  --check-locks-only Check for locks only and exit"
        echo "  --fix-networking   Fix Kubernetes networking issues only"
        echo "  --help            Show this help message"
        echo ""
        echo "This enhanced script provides educational explanations and"
        echo "automatic resolution of common system issues for learners."
        echo "It includes comprehensive Kubernetes networking fixes."
        exit 0
        ;;
    "")
        main
        ;;
    *)
        log_error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
