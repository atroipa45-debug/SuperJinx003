#!/usr/bin/env bash
set -uo pipefail
DATA=/var/lib/pasarguard

# ---- find the panel and its Python, whatever layout the PasarGuard image uses today ----
PANEL_DIR=/code
for d in /code /app /opt/pasarguard /pasarguard /usr/src/app; do
  if [ -f "$d/main.py" ]; then PANEL_DIR="$d"; break; fi
done
for v in "$PANEL_DIR/.venv" /code/.venv /app/.venv /opt/venv /venv; do
  if [ -x "$v/bin/python" ]; then export PATH="$v/bin:$PATH"; export VIRTUAL_ENV="$v"; break; fi
done
export PANEL_DIR
PY="$(command -v python || command -v python3 || echo python)"; export PY
echo "[chost] panel: $PANEL_DIR, python: $PY"
mkdir -p "$DATA/node-certs" /var/lib/pg-node /run /run/nginx /var/log/nginx /var/lib/nginx/body /var/cache/nginx 2>/dev/null
# Railway may hand the service its own PORT; CHOST always answers on 8080 AND on that port,
# so the domain and the health check work in every region whatever the target port is
RW_PORT="${PORT:-8080}"
case "$RW_PORT" in ''|*[!0-9]*) RW_PORT=8080 ;; esac
case "$RW_PORT" in 8000|8100|62050|1000[1-6]) RW_PORT=8080 ;; esac   # never clash with the internal ports
export PORT=8080

# CPUs really given to this service (Railway Metal hosts show every host CPU, which would start dozens of
# nginx workers and eat the memory): read the cgroup limit, fall back to nproc, keep it between 1 and 4
CPUS=""
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r q p < /sys/fs/cgroup/cpu.max 2>/dev/null || true
  if [ "${q:-max}" != "max" ] && [ "${p:-0}" -gt 0 ] 2>/dev/null; then CPUS=$(( (q + p - 1) / p )); fi
elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
  q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
  if [ "${q:--1}" -gt 0 ] 2>/dev/null && [ "${p:-0}" -gt 0 ] 2>/dev/null; then CPUS=$(( (q + p - 1) / p )); fi
fi
case "$CPUS" in ''|*[!0-9]*) CPUS=$(nproc 2>/dev/null || echo 2) ;; esac
case "$CPUS" in ''|*[!0-9]*|0) CPUS=2 ;; esac
[ "$CPUS" -gt 4 ] && CPUS=4
export GOMAXPROCS="${GOMAXPROCS:-$CPUS}"
NGX_W=$CPUS; [ "$NGX_W" -gt 2 ] && NGX_W=2      # 2 nginx workers carry thousands of connections

# memory really given to this service; small plans (512 MB) must never be killed for running out of memory
MEM_MAX=""
if [ -r /sys/fs/cgroup/memory.max ]; then MEM_MAX=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then MEM_MAX=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null); fi
case "$MEM_MAX" in ''|max|*[!0-9]*) MEM_MAX="" ;; esac
[ -n "$MEM_MAX" ] && [ "$MEM_MAX" -gt 274877906944 ] && MEM_MAX=""   # "no limit" written as a huge number
export MALLOC_ARENA_MAX=2       # Python uses far less memory with fewer malloc arenas
if [ -n "$MEM_MAX" ]; then export GOMEMLIMIT="${GOMEMLIMIT:-$(( MEM_MAX * 35 / 100 ))B}"; fi   # core gives memory back early

# owner admin/admin is written by bootstrap.py on FIRST boot only
unset SUDO_USERNAME SUDO_PASSWORD

# ---- node secrets: generated once, kept on the volume ----
[ -f "$DATA/node_api_key" ] || "$PY" -c "import uuid;print(uuid.uuid4())" > "$DATA/node_api_key"
if [ ! -f "$DATA/node-certs/cert.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
  # fallback for an older openssl: RSA key, then without the SAN option
  [ -s "$DATA/node-certs/cert.pem" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
  [ -s "$DATA/node-certs/cert.pem" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$DATA/node-certs/key.pem" -out "$DATA/node-certs/cert.pem" -subj "/CN=localhost" >/dev/null 2>&1
  [ -s "$DATA/node-certs/cert.pem" ] || echo "[chost] warning: node certificate could not be created"
fi

# ---- unique config paths for this install (kept on the volume) ----
if ! "$PY" /code/genpaths.py; then
  # never stop the deploy: the panel still opens, the next start writes the paths
  echo "[chost] warning: config paths could not be written now"; [ -f "$DATA/inbounds.inc" ] || : > "$DATA/inbounds.inc"
fi

# ---- nginx ----
# the panel answers on 8080, on the port Railway gives the service, and on the usual web ports,
# so whatever target port the domain uses, it reaches the panel (never "Application failed to respond")
EXTRA=""; PORTS="8080"
for pt in "$RW_PORT" 80 3000 5000 8888; do
  case " $PORTS " in *" $pt "*) continue ;; esac
  PORTS="$PORTS $pt"; EXTRA="${EXTRA}listen ${pt}; listen [::]:${pt}; "
done
sed -e "s/__PORT__/${PORT}/g" -e "s/#__EXTRA_LISTEN__/${EXTRA}/" -e "s/^worker_processes auto;/worker_processes ${NGX_W};/" /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
# nginx worker user: www-data on Debian, nginx on Alpine
if ! id www-data >/dev/null 2>&1; then
  if id nginx >/dev/null 2>&1; then sed -i 's/^user www-data;/user nginx;/' /etc/nginx/nginx.conf; else sed -i '/^user www-data;/d' /etc/nginx/nginx.conf; fi
fi
# real test: can this container open an IPv6 listening socket at all?
if ! "$PY" -c "import socket;s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1);s.bind(('::',0));s.close()" >/dev/null 2>&1; then
  # region without IPv6 inside the container: listen on IPv4 only instead of failing to start
  sed -i 's/listen \[::\]:[0-9]*[^;]*;//g' /etc/nginx/nginx.conf
  echo "[chost] IPv6 not available here, listening on IPv4 only"
fi
if ! nginx -t 2>/tmp/nginx-test.log; then
  # safe mode: drop the tuning lines an unusual nginx build may not accept (listening is never touched here)
  sed -i -e '/^worker_rlimit_nofile/d' -e 's/ multi_accept on;//' -e 's/ use epoll;//' -e '/proxy_socket_keepalive/d' /etc/nginx/nginx.conf /etc/nginx/ws.inc
  if nginx -t 2>>/tmp/nginx-test.log; then echo "[chost] nginx safe mode"; else cat /tmp/nginx-test.log; echo "[chost] nginx config error (the supervisor keeps trying)"; fi
fi
echo "[chost] listening on ports: ${PORTS} (domain port: 8080) | cpu: ${CPUS} | memory: $( [ -n "$MEM_MAX" ] && echo "$(( MEM_MAX / 1048576 )) MB" || echo "no limit" )"
echo "[chost] region: ${RAILWAY_REPLICA_REGION:-unknown}, domain: ${RAILWAY_PUBLIC_DOMAIN:-not generated yet}"

# ---- first boot: the panel opens only when admin/admin is ready (at most 4 minutes of waiting) ----
if [ ! -f "$DATA/.owner_initialized" ]; then
  touch /run/chost-starting
  ( for i in $(seq 1 120); do [ -f "$DATA/.owner_initialized" ] && break; sleep 2; done; rm -f /run/chost-starting ) &
else
  rm -f /run/chost-starting
fi

# ---- every part runs under its own supervisor: if one part stops, only that part is started again
#      (in a few seconds, inside the same container). The service itself is never restarted. ----
supervise() {   # supervise <name> <pidfile> <command...>
  local name="$1" pidf="$2"; shift 2; local n=0
  while true; do
    "$@" &
    echo $! > "$pidf"
    wait $! ; code=$?
    n=$((n+1))
    echo "[chost] $name stopped (exit $code), starting it again (#$n)"
    sleep $(( n < 5 ? 2 : 10 ))
  done
}

# ---- node (xray) ----
node_run() {
  cd /opt/pg-node || return 1
  export SERVICE_PORT=62050 NODE_HOST=127.0.0.1 SERVICE_PROTOCOL=grpc
  export API_KEY="$(cat "$DATA/node_api_key")"
  export SSL_CERT_FILE="$DATA/node-certs/cert.pem" SSL_KEY_FILE="$DATA/node-certs/key.pem"
  exec ./main
}
supervise "core" /run/chost-node.pid node_run &

# ---- panel: database update first (retried until it works), then the panel ----
panel_run() {
  cd "$PANEL_DIR" || return 1
  touch /run/chost-migrating
  until "$PY" -m alembic upgrade head; do echo "[chost] database update failed, retrying in 5s"; sleep 5; done
  rm -f /run/chost-migrating
  exec "$PY" main.py
}
supervise "panel" /run/chost-panel.pid panel_run &

# ---- auto setup + doctor (finds and fixes problems on its own) ----
supervise "setup" /run/chost-setup.pid bash -c 'cd "$PANEL_DIR" && exec "$PY" /code/bootstrap.py' &

# ---- Telegram sales bot (sidebar page "ربات تلگرام") ----
# the bot process only starts once a token is saved and the bot is turned on (saves memory on small plans);
# it is checked every 3 s, so the bot still comes online right after "Save"
( sleep 20; supervise "sales bot" /run/chost-bot.pid bash -c '
  until grep -Eq "\"enabled\": *true" "$1" 2>/dev/null && grep -Eq "\"token\": *\"[^\"]+" "$1" 2>/dev/null; do sleep 3; done
  cd "$PANEL_DIR" && exec "$PY" /code/chostbot.py' _ "$DATA/chost-bot.json" ) &

# nginx: before every start, each listening address is really tried. Only an address this container can
# never open is dropped (IPv6 missing in a region, a port that is not allowed); "already in use" is never
# a reason to drop anything, the supervisor simply tries again. 8080 is always kept.
nginx_prep() {
  "$PY" - "$RW_PORT" <<'PYEOF' || true
import re, socket, errno, sys
keep = {"8080", sys.argv[1]}
conf = "/etc/nginx/nginx.conf"
s = open(conf).read()
out = s
for m in re.finditer(r"listen (\[::\]:)?(\d+)([^;]*);", s):
    v6, port = bool(m.group(1)), m.group(2)
    fam = socket.AF_INET6 if v6 else socket.AF_INET
    try:
        k = socket.socket(fam, socket.SOCK_STREAM)
        k.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if v6: k.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        k.bind(("::" if v6 else "0.0.0.0", int(port))); k.close(); continue
    except OSError as e:
        code, why = e.errno, e.strerror
    if code == errno.EADDRINUSE: continue
    if v6 and code in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.EPROTONOSUPPORT):
        out = out.replace(m.group(0), "", 1); print(f"[chost] nginx: IPv6 port {port} not available here, using IPv4 for it", flush=True)
    elif port not in keep:
        out = out.replace(m.group(0), "", 1); print(f"[chost] nginx: port {port} not allowed here ({why}), skipped", flush=True)
if out != s:
    open(conf, "w").write(out)
PYEOF
}
nginx_run() { nginx_prep; exec nginx -g 'daemon off;'; }
supervise "nginx" /run/chost-nginx.pid nginx_run &

# ---- self test: 25 s after start, check the panel is reachable the way Railway reaches it
#      (every address of this container, IPv4 and IPv6, on the domain port and Railway's port) ----
( sleep 25; "$PY" - "$RW_PORT" <<'PYEOF' || true
import socket, sys, os
ports = sorted({8080, int(sys.argv[1])})
addrs = set()
for host in (socket.gethostname(), os.getenv("RAILWAY_PRIVATE_DOMAIN") or ""):
    if not host: continue
    try:
        for fam, _, _, _, sa in socket.getaddrinfo(host, None):
            if fam in (socket.AF_INET, socket.AF_INET6) and not sa[0].startswith(("127.", "::1", "fe80")): addrs.add((fam, sa[0]))
    except Exception: pass
addrs |= {(socket.AF_INET, "127.0.0.1")}
bad = 0
for fam, ip in sorted(addrs, key=lambda x: x[1]):
    for p in ports:
        s = socket.socket(fam, socket.SOCK_STREAM); s.settimeout(3)
        try:
            s.connect((ip, p)); s.sendall(b"GET /healthz HTTP/1.0\r\nHost: x\r\n\r\n"); ok = b" 200 " in s.recv(64)
        except Exception: ok = False
        finally: s.close()
        bad += not ok
        print(f"[chost] self test {'IPv6' if fam == socket.AF_INET6 else 'IPv4'} {ip}:{p} -> {'ok' if ok else 'NOT REACHABLE'}", flush=True)
print("[chost] self test: " + ("all good, the panel is reachable" if not bad else "some addresses are not reachable (send these lines to support)"), flush=True)
PYEOF
) &

# ---- watchdog: a part that stops answering is started again on its own; the service keeps running ----
(
  sleep 180; pf=0; nf=0; mh=0   # slow regions start slower: give them time before watching
  while true; do
    # memory guard: before the service could run out of memory, free it by restarting the sales bot,
    # then (only if still needed) the panel process; configs keep working, the container is never killed
    if [ -n "$MEM_MAX" ] && [ "$SECONDS" -ge "${mcool:-0}" ]; then
      # real working memory = used minus the file cache the kernel can drop by itself
      cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
      ina=$(awk '$1=="inactive_file"||$1=="total_inactive_file"{print $2; exit}' /sys/fs/cgroup/memory.stat /sys/fs/cgroup/memory/memory.stat 2>/dev/null)
      case "$cur" in ''|*[!0-9]*) cur=0 ;; esac; case "$ina" in ''|*[!0-9]*) ina=0 ;; esac
      ws=$(( cur > ina ? cur - ina : 0 ))
      if [ "$ws" -gt $(( MEM_MAX * 92 / 100 )) ]; then
        mh=$((mh+1))
        if [ "$mh" -eq 1 ]; then echo "[chost] doctor: memory high ($(( ws / 1048576 )) MB), refreshing the sales bot"; kill "$(cat /run/chost-bot.pid 2>/dev/null)" 2>/dev/null
        elif [ "$mh" -ge 3 ] && [ ! -f /run/chost-migrating ]; then
          echo "[chost] doctor: memory still high ($(( ws / 1048576 )) MB), refreshing the panel"; kill "$(cat /run/chost-panel.pid 2>/dev/null)" 2>/dev/null
          mh=0; mcool=$(( SECONDS + 600 ))   # then leave it alone for 10 minutes
        fi
      else mh=0; fi
    fi
    if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/healthz; then nf=0; else nf=$((nf+1)); fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8000/api/system)
    case "$code" in ""|000|5??) pf=$((pf+1)) ;; *) pf=0 ;; esac   # any real answer = the panel is alive
    if [ "$nf" -ge 3 ]; then echo "[chost] doctor: nginx not answering, starting it again"; kill "$(cat /run/nginx.pid 2>/dev/null || cat /run/chost-nginx.pid 2>/dev/null)" 2>/dev/null; nf=0; fi
    [ -f /run/chost-migrating ] && pf=0   # never interrupt a database update
    if [ "$pf" -ge 6 ]; then echo "[chost] doctor: panel not answering, starting it again"; kill "$(cat /run/chost-panel.pid 2>/dev/null)" 2>/dev/null; pf=0; fi
    sleep 20
  done
) &

# the container stays up; parts are healed in place
while true; do sleep 3600; done
