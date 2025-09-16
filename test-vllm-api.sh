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

