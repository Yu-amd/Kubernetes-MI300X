#!/bin/bash

# metallb-config-generator.sh
# Generates dynamic MetalLB configuration based on the current environment

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Detect network configuration
detect_network_config() {
    log_info "Detecting network configuration..."
    
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    
    if [ -z "$node_ip" ]; then
        log_error "Could not detect node internal IP"
        return 1
    fi
    
    log_success "Node internal IP: $node_ip"
    
    local network_prefix=$(echo $node_ip | cut -d. -f1-3)
    local start_ip="$network_prefix.240"
    local end_ip="$network_prefix.250"
    
    echo "$start_ip-$end_ip"
}

# Generate MetalLB configuration
generate_metallb_config() {
    local ip_range=$1
    
    cat > metallb-config.yaml << YAML_EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - $ip_range
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
YAML_EOF

    log_success "MetalLB configuration generated with IP range: $ip_range"
}

# Main function
main() {
    local ip_range=$(detect_network_config)
    if [ $? -eq 0 ]; then
        generate_metallb_config "$ip_range"
        echo ""
        echo "Generated configuration:"
        cat metallb-config.yaml
    else
        log_error "Failed to detect network configuration"
        exit 1
    fi
}

main "$@"
