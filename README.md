# Getting Started with Kubernetes on AMD GPUs 

This repository contains a comprehensive tutorial for deploying and managing AI inference workloads on Kubernetes clusters with AMD GPUs.                           

## 🚀 Quick Start

### Prerequisites

- Ubuntu/Debian server with AMD GPUs
- Root/sudo access
- At least 2GB RAM and 20GB free disk space
- Internet connectivity for package downloads

### Step 0: System Check and Preparation (Recommended)

Before starting the installation, run the enhanced system check to ensure your system is ready and resolve any potential issues:

```bash
sudo ./check-system-enhanced.sh
```

This educational script will:
- **Auto-detect and resolve** update manager lock issues (common problem)
- **Explain** what each check does and why it's important
- **Verify** system requirements (OS, disk space, memory, network)
- **Detect** container environment vs bare metal
- **Check** Kubernetes installation status
- **Provide** learning recommendations and next steps

### Complete Installation from Scratch

#### Step 1: Install Kubernetes 

```bash
sudo ./install-kubernetes.sh
```

This script will:
- Install vanilla Kubernetes 1.28+ on Ubuntu/Debian
- Configure containerd container runtime
- Set up Calico CNI networking
- Configure single-node cluster (removes control-plane taints)
- Disable swap and configure kernel settings
- Verify cluster functionality

#### Step 2: Install AMD GPU Operator

```bash
./install-amd-gpu-operator.sh
```

This script will:
- Install Helm (if not present)
- Install cert-manager (prerequisite)
- Install AMD GPU Operator
- Configure device settings for vanilla Kubernetes
- Set up persistent storage for AI models
- Verify the installation

#### Step 3: Deploy vLLM AI Inference

```bash
./deploy-vllm-inference.sh
```

This script will:
- Install MetalLB load balancer
- Deploy vLLM inference server with Llama-3.2-1B model
- Create LoadBalancer service for external access
- Generate test scripts for API validation

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│                Applications                 │
│  ┌─────────────┐  ┌─────────────┐           │
│  │    vLLM     │  │  Jupyter    │   ...     │
│  │  Inference  │  │ Notebooks   │           │
│  └─────────────┘  └─────────────┘           │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│            Kubernetes Layer                 │
│  ┌──────────┐ ┌──────────┐ ┌───────────┐    │
│  │   Pods   │ │ Services │ │Deployments│    │
│  └──────────┘ └──────────┘ └───────────┘    │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│           AMD GPU Operator                  │
│  ┌──────────────┐  ┌─────────────────┐      │
│  │Device Plugin │  │  Node Labeller  │      │
│  └──────────────┘  └─────────────────┘      │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│         Hardware Infrastructure             │
│  ┌─────────────────────────────────────┐    │
│  │     AMD Instinct MI300X GPUs        │    │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐    │    │
│  │  │GPU 0│ │GPU 1│ │GPU 2│ │GPU 3│    │    │
│  │  └─────┘ └─────┘ └─────┘ └─────┘    │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```
