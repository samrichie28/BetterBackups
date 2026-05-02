import requests
import yaml
import os

# Load configuration
CONFIG_PATH = os.path.join(os.path.dirname(__file__), "..", "config.yaml")
with open(CONFIG_PATH, "r") as f:
    config = yaml.safe_load(f)

def send_discord_alert(title, description, color=16711680): # Default to red (error)
    url = config.get('notifications', {}).get('discord_webhook_url')
    
    # Skip if URL isn't configured
    if not url or url == "YOUR_DISCORD_WEBHOOK_URL_HERE":
        return
        
    data = {
        "embeds": [{
            "title": title,
            "description": description[:4000], # Discord description length limit
            "color": color
        }]
    }
    
    try:
        requests.post(url, json=data)
    except Exception as e:
        print(f"Failed to send Discord alert: {e}")