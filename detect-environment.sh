#!/bin/bash

echo "🔍 Environment Detection Report"
echo "================================"

# Check container environment
if [ -f /.dockerenv ] || grep -sq 'docker\|lxc' /proc/1/cgroup 2>/dev/null; then
    echo "🐳 Container Environment: YES"
    CONTAINER=true
else
    echo "🖥️ Container Environment: NO"
    CONTAINER=false
fi

# Check systemd
if pidof systemd > /dev/null 2>&1; then
    echo "⚙️ Systemd Available: YES"
    SYSTEMD=true
else
    echo "⚙️ Systemd Available: NO"
    SYSTEMD=false
fi

# Check if this is likely a cloud instance
if grep -q "cloud" /proc/version 2>/dev/null || [ -d /sys/class/dmi/id/ ]; then
    echo "☁️ Cloud Instance: LIKELY"
else
    echo "☁️ Cloud Instance: UNKNOWN"
fi

echo ""
echo "📋 Recommendation:"

if [ "$CONTAINER" = true ] || [ "$SYSTEMD" = false ]; then
    echo "✅ Use: sudo ./install-kubernetes-container.sh"
    echo "   This script is designed for container/cloud environments"
    echo "   It will install kubectl tools and optionally create a kind cluster"
else
    echo "✅ Use: sudo ./install-kubernetes.sh"  
    echo "   This script will install a full single-node Kubernetes cluster"
fi

echo ""
echo "🛠️ Available scripts:"
for script in install-kubernetes.sh install-kubernetes-container.sh; do
    if [ -f "$script" ]; then
        echo "   ✅ $script"
    else
        echo "   ❌ $script (missing)"
    fi
done
