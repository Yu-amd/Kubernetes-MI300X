#!/usr/bin/env python3
import os
"""
vLLM API Demo Application
========================

This script demonstrates how to interact with the vLLM API endpoint
running on the AMD Instinct GPU with the Qwen model.

Usage:
    python vllm_demo.py

Features:
    - Chat completion
    - Model information
    - Health check
    - Interactive chat mode
"""

import requests
import json
import time
import sys
from typing import Dict, List, Optional

class VLLMClient:
    def __init__(self, base_url: str = None):
        if base_url is None:
            # Try to get IP from environment variable first
            vllm_ip = os.environ.get("VLLM_IP")
            if vllm_ip:
                base_url = f"http://{vllm_ip}:8080"
            else:
                # Auto-detect the IP from the service
                try:
                    import subprocess
                    result = subprocess.run(["kubectl", "get", "svc", "vllm-service", "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}"], 
                                          capture_output=True, text=True, timeout=10)
                    if result.returncode == 0 and result.stdout.strip():
                        base_url = f"http://{result.stdout.strip()}:8080"
                    else:
                        # Fallback to localhost if kubectl fails
                        base_url = "http://localhost:8080"
                except:
                    base_url = "http://localhost:8080"
        
        self.base_url = base_url
        print(f"🔗 Using vLLM endpoint: {self.base_url}")
        self.base_url = base_url
        print(f"🔗 Using vLLM endpoint: {self.base_url}")
        self.model = "Qwen/Qwen2.5-1.5B-Instruct"
    
    def health_check(self) -> bool:
        """Check if the vLLM service is healthy."""
        try:
            response = requests.get(f"{self.base_url}/health", timeout=10)
            return response.status_code == 200
        except requests.exceptions.RequestException:
            return False
    
    def get_models(self) -> List[Dict]:
        """Get available models."""
        try:
            response = requests.get(f"{self.base_url}/v1/models", timeout=10)
            response.raise_for_status()
            return response.json()["data"]
        except requests.exceptions.RequestException as e:
            print(f"Error getting models: {e}")
            return []
    
    def chat_completion(self, messages: List[Dict], max_tokens: int = 100, temperature: float = 0.7) -> Optional[str]:
        """Send a chat completion request."""
        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False
        }
        
        try:
            response = requests.post(
                f"{self.base_url}/v1/chat/completions",
                headers={"Content-Type": "application/json"},
                json=payload,
                timeout=30
            )
            response.raise_for_status()
            result = response.json()
            return result["choices"][0]["message"]["content"]
        except requests.exceptions.RequestException as e:
            print(f"Error in chat completion: {e}")
            return None
    
    def completion(self, prompt: str, max_tokens: int = 100, temperature: float = 0.7) -> Optional[str]:
        """Send a completion request (legacy format)."""
        payload = {
            "model": self.model,
            "prompt": prompt,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False
        }
        
        try:
            response = requests.post(
                f"{self.base_url}/v1/completions",
                headers={"Content-Type": "application/json"},
                json=payload,
                timeout=30
            )
            response.raise_for_status()
            result = response.json()
            return result["choices"][0]["text"]
        except requests.exceptions.RequestException as e:
            print(f"Error in completion: {e}")
            return None

def print_banner():
    """Print application banner."""
    print("=" * 60)
    print("🚀 vLLM API Demo Application")
    print("=" * 60)
    print("AMD Instinct MI300X GPU + Qwen2.5-1.5B-Instruct")
    print("=" * 60)

def demo_basic_usage():
    """Demonstrate basic API usage."""
    print("\n📋 BASIC API USAGE DEMO")
    print("-" * 30)
    
    client = VLLMClient()
    
    # Health check
    print("1. Health Check:")
    if client.health_check():
        print("   ✅ vLLM service is healthy")
    else:
        print("   ❌ vLLM service is not responding")
        return
    
    # Get models
    print("\n2. Available Models:")
    models = client.get_models()
    for model in models:
        print(f"   📦 {model['id']}")
        print(f"      Max Length: {model.get('max_model_len', 'N/A')}")
    
    # Chat completion
    print("\n3. Chat Completion:")
    messages = [
        {"role": "user", "content": "Hello! Can you tell me a short joke?"}
    ]
    
    print("   Sending: Hello! Can you tell me a short joke?")
    response = client.chat_completion(messages, max_tokens=100)
    if response:
        print(f"   Response: {response}")
    else:
        print("   ❌ Failed to get response")
    
    # Completion (legacy format)
    print("\n4. Completion (Legacy Format):")
    prompt = "The future of AI is"
    print(f"   Prompt: {prompt}")
    response = client.completion(prompt, max_tokens=50)
    if response:
        print(f"   Response: {response}")
    else:
        print("   ❌ Failed to get response")

def interactive_chat():
    """Interactive chat mode."""
    print("\n💬 INTERACTIVE CHAT MODE")
    print("-" * 30)
    print("Type 'quit' or 'exit' to end the chat")
    print("Type 'clear' to clear conversation history")
    print()
    
    client = VLLMClient()
    messages = []
    
    while True:
        try:
            user_input = input("You: ").strip()
            
            if user_input.lower() in ['quit', 'exit']:
                print("Goodbye! 👋")
                break
            
            if user_input.lower() == 'clear':
                messages = []
                print("Conversation history cleared.")
                continue
            
            if not user_input:
                continue
            
            # Add user message
            messages.append({"role": "user", "content": user_input})
            
            # Get response
            print("AI: ", end="", flush=True)
            response = client.chat_completion(messages, max_tokens=200)
            
            if response:
                print(response)
                # Add assistant response to history
                messages.append({"role": "assistant", "content": response})
            else:
                print("Sorry, I couldn't process your request.")
            
            print()
            
        except KeyboardInterrupt:
            print("\nGoodbye! 👋")
            break
        except Exception as e:
            print(f"Error: {e}")

def performance_test():
    """Run a simple performance test."""
    print("\n⚡ PERFORMANCE TEST")
    print("-" * 30)
    
    client = VLLMClient()
    
    test_prompts = [
        "What is artificial intelligence?",
        "Explain quantum computing in simple terms.",
        "Write a haiku about technology.",
        "What are the benefits of renewable energy?",
        "Describe the process of photosynthesis."
    ]
    
    total_time = 0
    successful_requests = 0
    
    for i, prompt in enumerate(test_prompts, 1):
        print(f"Test {i}/5: {prompt[:50]}...")
        
        start_time = time.time()
        messages = [{"role": "user", "content": prompt}]
        response = client.chat_completion(messages, max_tokens=100)
        end_time = time.time()
        
        if response:
            successful_requests += 1
            request_time = end_time - start_time
            total_time += request_time
            print(f"   ✅ Response time: {request_time:.2f}s")
        else:
            print(f"   ❌ Failed")
    
    if successful_requests > 0:
        avg_time = total_time / successful_requests
        print(f"\n📊 Results:")
        print(f"   Successful requests: {successful_requests}/5")
        print(f"   Average response time: {avg_time:.2f}s")
        print(f"   Total time: {total_time:.2f}s")

def main():
    """Main application function."""
    print_banner()
    
    while True:
        print("\n🎯 Choose an option:")
        print("1. Basic API Usage Demo")
        print("2. Interactive Chat")
        print("3. Performance Test")
        print("4. Exit")
        
        try:
            choice = input("\nEnter your choice (1-4): ").strip()
            
            if choice == "1":
                demo_basic_usage()
            elif choice == "2":
                interactive_chat()
            elif choice == "3":
                performance_test()
            elif choice == "4":
                print("Goodbye! 👋")
                break
            else:
                print("Invalid choice. Please enter 1-4.")
                
        except KeyboardInterrupt:
            print("\nGoodbye! 👋")
            break
        except Exception as e:
            print(f"Error: {e}")

if __name__ == "__main__":
    main()
