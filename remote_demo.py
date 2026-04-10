import socket
import platform
import os
import multiprocessing
import time

print("=== ScaleServe Remote Execution Demo ===\n")

# Machine identity
hostname = socket.gethostname()
print(f"[+] Hostname: {hostname}")

# OS info
print(f"[+] OS: {platform.system()} {platform.release()}")
print(f"[+] Architecture: {platform.machine()}")

# CPU info
cpu_count = multiprocessing.cpu_count()
print(f"[+] CPU Cores: {cpu_count}")

# Current user
user = os.getenv("USER") or os.getenv("USERNAME")
print(f"[+] Running as user: {user}")

# Current working directory
print(f"[+] Current Directory: {os.getcwd()}")

# Simulate workload
print("\n[+] Running simulated workload...")
for i in range(5):
    print(f"   Processing step {i+1}/5...")
    time.sleep(0.5)

print("\n=== Execution Complete ===")