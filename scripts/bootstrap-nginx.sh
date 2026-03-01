# VERIFICATION
# cloud-init status --long
# sudo cat /var/log/cloud-init-output.log
# sudo systemctl status nginx --no-pager
# curl -I http://localhost
# sudo nginx -t
# sudo ss -lntp | egrep ':80|:8080'
# sudo ls -l /srv/hellowar
# sudo cat /srv/hellowar/index.html

#!/usr/bin/env bash
set -euo pipefail

echo "[bootstrap] Updating system..."
dnf -y update || yum -y update

echo "[bootstrap] Installing NGINX..."
dnf -y install nginx || yum -y install nginx

# ---- Basic OS-level hardening for NGINX files ----
# Why profile.d? - when login shell starts(ssh), it loads all the scripts inside /etc/profile.d/*.sh
# umask 0027 - Files:640 / Directories:750
# umask - new files/dir (default privacy filter settings) - created by various processess (users / services(nginx) / systemd / cron etc)
  # -- Scripts run by Humans | Services by System.D | CI-CD : Depends on how they start (SSH/Cron/Gihub runner service) etc..
# -- Each has to have it's own umask; service will have a .conf file that will have umask (will see below for nginx)
# -- users have ssh
# -- a Shell script run is via first SSH ec2-user@IP...then shell script runs ---> this inherits the umask of shell (human/user)
# -- why ? /bin -- when you run a command say umask PATH is searched (PATH has : /bin:usr/local/bin:/usr/bin ...)
# -- Here we're hardcoding /bin to avoid ambiguity (as it could be an alias / another program / function etc)
# -- Good practice in scripting - hardening features / avoids shell differences / gaurantees behavior - Not strictly needed
# ***** ALSO THIS WILL NOT TAKE EFFECT IN THIS SHELL - BUT NEXT LOGINS; SO PERMISSIONS STILL HAVE TO BE EXPLICITLY DEFINED ELSEWHERE ******
echo "[bootstrap] Setting secure umask for future shells..."
cat > /etc/profile.d/nginx-umask.sh << 'EOF'
# Default umask for interactive shells (doesn't affect existing files)
/bin/umask 0027
EOF

# App docroot lives outside default /usr/share/nginx/html
# /etc  - configuration
# /usr  - installed software
# /var  - logs & changing data
# /home - user files
# /srv  - services being served --- data served by services (websites / APIs / FTP etc)
# nginx default serves from : /usr/share/nginx/html - Package owned - Nginx can modify/replace files if placed here / Also avoid mixing apps-distros (bad separation)
# Variable APP_ROOT - as if path changes - only 1 code line to change
APP_ROOT="/srv/hellowar"

echo "[user_data] Creating application docroot at ${APP_ROOT}..."
mkdir -p "${APP_ROOT}"

# Ensure nginx user exists (should already exist from package, but safe to check)
if ! id nginx >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /sbin/nologin nginx
fi

echo "[user_data] Setting ownership and permissions..."
chown -R nginx:nginx "${APP_ROOT}"
chmod 0750 "${APP_ROOT}"

# ---- NGINX config hardening / cleanup ----
echo "[user_data] Disabling default server config if present..."
if [ -f /etc/nginx/conf.d/default.conf ]; then
  mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
fi

echo "[user_data] Creating hellowar frontend server block..."
cat > /etc/nginx/conf.d/hellowar.conf << 'EOF'
server {
    listen       80 default_server;
    listen       [::]:80 default_server;

    server_name  _;

    # Our app docroot
    root   /srv/hellowar;
    index  index.html;

    # Basic security headers (tweak as needed)
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection "1; mode=block";

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Restrict access to nginx status/example locations (none enabled by default)
}
EOF

# ---- Placeholder app content ----
echo "[user_data] Writing placeholder index.html..."
cat > "${APP_ROOT}/index.html" << 'HTML'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Hello WAR Frontend - Placeholder</title>
  </head>
  <body>
    <h1>Hello WAR Frontend</h1>
    <p>NGINX is up and serving from /srv/hellowar</p>
    <p>CI/CD will later deploy the React dist here.</p>
  </body>
</html>
HTML

chown nginx:nginx "${APP_ROOT}/index.html"
chmod 0640 "${APP_ROOT}/index.html"

# ---- Systemd service hardening (similar spirit to Tomcat) ----
# DO NOT OVERWRITE /systemd/system/nginx.service (package upgrades can overwrite it later)
# Override/Extend : /systemd/system/<service>.service.d/<custom>.conf
# Systemd will load the unit file in this order:
# /usr/lib/systemd/system/nginx.service ← packaged file
# /etc/systemd/system/nginx.service.d/*.conf ← YOUR overrides
# Merge them



# Official "override folder" for systemd serivce
# Changing service settings without touching vendor's nginx.service file
# main service file is --- /usr/lib/systemd/system/nginx.service (Installed via RPM)
  # -- Even if you modify the above it will work - but system updates can replace it
# nginx serivce loads the vendor file : /usr/lib/systemd/system/nginx.service
# then reads all drop-in files (.d) : /etc/systemd/system/nginx.service.d/*.comf
echo "[user_data] Adding systemd hardening overrides for NGINX..."
mkdir -p /etc/systemd/system/nginx.service.d

cat > /etc/systemd/system/nginx.service.d/hardening.conf << 'EOF'
[Service]
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
EOF

echo "[user_data] Enabling and restarting NGINX..."
systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

echo "[user_data] Done (NGINX frontend hardened-ish)."
