#!/usr/bin/env bash
#
# bootstrap-tomcat.sh
#
# Phase-1: Turn a fresh Amazon Linux EC2 into a hardened Tomcat 10.1 host
# Usage (once you scp it to the box):
#   sudo bash bootstrap-tomcat.sh
#
# Log : /var/log/cloud-init-output.log
# Ship to central logging
# echo "ok" > /opt/bootstrap.status
# 


# -e : Exit immediate
# -u : Error if unset var referenced
# -o : pipefail (cmd1 | cmd2)
set -euo pipefail


# VARIABLES
TOMCAT_USER="tomcat"
TOMCAT_GROUP="tomcat"
TOMCAT_HOME="/opt/tomcat"

# ONLY IF DEPLOY SCRIPT BEING USED (deploy.sh = Artifactory Pull Script, place in below Dir - Invoked by CD)
DEPLOY_DIR="/opt/deploy"
DEPLOY_SCRIPT_URL="https://.<PUT THE RAW HTTP URL OF THE DEPLOY.SH FROM PROJ-hellow-infra/scripts"

TOMCAT_VERSION="10.1.49"
TOMCAT_TGZ="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
TOMCAT_URL="https://dlcdn.apache.org/tomcat/tomcat-10/v${TOMCAT_VERSION}/bin/${TOMCAT_TGZ}"
TOMCAT_SHA_URL="${TOMCAT_URL}.sha512"



echo "[bootstrap] Starting Tomcat bootstrap for ${TOMCAT_VERSION} ..."

## 0) Basic sanity - Script must run as BootStrap
# $(id-u) : Command substitution ..... [[ ... ]]- better at parsing Var expansions
# exit 1 (non zero) as 0 = success / nonzero = failure of script
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[bootstrap] ERROR: must run as root (use sudo)"
  exit 1 
fi




## 1) OS update + packages
echo "[bootstrap] Updating system and installing packages..."
dnf update -y
dnf upgrade -y

# Same as --- dnf install -y java-17-amazon-corretto-devel tar unzip
# Installing java + tar + unzip tools
dnf install -y \
  java-17-amazon-corretto-devel \
  tar \
  unzip


# Check if 'curl' is already installed
# >/dev/null 2>&1 ---  hides stdout+stderr 
if ! command -v curl >/dev/null 2>&1; then
  dnf install -y curl-minimal
fi



## 2) Tomcat : User and directories
echo "[bootstrap] Creating ${TOMCAT_USER} user and directories..."

# id ... (guard condition) Checks if TOMCAT_USER already exists (suppresses ouptut of it)
# || If left side fails ---> Run right side
# --system : System account (< 1000 : No human login)
# --create-home : (--home-dir : sets home dir) but --create-home : Creates dir
# --shell /sbin/nologin : Cannot login interactively

id "${TOMCAT_USER}" &>/dev/null || \
  useradd --system --home-dir "${TOMCAT_HOME}" --create-home --shell /sbin/nologin "${TOMCAT_USER}"

mkdir -p "${TOMCAT_HOME}" #idempotency - incase useradd not created (if tomcat user exists) | as home_dir may still not be present even if user exists
chown -R "${TOMCAT_USER}:${TOMCAT_GROUP}" "${TOMCAT_HOME}"
chmod 750 "${TOMCAT_HOME}"





## 3) Download & install Tomcat
echo "[bootstrap] Downloading Tomcat ${TOMCAT_VERSION}..."
cd /tmp

# -f : fail on HTTP errors | -S : Show error msg | -L : Follow redirects(links) | -o : Output to TOMCAT_TGZ file

curl -fSL -o "${TOMCAT_TGZ}" "${TOMCAT_URL}"
curl -fSL -o "${TOMCAT_TGZ}.sha512" "${TOMCAT_SHA_URL}"

# File integrity / not corrupted-tampered
echo "[bootstrap] Verifying checksum..."
sha512sum -c "${TOMCAT_TGZ}.sha512"

echo "[bootstrap] Extracting Tomcat to ${TOMCAT_HOME}..."
# Clean existing contents but keep dir
rm -rf "${TOMCAT_HOME:?}/"*
tar -xzf "${TOMCAT_TGZ}" -C "${TOMCAT_HOME}" --strip-components=1

# Why run again - tar command run by root (if packged by root unpacked by tomcat user - then not needed)
chown -R "${TOMCAT_USER}:${TOMCAT_GROUP}" "${TOMCAT_HOME}"




## 4) setenv.sh (JVM options, umask, encoding)
# Tomcat startup script (/opt/tomcat/bin/catalina.sh) has logic, if bin/setenv.sh exists - source it before starting JVM
# So setenv.sh = hookfile
# Why not directly update in catalina.sh --- as upgrades to Tomcat would overwrite (bad practice - recommended by Apache)
# "EOF" - quoted eof - no expand variables | $PATH stays literal (not expanded)

# What it does:
# 1. JAVA + Catalina paths exported (where java/tomcat lives) + adds JAVA to PATH
# 2. Umask - Default permissions 0027 = Files:640 | Dir:750
# 3. JVM Memory options - xms256m: Initial Heap | xmx512m: Max Heap  || Limits Metaspace | Exit : if JVM runs out of memor (instead of limping)
# 4. Encoding defaults for consistent UTF-8 Behavior
# 
echo "[bootstrap] Creating setenv.sh..."
cat > "${TOMCAT_HOME}/bin/setenv.sh" <<"EOF"
#!/usr/bin/env bash

# JAVA + CATALINA paths
export JAVA_HOME="/usr/lib/jvm/java-17-amazon-corretto.x86_64"
export CATALINA_HOME="/opt/tomcat"
export CATALINA_BASE="/opt/tomcat"
export PATH="${JAVA_HOME}/bin:${PATH}"

# Security: default umask for Tomcat processes
umask 0027

# JVM memory & stability options
CATALINA_OPTS="${CATALINA_OPTS} -Xms256m"
CATALINA_OPTS="${CATALINA_OPTS} -Xmx512m"
CATALINA_OPTS="${CATALINA_OPTS} -XX:MaxMetaspaceSize=256m"
CATALINA_OPTS="${CATALINA_OPTS} -XX:+ExitOnOutOfMemoryError"

# Encoding defaults
CATALINA_OPTS="${CATALINA_OPTS} -Dfile.encoding=UTF-8 -Dsun.jnu.encoding=UTF-8"

export CATALINA_OPTS
EOF

# Since file was made by root
chown "${TOMCAT_USER}:${TOMCAT_GROUP}" "${TOMCAT_HOME}/bin/setenv.sh"
chmod 750 "${TOMCAT_HOME}/bin/setenv.sh"




## 5) systemd unit
echo "[bootstrap] Creating systemd unit /etc/systemd/system/tomcat.service ..."
cat > /etc/systemd/system/tomcat.service <<"EOF"
[Unit]
Description=Apache Tomcat Application Server (Hardened)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tomcat
Group=tomcat
WorkingDirectory=/opt/tomcat

# --- Core Tomcat env ---
Environment=CATALINA_HOME=/opt/tomcat
Environment=CATALINA_BASE=/opt/tomcat
UMask=0027

# --- Security hardening (reasonable, not insane) ---
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/opt/tomcat

ProtectControlGroups=true
ProtectKernelTunables=true
ProtectClock=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# --- Resource limits ---
LimitNOFILE=65535

# --- Start/stop commands ---
ExecStart=/opt/tomcat/bin/catalina.sh run
ExecStop=/opt/tomcat/bin/shutdown.sh

# --- Restart policy ---
Restart=on-failure
RestartSec=5s

# --- Logging ---
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF




## 6) Enable + start Tomcat
echo "[bootstrap] Enabling & starting Tomcat via systemd..."
systemctl daemon-reload         # SystemD does not auto detect new unit files
systemctl enable --now tomcat   # Enable creates : Symlink --> to tomcat.service file created above (/etc/systemd/system/) : Auto starts at boot   |   --nnow : start now as well




## 7) Security hygiene: remove default webapps, disable shutdown port
echo "[bootstrap] Removing default webapps..."
rm -rf /opt/tomcat/webapps/{docs,examples,host-manager,manager,ROOT}

# 8005 is tomcat shutdown port localhost:8005 - someone can send SHUTDOWN to port and tomcat will stop; so replace with -1
# || true --- we have set -e at top; if command (Sed) fails to find 8005; script should continue so take it as "true" ---> Right side of ||
echo "[bootstrap] Disabling shutdown port..."
sed -i 's/port="8005"/port="-1"/' /opt/tomcat/conf/server.xml || true

echo "[bootstrap] Restarting Tomcat after changes..."
systemctl restart tomcat


sleep 2


## 8) Deploy Script (deploy.sh)

echo "[bootstrap] Creating deploy directory and installing deploy.sh..."
mkdir -p "${DEPLOY_DIR}"
chown root:root "${DEPLOY_DIR}"
chmod 750 "${DEPLOY_DIR}"

curl -fSL "${DEPLOY_SCRIPT_URL}" -o "${DEPLOY_DIR}/deploy.sh"
chown root:root "${DEPLOY_DIR}/deploy.sh"
chmod 700 "${DEPLOY_DIR}/deploy.sh"

echo "[bootstrap] deploy.sh installed at ${DEPLOY_DIR}/deploy.sh"


## 9) Service status Verification

# --quiet : without will print active/inactive; in scripts we need error codes : 0/1 --quite returns these code (0-active | non-0 : inactive)
# --no-pager : full output (no page/less) : as script can hang waiting for pager input 
# if not active : exit 1 --- indicating to linux script failed 
echo "[bootstrap] Verifying Tomcat service state..."
if ! systemctl is-active --quiet tomcat; then
  echo "[bootstrap] ERROR: tomcat service is not active"
  systemctl status tomcat --no-pager || true
  exit 1
fi
echo "[bootstrap] OK: tomcat service is active."


# 2nd level health-check : if port listening
# -lntp : listening socket only | numeric address  | tcp only | process no.
# ss = socket statistics (modern / replacement of netstat)
echo "[bootstrap] Verifying port 8080 is listening..."
if ! ss -lntp | grep -q ":8080"; then
  echo "[bootstrap] ERROR: port 8080 is not listening"
  ss -lntp || true
  exit 1
fi
echo "[bootstrap] OK: port 8080 is listening."

echo "[bootstrap] SUCCESS: Tomcat installed and running on port 8080."
echo "[bootstrap] You can now deploy a WAR and hit http://<ip>:8080/..."
