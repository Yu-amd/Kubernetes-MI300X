# Getting Started with Kubernetes on AMD GPUs 

This repository contains a comprehensive tutorial for deploying and managing AI inference workloads on Kubernetes clusters with AMD GPUs.                           

## 🚀 Quick Start

### Prerequisites

- Ubuntu/Debian server with AMD GPUs
- Root/sudo access
- At least 2GB RAM and 20GB free disk space
- Internet connectivity for package downloads

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
