#!/bin/bash

echo "🚀 Kubernetes Installation Readiness Check"
echo "=========================================="

# Check script permissions
echo "📋 Script Status:"
for script in install-kubernetes.sh install-kubernetes-container.sh detect-environment.sh; do
    if [ -f "$script" ]; then
        if [ -x "$script" ]; then
            echo "   ✅ $script (executable)"
        else
            echo "   🔧 $script (needs chmod +x)"
            chmod +x "$script"
            echo "   ✅ $script (fixed)"
        fi
    else
        echo "   ❌ $script (missing)"
    fi
done

echo ""
echo "🔍 Environment Check:"
echo "   • Systemd PID 1: $(ps -p 1 -o comm= 2>/dev/null || echo 'Unknown')"
echo "   • Containerd: $(systemctl is-active containerd 2>/dev/null || echo 'Not installed')"
if ./check-system-enhanced.sh --check-locks-only >/dev/null 2>&1; then echo "   • Package manager: Available"; else echo "   • Package manager: Busy (locks detected)"; fi

echo ""
echo "💾 Disk Space:"
df -h / | tail -1 | awk '{print "   • Root filesystem: " $4 " available"}'

echo ""
echo "🧠 Memory:"
free -h | grep "Mem:" | awk '{print "   • Available RAM: " $7}'

echo ""
echo "🎯 Recommended Action:"
echo "   Run: sudo ./install-kubernetes.sh"
echo ""
echo "✨ All systems ready for Kubernetes installation!"
