import os
import json
import asyncio
import yaml
import string
import stat
import subprocess
import hashlib
import secrets
import time
import html
import threading
from fastapi import FastAPI, WebSocket, Request, WebSocketDisconnect, status
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse, FileResponse
from fastapi.templating import Jinja2Templates
from starlette.middleware.base import BaseHTTPMiddleware
from contextlib import asynccontextmanager

from core.scheduler import init_scheduler, scheduler
from core import engine
from apscheduler.triggers.cron import CronTrigger

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOGS_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "logs"))
HISTORY_PATH = os.path.join(BASE_DIR, "..", "history.json")

if not os.path.exists(LOGS_DIR): os.makedirs(LOGS_DIR)
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))

# ==========================================
# STATE MANAGEMENT & GARBAGE COLLECTION
# ==========================================
ACTIVE_SESSIONS = {}
SESSION_DURATION = 86400 * 7 

ACTION_COOLDOWNS = {}
COOLDOWNS_DURATION = 1.0 

IP_STRIKES = {}
MAX_STRIKES = 5
LOCKOUT_DURATION = 900 

LAST_CLEANUP = time.time()
STATE_LOCK = threading.Lock()

def cleanup_memory():
    global LAST_CLEANUP
    now = time.time()
    with STATE_LOCK:
        if now - LAST_CLEANUP > 3600: 
            expired_tokens = [k for k, v in ACTIVE_SESSIONS.items() if now > v]
            for k in expired_tokens: del ACTIVE_SESSIONS[k]
            
            expired_strikes = [k for k, v in IP_STRIKES.items() if now > v["lockout_until"]]
            for k in expired_strikes: del IP_STRIKES[k]
            
            expired_cooldowns = [k for k, v in ACTION_COOLDOWNS.items() if (now - v) > COOLDOWNS_DURATION]
            for k in expired_cooldowns: del ACTION_COOLDOWNS[k]
            
            LAST_CLEANUP = now

# ==========================================
# AUTHENTICATION & SECURITY GUARDS
# ==========================================
def check_auth(request: Request):
    sec = engine.config.get('security', {})
    if not sec.get('auth_enabled', False): return True
    token = request.cookies.get("bb_session")
    with STATE_LOCK:
        if not token or token not in ACTIVE_SESSIONS: return False
        if time.time() > ACTIVE_SESSIONS[token]:
            del ACTIVE_SESSIONS[token] 
            return False
    return True

def check_ws_auth(websocket: WebSocket):
    sec = engine.config.get('security', {})
    if not sec.get('auth_enabled', False): return True
    
    origin = websocket.headers.get("origin")
    host = websocket.headers.get("host", "")
    if origin and host not in origin:
        return False

    token = websocket.cookies.get("bb_session")
    with STATE_LOCK:
        if not token or token not in ACTIVE_SESSIONS: return False
        if time.time() > ACTIVE_SESSIONS[token]:
            del ACTIVE_SESSIONS[token]
            return False
    return True

def get_client_ip(request: Request):
    client_ip = request.client.host
    sec = engine.config.get('security', {})
    trusted_str = sec.get('trusted_proxies', '')
    
    trusted_set = {"127.0.0.1", "::1"}
    if trusted_str:
        trusted_set.update([p.strip() for p in trusted_str.split(",") if p.strip()])
        
    if client_ip in trusted_set:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return client_ip

def check_rate_limit(ip: str):
    with STATE_LOCK:
        record = IP_STRIKES.get(ip, {"strikes": 0, "lockout_until": 0})
        if time.time() < record["lockout_until"]:
            remaining_minutes = int((record["lockout_until"] - time.time()) / 60) + 1
            return False, remaining_minutes
    return True, 0

def record_failed_login(ip: str):
    sec = engine.config.get('security', {})
    max_strikes = int(sec.get('max_login_strikes', 5))
    lockout_seconds = int(sec.get('lockout_duration_minutes', 15)) * 60

    with STATE_LOCK:
        record = IP_STRIKES.get(ip, {"strikes": 0, "lockout_until": 0})
        if time.time() > record["lockout_until"] and record["strikes"] >= max_strikes:
            record["strikes"] = 0
            
        record["strikes"] += 1
        if record["strikes"] >= max_strikes:
            record["lockout_until"] = time.time() + lockout_seconds
        IP_STRIKES[ip] = record

# ==========================================
# HARDENING MIDDLEWARE
# ==========================================
class SecurityMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        cleanup_memory() 
        
        if request.headers.get("transfer-encoding", "").lower() == "chunked":
            return JSONResponse(status_code=status.HTTP_411_LENGTH_REQUIRED, content={"error": "Chunked encoding not supported."})

        content_length = request.headers.get("content-length")
        if content_length and int(content_length) > 1024 * 1024:
            return JSONResponse(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, content={"error": "Payload too large (Max 1MB)"})

        if request.method == "POST" and "/api/login" not in request.url.path:
            ip = get_client_ip(request)
            now = time.time()
            with STATE_LOCK:
                if ip in ACTION_COOLDOWNS and (now - ACTION_COOLDOWNS[ip]) < COOLDOWNS_DURATION:
                    return JSONResponse(status_code=status.HTTP_429_TOO_MANY_REQUESTS, content={"error": "Please wait a moment between actions."})
                ACTION_COOLDOWNS[ip] = now

        response = await call_next(request)

        response.headers["X-Frame-Options"] = "DENY" 
        response.headers["X-Content-Type-Options"] = "nosniff" 
        response.headers["X-XSS-Protection"] = "1; mode=block" 
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com; style-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com; connect-src 'self' ws: wss:;"
        return response

# ==========================================
# APP INITIALIZATION
# ==========================================
@asynccontextmanager
async def lifespan(app: FastAPI):
    init_scheduler()
    reload_scheduler()
    yield
    scheduler.shutdown()

app = FastAPI(lifespan=lifespan)
app.add_middleware(SecurityMiddleware)

def reload_scheduler():
    scheduler.remove_all_jobs()
    jobs_conf = engine.config.get('jobs') or {}
    for job_id, data in jobs_conf.items():
        if data.get('enabled', True) and data.get('schedule_cron'):
            cron_expr = data['schedule_cron']
            try:
                trigger = CronTrigger.from_crontab(cron_expr)
                def make_wrapper(jid):
                    def wrapper(): engine.enqueue_job(jid, "Scheduled")
                    return wrapper
                scheduler.add_job(make_wrapper(job_id), trigger, id=job_id, name=data.get('name', job_id))
            except Exception as e:
                print(f"Failed to schedule job {job_id}: {e}")

# ==========================================
# WEB UI ROUTES
# ==========================================
@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    sec = engine.config.get('security', {})
    if not sec.get('auth_enabled', False): 
        return RedirectResponse(url="/", status_code=303)
    return templates.TemplateResponse(request=request, name="login.html", context={})

@app.post("/api/login")
async def api_login(request: Request):
    ip = get_client_ip(request)
    allowed, wait_time = check_rate_limit(ip)
    if not allowed:
        return JSONResponse(content={"success": False, "error": f"Too many failed attempts. Try again in {wait_time} minutes."})

    data = await request.json()
    sec = engine.config.get('security', {})
    
    provided_user = data.get("username", "")
    provided_pass = data.get("password", "")
    
    expected_user = sec.get("username", "admin")
    stored_hash_payload = sec.get("password_hash", "")
    
    user_match = secrets.compare_digest(provided_user, expected_user)
    
    if ":" in stored_hash_payload:
        salt, expected_key = stored_hash_payload.split(":", 1)
    else:
        salt, expected_key = "dummysalt", "dummykey"
        user_match = False
        
    attempt_key = hashlib.pbkdf2_hmac('sha256', provided_pass.encode('utf-8'), salt.encode('utf-8'), 100000).hex()
    pass_match = secrets.compare_digest(attempt_key, expected_key)
    
    if user_match and pass_match:
        with STATE_LOCK:
            if ip in IP_STRIKES: del IP_STRIKES[ip]
            token = secrets.token_urlsafe(32)
            ACTIVE_SESSIONS[token] = time.time() + SESSION_DURATION
            
        response = JSONResponse(content={"success": True})
        is_secure = request.url.scheme == "https" or request.headers.get("x-forwarded-proto", "").lower() == "https"
        response.set_cookie(key="bb_session", value=token, httponly=True, max_age=SESSION_DURATION, samesite="strict", secure=is_secure)
        return response
        
    record_failed_login(ip)
    return JSONResponse(content={"success": False, "error": "Invalid credentials"})

@app.post("/api/logout")
async def api_logout(request: Request):
    token = request.cookies.get("bb_session")
    with STATE_LOCK:
        if token and token in ACTIVE_SESSIONS: del ACTIVE_SESSIONS[token]
        
    response = JSONResponse(content={"success": True})
    is_secure = request.url.scheme == "https" or request.headers.get("x-forwarded-proto", "").lower() == "https"
    response.delete_cookie(key="bb_session", samesite="strict", secure=is_secure)
    return response

@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    if not check_auth(request): return RedirectResponse(url="/login", status_code=303)
    history = {}
    if os.path.exists(HISTORY_PATH):
        try:
            with open(HISTORY_PATH, "r") as f: history = json.load(f)
        except: pass
    jobs = []
    jobs_conf = engine.config.get('jobs') or {}
    for job_id, data in jobs_conf.items():
        if not data.get('enabled', True): continue 
        h = history.get(job_id, {})
        aps_job = scheduler.get_job(job_id)
        next_run = aps_job.next_run_time.strftime("%Y-%m-%d %H:%M:%S") if aps_job and aps_job.next_run_time else "Manual Only"
        jobs.append({
            "id": job_id, "name": data.get('name', job_id.replace("_", " ").title()),
            "type": data.get('type', 'rclone_sync'), "next_run": next_run,
            "last_run": h.get("last_run", "Never"), "status": h.get("status", "N/A"),
            "error": h.get("error"), "log_link": h.get("log_link")
        })
    return templates.TemplateResponse(request=request, name="index.html", context={"jobs": jobs})

@app.get("/config", response_class=HTMLResponse)
async def config_page(request: Request):
    if not check_auth(request): return RedirectResponse(url="/login", status_code=303)
    return templates.TemplateResponse(request=request, name="config.html", context={})

@app.get("/logs/{filename}")
async def serve_log_file(request: Request, filename: str):
    if not check_auth(request): return RedirectResponse(url="/login", status_code=303)
    clean_filename = os.path.basename(filename)
    file_path = os.path.join(LOGS_DIR, clean_filename)
    if not os.path.exists(file_path) or not file_path.endswith('.log'):
        return HTMLResponse(content="Log file not found or has expired.", status_code=404)
    return FileResponse(file_path)

# ==========================================
# API DATA ROUTES
# ==========================================
@app.get("/api/config")
async def get_config(request: Request):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    with open(engine.CONFIG_PATH, "r") as f: 
        safe_conf = yaml.safe_load(f)
        
        if "security" in safe_conf and "password_hash" in safe_conf["security"]:
            safe_conf["security"]["password"] = "" 
            del safe_conf["security"]["password_hash"]
            
        if "jobs" in safe_conf:
            for j_id, j_data in safe_conf["jobs"].items():
                if j_data.get("nas_pass"):
                    j_data["nas_pass"] = "********" 
                    
        return safe_conf

@app.post("/api/config/save")
async def save_config(request: Request):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    data = await request.json()
    
    rclone_path = data.get('paths', {}).get('rclone_exe', '').lower()
    if rclone_path and not (rclone_path.endswith('rclone.exe') or rclone_path.endswith('rclone')):
        return {"success": False, "error": "SECURITY BLOCK: Rclone executable path must end with 'rclone.exe'"}

    # Removed robocopy validation as the tool is deprecated

    sec_data = data.get('security', {})
    new_pass = sec_data.get('password', '').strip()
    
    if new_pass:
        salt = secrets.token_hex(16)
        key = hashlib.pbkdf2_hmac('sha256', new_pass.encode('utf-8'), salt.encode('utf-8'), 100000).hex()
        data['security']['password_hash'] = f"{salt}:{key}"
    else:
        data['security']['password_hash'] = engine.config.get('security', {}).get('password_hash', '')
        
    if 'password' in data['security']:
        del data['security']['password']

    old_config = engine.config
    if "jobs" in data:
        for j_id, j_data in data["jobs"].items():
            if j_data.get("nas_pass") == "********":
                j_data["nas_pass"] = old_config.get("jobs", {}).get(j_id, {}).get("nas_pass", "")

    try:
        with open(engine.CONFIG_PATH, "w") as f: yaml.dump(data, f, default_flow_style=False, sort_keys=False)
        engine.config = data
        reload_scheduler()
        return {"success": True}
    except Exception as e: return {"success": False, "error": str(e)}

@app.get("/api/browse")
async def api_browse(request: Request, path: str = ""):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    try:
        if path == "cloud://":
            remotes = engine.get_rclone_remotes()
            return {"success": True, "path": "cloud://", "parent": "", "items": [{"name": r, "path": f"{r}:", "type": "dir", "hidden": False} for r in remotes]}
        if ":" in path and len(path.split(":")[0]) > 1 and not path.startswith(r"\\"): return engine.browse_rclone(path)
        
        items = []
        if not path:
            if os.name == 'nt':
                drives = [d for d in string.ascii_uppercase if os.path.exists(f"{d}:\\")]
                items = [{"name": f"Local Disk ({d}:)", "path": f"{d}:\\", "type": "dir", "hidden": False} for d in drives]
                nas_paths = set()
                for j_id, j_data in engine.config.get('jobs', {}).items():
                    for p in [*([j_data.get('source')] if isinstance(j_data.get('source'), str) else j_data.get('source', [])), j_data.get('dest', '')]:
                        if isinstance(p, str) and p.startswith(r"\\"):
                            parts = [x for x in p.replace('/', '\\').split('\\') if x]
                            if len(parts) >= 2: nas_paths.add(f"\\\\{parts[0]}\\{parts[1]}")
                for np in sorted(list(nas_paths)): items.append({"name": f"Network Share ({np})", "path": np, "type": "dir", "hidden": False})
                return {"success": True, "path": "", "parent": "", "items": items}
            else: path = "/" 

        if path.startswith(r"\\"):
            target_parts = [x for x in path.replace('/', '\\').split('\\') if x]
            if len(target_parts) >= 2:
                target_base = f"\\\\{target_parts[0]}\\{target_parts[1]}".lower()
                for j_id, j_data in engine.config.get('jobs', {}).items():
                    if j_data.get('nas_user') and j_data.get('nas_pass'):
                        for p in [*([j_data.get('source')] if isinstance(j_data.get('source'), str) else j_data.get('source', [])), j_data.get('dest', '')]:
                            if isinstance(p, str) and p.startswith(r"\\"):
                                p_parts = [x for x in p.replace('/', '\\').split('\\') if x]
                                if len(p_parts) >= 2:
                                    p_base = f"\\\\{p_parts[0]}\\{p_parts[1]}".lower()
                                    if target_base == p_base:
                                        subprocess.run(
                                            ["net", "use", target_base, "*", f"/user:{j_data['nas_user']}", "/persistent:no"], 
                                            input=j_data['nas_pass'] + "\n", 
                                            capture_output=True, 
                                            text=True, 
                                            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
                                        )
                                        break

        abs_path = os.path.abspath(path)
        parent = "" if abs_path.rstrip('\\') == os.path.abspath(os.path.join(abs_path, "..")).rstrip('\\') else os.path.abspath(os.path.join(abs_path, ".."))
        
        with os.scandir(abs_path) as it:
            for entry in it:
                is_hidden = bool(entry.stat(follow_symlinks=False).st_file_attributes & stat.FILE_ATTRIBUTE_HIDDEN) if os.name == 'nt' else entry.name.startswith('.')
                items.append({"name": entry.name, "path": entry.path, "type": "dir" if entry.is_dir() else "file", "hidden": is_hidden})
        
        items.sort(key=lambda x: (x["type"] != "dir", x["name"].lower()))
        return {"success": True, "path": abs_path, "parent": parent, "items": items}
    except Exception as e: return {"success": False, "error": str(e)}

# ==========================================
# ENGINE CONTROL ROUTES
# ==========================================
@app.post("/api/run/{job_id}")
async def api_run_job(request: Request, job_id: str):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    success, msg = engine.enqueue_job(job_id, "Manual")
    return {"success": success, "message": msg}

@app.get("/api/queue")
async def api_get_queue(request: Request):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    return {"queue_state": engine.get_queue_state(), "statuses": engine.get_all_statuses()}

@app.post("/api/queue/remove/{uuid}")
async def api_remove_queue(request: Request, uuid: str):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    return {"success": engine.remove_from_queue(uuid)}

@app.post("/api/stop/{job_id}")
async def api_stop_job(request: Request, job_id: str):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    return {"success": engine.stop_job(job_id)}

@app.post("/api/force_stop/{job_id}")
async def api_force_stop_job(request: Request, job_id: str):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    return {"success": engine.force_stop_job(job_id)}

@app.websocket("/ws/run/{job_id}")
async def websocket_run_job(websocket: WebSocket, job_id: str):
    await websocket.accept()
    if not check_ws_auth(websocket):
        await websocket.send_text("<div class='text-red-600 font-bold'>Unauthorized Access Blocked.</div>")
        await websocket.close(code=1008)
        return
    try:
        async for line in engine.stream_log(job_id):
            clean_line = html.escape(line)
            await websocket.send_text(f"<div class='font-mono text-sm'>{clean_line}</div>")
    except WebSocketDisconnect: pass
    finally:
        try: await websocket.close()
        except: pass

@app.get("/api/rclone/remotes")
async def api_rclone_remotes(request: Request):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    return {"success": True, "remotes": engine.get_rclone_remotes()}

@app.delete("/api/rclone/remotes/{remote_name}")
async def api_delete_remote(request: Request, remote_name: str):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    return {"success": engine.delete_rclone_remote(remote_name)}

@app.websocket("/ws/rclone/config/{remote_name}")
async def websocket_rclone_config(websocket: WebSocket, remote_name: str, client_id: str = "", client_secret: str = ""):
    await websocket.accept()
    if not check_ws_auth(websocket):
        await websocket.close(code=1008)
        return
    try:
        async for line in engine.stream_rclone_config(remote_name, client_id, client_secret):
            clean_line = html.escape(line)
            await websocket.send_text(f"<div class='font-mono text-sm'>{clean_line}</div>")
    except WebSocketDisconnect: pass
    finally:
        try: await websocket.close()
        except: pass

@app.post("/api/system/restart")
async def api_system_restart(request: Request):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    engine.restart_app()
    return {"success": True}

@app.post("/api/system/shutdown")
async def api_system_shutdown(request: Request):
    if not check_auth(request): return {"success": False, "error": "Unauthorized"}
    engine.shutdown_app()
    return {"success": True}