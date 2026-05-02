# BetterBackups (v1.0.1)

BetterBackups is a highly secure, self-hosted, web-based backup engine for Windows. It provides a beautiful GUI to manage local file archiving, NAS syncing, and Cloud Storage pushes/pulls (Google Drive) using the sheer power of Rclone.

## ✨ Features
* **Web GUI:** Manage, run, and monitor all backup jobs from a modern web dashboard.
* **Automated Scheduling:** Built-in Cron scheduling for set-and-forget backups.
* **Live Terminal Streaming:** Watch your backup logs stream in real-time via WebSockets.
* **Rclone Powered:** Natively downloads and utilizes Rclone for lightning-fast, multi-threaded cloud transfers.
* **Zip Archiving:** Automatically zips multiple source folders with built-in rolling retention policies.
* **Enterprise Security:** Hardened against XSS, SSRF, Path Traversal, and Brute-Force attacks. Features PBKDF2 password hashing, strict CORS policies, rate limiting, and Same-Site WebSocket validation.

## ✨ Planned Features
* **Plugin Support:** Create your own plugins to integrate other software with BetterBackups.
* **SnapRAID Plugin:** Link BetterBackups with SnapRAID.

## 🚀 Installation (Windows Only)

1. Ensure you have **Python 3.10+** installed on your system (Make sure "Add to PATH" is checked during Python installation).
2. Download or clone this repository to a permanent location on your machine (e.g., `C:\BetterBackups`).
3. Double-click `install.bat`. 

The installer will automatically request Administrator privileges, download required binaries (Rclone and NSSM), create an isolated Python virtual environment, ask you to create a Web UI password, and install BetterBackups as a background Windows Service.

Once the installer finishes, it will open the dashboard in your browser.

## ⚙️ Configuration & Access
* **Dashboard URL:** `http://localhost:8050` (or `http://<YOUR_SERVER_IP>:8050`)
* **Service Management:** BetterBackups runs continuously in the background using NSSM. It will automatically start when your server boots.
* **Adding Cloud Accounts:** Go to the Configuration page and click `+ Link Google Drive` to safely authenticate using Oauth.

## 🛡️ Reverse Proxy (Optional)
If you wish to expose BetterBackups to the internet securely:
1. Put BetterBackups behind a reverse proxy (like Nginx, Caddy, or Cloudflare Tunnels) for SSL termination.
2. Open the Configuration page and add your Reverse Proxy's internal IP to the **Trusted Reverse Proxies** field to prevent self-lockouts from the brute-force protection system.

## 🗑️ Uninstallation
To completely remove BetterBackups:
1. Double-click `uninstall.bat` to safely remove the Windows Service and Firewall rules.
2. Delete the `BetterBackups` folder.

## License
[MIT License](LICENSE)