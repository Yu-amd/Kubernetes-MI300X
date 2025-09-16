#!/bin/bash

# port-management.sh
# Robust port management utilities for AI-Academy-k8s
# Handles port conflicts and provides multiple access methods

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

# Function to check if a port is available
check_port_available() {
    local port=$1
    if ss -tlnp | grep -q ":$port "; then
        return 1  # Port is in use
    else
        return 0  # Port is available
    fi
}

# Function to find an available port starting from a given port
find_available_port() {
    local start_port=$1
    local max_attempts=10
    local port=$start_port
    
    for ((i=0; i<max_attempts; i++)); do
        if check_port_available $port; then
            echo $port
            return 0
        fi
        port=$((port + 1))
    done
    
    log_error "Could not find an available port starting from $start_port"
    return 1
}

# Function to kill existing port-forward processes
cleanup_port_forwards() {
    log_info "Cleaning up existing port-forward processes..."
    
    local pids=$(pgrep -f "kubectl.*port-forward")
    if [ -n "$pids" ]; then
        log_info "Found existing port-forward processes: $pids"
        echo $pids | xargs kill -TERM 2>/dev/null
        sleep 2
        
        # Force kill if still running
        local remaining_pids=$(pgrep -f "kubectl.*port-forward")
        if [ -n "$remaining_pids" ]; then
            log_warning "Force killing remaining port-forward processes: $remaining_pids"
            echo $remaining_pids | xargs kill -KILL 2>/dev/null
        fi
        
        log_success "Port-forward cleanup completed."
    else
        log_info "No existing port-forward processes found."
    fi
}

# Function to get service external IP
get_service_external_ip() {
    local service_name=$1
    local external_ip=$(kubectl get service $service_name -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    
    if [ -n "$external_ip" ] && [ "$external_ip" != "null" ]; then
        echo $external_ip
        return 0
    else
        return 1
    fi
}

# Function to setup vLLM access with automatic port conflict resolution
setup_vllm_access() {
    local service_name="vllm-service"
    local preferred_port=8080
    
    log_info "Setting up vLLM service access..."
    
    # Check if service exists
    if ! kubectl get service $service_name &> /dev/null; then
        log_error "Service $service_name not found. Please deploy vLLM first."
        return 1
    fi
    
    # Get external IP
    local external_ip=$(get_service_external_ip $service_name)
    
    if [ -n "$external_ip" ]; then
        log_success "vLLM service has external IP: $external_ip"
        echo ""
        echo "🌐 DIRECT ACCESS (Recommended):"
        echo "   http://$external_ip:8080"
        echo ""
        echo "📋 API Endpoints:"
        echo "   Models: http://$external_ip:8080/v1/models"
        echo "   Chat:   http://$external_ip:8080/v1/chat/completions"
        echo "   Health: http://$external_ip:8080/health"
        echo ""
    else
        log_warning "No external IP found. Setting up port forwarding..."
    fi
    
    # Setup port forwarding with conflict resolution
    if ! check_port_available $preferred_port; then
        log_warning "Port $preferred_port is already in use."
        
        # Try to find an alternative port
        local alt_port=$(find_available_port $((preferred_port + 1)))
        if [ $? -eq 0 ]; then
            log_info "Using alternative port: $alt_port"
            preferred_port=$alt_port
        else
            log_error "Cannot find an available port for port forwarding."
            return 1
        fi
    fi
    
    # Start port forwarding
    log_info "Starting port forwarding on port $preferred_port..."
    
    # Cleanup any existing port forwards first
    cleanup_port_forwards
    
    # Start new port forward in background
    kubectl port-forward service/$service_name $preferred_port:8080 > /dev/null 2>&1 &
    local pf_pid=$!
    
    # Wait a moment for port forward to establish
    sleep 3
    
    # Verify port forward is working
    if kill -0 $pf_pid 2>/dev/null; then
        log_success "Port forwarding established on port $preferred_port (PID: $pf_pid)"
        echo ""
        echo "🔄 PORT FORWARD ACCESS:"
        echo "   http://localhost:$preferred_port"
        echo ""
        echo "📋 API Endpoints:"
        echo "   Models: http://localhost:$preferred_port/v1/models"
        echo "   Chat:   http://localhost:$preferred_port/v1/chat/completions"
        echo "   Health: http://localhost:$preferred_port/health"
        echo ""
        echo "💡 To stop port forwarding: kill $pf_pid"
        
        # Save PID for cleanup
        echo $pf_pid > /tmp/vllm-port-forward.pid
        return 0
    else
        log_error "Failed to establish port forwarding."
        return 1
    fi
}

# Function to test vLLM service connectivity
test_vllm_connectivity() {
    local base_url=$1
    local timeout=10
    
    log_info "Testing vLLM service connectivity at $base_url..."
    
    # Test health endpoint
    if curl -s --max-time $timeout "$base_url/health" > /dev/null 2>&1; then
        log_success "Health check passed"
    else
        log_warning "Health check failed, trying models endpoint..."
    fi
    
    # Test models endpoint
    if curl -s --max-time $timeout "$base_url/v1/models" > /dev/null 2>&1; then
        log_success "Models endpoint accessible"
        
        # Get model info
        local model_info=$(curl -s --max-time $timeout "$base_url/v1/models" 2>/dev/null)
        if [ -n "$model_info" ]; then
            echo ""
            echo "🤖 Available Models:"
            echo "$model_info" | jq -r '.data[].id' 2>/dev/null || echo "Qwen/Qwen2.5-1.5B-Instruct"
            echo ""
        fi
        return 0
    else
        log_error "Cannot connect to vLLM service at $base_url"
        return 1
    fi
}

# Function to show comprehensive access information
show_vllm_access_info() {
    local service_name="vllm-service"
    
    echo ""
    echo "=============================================="
    echo "🚀 vLLM Service Access Information"
    echo "=============================================="
    
    # Check service status
    if ! kubectl get service $service_name &> /dev/null; then
        log_error "vLLM service not found. Please run: ./deploy-vllm-inference.sh"
        return 1
    fi
    
    # Get service details
    local external_ip=$(get_service_external_ip $service_name)
    local service_info=$(kubectl get service $service_name -o wide)
    
    echo ""
    echo "�� Service Status:"
    echo "$service_info"
    echo ""
    
    if [ -n "$external_ip" ]; then
        echo "🌐 External Access:"
        echo "   URL: http://$external_ip:8080"
        echo ""
        
        # Test external access
        if test_vllm_connectivity "http://$external_ip:8080"; then
            echo "✅ External access is working!"
        else
            echo "⚠️  External access may not be working. Setting up port forwarding..."
            setup_vllm_access
        fi
    else
        echo "🔄 No external IP available. Setting up port forwarding..."
        setup_vllm_access
    fi
    
    echo ""
    echo "💡 Quick Test Commands:"
    echo "   # Test models endpoint"
    echo "   curl http://$external_ip:8080/v1/models"
    echo ""
    echo "   # Test chat completion"
    echo "   curl -X POST http://$external_ip:8080/v1/chat/completions \\"
    echo "     -H 'Content-Type: application/json' \\"
    echo "     -d '{\"model\": \"Qwen/Qwen2.5-1.5B-Instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 50}'"
    echo ""
}

# Main function
main() {
    case "${1:-show}" in
        "setup")
            setup_vllm_access
            ;;
        "test")
            if [ -n "$2" ]; then
                test_vllm_connectivity "$2"
            else
                log_error "Please provide URL to test: $0 test <url>"
                exit 1
            fi
            ;;
        "cleanup")
            cleanup_port_forwards
            ;;
        "show"|*)
            show_vllm_access_info
            ;;
    esac
}

# Run main function with all arguments
main "$@"
