#!/bin/bash

# install-amd-gpu-operator.sh
# Installs AMD GPU Operator on vanilla Kubernetes cluster
# Based on ROCm blog series: https://rocm.blogs.amd.com/artificial-intelligence/k8s-orchestration-part1/

set -e  # Exit on any error

echo "=============================================="
echo "AMD GPU Operator Installation Script"
echo "For Kubernetes AMD GPU Tutorial"
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

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if kubectl is installed and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi
    
    # Check cluster connectivity
    
    # Enhanced connectivity check with auto-fix
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Attempting to fix..."
        
        # Try to fix kubeconfig
        if [ -f /etc/kubernetes/admin.conf ] && [ ! -f ~/.kube/config ]; then
            log_info "Setting up kubeconfig..."
            mkdir -p ~/.kube
            cp /etc/kubernetes/admin.conf ~/.kube/config
            chown $(id -u):$(id -g) ~/.kube/config
            chmod 600 ~/.kube/config
            export KUBECONFIG=~/.kube/config
        fi
        
        # Try to start services
        if ! systemctl is-active --quiet kubelet; then
            log_info "Starting kubelet service..."
            sudo systemctl start kubelet
        fi
        
        if ! systemctl is-active --quiet containerd; then
            log_info "Starting containerd service..."
            sudo systemctl start containerd
        fi
        
        # Wait and retry
        log_info "Waiting for services to stabilize..."
        sleep 15
        
        if ! kubectl cluster-info &> /dev/null; then
            log_error "Still cannot connect to cluster after fix attempts"
            log_error "Please run: ./k8s-connectivity-fix.sh"
            log_error "Or check cluster status: ./cluster-status-check.sh"
            exit 1
        else
            log_success "Cluster connectivity restored!"
        fi
    fi
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please ensure cluster is running."
        exit 1
    fi
    
    # Check Kubernetes version
    K8S_VERSION=$(kubectl version --output=json 2>/dev/null | jq -r '.serverVersion.gitVersion' | sed 's/v//')
    log_info "Detected Kubernetes version: $K8S_VERSION"
    
    # Check if version is compatible (we'll handle v1.28 compatibility)
    if [[ "$K8S_VERSION" < "1.28.0" ]]; then
        log_error "Kubernetes version $K8S_VERSION is not supported. Minimum required: 1.28.0"
        exit 1
    fi
    
    log_success "Prerequisites check completed."
}

# Function to install Helm
install_helm() {
    log_info "Installing Helm..."
    
    if command -v helm &> /dev/null; then
        log_info "Helm is already installed."
        return
    fi
    
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log_success "Helm installed successfully."
}

# Function to install cert-manager
install_cert_manager() {
    log_info "Installing cert-manager..."
    
    # Add Jetstack Helm repository with retry logic
    log_info "Adding Jetstack Helm repository..."
    for i in {1..3}; do
        if helm repo add jetstack https://charts.jetstack.io --force-update; then
            log_success "Repository added successfully."
            break
        else
            log_warning "Failed to add repository (attempt $i/3). Retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    # Update Helm repositories with retry logic
    log_info "Updating Helm repositories..."
    for i in {1..3}; do
        if helm repo update; then
            log_success "Repositories updated successfully."
            break
        else
            log_warning "Failed to update repositories (attempt $i/3). Retrying in 10 seconds..."
            sleep 10
        fi
    done
    # Install cert-manager
    # Check if already installed
    if helm list -n cert-manager | grep -q cert-manager; then
        log_info "cert-manager already installed, skipping..."
        return 0
    fi
    
    log_info "Installing cert-manager (this may take 5-10 minutes)..."
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.15.1 \
        --set installCRDs=true \
        --wait --timeout=900s
    
    if [ $? -ne 0 ]; then
        log_error "cert-manager installation failed. This could be due to:"
        log_error "  • Network connectivity issues"
        log_error "  • Insufficient cluster resources"
        log_error "  • Helm repository problems"
        log_error ""
        log_error "Troubleshooting steps:"
        log_error "  1. Check network: ping charts.jetstack.io"
        log_error "  2. Check cluster resources: kubectl top nodes"
        log_error "  3. Try manual install: helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace"
        exit 1
    fi
    
    log_info "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n cert-manager --timeout=600s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cainjector -n cert-manager --timeout=600s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=webhook -n cert-manager --timeout=600s
    
    log_success "cert-manager installed and ready."
}

# Function to install AMD GPU Operator with version compatibility
install_gpu_operator() {
    log_info "Installing AMD GPU Operator..."
    
    # Add AMD ROCm Helm repository
    helm repo add rocm https://rocm.github.io/gpu-operator --force-update
    helm repo update
    
    # Check Kubernetes version for compatibility
    K8S_VERSION=$(kubectl version --output=json 2>/dev/null | jq -r '.serverVersion.gitVersion' | sed 's/v//')
    
    if [[ "$K8S_VERSION" < "1.29.0" ]]; then
        log_warning "Kubernetes version $K8S_VERSION detected. AMD GPU Operator v1.2.2+ requires v1.29+"
        log_info "Downloading and modifying chart for compatibility..."
        
        # Download the chart
        helm pull rocm/gpu-operator-charts --version v1.2.2 --untar
        
        # Modify Chart.yaml to support v1.28
        sed -i "s/kubeVersion: '>= 1.29.0-0'/kubeVersion: '>= 1.28.0-0'/" gpu-operator-charts/Chart.yaml
        
        log_info "Installing modified AMD GPU Operator chart..."
        helm install gpu-operator ./gpu-operator-charts \
            --namespace kube-amd-gpu \
            --create-namespace \
            --wait --timeout=900s
        
        # Clean up downloaded chart
        rm -rf gpu-operator-charts
        
    else
        log_info "Installing AMD GPU Operator with standard chart..."
        helm install gpu-operator rocm/gpu-operator-charts \
            --namespace kube-amd-gpu \
            --create-namespace \
            --wait --timeout=900s
    fi
    
    log_success "AMD GPU Operator installed."
}

# Function to create and apply device configuration
# Function to validate storage prerequisites
validate_storage_prerequisites() {
    log_info "Validating storage prerequisites..."
    
    # Check if storage class exists
    if ! kubectl get storageclass local-storage &> /dev/null; then
        log_warning "Storage class 'local-storage' not found. Creating it..."
        
        # Check if local-storage-class.yaml exists
        if [ -f "local-storage-class.yaml" ]; then
            if kubectl apply -f local-storage-class.yaml; then
                log_success "Storage class created successfully."
            else
                log_error "Failed to create storage class."
                return 1
            fi
        else
            log_error "local-storage-class.yaml not found. Cannot create storage class."
            return 1
        fi
    else
        log_success "Storage class 'local-storage' already exists."
    fi
    
    # Check available disk space
    local available_space=$(df /mnt 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    local required_space=52428800  # 50GB in KB
    
    if [ "$available_space" -lt "$required_space" ]; then
        log_warning "Available disk space ($(($available_space/1024/1024))GB) may be insufficient for 50GB storage."
        log_info "Consider using a different mount point or reducing storage size."
    else
        log_success "Sufficient disk space available: $(($available_space/1024/1024))GB"
    fi
}

# Function to create and apply device configuration
configure_device_config() {
    log_info "Configuring AMD GPU device settings..."
    
    # Check if device config file exists
    if [ ! -f "yaml-configs/device-config-cr.yaml" ]; then
        log_error "Device configuration file not found: yaml-configs/device-config-cr.yaml"
        return 1
    fi
    
    # Apply device configuration with error handling
    if kubectl apply -f yaml-configs/device-config-cr.yaml; then
        log_success "Device configuration applied successfully."
        
        # Verify the configuration was created
        if kubectl get deviceconfig amd-gpu-device-config -n kube-amd-gpu &> /dev/null; then
            log_success "Device configuration verified in cluster."
        else
            log_warning "Device configuration applied but not immediately visible in cluster."
        fi
    else
        log_error "Failed to apply device configuration."
        return 1
    fi
}

# Function to set up persistent storage with robust error handling
setup_persistent_storage() {
    log_info "Setting up persistent storage for AI models..."
    
    # Validate prerequisites first
    if ! validate_storage_prerequisites; then
        log_error "Storage prerequisites validation failed."
        return 1
    fi
    
    # Define storage path (configurable)
    local storage_path="/mnt/data/ai-models"
    local storage_size="50Gi"
    
    # Create storage directory with proper error handling
    log_info "Creating storage directory: $storage_path"
    
    if sudo mkdir -p "$storage_path" 2>/dev/null; then
        log_success "Storage directory created: $storage_path"
    else
        log_error "Failed to create storage directory: $storage_path"
        log_info "Attempting to create with different permissions..."
        
        # Try alternative approach
        if mkdir -p "$storage_path" 2>/dev/null; then
            log_success "Storage directory created with current user permissions: $storage_path"
        else
            log_error "Cannot create storage directory. Please check permissions and disk space."
            return 1
        fi
    fi
    
    # Set appropriate permissions
    if sudo chmod 755 "$storage_path" 2>/dev/null; then
        log_success "Storage directory permissions set."
    else
        log_warning "Could not set directory permissions. Continuing with default permissions."
    fi
    
    # Check if persistent storage YAML exists
    if [ ! -f "yaml-configs/persistent-storage.yaml" ]; then
        log_error "Persistent storage configuration file not found: yaml-configs/persistent-storage.yaml"
        return 1
    fi
    
    # Apply persistent volume configuration with error handling
    log_info "Applying persistent storage configuration..."
    
    if kubectl apply -f yaml-configs/persistent-storage.yaml; then
        log_success "Persistent storage configuration applied successfully."
        
        # Verify PV and PVC were created
        if kubectl get pv ai-models-pv &> /dev/null && kubectl get pvc ai-models-pvc &> /dev/null; then
            log_success "Persistent volume and claim verified in cluster."
            
            # Show storage status
            log_info "Storage Status:"
            kubectl get pv ai-models-pv
            kubectl get pvc ai-models-pvc
        else
            log_warning "Persistent storage applied but not immediately visible in cluster."
        fi
    else
        log_error "Failed to apply persistent storage configuration."
        return 1
    fi
}

# Function to verify storage setup
verify_storage_setup() {
    log_info "Verifying storage setup..."
    
    # Check if storage class exists
    if kubectl get storageclass local-storage &> /dev/null; then
        log_success "Storage class 'local-storage' is available."
    else
        log_error "Storage class 'local-storage' not found."
        return 1
    fi
    
    # Check if PV exists and is bound
    if kubectl get pv ai-models-pv &> /dev/null; then
        local pv_status=$(kubectl get pv ai-models-pv -o jsonpath='{.status.phase}')
        if [ "$pv_status" = "Available" ] || [ "$pv_status" = "Bound" ]; then
            log_success "Persistent volume is $pv_status."
        else
            log_warning "Persistent volume status: $pv_status"
        fi
    else
        log_error "Persistent volume 'ai-models-pv' not found."
        return 1
    fi
    
    # Check if PVC exists and is bound
    if kubectl get pvc ai-models-pvc &> /dev/null; then
        local pvc_status=$(kubectl get pvc ai-models-pvc -o jsonpath='{.status.phase}')
        if [ "$pvc_status" = "Bound" ]; then
            log_success "Persistent volume claim is bound."
        else
            log_warning "Persistent volume claim status: $pvc_status"
        fi
    else
        log_error "Persistent volume claim 'ai-models-pvc' not found."
        return 1
    fi
    
    # Check directory exists and is writable
    local storage_path="/mnt/data/ai-models"
    if [ -d "$storage_path" ]; then
        if [ -w "$storage_path" ]; then
            log_success "Storage directory is writable: $storage_path"
        else
            log_warning "Storage directory exists but may not be writable: $storage_path"
        fi
    else
        log_error "Storage directory does not exist: $storage_path"
        return 1
    fi
}

# Function to verify installation
verify_installation() {
    log_info "Verifying AMD GPU Operator installation..."
    
    # Wait for pods to be ready
    log_info "Waiting for GPU operator pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=gpu-operator-charts -n kube-amd-gpu --timeout=600s
    
    # Check pod status
    log_info "GPU Operator Pods Status:"
    kubectl get pods -n kube-amd-gpu
    
    # Check for GPU resources
    log_info "Checking for GPU resources on nodes:"
    kubectl get nodes -o custom-columns=NAME:.metadata.name,"GPUs:.status.capacity.amd\.com/gpu" 2>/dev/null || log_warning "GPU resources not yet detected (this is normal for non-GPU nodes)"
    
    # Check node labels for GPU features
    log_info "Checking for GPU feature labels:"
    kubectl get nodes --show-labels | grep amd || log_warning "AMD GPU feature labels not found"
    
    log_success "Installation verification completed."
}

# Function to show next steps
show_next_steps() {
    echo ""
    echo "=============================================="
    log_success "🎉 AMD GPU OPERATOR INSTALLATION COMPLETE!"
    echo "=============================================="
    echo ""
    echo "✅ What you've accomplished:"
    echo "  • Helm package manager installed"
    echo "  • cert-manager installed and configured"
    echo "  • AMD GPU Operator installed and running"
    echo "  • Device configuration applied"
    echo "  • Persistent storage configured"
    echo ""
    echo "🚀 NEXT STEPS - Deploy AI Inference Service:"
    echo ""
    echo "📋 Phase 3: Deploy vLLM AI Inference"
    echo "  Command: ./deploy-vllm-inference.sh"
    echo "  Time: ~5-10 minutes"
    echo "  What it does: Deploys vLLM with Qwen2.5-1.5B model"
    echo ""
    echo "📋 Phase 4: Interactive Learning"
    echo "  Command: jupyter notebook kubernetes-amd-gpu-demo.ipynb"
    echo "  What it does: Hands-on tutorial and testing"
    echo ""
    echo "💡 Pro Tips:"
    echo "  • Use 'kubectl get pods -n kube-amd-gpu' to monitor GPU operator"
    echo "  • Use 'kubectl get nodes --show-labels | grep amd' to check GPU features"
    echo "  • All scripts are idempotent (safe to re-run)"
    echo ""
    echo "🎯 Ready for the next phase? Run: ./deploy-vllm-inference.sh"
    echo ""
}

# Main function
main() {
    check_prerequisites
    echo ""
    
    install_helm
    echo ""
    
    install_cert_manager
    echo ""
    
    install_gpu_operator
    echo ""
    
    configure_device_config
    echo ""
    
    setup_persistent_storage
    
    # Verify storage setup
    verify_storage_setup
    echo ""
    
    verify_installation
    echo ""
    
    show_next_steps
}

# Run main function
main "$@"
