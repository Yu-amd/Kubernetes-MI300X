#!/bin/bash

# deploy-vllm-inference.sh
# Deploys vLLM inference server with MetalLB load balancing on vanilla Kubernetes
# Based on ROCm blog series: https://rocm.blogs.amd.com/artificial-intelligence/k8s-orchestration-part2/

set -e  # Exit on any error

echo "=============================================="
echo "vLLM AI Inference Deployment Script"
echo "Target: Vanilla Kubernetes with AMD GPUs"
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
    
    # Check if AMD GPU Operator is installed
    if ! kubectl get namespace kube-amd-gpu &> /dev/null; then
        log_error "AMD GPU Operator not found. Please run install-amd-gpu-operator.sh first."
        exit 1
    fi
    
    # Check if nodes have GPU resources
    GPU_NODES=$(kubectl get nodes -o custom-columns=NAME:.metadata.name,"GPUs:.status.capacity.amd\.com/gpu" --no-headers | grep -v '<none>' | wc -l)
    if [ "$GPU_NODES" -eq 0 ]; then
        log_warning "No nodes with AMD GPU resources found. Deployment may fail."
    else
        log_success "Found $GPU_NODES node(s) with AMD GPU resources."
    fi
    
    
    # Check if storage directories can be created
    log_info "Checking storage prerequisites..."
    if ! sudo mkdir -p /tmp/storage-test 2>/dev/null; then
        log_error "Cannot create directories with sudo. Please ensure sudo access is available."
        exit 1
    fi
    sudo rmdir /tmp/storage-test
    log_success "Storage prerequisites check passed."
    log_success "Prerequisites check completed."
}

# Function to install MetalLB load balancer
install_metallb() {
    log_info "Installing MetalLB load balancer..."
    
    # Check if MetalLB is already installed
    if kubectl get namespace metallb-system &> /dev/null; then
        log_info "MetalLB already installed. Skipping installation."
        return 0
    fi
    
    # Install MetalLB using manifests
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
    
    # Wait for MetalLB pods to be ready
    log_info "Waiting for MetalLB to be ready..."
    kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=90s
    
    log_success "MetalLB installed successfully."
}

# Function to configure MetalLB IP pool
configure_metallb() {

    echo ""
    log_info "Configuring MetalLB IP address pool..."
    
    # Use dynamic configuration generator
    if [ -f "./metallb-config-generator.sh" ]; then
        log_info "Using dynamic MetalLB configuration generator..."
        ./metallb-config-generator.sh > /dev/null
        
        # Apply the generated configuration
        kubectl apply -f metallb-config.yaml
        
        # Get the IP range for logging
        local ip_range=$(grep "addresses:" -A1 metallb-config.yaml | tail -1 | sed "s/.*- //")
        log_success "MetalLB configured with IP range: $ip_range"
    else
        log_warning "Dynamic configuration generator not found. Using fallback method..."
        
        # Fallback to original method
        NODE_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[?(@.type=="InternalIP")].address}")
        log_info "Detected node IP: $NODE_IP"
        
        IP_PREFIX=$(echo $NODE_IP | cut -d. -f1-3)
        IP_RANGE="${IP_PREFIX}.240-${IP_PREFIX}.250"
        
        log_info "Using IP range: $IP_RANGE"
        
        cat > metallb-config.yaml << CONFIG_EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - $IP_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
CONFIG_EOF
        
        kubectl apply -f metallb-config.yaml
        log_success "MetalLB configured with IP range: $IP_RANGE"
    fi
}


# Function to setup storage for vLLM models
setup_storage() {
    log_info "Setting up storage for vLLM models..."
    
    # Define storage path
    STORAGE_PATH="/data/qwen-2.5-1.5b"
    
    # Create storage directory if it doesn't exist
    log_info "Ensuring storage directory exists: $STORAGE_PATH"
    if [ ! -d "$STORAGE_PATH" ]; then
        log_info "Creating storage directory: $STORAGE_PATH"
        sudo mkdir -p "$STORAGE_PATH"
        if [ $? -ne 0 ]; then
            log_error "Failed to create storage directory: $STORAGE_PATH"
            exit 1
        fi
        sudo chmod 755 "$STORAGE_PATH"
        log_success "Storage directory created successfully."
    else
        log_info "Storage directory already exists: $STORAGE_PATH"
    fi
    
    # Check if PVC already exists
    if kubectl get pvc qwen-2.5-1.5b &> /dev/null; then
        log_info "PVC qwen-2.5-1.5b already exists. Skipping creation."
        return 0
    fi
    
    # Check if PV already exists
    if ! kubectl get pv qwen-2.5-1.5b-pv &> /dev/null; then
        log_info "Creating PersistentVolume for model storage..."
        cat > qwen-pv.yaml << PV_EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: qwen-2.5-1.5b-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  hostPath:
    path: $STORAGE_PATH
PV_EOF
        kubectl apply -f qwen-pv.yaml
        log_success "PersistentVolume created."
    else
        log_info "PersistentVolume qwen-2.5-1.5b-pv already exists."
    fi
    
    # Create PVC
    log_info "Creating PersistentVolumeClaim for model storage..."
    kubectl apply -f qwen-pvc.yaml
    
    # Check PVC status - with WaitForFirstConsumer mode, PVC won't bind until pod is created
    log_info "Checking PVC status..."
    PVC_STATUS=$(kubectl get pvc qwen-2.5-1.5b -o jsonpath='{.status.phase}')
    
    if [ "$PVC_STATUS" = "Bound" ]; then
        log_success "PVC is already bound."
    elif [ "$PVC_STATUS" = "Pending" ]; then
        log_info "PVC is pending (WaitForFirstConsumer mode). This is expected."
        log_info "PVC will bind when the first pod using it is created."
    else
        log_warning "PVC status: $PVC_STATUS"
    fi
    
    log_success "Storage setup completed successfully."
}

# Function to deploy vLLM inference server
deploy_vllm() {
    log_info "Deploying vLLM inference server..."

    # Validate that required PVC exists
    if ! kubectl get pvc qwen-2.5-1.5b &> /dev/null; then
        log_error "Required PVC qwen-2.5-1.5b not found!"
        log_error "Please ensure storage setup completed successfully."
        exit 1
    fi
    
    log_info "Verified PVC qwen-2.5-1.5b exists."
    
    # Create vLLM deployment manifest
    cat > vllm-deployment.yaml << 'VLLM_EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-inference
  namespace: default
  labels:
    app: vllm-inference
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-inference
  template:
    metadata:
      labels:
        app: vllm-inference
    spec:
      containers:
      - name: vllm-container
        image: rocm/vllm:latest
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          value: ""  # Add your HF token if needed for gated models
        command:
        - "python"
        - "-m"
        - "vllm.entrypoints.openai.api_server"
        args:
        - "--model"
        - "Qwen/Qwen2.5-1.5B-Instruct"  # Small model for demo
        - "--host"
        - "0.0.0.0"
        - "--port"
        - "8080"
        - "--download-dir"
        - "/models"
        - "--tensor-parallel-size"
        - "1"
        volumeMounts:
        - name: model-storage
          mountPath: /models
        resources:
          requests:
            amd.com/gpu: 1
            memory: "8Gi"
            cpu: "2"
          limits:
            amd.com/gpu: 1
            memory: "16Gi"
            cpu: "4"
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 30
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: qwen-2.5-1.5b
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: amd.com/gpu
        operator: Exists
        effect: NoSchedule
VLLM_EOF

    # Apply vLLM deployment
    kubectl apply -f vllm-deployment.yaml
    
    log_success "vLLM deployment created."
}

# Function to create vLLM service with LoadBalancer
create_vllm_service() {
    log_info "Creating vLLM service with LoadBalancer..."
    
    # Create service manifest
    cat > vllm-service.yaml << 'SERVICE_EOF'
apiVersion: v1
kind: Service
metadata:
  name: vllm-service
  namespace: default
  labels:
    app: vllm-inference
spec:
  type: LoadBalancer
  selector:
    app: vllm-inference
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
    name: http
  - port: 8080
    targetPort: 8080
    protocol: TCP
    name: api
SERVICE_EOF

    # Apply service
    kubectl apply -f vllm-service.yaml
    
    log_success "vLLM service created."
}

# Function to wait for deployment and get access information
wait_and_verify() {
    log_info "Waiting for vLLM deployment to be ready..."
    
    # Wait for deployment to be ready
    kubectl wait --for=condition=available deployment/vllm-inference --timeout=600s
    
    # Wait for service to get external IP
    log_info "Waiting for LoadBalancer to assign external IP..."
    EXTERNAL_IP=""
    for i in {1..30}; do
        EXTERNAL_IP=$(kubectl get service vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
            break
        fi
        echo "Waiting for external IP... (attempt $i/30)"
        sleep 10
    done
    
    if [ -z "$EXTERNAL_IP" ] || [ "$EXTERNAL_IP" = "null" ]; then
        log_warning "External IP not assigned. Using NodePort or port-forward to access the service."
        echo ""
        echo "Setting up robust port forwarding with conflict resolution..."
        if [ -f "./port-management.sh" ]; then
            ./port-management.sh setup
        else
            echo "Port management script not found. Using basic port-forward:"
            echo "kubectl port-forward service/vllm-service 8080:8080"
            echo "Then access http://localhost:8080"
        fi
    else
        log_success "vLLM service is accessible at: http://$EXTERNAL_IP"
        echo "API endpoint: http://$EXTERNAL_IP/v1/completions"
        echo "Health check: http://$EXTERNAL_IP/health"
    fi
}

# Function to create test scripts
create_test_scripts() {
    log_info "Creating test scripts..."
    
    # Create a simple test script
    cat > test-vllm-api.sh << 'TEST_EOF'
#!/bin/bash

# Function to check if port-forward is already running
check_existing_port_forward() {
    local existing_pid=$(pgrep -f "kubectl.*port-forward.*vllm-service")
    if [ -n "$existing_pid" ]; then
        # Get the port from the existing port-forward command
        local port_info=$(ps -p $existing_pid -o args= | grep -o '[0-9]*:8080' | head -1)
        if [ -n "$port_info" ]; then
            local port=$(echo $port_info | cut -d: -f1)
            echo $port
            return 0
        fi
    fi
    return 1
}

# Function to get external IP if available
get_external_ip() {
    kubectl get service vllm-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}

echo "Testing vLLM API..."

# Check if external IP is available (preferred method)
EXTERNAL_IP=$(get_external_ip)
if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "Using external IP access: $EXTERNAL_IP"
    ENDPOINT="http://$EXTERNAL_IP:8080"
    echo "🌐 External access: $ENDPOINT"
else
    echo "No external IP available. Checking for existing port-forward..."
    
    # Check if port-forward is already running
    EXISTING_PORT=$(check_existing_port_forward)
    if [ -n "$EXISTING_PORT" ]; then
        echo "✅ Found existing port-forward on port $EXISTING_PORT"
        ENDPOINT="http://localhost:$EXISTING_PORT"
        echo "🔄 Using existing port-forward: $ENDPOINT"
    else
        echo "No existing port-forward found. Setting up new one..."
        if [ -f "./port-management.sh" ]; then
            echo "Using port-management.sh for robust port handling..."
            ./port-management.sh setup
            # Get the port from the output
            PORT=$(./port-management.sh setup 2>/dev/null | grep "localhost:" | head -1 | sed "s/.*localhost://" | sed "s/[^0-9].*//")
            if [ -z "$PORT" ]; then
                PORT="8080"  # Fallback to default port
            fi
            ENDPOINT="http://localhost:$PORT"
        else
            echo "Using basic port-forward..."
            kubectl port-forward service/vllm-service 8080:8080 &
            PORT_FORWARD_PID=$!
            sleep 5
            ENDPOINT="http://localhost:8080"
        fi
    fi
fi

echo "Testing vLLM API at: $ENDPOINT"

# Test health endpoint
echo "1. Testing health endpoint..."
HEALTH_RESPONSE=$(curl -s -w "%{http_code}" "$ENDPOINT/health")
HTTP_CODE="${HEALTH_RESPONSE: -3}"
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Health check passed (HTTP $HTTP_CODE)"
else
    echo "❌ Health check failed (HTTP $HTTP_CODE)"
fi

echo -e "
2. Testing completions endpoint..."
# Test completions endpoint
curl -X POST "$ENDPOINT/v1/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "Qwen/Qwen2.5-1.5B-Instruct",
        "prompt": "Explain the benefits of using Kubernetes for AI workloads:",
        "max_tokens": 100,
        "temperature": 0.7
    }' | jq .

# Cleanup port-forward if we created one
if [ -n "$PORT_FORWARD_PID" ]; then
    kill $PORT_FORWARD_PID 2>/dev/null
fi

TEST_EOF

    chmod +x test-vllm-api.sh
    
    
    log_success "Test script created: test-vllm-api.sh"
}

# Function to display deployment information
show_deployment_info() {
    echo ""
    echo "=============================================="
    log_success "vLLM Deployment Complete!"
    echo "=============================================="
    echo ""
    
    echo "Deployment Status:"
    kubectl get deployment vllm-inference
    echo ""
    
    echo "Service Information:"
    kubectl get service vllm-service
    echo ""
    
    echo "Pod Status:"
    kubectl get pods -l app=vllm-inference
    echo ""
    
    echo "GPU Resource Usage:"
    kubectl describe nodes | grep -A 5 "amd.com/gpu" || echo "GPU resources not visible in describe output"
    echo ""
    
    echo "Files created:"
    echo "- vllm-deployment.yaml: vLLM inference server deployment"
    echo "- vllm-service.yaml: LoadBalancer service for vLLM"
    echo "- ./port-management.sh show  # Get comprehensive access information"
    echo "- test-vllm-api.sh: Script to test the API"
    echo ""
    
    echo "Next Steps - Try the vLLM Demo Applications:"
    echo "- ./test-vllm-api.sh  # Test the API with command line"
    echo "- python vllm_demo.py  # Interactive command-line demo"
    echo "- python vllm_web_demo.py  # Web UI demo (requires port-forward)"
    echo ""

    echo "Useful commands:"
    echo "- kubectl get pods -l app=vllm-inference  # Check vLLM pods"
    echo "- kubectl logs -l app=vllm-inference  # Check vLLM logs"
    echo "- kubectl port-forward service/vllm-service 8080:8080  # Access via port-forward"
    echo "- ./test-vllm-api.sh  # Test the API"
    echo ""
}

# Main execution
main() {
    echo "Starting vLLM inference deployment..."
    echo "Timestamp: $(date)"
    echo ""
    
    check_prerequisites
    echo ""
    
    install_metallb
    echo ""
    
    configure_metallb

    setup_storage
    echo ""
    echo ""
    
    deploy_vllm
    echo ""
    
    create_vllm_service
    echo ""
    
    wait_and_verify
    echo ""
    
    create_test_scripts
    echo ""
    
    show_deployment_info
}

# Run main function
main "$@"
