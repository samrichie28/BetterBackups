from apscheduler.schedulers.background import BackgroundScheduler

scheduler = BackgroundScheduler()

def init_scheduler():
    """Starts the background scheduler. 
    Jobs are now dynamically injected by app.py based on config.yaml"""
    if not scheduler.running:
        scheduler.start()