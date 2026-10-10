{{/*
qradar-ha Helm chart helpers
*/}}

{{/*
Resolve plan sizing from .Values.plan and .Values.plans.
Returns a dict with cpuCores, memoryGb, storageGb.
Usage: include "qradar-ha.planSizing" . | fromYaml
*/}}
{{- define "qradar-ha.planSizing" -}}
{{- $plan := .Values.plan | default "medium" -}}
{{- $plan = trimSuffix "-ha" $plan -}}
{{- $sizing := index .Values.plans $plan | default (index .Values.plans "medium") -}}
cpuCores: {{ $sizing.cpuCores }}
memoryGb: {{ $sizing.memoryGb }}
storageGb: {{ $sizing.storageGb }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "qradar-ha.labels" -}}
app: qradar
app.kubernetes.io/name: qradar
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
instance: {{ .Release.Name }}
version: {{ .Chart.AppVersion | quote }}
deployment-type: {{ .Values.topology }}
{{- end }}

{{/*
================================================================================
qradar-ocp-configure.sh — PRIMARY variant
Node-specific: LOCAL_HA_IP=10.0.0.1 (VIP), PEER=10.0.0.11, hostname=console.qradar.lab
Indented 10 spaces for cloud-init write_files content block.
================================================================================
*/}}
{{- define "qradar-ha.configureSh.primary" -}}
#!/bin/bash
set -euo pipefail

echo '=== Configuring Networks for QRadar HA ===' >> /var/log/qradar-ocp-init.log
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
PRIMARY_IP=$(ip -4 addr show dev "$PRIMARY_IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
CIDR=$(ip -4 addr show dev "$PRIMARY_IFACE" | awk '/inet / {print $2}' | cut -d/ -f2)
PRIMARY_GW=$(ip route | grep default | awk '{print $3}' | head -n1)
PRIMARY_DNS='{{ .Values.qradar.dnsPrimary }}'
SECONDARY_DNS='{{ .Values.qradar.dnsSecondary }}'
DOMAIN_NAME='qradar.lab'
PRIMARY_NETMASK=$(python3 -c "import socket,struct; print(socket.inet_ntoa(struct.pack('>I', (0xffffffff << (32 - int('$CIDR'))) & 0xffffffff)))")
echo "Primary NIC: IF=$PRIMARY_IFACE IP=$PRIMARY_IP MASK=$PRIMARY_NETMASK GW=$PRIMARY_GW" >> /var/log/qradar-ocp-init.log
LOCAL_HA_IP='10.0.0.10'
PEER_HA_IP='10.0.0.11'
echo "HA Network: IP=$LOCAL_HA_IP VIP=10.0.0.1 PEER=$PEER_HA_IP" >> /var/log/qradar-ocp-init.log
LOCAL_FQDN='console.qradar.lab'
LOCAL_HOSTNAME=$(echo "$LOCAL_FQDN" | cut -d'.' -f1)
hostnamectl set-hostname "$LOCAL_FQDN"
cp -a /etc/hosts /etc/hosts.bak
# Primary removes any stale self entries tied to the pod-network IP and
# its local HA IP, then rewrites /etc/hosts so the primary HA IP maps to
# itself and the peer HA IP maps to the secondary node.
sed -i -E "/\b${LOCAL_FQDN}\b/d" /etc/hosts
sed -i "/^${PRIMARY_IP}[[:space:]]/d" /etc/hosts
sed -i "/^${LOCAL_HA_IP}[[:space:]]/d" /etc/hosts
sed -i "/^10\.0\.0\.1[[:space:]]/d" /etc/hosts
sed -i "/^127\.0\.0\.1[[:space:]]/d" /etc/hosts
sed -i "/^::1[[:space:]]/d" /etc/hosts
sed -i -E '/^10\.(12[89]|13[01])\./d' /etc/hosts
sed -i -E '/^fe80::/d' /etc/hosts
# Add localhost and also the post-HA-Wizard hostname for this node.
# The HA Wizard appends '-primary' to the short hostname, e.g.
# console -> console-primary. Pre-populating this entry ensures
# hostname -f resolves immediately after pairing (required by
# configure-traefik.sh; without it traefik hangs on DNS timeout).
POST_HA_HOSTNAME="${LOCAL_HOSTNAME}-primary"
LOCAL_DOMAIN=$(echo "$LOCAL_FQDN" | cut -d'.' -f2-)
POST_HA_FQDN="${POST_HA_HOSTNAME}.${LOCAL_DOMAIN}"
echo "127.0.0.1       localhost.localdomain localhost localhost4.localdomain4 localhost4 ${POST_HA_FQDN} ${POST_HA_HOSTNAME}" >> /etc/hosts
echo "::1             localhost6.localdomain6 localhost6 localhost.localdomain localhost ${POST_HA_FQDN} ${POST_HA_HOSTNAME}" >> /etc/hosts
# QRadar HA Console VIP / cluster address (enp2s0)
echo "$LOCAL_HA_IP    $LOCAL_FQDN $LOCAL_HOSTNAME" >> /etc/hosts
# QRadar HA Primary physical IP (10.0.0.1) post-pairing
echo "10.0.0.1        ${POST_HA_FQDN} ${POST_HA_HOSTNAME}" >> /etc/hosts
# QRadar secondary peer (10.0.0.11); used by SSH pre-trust and HA pairing
echo "$PEER_HA_IP    standby.qradar.lab standby console-secondary.qradar.lab console-secondary" >> /etc/hosts
cat > /etc/NetworkManager/conf.d/90-dns-none.conf <<'EOF'
[main]
dns=none
EOF
sed -i '/DHCP_HOSTNAME/d' "/etc/sysconfig/network-scripts/ifcfg-$PRIMARY_IFACE" 2>/dev/null || true
nmcli connection reload 2>/dev/null || true
nmcli connection up "$PRIMARY_IFACE" 2>/dev/null || true
# Write resolv.conf AFTER nmcli connection up — nmcli activates NM via D-Bus
# which triggers a DHCP renew that overwrites resolv.conf with search-domain-only.
# Writing after the nmcli calls ensures our nameservers are the final state.
printf 'nameserver %s\nnameserver %s\nsearch %s\n' "$PRIMARY_DNS" "$SECONDARY_DNS" "$DOMAIN_NAME" > /etc/resolv.conf
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi
{{- end }}

{{/*
================================================================================
qradar-ocp-configure.sh — SECONDARY variant
Node-specific: LOCAL_HA_IP=10.0.0.11, PEER=10.0.0.1 (VIP), hostname=standby.qradar.lab
================================================================================
*/}}
{{- define "qradar-ha.configureSh.secondary" -}}
#!/bin/bash
set -euo pipefail

echo '=== Configuring Networks for QRadar HA ===' >> /var/log/qradar-ocp-init.log
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
PRIMARY_IP=$(ip -4 addr show dev "$PRIMARY_IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
CIDR=$(ip -4 addr show dev "$PRIMARY_IFACE" | awk '/inet / {print $2}' | cut -d/ -f2)
PRIMARY_GW=$(ip route | grep default | awk '{print $3}' | head -n1)
PRIMARY_DNS='{{ .Values.qradar.dnsPrimary }}'
SECONDARY_DNS='{{ .Values.qradar.dnsSecondary }}'
DOMAIN_NAME='qradar.lab'
PRIMARY_NETMASK=$(python3 -c "import socket,struct; print(socket.inet_ntoa(struct.pack('>I', (0xffffffff << (32 - int('$CIDR'))) & 0xffffffff)))")
echo "Primary NIC: IF=$PRIMARY_IFACE IP=$PRIMARY_IP MASK=$PRIMARY_NETMASK GW=$PRIMARY_GW" >> /var/log/qradar-ocp-init.log
LOCAL_HA_IP='10.0.0.11'
PEER_HA_IP='10.0.0.10'
echo "HA Network: IP=$LOCAL_HA_IP PEER_PRIMARY=$PEER_HA_IP VIP=10.0.0.1" >> /var/log/qradar-ocp-init.log
LOCAL_FQDN='standby.qradar.lab'
LOCAL_HOSTNAME=$(echo "$LOCAL_FQDN" | cut -d'.' -f1)
PEER_FQDN='console.qradar.lab'
PEER_HOSTNAME=$(echo "$PEER_FQDN" | cut -d'.' -f1)
hostnamectl set-hostname "$LOCAL_FQDN"
cp -a /etc/hosts /etc/hosts.bak
# Secondary removes any stale local and peer hostname/IP entries, then
# rewrites /etc/hosts so the peer HA IP maps to the primary node and the
# local HA IP maps to the secondary node itself.
sed -i -E "/\b${LOCAL_FQDN}\b/d" /etc/hosts
sed -i -E "/\b${PEER_FQDN}\b/d" /etc/hosts
sed -i "/^${LOCAL_HA_IP}[[:space:]]/d" /etc/hosts
sed -i "/^${PEER_HA_IP}[[:space:]]/d" /etc/hosts
sed -i "/^10\.0\.0\.1[[:space:]]/d" /etc/hosts
sed -i "/^127\.0\.0\.1[[:space:]]/d" /etc/hosts
sed -i "/^::1[[:space:]]/d" /etc/hosts
sed -i -E '/^10\.(12[89]|13[01])\./d' /etc/hosts
sed -i -E '/^fe80::/d' /etc/hosts
# Add localhost and also the post-HA-Wizard hostname for this node.
# The HA Wizard derives the post-pairing hostname from CLUSTER_HOSTNAME
# (ha.conf), not from the node's pre-pairing hostname. The cluster VIP
# hostname is PEER_FQDN (e.g. console.qradar.lab); the HA Wizard appends
# '-secondary' to its short part → console-secondary.qradar.lab.
# Pre-populating this entry ensures hostname -f resolves immediately after
# pairing without a DNS lookup (required by myver, configure-traefik.sh,
# and other QRadar binaries that call hostname -f at startup).
CLUSTER_SHORT=$(echo "$PEER_FQDN" | cut -d'.' -f1)
CLUSTER_DOMAIN=$(echo "$PEER_FQDN" | cut -d'.' -f2-)
POST_HA_HOSTNAME="${CLUSTER_SHORT}-secondary"
POST_HA_FQDN="${POST_HA_HOSTNAME}.${CLUSTER_DOMAIN}"
echo "127.0.0.1       localhost.localdomain localhost localhost4.localdomain4 localhost4 ${POST_HA_FQDN} ${POST_HA_HOSTNAME}" >> /etc/hosts
echo "::1             localhost6.localdomain6 localhost6 localhost.localdomain localhost ${POST_HA_FQDN} ${POST_HA_HOSTNAME}" >> /etc/hosts
# QRadar primary peer / VIP (10.0.0.10); used by SSH pre-trust and HA pairing
echo "$PEER_HA_IP    $PEER_FQDN $PEER_HOSTNAME" >> /etc/hosts
# QRadar HA Primary physical IP (10.0.0.1) post-pairing
echo "10.0.0.1        ${CLUSTER_SHORT}-primary.${CLUSTER_DOMAIN} ${CLUSTER_SHORT}-primary" >> /etc/hosts
# QRadar secondary local IP (enp2s0); used by ha_manager
echo "$LOCAL_HA_IP    $LOCAL_FQDN $LOCAL_HOSTNAME ${POST_HA_FQDN} ${POST_HA_HOSTNAME}" >> /etc/hosts
cat > /etc/NetworkManager/conf.d/90-dns-none.conf <<'EOF'
[main]
dns=none
EOF
sed -i '/DHCP_HOSTNAME/d' "/etc/sysconfig/network-scripts/ifcfg-$PRIMARY_IFACE" 2>/dev/null || true
nmcli connection reload 2>/dev/null || true
nmcli connection up "$PRIMARY_IFACE" 2>/dev/null || true
# Write resolv.conf AFTER nmcli connection up — nmcli activates NM via D-Bus
# which triggers a DHCP renew that overwrites resolv.conf with search-domain-only.
# Writing after the nmcli calls ensures our nameservers are the final state.
printf 'nameserver %s\nnameserver %s\nsearch %s\n' "$PRIMARY_DNS" "$SECONDARY_DNS" "$DOMAIN_NAME" > /etc/resolv.conf
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi
{{- end }}

{{/*
================================================================================
qradar-ocp-configure.sh — STANDALONE variant
DHCP discovery: detects primary NIC, IP, gateway, netmask at runtime.
Hostname derived from release name + domain (or standalone.hostname override).
All AUTO_INSTALL_INSTRUCTIONS network fields are patched at runtime.
================================================================================
*/}}
{{- define "qradar-ha.configureSh.standalone" -}}
#!/bin/bash
set -euo pipefail

echo '=== Configuring Network for QRadar Standalone ===' >> /var/log/qradar-ocp-init.log
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
PRIMARY_IP=$(ip -4 addr show dev "$PRIMARY_IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
CIDR=$(ip -4 addr show dev "$PRIMARY_IFACE" | awk '/inet / {print $2}' | cut -d/ -f2)
PRIMARY_GW=$(ip route | grep default | awk '{print $3}' | head -n1)
PRIMARY_DNS='{{ .Values.qradar.dnsPrimary }}'
SECONDARY_DNS='{{ .Values.qradar.dnsSecondary | default "8.8.4.4" }}'
DOMAIN_NAME='{{ .Values.network.domainName }}'
PRIMARY_NETMASK=$(python3 -c "import socket,struct; print(socket.inet_ntoa(struct.pack('>I', (0xffffffff << (32 - int('$CIDR'))) & 0xffffffff)))")
echo "Primary NIC: IF=$PRIMARY_IFACE IP=$PRIMARY_IP MASK=$PRIMARY_NETMASK GW=$PRIMARY_GW" >> /var/log/qradar-ocp-init.log
{{- $hostname := .Values.standalone.hostname }}
{{- if not $hostname }}
{{-   $hostname = printf "%s.%s" .Release.Name .Values.network.domainName }}
{{- end }}
LOCAL_FQDN='{{ $hostname }}'
LOCAL_HOSTNAME=$(echo "$LOCAL_FQDN" | cut -d'.' -f1)
hostnamectl set-hostname "$LOCAL_FQDN"
cp -a /etc/hosts /etc/hosts.bak
sed -i -E "/\b${LOCAL_FQDN}\b/d" /etc/hosts
sed -i "/^${PRIMARY_IP}[[:space:]]/d" /etc/hosts
sed -i "/^127\.0\.0\.1[[:space:]]/d" /etc/hosts
sed -i "/^::1[[:space:]]/d" /etc/hosts
echo "127.0.0.1       localhost.localdomain localhost localhost4.localdomain4 localhost4" >> /etc/hosts
echo "::1             localhost6.localdomain6 localhost6 localhost.localdomain localhost" >> /etc/hosts
echo "$PRIMARY_IP    $LOCAL_FQDN $LOCAL_HOSTNAME" >> /etc/hosts
cat > /etc/NetworkManager/conf.d/90-dns-none.conf <<'EOF'
[main]
dns=none
EOF
sed -i '/DHCP_HOSTNAME/d' "/etc/sysconfig/network-scripts/ifcfg-$PRIMARY_IFACE" 2>/dev/null || true
nmcli connection reload 2>/dev/null || true
nmcli connection up "$PRIMARY_IFACE" 2>/dev/null || true
# Write resolv.conf AFTER nmcli connection up — nmcli activates NM via D-Bus
# which triggers a DHCP renew that overwrites resolv.conf with search-domain-only.
# Writing after the nmcli calls ensures our nameservers are the final state.
printf 'nameserver %s\nnameserver %s\nsearch %s\n' "$PRIMARY_DNS" "$SECONDARY_DNS" "$DOMAIN_NAME" > /etc/resolv.conf
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi
# Patch AUTO_INSTALL_INSTRUCTIONS with runtime-discovered network values.
# The written file contains placeholder addresses; these sed calls overwrite
# them with the actual DHCP-assigned values before the installer runs.
sed -i "s|^ai_ip_management_interface=.*|ai_ip_management_interface=$PRIMARY_IFACE|" /root/AUTO_INSTALL_INSTRUCTIONS
sed -i "s|^ai_ip_v4_address=.*|ai_ip_v4_address=$PRIMARY_IP|" /root/AUTO_INSTALL_INSTRUCTIONS
sed -i "s|^ai_ip_v4_gateway=.*|ai_ip_v4_gateway=$PRIMARY_GW|" /root/AUTO_INSTALL_INSTRUCTIONS
sed -i "s|^ai_ip_v4_network_mask=.*|ai_ip_v4_network_mask=$PRIMARY_NETMASK|" /root/AUTO_INSTALL_INSTRUCTIONS
sed -i "s|^ai_hostname=.*|ai_hostname=$LOCAL_FQDN|" /root/AUTO_INSTALL_INSTRUCTIONS
echo "AUTO_INSTALL_INSTRUCTIONS patched with runtime network values" >> /var/log/qradar-ocp-init.log
{{- end }}

{{/*
================================================================================
qradar-ocp-network.sh — PRIMARY variant
HA_IP=10.0.0.1 (VIP/management IP during install)
================================================================================
*/}}
{{- define "qradar-ha.networkSh.primary" -}}
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/qradar-ocp-network.log) 2>&1

# Interface names are fixed by the VM template:
#   enp1s0 — pod network NIC (DHCP)
#   enp2s0 — HA/management NIC (fixed primary IP during install)
PRIMARY_IFACE='enp1s0'
HA_IFACE='enp2s0'

HA_IP='{{ .Values.network.primaryIp | default "10.0.0.10" }}'
HA_PREFIX={{ .Values.network.haPrefix | default 24 }}

# If HA pairing has completed or was initiated, the primary node's persistent physical IP
# in ha.conf is PRIMARY_IP (typically 10.0.0.1), while the virtual cluster IP (10.0.0.10)
# is dynamically managed by ha_manager and ha_ipaddr. Never reset the physical IP back to the VIP on reboot!
if [ -f /opt/qradar/ha/ha.conf ]; then
    CONF_PRIM_IP=$(grep '^PRIMARY_IP=' /opt/qradar/ha/ha.conf 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    if [ -n "$CONF_PRIM_IP" ]; then
        echo "[INFO] Detected HA configuration in ha.conf — preserving physical primary IP $CONF_PRIM_IP" >> /var/log/qradar-ocp-network.log
        HA_IP="$CONF_PRIM_IP"
    fi
fi

# Use NetworkManager if available (first boot); fall back to direct ip(8)
# for subsequent boots where QRadar's netsetup has stopped NM.
if nmcli -t general status 2>/dev/null | grep -q "^connected\|^disconnected\|^asleep"; then
    echo "[OK] NetworkManager available — using nmcli" >> /var/log/qradar-ocp-network.log

    PRIMARY_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep ":$PRIMARY_IFACE$" | cut -d: -f1 | head -n1 || true)
    if [ -n "$PRIMARY_CONN" ]; then
        nmcli connection modify "$PRIMARY_CONN" ipv4.dhcp-hostname "" ipv6.dhcp-hostname "" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes 2>/dev/null || true
        nmcli connection up "$PRIMARY_CONN" 2>/dev/null || true
    fi

    EXISTING_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep ":$HA_IFACE$" | cut -d: -f1 | head -n1 || true)
    if [ -n "$EXISTING_CONN" ]; then
        echo "Found existing connection '$EXISTING_CONN' on $HA_IFACE, reconfiguring it..."
        nmcli connection modify "$EXISTING_CONN" \
            ipv4.method manual \
            ipv4.addresses "${HA_IP}/${HA_PREFIX}" \
            ipv4.never-default yes \
            connection.autoconnect yes
        HA_CONN="$EXISTING_CONN"
    else
        nmcli connection add \
            type ethernet \
            con-name qradar-ha-net \
            ifname "$HA_IFACE" \
            ipv4.method manual \
            ipv4.addresses "${HA_IP}/${HA_PREFIX}" \
            ipv4.never-default yes \
            connection.autoconnect yes
        HA_CONN="qradar-ha-net"
    fi

    nmcli connection up "$HA_CONN" || true
else
    echo "[WARN] NetworkManager not running — assigning IP directly" >> /var/log/qradar-ocp-network.log
    # QRadar's netsetup stops NM post-install; use ip(8) directly.
    ip addr show "$HA_IFACE" | grep -q "${HA_IP}/" || \
        ip addr add "${HA_IP}/${HA_PREFIX}" dev "$HA_IFACE"
    ip link set "$HA_IFACE" up
fi

# Flush stale ARP cache and send gratuitous ARP.
# Required for cross-node deployments: OVN southbound DB caches MAC→IP
# bindings across deployments. Without this, VMs on different OCP nodes
# cannot reach each other until OVN ages out the stale entry (~5 min).
# arping -A forces immediate re-learning on both the remote VM kernel
# and the OVN southbound DB.
ip neigh flush dev "$HA_IFACE" 2>/dev/null || true
arping -c 3 -A -I "$HA_IFACE" "$HA_IP" 2>/dev/null || true
ip addr show "$HA_IFACE"
{{- end }}

{{/*
================================================================================
qradar-ocp-network.sh — SECONDARY variant
HA_IP=10.0.0.11 (secondary static IP)
================================================================================
*/}}
{{- define "qradar-ha.networkSh.secondary" -}}
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/qradar-ocp-network.log) 2>&1

# Interface names are fixed by the VM template:
#   enp1s0 — pod network NIC (DHCP)
#   enp2s0 — HA/management NIC (static)
PRIMARY_IFACE='enp1s0'
HA_IFACE='enp2s0'

HA_IP='{{ .Values.network.secondaryIp | default "10.0.0.11" }}'
HA_PREFIX={{ .Values.network.haPrefix | default 24 }}

# Use NetworkManager if available (first boot); fall back to direct ip(8)
# for subsequent boots where QRadar's netsetup has stopped NM.
if nmcli -t general status 2>/dev/null | grep -q "^connected\|^disconnected\|^asleep"; then
    echo "[OK] NetworkManager available — using nmcli" >> /var/log/qradar-ocp-network.log

    PRIMARY_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep ":$PRIMARY_IFACE$" | cut -d: -f1 | head -n1 || true)
    if [ -n "$PRIMARY_CONN" ]; then
        nmcli connection modify "$PRIMARY_CONN" ipv4.dhcp-hostname "" ipv6.dhcp-hostname "" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes 2>/dev/null || true
        nmcli connection up "$PRIMARY_CONN" 2>/dev/null || true
    fi

    EXISTING_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep ":$HA_IFACE$" | cut -d: -f1 | head -n1 || true)
    if [ -n "$EXISTING_CONN" ]; then
        echo "Found existing connection '$EXISTING_CONN' on $HA_IFACE, reconfiguring it..."
        nmcli connection modify "$EXISTING_CONN" \
            ipv4.method manual \
            ipv4.addresses "${HA_IP}/${HA_PREFIX}" \
            ipv4.never-default yes \
            connection.autoconnect yes
        HA_CONN="$EXISTING_CONN"
    else
        nmcli connection add \
            type ethernet \
            con-name qradar-ha-net \
            ifname "$HA_IFACE" \
            ipv4.method manual \
            ipv4.addresses "${HA_IP}/${HA_PREFIX}" \
            ipv4.never-default yes \
            connection.autoconnect yes
        HA_CONN="qradar-ha-net"
    fi

    nmcli connection up "$HA_CONN" || true
else
    echo "[WARN] NetworkManager not running — assigning IP directly" >> /var/log/qradar-ocp-network.log
    # QRadar's netsetup stops NM post-install; use ip(8) directly.
    ip addr show "$HA_IFACE" | grep -q "${HA_IP}/" || \
        ip addr add "${HA_IP}/${HA_PREFIX}" dev "$HA_IFACE"
    ip link set "$HA_IFACE" up
fi

# Flush stale ARP cache and send gratuitous ARP.
ip neigh flush dev "$HA_IFACE" 2>/dev/null || true
arping -c 3 -A -I "$HA_IFACE" "$HA_IP" 2>/dev/null || true
ip addr show "$HA_IFACE"
{{- end }}

{{/*
================================================================================
qradar-ocp-network.service — invariant (same for both nodes)
================================================================================
*/}}
{{- define "qradar-ha.networkService" -}}
[Unit]
Description=QRadar HA Network Interface Configuration
After=network.target
# Deliberately no Wants/After NetworkManager — NM is stopped after QRadar installs

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/bin/qradar-ocp-network.sh

[Install]
WantedBy=multi-user.target
{{- end }}

{{/*
================================================================================
qradar-ocp-pretrust.sh — invariant (same IP constants for both nodes)
================================================================================
*/}}
{{- define "qradar-ha.pretrustSh" -}}
#!/bin/bash
set -e

LOG="/var/log/qradar-ocp-pretrust.log"
PRIMARY_IP="10.0.0.10"
VIP="10.0.0.1"
SECONDARY_IP="10.0.0.11"
MARKER="/var/log/qradar-ocp-pretrust-complete"

if [ -f "$MARKER" ]; then
    echo "SSH pre-trust already completed" >> "$LOG"
    systemctl disable qradar-ocp-pretrust.service 2>/dev/null || true
    exit 0
fi

# Detect peer IP dynamically based on local interface
LOCAL_IPS=$(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1)
if echo "$LOCAL_IPS" | grep -q "10.0.0.10"; then
    PEER_IP="$SECONDARY_IP"
else
    PEER_IP="$PRIMARY_IP"
fi

echo "=== QRadar SSH Key Pre-Trust ===" >> "$LOG"
echo "Started: $(date)" >> "$LOG"
echo "Primary IP: $PRIMARY_IP (VIP: $VIP)" >> "$LOG"
echo "Secondary IP: $SECONDARY_IP" >> "$LOG"
echo "Target Peer IP: $PEER_IP" >> "$LOG"

mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts

if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

ssh-keygen -R "$PRIMARY_IP" >/dev/null 2>&1 || true
ssh-keygen -R "$VIP" >/dev/null 2>&1 || true
ssh-keygen -R "$SECONDARY_IP" >/dev/null 2>&1 || true

echo "Waiting for peer VM SSH at $PEER_IP:22..." >> "$LOG"
while ! nc -z -w 2 "$PEER_IP" 22 2>/dev/null; do
    echo "[WAIT] Peer SSH not available yet, retrying in 10s..." >> "$LOG"
    sleep 10
done
echo "[OK] Peer SSH is available" >> "$LOG"

echo "Scanning for SSH host keys (with retry)..." >> "$LOG"
for ((i=1; i<=10; i++)); do
    ssh-keyscan -T 5 -t ecdsa,rsa,ed25519 -H "$PRIMARY_IP" >> /root/.ssh/known_hosts 2>>"$LOG"
    ssh-keyscan -T 5 -t ecdsa,rsa,ed25519 -H "$SECONDARY_IP" >> /root/.ssh/known_hosts 2>>"$LOG"
    ssh-keyscan -T 5 -t ecdsa,rsa,ed25519 -H "$VIP" >> /root/.ssh/known_hosts 2>>"$LOG" || true

    if ssh-keygen -F "$SECONDARY_IP" >/dev/null 2>&1 && ssh-keygen -F "$PRIMARY_IP" >/dev/null 2>&1; then
        echo "[OK] All SSH host keys successfully scanned (attempt $i)" >> "$LOG"
        break
    fi
    
    if [ $i -lt 10 ]; then
        echo "[RETRY] Keys not found, retrying in 5s (attempt $i/10)..." >> "$LOG"
        sleep 5
    else
        echo "[ERROR] Failed to scan SSH keys after 10 attempts" >> "$LOG"
        exit 1
    fi
done

sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts
touch "$MARKER"
systemctl disable qradar-ocp-pretrust.service 2>/dev/null || true

echo "[OK] SSH host keys successfully added" >> "$LOG"
echo "Completed: $(date)" >> "$LOG"
echo "=== End SSH Key Pre-Trust ===" >> "$LOG"
{{- end }}

{{/*
================================================================================
qradar-ocp-pretrust.service — invariant
================================================================================
*/}}
{{- define "qradar-ha.pretrustService" -}}
[Unit]
Description=QRadar HA SSH Key Pre-Trust
ConditionPathExists=!/var/log/qradar-ocp-pretrust-complete
After=network-online.target sshd.service
Wants=network-online.target
Before=qradar-ocp-installer.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/qradar-ocp-pretrust.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10s
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
{{- end }}

{{/*
================================================================================
qradar-ocp-install.sh — invariant (same for both nodes; node role is set by
AUTO_INSTALL_INSTRUCTIONS which is node-specific)
================================================================================
*/}}
{{- define "qradar-ha.installSh" -}}
#!/bin/bash
export TERM=xterm-256color
INSTALL_LOG="/var/log/qradar-ocp-install.log"
COMPLETION_MARKER="/var/log/qradar-ocp-install-complete"

# Check if installation already completed
if [ -f "$COMPLETION_MARKER" ]; then
    echo "Installation already completed. Exiting." >> "$INSTALL_LOG"
    systemctl disable qradar-ocp-installer.service 2>/dev/null || true
    exit 0
fi

exec > >(tee -a /var/log/qradar-ocp-install.log /dev/ttyS0) 2>&1
RUN_COUNT_FILE="/var/log/qradar-ocp-run-count"
LAST_KERNEL_FILE="/var/log/qradar-ocp-last-kernel"
{{- if eq .Values.topology "ha" }}
HOSTNAME_PRI=console.qradar.lab
HOSTNAME_SEC=standby.qradar.lab
{{- else }}
{{-   $hostname := .Values.standalone.hostname }}
{{-   if not $hostname }}
{{-     $hostname = printf "%s.%s" .Release.Name .Values.network.domainName }}
{{-   end }}
HOSTNAME_LOCAL='{{ $hostname }}'
{{- end }}

echo "=== QRadar Installation Wrapper Started: $(date) ==="
{{- if eq .Values.topology "ha" }}
sed -i "/${HOSTNAME_PRI}/d" /etc/hosts 2>/dev/null || true
sed -i "/${HOSTNAME_SEC}/d" /etc/hosts 2>/dev/null || true
sed -i "/10\.0\.0\.1/d" /etc/hosts 2>/dev/null || true
sed -i -E '/^10\.(12[89]|13[01])\./d' /etc/hosts 2>/dev/null || true
sed -i -E '/^fe80::/d' /etc/hosts 2>/dev/null || true
echo "10.0.0.10    ${HOSTNAME_PRI} $(echo ${HOSTNAME_PRI} | cut -d'.' -f1)" >> /etc/hosts
echo "10.0.0.1     console-primary.qradar.lab console-primary" >> /etc/hosts
echo "10.0.0.11    ${HOSTNAME_SEC} $(echo ${HOSTNAME_SEC} | cut -d'.' -f1) console-secondary.qradar.lab console-secondary" >> /etc/hosts
{{- end }}
CURRENT_KERNEL=$(uname -r)

if [ ! -f "$RUN_COUNT_FILE" ]; then echo "0" > "$RUN_COUNT_FILE"; fi
RUN_COUNT=$(cat "$RUN_COUNT_FILE")

if [ "$RUN_COUNT" -ge 3 ]; then
    echo "ERROR: Maximum run count (3) reached. Disabling service." >> "$INSTALL_LOG"
    systemctl disable qradar-ocp-installer.service
    exit 1
fi

if [ -f "$LAST_KERNEL_FILE" ]; then
    LAST_KERNEL=$(cat "$LAST_KERNEL_FILE")
    if [ "$CURRENT_KERNEL" != "$LAST_KERNEL" ]; then
        echo "Kernel changed - successful reboot detected!" >> "$INSTALL_LOG"
    fi
fi

echo "$CURRENT_KERNEL" > "$LAST_KERNEL_FILE"
echo $((RUN_COUNT + 1)) > "$RUN_COUNT_FILE"

# Function to check if QRadar installation is complete
check_installation_complete() {
    echo "=== Checking QRadar Installation Completion ===" >> "$INSTALL_LOG"

    # Check 1: Is setup process still running?
    if pgrep -f "/media/cdrom/setup" > /dev/null 2>&1; then
        echo "[FAIL] Setup process is still running" >> "$INSTALL_LOG"
        ps aux | grep -E "[/]media/cdrom/setup" >> "$INSTALL_LOG"
        return 1
    else
        echo "[OK] Setup process not running" >> "$INSTALL_LOG"
    fi

    # Check 2: Is ISO mount point in use?
    if fuser -m /media/cdrom 2>/dev/null | grep -q .; then
        echo "[FAIL] ISO mount point /media/cdrom is still in use" >> "$INSTALL_LOG"
        fuser -vm /media/cdrom 2>&1 | tee -a "$INSTALL_LOG"
        lsof /media/cdrom 2>&1 | tee -a "$INSTALL_LOG"
        return 1
    else
        echo "[OK] ISO mount point not in use" >> "$INSTALL_LOG"
    fi

    # Check 3: Are QRadar services running?
    QRADAR_SERVICES_RUNNING=false
    if systemctl is-active --quiet hostcontext 2>/dev/null; then
        echo "[OK] QRadar hostcontext service is running" >> "$INSTALL_LOG"
        QRADAR_SERVICES_RUNNING=true
    elif systemctl list-units --type=service --state=running | grep -q qradar; then
        echo "[OK] QRadar services detected running" >> "$INSTALL_LOG"
        systemctl list-units --type=service --state=running | grep qradar >> "$INSTALL_LOG"
        QRADAR_SERVICES_RUNNING=true
    else
        echo "[WARN] QRadar services not yet running (may start after deployment)" >> "$INSTALL_LOG"
    fi

    # Check 4: QRadar installation directory exists and populated
    if [ -d "/opt/qradar" ] && [ -d "/opt/qradar/bin" ]; then
        QRADAR_FILES=$(find /opt/qradar -type f 2>/dev/null | wc -l)
        echo "[OK] QRadar installation directory exists with $QRADAR_FILES files" >> "$INSTALL_LOG"
    else
        echo "[FAIL] QRadar installation directory not found or empty" >> "$INSTALL_LOG"
        return 1
    fi

    # Check 5: Stage 2 completion markers in logs
    LATEST_LOG=$(ls -t /var/log/setup-*/*.log 2>/dev/null | head -1)

    if [ -n "$LATEST_LOG" ]; then
        echo "Checking completion markers in: $LATEST_LOG" >> "$INSTALL_LOG"

        MARKER_1=$(grep -E "Initial configuration of .* is now complete" "$LATEST_LOG" 2>/dev/null)
        MARKER_2=$(grep -E "qradar_netsetup\.py: End: 0" "$LATEST_LOG" 2>/dev/null)
        MARKER_3=$(grep -E "OK: Installed QRadar version .* \(Build [0-9]+\)" "$LATEST_LOG" 2>/dev/null)
        MARKER_4=$(grep -E "Recording currently installed RPM list: done" "$LATEST_LOG" 2>/dev/null)

        MARKERS_FOUND=0
        [ -n "$MARKER_1" ] && MARKERS_FOUND=$((MARKERS_FOUND + 1)) && echo "  [OK] Initial configuration complete" >> "$INSTALL_LOG"
        [ -n "$MARKER_2" ] && MARKERS_FOUND=$((MARKERS_FOUND + 1)) && echo "  [OK] Network setup complete" >> "$INSTALL_LOG"
        [ -n "$MARKER_3" ] && MARKERS_FOUND=$((MARKERS_FOUND + 1)) && echo "  [OK] Version installed" >> "$INSTALL_LOG"
        [ -n "$MARKER_4" ] && MARKERS_FOUND=$((MARKERS_FOUND + 1)) && echo "  [OK] RPM list recorded" >> "$INSTALL_LOG"

        [ -z "$MARKER_1" ] && echo "  [WARN] Initial configuration marker not found" >> "$INSTALL_LOG"
        [ -z "$MARKER_2" ] && echo "  [WARN] Network setup marker not found" >> "$INSTALL_LOG"
        [ -z "$MARKER_3" ] && echo "  [WARN] Version installed marker not found" >> "$INSTALL_LOG"
        [ -z "$MARKER_4" ] && echo "  [WARN] RPM list marker not found" >> "$INSTALL_LOG"

        echo "Log markers found: $MARKERS_FOUND/4" >> "$INSTALL_LOG"

        if [ "$MARKERS_FOUND" -eq 4 ]; then
            echo "[OK] All Stage 2 completion markers found in logs!" >> "$INSTALL_LOG"
            echo "" >> "$INSTALL_LOG"
            echo "Last 15 lines of installation log:" >> "$INSTALL_LOG"
            tail -15 "$LATEST_LOG" >> "$INSTALL_LOG"
        fi
    else
        echo "[WARN] No QRadar setup logs found at /var/log/setup-*/*.log" >> "$INSTALL_LOG"
    fi

    # Check 6: qradar_netsetup.log completion markers
    NETSETUP_COMPLETE=false
    NETSETUP_LOG=$(ls -t /var/log/setup-*/qradar_netsetup.log 2>/dev/null | head -1)
    if [ -z "$NETSETUP_LOG" ]; then
        NETSETUP_LOG="/var/log/qradar_netsetup.log"
    fi
    if [ -f "$NETSETUP_LOG" ]; then
        if grep -q "qradar_netsetup finalBlock \[INFO\] Success" "$NETSETUP_LOG" 2>/dev/null; then
            echo "[OK] Found 'qradar_netsetup finalBlock [INFO] Success' in $NETSETUP_LOG" >> "$INSTALL_LOG"
            NETSETUP_COMPLETE=true
        fi
        if grep -q "qradar_netsetup cleanupPid \[INFO\] Cleaning up PID file" "$NETSETUP_LOG" 2>/dev/null; then
            echo "[OK] Found 'cleanupPid' marker in $NETSETUP_LOG" >> "$INSTALL_LOG"
        fi
    fi

    # Check 7: qradar_setup.log completion markers
    SETUP_COMPLETE=false
    SETUP_LOG=$(ls -t /var/log/setup-*/qradar_setup.log 2>/dev/null | head -1)
    if [ -z "$SETUP_LOG" ]; then
        SETUP_LOG="/var/log/qradar_setup.log"
    fi
    if [ -f "$SETUP_LOG" ]; then
        if grep -q "\[setup\]: End" "$SETUP_LOG" 2>/dev/null; then
            echo "[OK] Found '[setup]: End' in $SETUP_LOG" >> "$INSTALL_LOG"
            SETUP_COMPLETE=true
        fi
        if grep -q "No /tmp/autoreboot_timeout file found - NOT REBOOTING from setup" "$SETUP_LOG" 2>/dev/null; then
            echo "[OK] Found 'NOT REBOOTING from setup' marker in $SETUP_LOG" >> "$INSTALL_LOG"
        fi
        if grep -q "rm -fr /var/run/qradar_setup.pid" "$SETUP_LOG" 2>/dev/null; then
            echo "[OK] Found PID cleanup marker in $SETUP_LOG" >> "$INSTALL_LOG"
        fi
    fi

    # Decision: Installation is complete if:
    # - Setup is not running AND
    # - ISO not in use AND
    # - QRadar directory exists AND
    # - (Log markers found OR QRadar services running OR netsetup/setup complete markers)

    COMPLETION_INDICATORS=0
    [ "$QRADAR_SERVICES_RUNNING" = true ] && COMPLETION_INDICATORS=$((COMPLETION_INDICATORS + 1))
    [ "${MARKERS_FOUND:-0}" -ge 3 ] && COMPLETION_INDICATORS=$((COMPLETION_INDICATORS + 1))
    [ "$NETSETUP_COMPLETE" = true ] && COMPLETION_INDICATORS=$((COMPLETION_INDICATORS + 1))
    [ "$SETUP_COMPLETE" = true ] && COMPLETION_INDICATORS=$((COMPLETION_INDICATORS + 1))

    if [ "$COMPLETION_INDICATORS" -ge 1 ]; then
        echo "" >> "$INSTALL_LOG"
        echo "[DONE] Installation completion criteria met!" >> "$INSTALL_LOG"
        echo "  - Setup not running: YES" >> "$INSTALL_LOG"
        echo "  - ISO not in use: YES" >> "$INSTALL_LOG"
        echo "  - QRadar installed: YES" >> "$INSTALL_LOG"
        echo "  - Completion indicators: $COMPLETION_INDICATORS" >> "$INSTALL_LOG"
        [ "$QRADAR_SERVICES_RUNNING" = true ] && echo "    * QRadar services running" >> "$INSTALL_LOG"
        [ "${MARKERS_FOUND:-0}" -ge 3 ] && echo "    * Setup log markers ($MARKERS_FOUND/4)" >> "$INSTALL_LOG"
        [ "$NETSETUP_COMPLETE" = true ] && echo "    * Network setup complete" >> "$INSTALL_LOG"
        [ "$SETUP_COMPLETE" = true ] && echo "    * Setup script complete" >> "$INSTALL_LOG"
        return 0
    else
        echo "" >> "$INSTALL_LOG"
        echo "[FAIL] Installation not complete - criteria not met" >> "$INSTALL_LOG"
        echo "  - Completion indicators found: $COMPLETION_INDICATORS (need at least 1)" >> "$INSTALL_LOG"
        return 1
    fi
}

# Function to unmount and detach ISO
unmount_iso() {
    echo "=== Unmounting QRadar installation ISO ===" >> "$INSTALL_LOG"

    if mountpoint -q /media/cdrom; then
        umount /media/cdrom 2>&1 | tee -a "$INSTALL_LOG"
        if [ $? -eq 0 ]; then
            echo "[OK] ISO unmounted successfully from /media/cdrom" >> "$INSTALL_LOG"
            eject /dev/sr0 2>/dev/null || true
            echo "[OK] ISO tray ejected (signals guest kernel to release tray lock)" >> "$INSTALL_LOG"
        else
            echo "[WARN] Failed to unmount ISO from /media/cdrom" >> "$INSTALL_LOG"
        fi
    else
        echo "ISO not mounted at /media/cdrom" >> "$INSTALL_LOG"
    fi

    # Remove fstab entry
    if grep -q "/media/cdrom" /etc/fstab 2>/dev/null; then
        sed -i '\|/media/cdrom|d' /etc/fstab
        echo "Removed /media/cdrom entry from /etc/fstab" >> "$INSTALL_LOG"
    fi
}

{{- if eq .Values.topology "ha" }}
# Remove the default route from enp1s0 before invoking the installer so that
# qradar_netsetup.py discovers enp2s0 (10.0.0.10) as the management interface
# instead of the DHCP primary NIC. The kubelet readiness probe reaches port
# 8181 via the OVN overlay directly — it does not depend on this route —
# so removing it does not affect the probe.
DEFAULT_GW=$(ip route show default dev enp1s0 2>/dev/null | awk '{print $3}' | head -n1)
if [ -n "$DEFAULT_GW" ]; then
    ip route del default dev enp1s0 2>/dev/null || true
    echo "[OK] Default route via enp1s0 ($DEFAULT_GW) removed before installer" >> "$INSTALL_LOG"
else
    echo "[WARN] No default route found on enp1s0; skipping route removal" >> "$INSTALL_LOG"
fi
{{- end }}
echo "Running QRadar installer..." >> "$INSTALL_LOG"
TEMP_LOG=$(mktemp)
yes Y | /media/cdrom/setup --no-screen > "$TEMP_LOG" 2>&1; EXIT_CODE=$?
{{- if eq .Values.topology "ha" }}
# Restore the default route immediately after the installer exits so that
# QRadar services (DNS, NTP, syslog forwarding) have outbound connectivity.
if [ -n "$DEFAULT_GW" ]; then
    ip route add default via "$DEFAULT_GW" dev enp1s0 2>/dev/null || true
    echo "[OK] Default route via enp1s0 ($DEFAULT_GW) restored after installer" >> "$INSTALL_LOG"
fi
{{- end }}

cat "$TEMP_LOG" >> "$INSTALL_LOG"
echo "Installer exit code: $EXIT_CODE" >> "$INSTALL_LOG"

LAST_OUTPUT=$(tail -100 "$TEMP_LOG")
rm -f "$TEMP_LOG"

# Check if installation completed
if check_installation_complete; then
    echo "[DONE] QRadar installation completed successfully!" >> "$INSTALL_LOG"
    touch "$COMPLETION_MARKER"

    # Deploy iptables drop-in for healthz now that /opt/qradar/conf/iptables.d/post/
    # exists. ExecStartPre in the healthz service only runs at service start; since
    # the service has been running since boot (before QRadar installed), we must
    # deploy the drop-in here and restart the service to activate the iptables rule.
    IPTABLES_POST=/opt/qradar/conf/iptables.d/post
    if [ -d "$IPTABLES_POST" ]; then
        cp /usr/local/etc/qradar-ocp-healthz.iptables "$IPTABLES_POST/qradar-ocp-healthz"
        chmod 644 "$IPTABLES_POST/qradar-ocp-healthz"
        echo "[OK] iptables drop-in deployed: $IPTABLES_POST/qradar-ocp-healthz" >> "$INSTALL_LOG"
    else
        echo "[WARN] $IPTABLES_POST not found; drop-in not deployed" >> "$INSTALL_LOG"
    fi
    systemctl restart qradar-ocp-healthz.service
    echo "[OK] qradar-ocp-healthz restarted to activate iptables rule" >> "$INSTALL_LOG"

    unmount_iso
    systemctl disable qradar-ocp-installer.service
    echo "Installation service disabled. QRadar is ready!" >> "$INSTALL_LOG"

    {{- if eq .Values.topology "ha" }}
    if systemctl is-enabled qradar-ocp-ha-setup.service >/dev/null 2>&1; then
        echo "[OK] Triggering QRadar HA automated setup service..." >> "$INSTALL_LOG"
        systemctl start --no-block qradar-ocp-ha-setup.service
    fi
    {{- end }}
    exit 0
fi

# Check if kernel update reboot is required
REBOOT_REQUIRED=false
if echo "$LAST_OUTPUT" | grep -q "A reboot is required for changes to take effect"; then
    if echo "$LAST_OUTPUT" | grep -q "The kernel has been updated"; then
        echo "Kernel update detected - reboot required" >> "$INSTALL_LOG"
        REBOOT_REQUIRED=true
    fi
fi

if [ "$REBOOT_REQUIRED" = "true" ]; then
    echo "Rebooting for kernel update..." >> "$INSTALL_LOG"
    sleep 10
    /sbin/reboot
else
    echo "Installer finished but installation not complete. Service will retry on next boot." >> "$INSTALL_LOG"
    systemctl disable qradar-ocp-installer.service
fi
{{- end }}

{{/*
================================================================================
qradar-ocp-installer.service — invariant
================================================================================
*/}}
{{- define "qradar-ha.installerService" -}}
[Unit]
Description=QRadar Software Installer
After=network.target qradar-ocp-network.service
ConditionPathExists=/media/cdrom/setup
ConditionPathExists=!/var/log/qradar-ocp-install-complete

[Service]
Type=oneshot
TimeoutStartSec=0
ExecStartPre=/bin/sleep 30
ExecStartPre=/bin/bash -c 'echo "Starting QRadar installation service: $(date)" >> /var/log/qradar-ocp-init.log'
ExecStart=/usr/local/bin/qradar-ocp-install.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
{{- end }}

{{/*
================================================================================
qradar-ocp-healthz.py — invariant
================================================================================
*/}}
{{- define "qradar-ha.healthzPy" -}}
#!/usr/bin/env python3
"""
QRadar HA readiness endpoint.
Serves GET /healthz -> 200 (active/pre-HA-primary) or 503 (standby/pre-HA-secondary).
Runs as: systemd unit qradar-ocp-healthz.service
"""
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8181

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        return r.returncode, r.stdout.decode().strip()
    except subprocess.TimeoutExpired:
        return 1, ''

INSTALL_SENTINEL = "/var/log/qradar-ocp-install-complete"
HA_CONF = "/opt/qradar/ha/ha.conf"

def tomcat_active():
    rc, _ = run("systemctl is-active tomcat.service")
    return rc == 0

def is_ready():
    # Gate 1: install must be fully complete
    if not os.path.exists(INSTALL_SENTINEL):
        return False
    # Gate 2: pre- vs post-HA Wizard discrimination via ha.conf presence.
    # ha.conf is written by the HA Wizard and is absent pre-Wizard.
    # Avoids calling myver -ha which spawns hostname -f and can hang
    # under load (observed on -49 secondary post-failover).
    if not os.path.exists(HA_CONF):
        # Pre-HA Wizard: tomcat running means primary with UI serving
        return tomcat_active()
    # Post-HA Wizard: node must be active AND tomcat must be serving
    rc, state = run("/opt/qradar/ha/bin/ha stateshow")
    if not (rc == 0 and state.lower().startswith("active")):
        return False
    return tomcat_active()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            ready = is_ready()
            self.send_response(200 if ready else 503)
            self.end_headers()
            self.wfile.write(b"ok\n" if ready else b"standby\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # suppress access log noise

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
{{- end }}

{{/*
================================================================================
qradar-ocp-healthz.iptables — invariant
================================================================================
*/}}
{{- define "qradar-ha.healthzIptables" -}}
# Allow kubelet readiness probe to reach qradar-ocp-healthz on port 8181.
# This file is read by iptables_update.pl every time QChain is rebuilt,
# ensuring the rule survives QRadar iptables updates.
# Staged here (not in /opt/qradar/conf/) to avoid triggering the QRadar
# installer's upgrade detection before QRadar is installed.
# Installed into /opt/qradar/conf/iptables.d/post/ by ExecStartPre below.
-I QChain 1 -m state --state NEW -m tcp -p tcp --dport 8181 -j ACCEPT -m comment --comment "source: qradar-ocp-healthz readiness probe"
{{- end }}

{{/*
================================================================================
qradar-ocp-healthz.service — invariant
================================================================================
*/}}
{{- define "qradar-ha.healthzService" -}}
[Unit]
Description=QRadar HA readiness health endpoint
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c '\
  DEST=/opt/qradar/conf/iptables.d/post/qradar-ocp-healthz; \
  SRC=/usr/local/etc/qradar-ocp-healthz.iptables; \
  if [ -d /opt/qradar/conf/iptables.d/post ] && [ ! -f "$DEST" ]; then \
    cp "$SRC" "$DEST" && chmod 644 "$DEST"; \
  fi; \
  iptables -C QChain -p tcp --dport 8181 -j ACCEPT 2>/dev/null || iptables -I QChain 1 -p tcp --dport 8181 -j ACCEPT 2>/dev/null; \
  true'
ExecStart=/usr/bin/python3 /usr/local/bin/qradar-ocp-healthz.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
{{- end }}

{{/*
================================================================================
no-status-messages.conf — invariant
================================================================================
*/}}
{{- define "qradar-ha.noStatusMessages" -}}
[Manager]
ShowStatus=no
{{- end }}

{{/*
================================================================================
qradar-ocp-ha-setup.sh — PRIMARY VM ONLY
Automated QRadar HA pairing orchestration applying proven qforge logic:
1. Wait for Primary install completion marker
2. Wait for Secondary VM SSH reachable
3. Pre-trust SSH host keys
4. Hardened Console preparation: REST EULA acceptance, wait_for_start.sh,
   REST FULL & INCREMENTAL staged-config deploy, do_deploy.pl, hostcontext & Tomcat readiness
5. Check disk replication capability (disableDiskReplication)
6. Execute /opt/qradar/bin/add_ha_host.sh with correct parameter ordering
7. Await /opt/qradar/ha/ha.conf, Active state on Primary, Standby state on Secondary
================================================================================
*/}}
{{- define "qradar-ha.haSetupSh" -}}
#!/bin/bash
export TERM=xterm-256color
exec > >(tee -a /var/log/qradar-ocp-ha-setup.log /dev/ttyS0) 2>&1

HA_LOG="/var/log/qradar-ocp-ha-setup.log"
INSTALL_MARKER="/var/log/qradar-ocp-install-complete"
COMPLETION_MARKER="/var/log/qradar-ocp-ha-complete"
HA_INITIATED_MARKER="/var/log/qradar-ocp-ha-initiated"
APPS_COMPLETION_MARKER="/var/log/qradar-ocp-apps-complete"

PRIMARY_IP='{{ .Values.network.primaryIp }}'
VIRTUAL_IP='{{ .Values.network.virtualIp }}'
SECONDARY_IP='{{ .Values.network.secondaryIp }}'
ADMIN_USER="admin"
ADMIN_PASS='{{ .Values.qradar.adminPassword }}'
ROOT_PASS='{{ .Values.qradar.rootPassword }}'
SECONDARY_PASS="$ROOT_PASS"

echo "=== QRadar HA Setup Service Started: $(date) ===" >> "$HA_LOG"

{{/* Cluster Status Verification & Convergence Wait */}}
check_ha_cluster_active() {
    if [ ! -x /opt/qradar/ha/bin/ha ]; then
        return 1
    fi
    local st
    local cs
    st=$(/opt/qradar/ha/bin/ha stateshow 2>/dev/null | tr '[:upper:]' '[:lower:]' | xargs || true)
    cs=$(/opt/qradar/ha/bin/ha cstate 2>/dev/null || true)
    
    if [[ "$st" == active* ]]; then
        if echo "$cs" | grep -q "S:ACTIVE" && (echo "$cs" | grep -q "S:STANDBY" || echo "$cs" | grep -q "HBC: ALIVE"); then
            echo "[OK] HA cluster verified healthy:" >> "$HA_LOG"
            echo "     stateshow: $st" >> "$HA_LOG"
            echo "     cstate summary:" >> "$HA_LOG"
            echo "$cs" | head -n 4 >> "$HA_LOG"
            return 0
        fi
    fi
    return 1
}


verify_and_heal_console_ha_registration() {
    echo "=== Verifying Console HA Registration in Database ===" >> "$HA_LOG"
    local check_sql="SELECT m.id, m.primary_host, m.secondary_host, (SELECT count(*) FROM serverhost s WHERE s.managed_host_id = m.id AND s.status != 14) as active_count FROM managedhost m WHERE m.isconsole = true;"
    local out
    out=$(psql -U qradar -t -A -F "|" -c "$check_sql" 2>/dev/null || true)
    echo "Console HA registration check: $out" >> "$HA_LOG"
    local sec_id
    sec_id=$(echo "$out" | cut -d'|' -f3)
    if [ -n "$sec_id" ] && [ "$sec_id" != "" ]; then
        echo "[OK] Console HA database registration verified: secondary_host=$sec_id" >> "$HA_LOG"
        return 0
    fi
    echo "[WARN] Console managedhost secondary_host is NULL. Healing database records..." >> "$HA_LOG"
    python3 - << 'HEAL_EOF' >> "$HA_LOG" 2>&1 || true
import subprocess, sys

def run_cmd(cmd):
    return subprocess.check_output(['/bin/bash', '-c', cmd]).decode().strip()

try:
    pri_ip = run_cmd("grep '^PRIMARY_IP=' /opt/qradar/ha/ha.conf | cut -d= -f2")
    sec_ip = run_cmd("grep '^SECONDARY_IP=' /opt/qradar/ha/ha.conf | cut -d= -f2")
    pri_name = run_cmd("grep '^PRIMARY_NAME=' /opt/qradar/ha/ha.conf | cut -d= -f2")
    sec_name = run_cmd("grep '^SECONDARY_NAME=' /opt/qradar/ha/ha.conf | cut -d= -f2")
    if not pri_ip or not sec_ip:
        print("ha.conf not ready or missing IPs")
        sys.exit(0)
    managed_id = run_cmd("psql -U qradar -t -A -c \"SELECT id FROM managedhost WHERE isconsole = true;\"")
    primary_host = run_cmd(f"psql -U qradar -t -A -c \"SELECT primary_host FROM managedhost WHERE id = {managed_id};\"")
    sec_id = run_cmd(f"psql -U qradar -t -A -c \"SELECT id FROM serverhost WHERE managed_host_id = {managed_id} AND status = 14 ORDER BY id DESC LIMIT 1;\"")
    if not sec_id:
        sec_id = run_cmd(f"psql -U qradar -t -A -c \"SELECT id FROM serverhost WHERE managed_host_id = {managed_id} AND id != {primary_host} LIMIT 1;\"")
    
    print(f"Healing Console HA: managed_host={managed_id}, primary_host={primary_host}, secondary_host={sec_id}")
    sql = f"""
    BEGIN;
    UPDATE serverhost SET ip='{pri_ip}', hostname='{pri_name}', status=0, updatedate=NOW() WHERE id={primary_host};
    """
    if sec_id:
        sql += f"""
        UPDATE serverhost SET ip='{sec_ip}', hostname='{sec_name}', status=5, managementinterface='enp2s0', updatedate=NOW() WHERE id={sec_id};
        UPDATE managedhost SET secondary_host={sec_id}, haoptions='disableReplication=false;enableCrossover=false;heartBeat=10;heartBeatTimeout=30;rate=100', updatedate=NOW() WHERE id={managed_id};
        """
    else:
        sql += f"""
        INSERT INTO serverhost (ip, hostname, status, creationdate, updatedate, qradar_version, managed_host_id, managementinterface)
        VALUES ('{sec_ip}', '{sec_name}', 5, NOW(), NOW(), '7.6.0.0', {managed_id}, 'enp2s0');
        UPDATE managedhost SET secondary_host=(SELECT id FROM serverhost WHERE ip='{sec_ip}'), haoptions='disableReplication=false;enableCrossover=false;heartBeat=10;heartBeatTimeout=30;rate=100', updatedate=NOW() WHERE id={managed_id};
        """
    sql += "COMMIT;"
    run_cmd(f"psql -U qradar -c \"{sql}\"")
    print("SUCCESS: Console HA database records successfully restored!")
except Exception as e:
    print(f"ERROR: {e}")
HEAL_EOF
}


await_ha_cluster_stabilization() {
    echo "=== Step 6: Awaiting HA Cluster Configuration and State Transitions ===" >> "$HA_LOG"
    
    local conf_file="/opt/qradar/ha/ha.conf"
    local conf_found=false
    for ((i=1; i<=30; i++)); do
        if [ -f "$conf_file" ]; then
            echo "[OK] Found $conf_file." >> "$HA_LOG"
            conf_found=true
            break
        fi
        echo "Waiting for $conf_file to appear (try $i/30)..." >> "$HA_LOG"
        sleep 10
    done
    if [ "$conf_found" != "true" ]; then
        echo "[WARN] $conf_file did not appear within expected time." >> "$HA_LOG"
    fi

    echo "Polling /opt/qradar/ha/bin/ha stateshow and cstate (up to 200 attempts, 30s interval = 100 minutes)..." >> "$HA_LOG"
    local max_tries=200
    local cluster_healthy=false
    
    for ((i=1; i<=max_tries; i++)); do
        local st
        local cs
        st=$(/opt/qradar/ha/bin/ha stateshow 2>/dev/null | tr '[:upper:]' '[:lower:]' | xargs || true)
        cs=$(/opt/qradar/ha/bin/ha cstate 2>/dev/null || true)
        
        echo "ha stateshow (attempt $i/$max_tries): '$st'" >> "$HA_LOG"
        if [ -n "$cs" ]; then
            local cs_summary
            cs_summary=$(echo "$cs" | head -n 2 | tr '\n' ' | ')
            echo "ha cstate (attempt $i/$max_tries): $cs_summary" >> "$HA_LOG"
        fi

        if [[ "$st" == active* ]]; then
            if echo "$cs" | grep -q "S:ACTIVE" && (echo "$cs" | grep -q "S:STANDBY" || echo "$cs" | grep -q "HBC: ALIVE"); then
                echo "[OK] Primary HA state is Active: $st" >> "$HA_LOG"
                echo "[OK] HA Cluster state verified via cstate:" >> "$HA_LOG"
                echo "$cs" >> "$HA_LOG"
                cluster_healthy=true
                break
            fi
        elif [[ "$st" == synchronizing* ]] || echo "$cs" | grep -qi "drbd_sync"; then
            echo "DRBD disk synchronization in progress ($st), waiting 30s..." >> "$HA_LOG"
            # Signature K: Check if DRBD block replication is already complete
            local drbd_out
            drbd_out=$(drbdadm status store 2>/dev/null || cat /proc/drbd 2>/dev/null || true)
            if echo "$drbd_out" | grep -qi "peer-disk:uptodate\|ds:uptodate/uptodate" && ! echo "$drbd_out" | grep -qi "syncsource\|synctarget\|sync'ed:\|done:"; then
                echo "[HA] DRBD disk replication is 100% UpToDate on Primary, checking for Secondary .remote_ha_install latch..." >> "$HA_LOG"
                rm -f /opt/qradar/ha/.local_ha_failed /opt/qradar/ha/.finalize_remote_install 2>/dev/null || true
                sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "rm -f /opt/qradar/ha/.remote_ha_install /opt/qradar/ha/.local_ha_failed 2>/dev/null; /opt/qradar/ha/bin/ha_reload.sh" >> "$HA_LOG" 2>&1 || true
            fi
        fi
        
        sleep 30
    done
    
    if [ "$cluster_healthy" = "true" ]; then
        echo "[OK] HA cluster stabilized successfully." >> "$HA_LOG"
        verify_and_heal_console_ha_registration
        return 0
    else
        echo "[ERROR] HA cluster did not achieve healthy Active/Standby status within $max_tries attempts." >> "$HA_LOG"
        return 1
    fi
}

install_preload_apps() {
    echo "=== Step 7: Post-HA Installing Out-Of-The-Box Apps ===" >> "$HA_LOG"

    # Signature M: Clear Podman cached boot ID mismatch if present
    if [ -f /store/docker-data/engine/libpod/alive ] && [ -f /proc/sys/kernel/random/boot_id ]; then
        cat /proc/sys/kernel/random/boot_id > /store/docker-data/engine/libpod/alive 2>/dev/null || true
    fi

    # Ensure dual-stack loopback resolution in /etc/hosts for Traefik and local services
    for loopback_ip in "127.0.0.1" "::1"; do
        for alias in "console.qradar.lab" "console" "console-primary.qradar.lab" "console-primary" "console.localdeployment"; do
            if ! grep -E "^[[:space:]]*${loopback_ip}[[:space:]]" /etc/hosts | grep -qw "$alias"; then
                echo "Adding $alias to $loopback_ip in /etc/hosts..." >> "$HA_LOG"
                sed -i "/^[[:space:]]*${loopback_ip}/ s/$/ $alias/" /etc/hosts
            fi
        done
    done

    # Ensure Local Registry CA Certificate exists
    local ca_cert="/etc/containers/certs.d/console.localdeployment:5000/docker-distribution_ca.crt"
    if [ ! -s "$ca_cert" ]; then
        echo "Triggering CA monitor to generate registry client certificates..." >> "$HA_LOG"
        /opt/qradar/ca/bin/si-qradarca monitor -debug >> "$HA_LOG" 2>&1 || true
        for ((i=1; i<=15; i++)); do
            [ -s "$ca_cert" ] && break
            sleep 2
        done
    fi
    if [ -s "$ca_cert" ]; then
        mkdir -p /etc/docker/certs.d/console.localdeployment:5000 2>/dev/null || true
        cp -u "$ca_cert" /etc/docker/certs.d/console.localdeployment:5000/ 2>/dev/null || true
    fi

    # Deliver base container images into local registry
    if [ -x /store/docker-data/images/deliver.sh ]; then
        echo "Delivering base container images into local registry..." >> "$HA_LOG"
        /store/docker-data/images/deliver.sh push >> "$HA_LOG" 2>&1 || true
    fi

    # Clean up cancelled application records and stage preload packages
    psql -U qradar -d qradar -c "DELETE FROM installed_application_instance WHERE task_status='CANCELLED' OR (status='ERROR' AND task_id IS NULL); DELETE FROM installed_application WHERE status='CANCELLED';" >> "$HA_LOG" 2>&1 || true
    mkdir -p /store/cmt/staged-packages /store/cmt/preload_content
    if [ -d /store/cmt/exports ]; then
        echo "Staging preload content packages from /store/cmt/exports..." >> "$HA_LOG"
        cp -fv /store/cmt/exports/*extension*.zip /store/cmt/exports/*signed*.zip /store/cmt/exports/logsourcemanagement*.zip /store/cmt/preload_content/ 2>/dev/null || true
        cp -u /store/cmt/exports/*.zip /store/cmt/staged-packages/ 2>/dev/null || true
    fi
    rm -f /store/cmt/CountFile*.txt

    # Cache LocalCA keystores once
    if [ ! -f /var/log/qradar-ocp-keystores-synced ]; then
        echo "Restarting tomcat and hostcontext to cache LocalCA keystores..." >> "$HA_LOG"
        systemctl restart hostcontext tomcat 2>/dev/null || true
        touch /var/log/qradar-ocp-keystores-synced
    fi

    # Wait for Tomcat and hostcontext 300s uptime
    echo "Waiting for Tomcat and hostcontext 300s uptime..." >> "$HA_LOG"
    for ((i=1; i<=60; i++)); do
        local tc_pid
        local hc_pid
        tc_pid=$(systemctl show -p MainPID --value tomcat 2>/dev/null || true)
        [ -z "$tc_pid" ] || [ "$tc_pid" = "0" ] && tc_pid=$(pgrep -f "org.apache.catalina.startup.Bootstrap" 2>/dev/null | head -1 || true)
        hc_pid=$(systemctl show -p MainPID --value hostcontext 2>/dev/null || true)
        [ -z "$hc_pid" ] || [ "$hc_pid" = "0" ] && hc_pid=$(pgrep -f "com.q1labs.hostcontext" 2>/dev/null | head -1 || true)
        local tc_up=0
        local hc_up=0
        [ -n "$tc_pid" ] && [ "$tc_pid" -gt 0 ] 2>/dev/null && tc_up=$(ps -o etimes= -p "$tc_pid" 2>/dev/null | xargs || echo 0)
        [ -n "$hc_pid" ] && [ "$hc_pid" -gt 0 ] 2>/dev/null && hc_up=$(ps -o etimes= -p "$hc_pid" 2>/dev/null | xargs || echo 0)
        local tomcat_conn=false
        if [ -x /opt/qradar/bin/test_tomcat_connection.sh ] && /opt/qradar/bin/test_tomcat_connection.sh >/dev/null 2>&1; then
            tomcat_conn=true
        elif systemctl is-active --quiet tomcat 2>/dev/null; then
            tomcat_conn=true
        fi
        if [ "${tc_up:-0}" -ge 300 ] && [ "${hc_up:-0}" -ge 300 ] && [ "$tomcat_conn" = "true" ]; then
            echo "[OK] Tomcat (uptime: ${tc_up}s) and hostcontext (uptime: ${hc_up}s) ready." >> "$HA_LOG"
            break
        fi
        echo "Waiting for 300s uptime (Tomcat: ${tc_up:-0}s, hostcontext: ${hc_up:-0}s) [attempt $i/60]..." >> "$HA_LOG"
        sleep 10
    done

    # Trigger preload content installation
    if ls /store/cmt/preload_content/*.zip >/dev/null 2>&1; then
        echo "Triggering QRadar preload content installation..." >> "$HA_LOG"
        if ! pgrep -f "install_preload_content.pl" >/dev/null 2>&1; then
            /opt/qradar/bin/install_preload_content.pl >> /var/log/install_preload_content_cron.log 2>&1 &
        fi
        echo "Waiting for preload apps to finish installing..." >> "$HA_LOG"
        for ((i=1; i<=120; i++)); do
            if [ -f /store/docker-data/engine/libpod/alive ] && [ -f /proc/sys/kernel/random/boot_id ]; then
                cat /proc/sys/kernel/random/boot_id > /store/docker-data/engine/libpod/alive 2>/dev/null || true
            fi
            local remaining_pkgs
            remaining_pkgs=$(ls -1 /store/cmt/preload_content/*.zip 2>/dev/null | wc -l || echo 0)
            local running_proc=false
            pgrep -f "install_preload_content.pl" >/dev/null 2>&1 && running_proc=true
            local running_instances
            running_instances=$(psql -U qradar -d qradar -t -A -c "SELECT count(*) FROM installed_application_instance WHERE status='RUNNING';" 2>/dev/null || echo 0)
            local running_containers=0
            if command -v podman >/dev/null 2>&1; then
                running_containers=$(podman ps --filter name=qapp --filter status=running -q 2>/dev/null | wc -l || echo 0)
            fi
            if [ "$running_proc" = "false" ]; then
                if [ "$remaining_pkgs" -eq 0 ] || [ "$running_containers" -ge 6 ] || [ "$running_instances" -ge 6 ]; then
                    echo "[OK] Preload content installation complete (instances: $running_instances, containers: $running_containers)!" >> "$HA_LOG"
                    break
                fi
            fi
            if [ "$running_proc" = "false" ] && [ "$remaining_pkgs" -gt 0 ] && [ "$running_containers" -lt 6 ] && [ "$running_instances" -lt 6 ] && [ $((i % 8)) -eq 0 ]; then
                echo "Attempting re-trigger of install_preload_content.pl ($remaining_pkgs packages remaining)..." >> "$HA_LOG"
                rm -f /store/cmt/CountFile*.txt
                cp -fv /store/cmt/exports/*extension*.zip /store/cmt/exports/*signed*.zip /store/cmt/exports/logsourcemanagement*.zip /store/cmt/preload_content/ 2>/dev/null || true
                /opt/qradar/bin/install_preload_content.pl >> /var/log/install_preload_content_cron.log 2>&1 &
            fi
            sleep 15
        done
    fi

    # Background process drain loop
    echo "Waiting for background deployment tasks to settle..." >> "$HA_LOG"
    for ((attempt=1; attempt<=60; attempt++)); do
        local bg_procs
        bg_procs=$(ps -eo comm,args 2>/dev/null | grep -Ei "(install_preload_content\.pl|qradar_setup|qradar_netsetup|setup_qradar_host\.py|do_deploy\.pl|deploy_changes|/media/cdrom/setup|qradar_launcher)" | grep -v grep | head -10 || true)
        if [ -z "$bg_procs" ]; then
            echo "[OK] All background deployment tasks complete." >> "$HA_LOG"
            break
        fi
        sleep 10
    done

    # Self-heal any ERROR app instances
    local error_instances
    error_instances=$(psql -U qradar -d qradar -t -A -c "SELECT id FROM installed_application_instance WHERE status='ERROR' OR task_status='ERROR';" 2>/dev/null || true)
    if [ -n "$error_instances" ]; then
        echo "Found app instances in ERROR state: $error_instances. Restarting..." >> "$HA_LOG"
        for inst_id in $error_instances; do
            printf "23\n%s\n0\n" "$inst_id" | /opt/qradar/support/qappmanager >/dev/null 2>&1 || true
        done
    fi
    if command -v podman >/dev/null 2>&1; then
        local exited
        exited=$(podman ps -a --filter name=qapp --filter status=exited -q 2>/dev/null || true)
        if [ -n "$exited" ]; then
            echo "Restarting exited containers: $exited" >> "$HA_LOG"
            podman restart $exited >> "$HA_LOG" 2>&1 || true
        fi
    fi

    echo "=== Preload Apps Installation Complete at $(date) ===" >> "$HA_LOG"
    touch "$APPS_COMPLETION_MARKER"
}

{{/* Early Checks: Completion, Existing Active Cluster, or Post-Reboot Continuation */}}
if [ -f "$COMPLETION_MARKER" ]; then
    echo "[OK] HA setup already marked complete ($COMPLETION_MARKER exists). Exiting." >> "$HA_LOG"
    systemctl disable qradar-ocp-ha-setup.service 2>/dev/null || true
    exit 0
fi

if check_ha_cluster_active; then
    if [ -f "$APPS_COMPLETION_MARKER" ]; then
        echo "[OK] HA cluster is already active and healthy and apps are complete! Marking complete and exiting." >> "$HA_LOG"
        touch "$COMPLETION_MARKER"
        systemctl disable qradar-ocp-ha-setup.service 2>/dev/null || true
        exit 0
    else
        echo "[INFO] HA cluster is already active and healthy. Proceeding to preload apps..." >> "$HA_LOG"
        install_preload_apps
        touch "$COMPLETION_MARKER"
        systemctl disable qradar-ocp-ha-setup.service 2>/dev/null || true
        exit 0
    fi
fi

if [ -f "/opt/qradar/ha/ha.conf" ] || ([ -f "$HA_INITIATED_MARKER" ] && /opt/qradar/ha/bin/ha stateshow 2>/dev/null | grep -qiE "active|standby|synchronizing|primary"); then
    echo "[INFO] HA pairing was previously initiated (ha.conf or active stateshow found)." >> "$HA_LOG"
    echo "[INFO] Post-reboot continuation detected. Skipping pre-pairing steps and waiting for cluster convergence..." >> "$HA_LOG"
    if await_ha_cluster_stabilization; then
        install_preload_apps
        touch "$COMPLETION_MARKER"
        systemctl disable qradar-ocp-ha-setup.service 2>/dev/null || true
        exit 0
    else
        exit 1
    fi
fi

echo "Waiting for Primary QRadar installation marker ($INSTALL_MARKER)..." >> "$HA_LOG"
while [ ! -f "$INSTALL_MARKER" ]; do
    sleep 15
done
echo "[OK] Primary QRadar installation completed." >> "$HA_LOG"

{{/* Step 0: Await Console Post-Install Readiness */}}
echo "=== Step 0: Waiting for Console Background Activity to Settle ===" >> "$HA_LOG"

MAX_BG_WAIT=120
for ((attempt=1; attempt<=MAX_BG_WAIT; attempt++)); do
    BG_PROCS=$(ps -eo comm,args 2>/dev/null | grep -Ei "(qradar_setup|qradar_netsetup|setup_qradar_host\.py|/media/cdrom/setup|qradar_launcher)" | grep -v grep | head -10 || true)
    if [ -z "$BG_PROCS" ] && systemctl is-active --quiet hostcontext 2>/dev/null && [ -s /opt/qradar/conf/host.token ]; then
        if [ -x /opt/qradar/bin/test_tomcat_connection.sh ] && /opt/qradar/bin/test_tomcat_connection.sh >/dev/null 2>&1; then
            echo "[OK] Console post-install readiness confirmed." >> "$HA_LOG"
            break
        fi
    fi
    sleep 15
done

{{/* Step 1: Wait for Secondary VM SSH port */}}
echo "Waiting for Secondary VM SSH at $SECONDARY_IP:22..." >> "$HA_LOG"
MAX_SEC_WAIT=120
SEC_READY=false
for ((i=1; i<=MAX_SEC_WAIT; i++)); do
    if nc -z -w 3 "$SECONDARY_IP" 22 2>/dev/null; then
        echo "[OK] Secondary VM SSH is reachable (attempt $i/$MAX_SEC_WAIT)." >> "$HA_LOG"
        SEC_READY=true
        break
    fi
    echo "Secondary SSH not ready yet (attempt $i/$MAX_SEC_WAIT), sleeping 15s..." >> "$HA_LOG"
    sleep 15
done

if [ "$SEC_READY" != "true" ]; then
    echo "[ERROR] Secondary VM SSH never became reachable. Aborting HA setup." >> "$HA_LOG"
    exit 1
fi

{{/* Step 2: Ensure SSH known_hosts contains Secondary key */}}
echo "Scanning Secondary SSH host keys..." >> "$HA_LOG"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
ssh-keygen -R "$SECONDARY_IP" >/dev/null 2>&1 || true
for ((i=1; i<=5; i++)); do
    ssh-keyscan -T 5 -t ecdsa,rsa,ed25519 -H "$SECONDARY_IP" >> /root/.ssh/known_hosts 2>>"$HA_LOG" || true
    if ssh-keygen -F "$SECONDARY_IP" >/dev/null 2>&1; then
        echo "[OK] Secondary SSH key present in known_hosts." >> "$HA_LOG"
        break
    fi
    sleep 3
done
sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts

{{/* Step 3: Hardened Console Preparation on Primary */}}
echo "=== Step 3: Console Preparation (EULA & Staged Config Deploy) ===" >> "$HA_LOG"

echo "Checking / Accepting QRadar EULA via REST API..." >> "$HA_LOG"
curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Version: 10.1" \
    -H "Accept: application/json" \
    "https://127.0.0.1/api/system/eulas" >/dev/null 2>&1 || true

EULA_POST_OUT=$(curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Version: 10.1" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"accepted_eula": true}' \
    "https://127.0.0.1/api/system/eula_acceptances/1" 2>&1 || true)
echo "EULA acceptance response: $EULA_POST_OUT" >> "$HA_LOG"
sleep 5

WAIT_FOR_START="/opt/qradar/upgrade/util/setup/upgrades/wait_for_start.sh"
[ ! -f "$WAIT_FOR_START" ] && WAIT_FOR_START="/opt/qradar/bin/wait_for_start.sh"
if [ -f "$WAIT_FOR_START" ]; then
    echo "Running wait_for_start.sh..." >> "$HA_LOG"
    bash "$WAIT_FOR_START" >> "$HA_LOG" 2>&1 || true
fi

DEPLOY_URL="https://127.0.0.1/api/staged_config/deploy_status"
echo "Triggering REST API FULL deployment..." >> "$HA_LOG"
for eula_retry in 1 2 3; do
    FULL_RESP=$(curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -H "Version: 10.1" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -X POST \
        -d '{"type": "FULL"}' \
        "$DEPLOY_URL" 2>&1 || true)
    echo "FULL deploy trigger response: $FULL_RESP" >> "$HA_LOG"
    if echo "$FULL_RESP" | grep -q '"code":44'; then
        echo "EULA not accepted error encountered, re-accepting EULA..." >> "$HA_LOG"
        curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" -H "Version: 10.1" -H "Content-Type: application/json" -X POST -d '{"accepted_eula": true}' "https://127.0.0.1/api/system/eula_acceptances/1" >/dev/null 2>&1 || true
        sleep 5
    else
        break
    fi
done

for ((p=1; p<=40; p++)); do
    ST_OUT=$(curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" -H "Version: 10.1" -H "Accept: application/json" "$DEPLOY_URL" 2>/dev/null || true)
    echo "FULL deploy poll $p/40: $ST_OUT" >> "$HA_LOG"
    if echo "$ST_OUT" | grep -q '"status":"COMPLETE"'; then
        echo "[OK] FULL deploy status: COMPLETE" >> "$HA_LOG"
        break
    fi
    sleep 15
done

echo "Triggering REST API INCREMENTAL deployment..." >> "$HA_LOG"
INC_RESP=$(curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Version: 10.1" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"type": "INCREMENTAL"}' \
    "$DEPLOY_URL" 2>&1 || true)
echo "INCREMENTAL deploy trigger response: $INC_RESP" >> "$HA_LOG"

for ((p=1; p<=40; p++)); do
    ST_OUT=$(curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" -H "Version: 10.1" -H "Accept: application/json" "$DEPLOY_URL" 2>/dev/null || true)
    echo "INCREMENTAL deploy poll $p/40: $ST_OUT" >> "$HA_LOG"
    if echo "$ST_OUT" | grep -q '"status":"COMPLETE"'; then
        echo "[OK] INCREMENTAL deploy status: COMPLETE" >> "$HA_LOG"
        break
    fi
    sleep 15
done

# Wait for any in-flight deployment or staged config lock to clear before running do_deploy.pl
echo "Waiting for any in-flight deployments to settle before do_deploy.pl..." >> "$HA_LOG"
for ((w=1; w<=30; w++)); do
    CUR_STATUS=$(curl -sk -u "${ADMIN_USER}:${ADMIN_PASS}" -H "Version: 10.1" -H "Accept: application/json" "$DEPLOY_URL" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -z "$CUR_STATUS" ] || [ "$CUR_STATUS" = "COMPLETE" ] || [ "$CUR_STATUS" = "SUCCESS" ]; then
        break
    fi
    echo "Deployment in progress (status='$CUR_STATUS'), waiting 10s (attempt $w/30)..." >> "$HA_LOG"
    sleep 10
done
sleep 15

DO_DEPLOY="/opt/qradar/upgrade/util/setup/upgrades/do_deploy.pl"
[ ! -f "$DO_DEPLOY" ] && DO_DEPLOY="/opt/qradar/bin/do_deploy.pl"
if [ -f "$DO_DEPLOY" ]; then
    echo "Executing do_deploy.pl..." >> "$HA_LOG"
    for ((attempt=1; attempt<=5; attempt++)); do
        echo "do_deploy.pl attempt $attempt/5..." >> "$HA_LOG"
        if perl "$DO_DEPLOY" >> "$HA_LOG" 2>&1; then
            echo "[OK] do_deploy.pl succeeded." >> "$HA_LOG"
            break
        fi
        sleep 20
    done
fi

# Purge any deployment requirement markers generated if do_deploy.pl hit a transient status lock
rm -f /opt/qradar/conf/*DeployRequired.txt /tmp/restoringBackupSync.txt /tmp/addhost.txt 2>/dev/null || true

echo "Polling hostcontext readiness..." >> "$HA_LOG"
for ((attempt=1; attempt<=60; attempt++)); do
    if systemctl is-active --quiet hostcontext; then
        echo "[OK] hostcontext is active." >> "$HA_LOG"
        break
    fi
    sleep 10
done

echo "Polling Tomcat readiness..." >> "$HA_LOG"
for ((attempt=1; attempt<=60; attempt++)); do
    if [ -x /opt/qradar/bin/test_tomcat_connection.sh ]; then
        if /opt/qradar/bin/test_tomcat_connection.sh >> "$HA_LOG" 2>&1; then
            echo "[OK] Tomcat is accepting connections." >> "$HA_LOG"
            break
        fi
    else
        break
    fi
    sleep 10
done

echo "Waiting for Primary host ($PRIMARY_IP) to be Active in managedhost table..." >> "$HA_LOG"
for ((attempt=1; attempt<=30; attempt++)); do
    DB_STATUS=$(psql -U qradar -t -c "SELECT status FROM managedhost WHERE ip='${PRIMARY_IP}';" 2>/dev/null | tr -d '[:space:]' || true)
    echo "managedhost status for $PRIMARY_IP: '$DB_STATUS' (attempt $attempt/30)" >> "$HA_LOG"
    if [ "$DB_STATUS" = "Active" ]; then
        echo "[OK] Primary host confirmed Active in database." >> "$HA_LOG"
        break
    fi
    sleep 10
done

if [ -f /media/cdrom/post/prepare_ha.sh ]; then
    echo "Running /media/cdrom/post/prepare_ha.sh on primary..." >> "$HA_LOG"
    bash /media/cdrom/post/prepare_ha.sh >> "$HA_LOG" 2>&1 || true
fi

echo "[OK] Primary console preparation complete." >> "$HA_LOG"

{{/* Step 4: Pre-HA Sanitization & Hardening */}}
echo "=== Step 4: Pre-HA Sanitization & Hardening ===" >> "$HA_LOG"

# Signature I: Release private mount namespace locks on /store (jitterentropy)
echo "Releasing private mount namespace locks on Primary and Secondary (jitterentropy)..." >> "$HA_LOG"
systemctl restart jitterentropy-rngd jitterentropy 2>/dev/null || true
sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "systemctl restart jitterentropy-rngd jitterentropy 2>/dev/null || true" >> "$HA_LOG" 2>&1 || true

# Signatures G, J: Purge stale HA failure or install tokens
echo "Cleaning any stale HA failure tokens..." >> "$HA_LOG"
rm -f /opt/qradar/ha/.local_ha_failed /opt/qradar/ha/.remote_ha_install /opt/qradar/ha/.finalize_remote_install 2>/dev/null || true
sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "rm -f /opt/qradar/ha/.local_ha_failed /opt/qradar/ha/.remote_ha_install /opt/qradar/ha/.finalize_remote_install 2>/dev/null || true" >> "$HA_LOG" 2>&1 || true

# IBM Defect 169575: Purge stale deployment requirement markers
# If upgradeDeployRequired.txt exists on disk, ha_setup.sh fails precheck with rc=136 (undeployed_changes_error)
echo "Purging stale deployment requirement markers (IBM Defect 169575)..." >> "$HA_LOG"
rm -f /opt/qradar/conf/*DeployRequired.txt /tmp/restoringBackupSync.txt /tmp/addhost.txt 2>/dev/null || true
sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "rm -f /opt/qradar/conf/*DeployRequired.txt /tmp/restoringBackupSync.txt /tmp/addhost.txt 2>/dev/null || true" >> "$HA_LOG" 2>&1 || true

# Sanitize iptables dropins to prevent reload failures during ha_setup.sh
echo "Sanitizing iptables dropins..." >> "$HA_LOG"
rm -f /opt/qradar/conf/iptables.d/nat.post/podman.* /opt/qradar/conf/iptables.d/*.bak /opt/qradar/conf/iptables.d/*/*.bak 2>/dev/null || true
if [ -x /opt/qradar/bin/iptables_update.pl ]; then
    /opt/qradar/bin/iptables_update.pl >> "$HA_LOG" 2>&1 || true
fi
sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "rm -f /opt/qradar/conf/iptables.d/nat.post/podman.* /opt/qradar/conf/iptables.d/*.bak /opt/qradar/conf/iptables.d/*/*.bak 2>/dev/null || true; [ -x /opt/qradar/bin/iptables_update.pl ] && /opt/qradar/bin/iptables_update.pl >/dev/null 2>&1 || true" >> "$HA_LOG" 2>&1 || true

# Sanitize /etc/hosts on Primary and Secondary: strip pod-network and link-local entries, ensure clean mapping
echo "Sanitizing /etc/hosts on Primary and Secondary..." >> "$HA_LOG"
sed -i -E '/^10\.(12[89]|13[01])\./d' /etc/hosts /etc/hosts.default 2>/dev/null || true
sed -i -E '/^fe80::/d' /etc/hosts /etc/hosts.default 2>/dev/null || true
sed -i "/^10\.0\.0\.1[[:space:]]/d" /etc/hosts /etc/hosts.default 2>/dev/null || true
sed -i "/^10\.0\.0\.11[[:space:]]/d" /etc/hosts /etc/hosts.default 2>/dev/null || true
echo "10.0.0.1     console-primary.qradar.lab console-primary" >> /etc/hosts
echo "10.0.0.11    standby.qradar.lab standby console-secondary.qradar.lab console-secondary" >> /etc/hosts

sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" '
    sed -i -E "/^10\.(12[89]|13[01])\./d" /etc/hosts /etc/hosts.default 2>/dev/null || true
    sed -i -E "/^fe80::/d" /etc/hosts /etc/hosts.default 2>/dev/null || true
    sed -i "/^10\.0\.0\.1[[:space:]]/d" /etc/hosts /etc/hosts.default 2>/dev/null || true
    sed -i "/^10\.0\.0\.10[[:space:]]/d" /etc/hosts /etc/hosts.default 2>/dev/null || true
    sed -i "/^10\.0\.0\.11[[:space:]]/d" /etc/hosts /etc/hosts.default 2>/dev/null || true
    echo "10.0.0.10    console.qradar.lab console" >> /etc/hosts
    echo "10.0.0.1     console-primary.qradar.lab console-primary" >> /etc/hosts
    echo "10.0.0.11    standby.qradar.lab standby console-secondary.qradar.lab console-secondary" >> /etc/hosts
    for lb in "127.0.0.1" "::1"; do
        grep -q "console-secondary" /etc/hosts || sed -i "/^[[:space:]]*${lb}[[:space:]]/ s/$/ console-secondary.qradar.lab console-secondary/" /etc/hosts
    done
' >> "$HA_LOG" 2>&1 || true

# Signature L: Bidirectional SSH key trust (Secondary -> Primary and Primary -> Secondary)
echo "Ensuring bidirectional SSH key trust..." >> "$HA_LOG"
cat /root/.ssh/id_rsa.pub | sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys" >> "$HA_LOG" 2>&1 || true
sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "cat /root/.ssh/id_rsa.pub" >> /root/.ssh/authorized_keys 2>>"$HA_LOG" || true
chmod 600 /root/.ssh/authorized_keys
sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys

# Ensure podman containers are stopped and removed so /store can be cleanly unmounted by DRBD
echo "Stopping any lingering podman containers..." >> "$HA_LOG"
if command -v podman >/dev/null 2>&1; then
    systemctl stop podman 2>/dev/null || true
    podman stop -a -t 2 2>/dev/null || true
    podman rm -a -f 2>/dev/null || true
fi

# Clean any stale secondary host registrations from PostgreSQL
echo "Sanitizing QRadar database for fresh HA pairing..." >> "$HA_LOG"
psql -U qradar -c "
    BEGIN;
    DELETE FROM license_pool_allocation WHERE host_id IN (
        SELECT id FROM serverhost WHERE (managed_host_id IN (SELECT id FROM managedhost WHERE isconsole = true) AND ip != '$PRIMARY_IP') OR hostname LIKE 'Deleted-%' OR ip LIKE 'Deleted-%'
    );
    DELETE FROM license_key WHERE host_id IN (
        SELECT id FROM serverhost WHERE (managed_host_id IN (SELECT id FROM managedhost WHERE isconsole = true) AND ip != '$PRIMARY_IP') OR hostname LIKE 'Deleted-%' OR ip LIKE 'Deleted-%'
    );
    DELETE FROM serverhost WHERE (managed_host_id IN (SELECT id FROM managedhost WHERE isconsole = true) AND ip != '$PRIMARY_IP') OR hostname LIKE 'Deleted-%' OR ip LIKE 'Deleted-%';
    UPDATE managedhost SET secondary_host = NULL WHERE isconsole = true;
    COMMIT;
" >> "$HA_LOG" 2>&1 || true

{{/* Step 5: Check Disk Replication Capability */}}
DISABLE_REP_FLAG=""
CAP_FILE="/opt/qradar/conf/capabilities/hostcapabilities.xml"
if [ -f "$CAP_FILE" ]; then
    if grep -q "disableDiskReplication" "$CAP_FILE" 2>/dev/null; then
        VAL=$(grep "disableDiskReplication" "$CAP_FILE" | awk -F'=' '{print $2}' | tr -d '"' | tr -d '[:space:]')
        if [ "$VAL" = "true" ]; then
            DISABLE_REP_FLAG="-disable_replication true"
            echo "Disk replication disabled in hostcapabilities.xml — passing $DISABLE_REP_FLAG" >> "$HA_LOG"
        fi
    fi
fi

{{/* Step 6: Execute HA Pairing via add_ha_host.sh */}}
echo "=== Step 6: Initiating HA Pairing (add_ha_host.sh) ===" >> "$HA_LOG"
PAIRING_BIN="/opt/qradar/bin/add_ha_host.sh"
PAIRING_SUCCESS=false
MAX_PAIR_ATTEMPTS=15
PAIR_RETRY_SLEEP=60

# Ensure clean marker state before pairing attempts
rm -f "$HA_INITIATED_MARKER" 2>/dev/null || true

for ((attempt=1; attempt<=MAX_PAIR_ATTEMPTS; attempt++)); do
    echo "Attempt $attempt/$MAX_PAIR_ATTEMPTS: Running add_ha_host.sh..." >> "$HA_LOG"
    
    CURRENT_STATE=$(/opt/qradar/ha/bin/ha stateshow 2>/dev/null | tr '[:upper:]' '[:lower:]' | xargs || true)
    if [[ "$CURRENT_STATE" == active* ]]; then
        echo "[OK] HA stateshow is already active ($CURRENT_STATE)." >> "$HA_LOG"
        PAIRING_SUCCESS=true
        touch "$HA_INITIATED_MARKER"
        break
    fi

    "$PAIRING_BIN" \
        -enable_crossover false \
        -host_ip "$PRIMARY_IP" \
        -virtual_ip "$VIRTUAL_IP" \
        -secondary_ip "$SECONDARY_IP" \
        -secondary_pass "$SECONDARY_PASS" \
        $DISABLE_REP_FLAG >> "$HA_LOG" 2>&1
    PAIR_RC=$?

    if [ $PAIR_RC -eq 0 ]; then
        echo "[OK] add_ha_host.sh executed successfully." >> "$HA_LOG"
        PAIRING_SUCCESS=true
        touch "$HA_INITIATED_MARKER"
        break
    else
        # In case add_ha_host returned non-zero but HA was initiated
        CURRENT_STATE=$(/opt/qradar/ha/bin/ha stateshow 2>/dev/null | tr '[:upper:]' '[:lower:]' | xargs || true)
        if [[ "$CURRENT_STATE" == active* ]] || [[ "$CURRENT_STATE" == synchronizing* ]]; then
            echo "[OK] add_ha_host.sh non-zero ($PAIR_RC) but HA state is '$CURRENT_STATE' — treating as initiated." >> "$HA_LOG"
            PAIRING_SUCCESS=true
            touch "$HA_INITIATED_MARKER"
            break
        fi
        echo "[WARN] Pairing attempt $attempt/$MAX_PAIR_ATTEMPTS failed (rc=$PAIR_RC). Retrying in ${PAIR_RETRY_SLEEP}s..." >> "$HA_LOG"

        # Inter-retry healing: clean any stale failure tokens, markers, and database rows created by failed pre-checks
        rm -f /opt/qradar/ha/.local_ha_failed /opt/qradar/ha/.remote_ha_install /opt/qradar/ha/.finalize_remote_install 2>/dev/null || true
        rm -f /opt/qradar/conf/*DeployRequired.txt /tmp/restoringBackupSync.txt /tmp/addhost.txt 2>/dev/null || true
        sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "rm -f /opt/qradar/ha/.local_ha_failed /opt/qradar/ha/.remote_ha_install /opt/qradar/ha/.finalize_remote_install /opt/qradar/conf/*DeployRequired.txt /tmp/restoringBackupSync.txt /tmp/addhost.txt 2>/dev/null || true" >> "$HA_LOG" 2>&1 || true

        # Re-ensure mutual SSH trust (QRadar BaseHostExecutor removes secondary authorized_keys on pre-check failure)
        cat /root/.ssh/id_rsa.pub | sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "mkdir -p /root/.ssh && cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys" >> "$HA_LOG" 2>&1 || true
        sshpass -p "$SECONDARY_PASS" ssh -o StrictHostKeyChecking=no "$SECONDARY_IP" "cat /root/.ssh/id_rsa.pub" >> /root/.ssh/authorized_keys 2>>"$HA_LOG" || true
        chmod 600 /root/.ssh/authorized_keys
        sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys

        # Clean any soft-deleted secondary host records from PostgreSQL
        psql -U qradar -c "
            BEGIN;
            DELETE FROM license_pool_allocation WHERE host_id IN (
                SELECT id FROM serverhost WHERE (managed_host_id IN (SELECT id FROM managedhost WHERE isconsole = true) AND ip != '$PRIMARY_IP') OR hostname LIKE 'Deleted-%' OR ip LIKE 'Deleted-%'
            );
            DELETE FROM license_key WHERE host_id IN (
                SELECT id FROM serverhost WHERE (managed_host_id IN (SELECT id FROM managedhost WHERE isconsole = true) AND ip != '$PRIMARY_IP') OR hostname LIKE 'Deleted-%' OR ip LIKE 'Deleted-%'
            );
            DELETE FROM serverhost WHERE (managed_host_id IN (SELECT id FROM managedhost WHERE isconsole = true) AND ip != '$PRIMARY_IP') OR hostname LIKE 'Deleted-%' OR ip LIKE 'Deleted-%';
            UPDATE managedhost SET secondary_host = NULL WHERE isconsole = true;
            COMMIT;
        " >> "$HA_LOG" 2>&1 || true

        sleep "$PAIR_RETRY_SLEEP"
    fi
done

if [ "$PAIRING_SUCCESS" != "true" ]; then
    rm -f "$HA_INITIATED_MARKER" 2>/dev/null || true
    echo "[ERROR] Failed to initiate HA pairing after $MAX_PAIR_ATTEMPTS attempts." >> "$HA_LOG"
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 6: Await HA Cluster Stabilization
# -----------------------------------------------------------------------------
if ! await_ha_cluster_stabilization; then
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 7: Post-HA Install Out-Of-The-Box Apps
# -----------------------------------------------------------------------------
install_preload_apps

echo "[DONE] QRadar HA Automated Setup Complete at $(date)!" >> "$HA_LOG"
touch "$COMPLETION_MARKER"
systemctl disable qradar-ocp-ha-setup.service 2>/dev/null || true
exit 0
{{- end }}

{{/*
================================================================================
qradar-ocp-ha-setup.service — PRIMARY VM ONLY
================================================================================
*/}}
{{- define "qradar-ha.haSetupService" -}}
[Unit]
Description=QRadar HA Automated Pairing Service
After=network.target qradar-ocp-network.service
ConditionPathExists=/var/log/qradar-ocp-install-complete
ConditionPathExists=!/var/log/qradar-ocp-ha-complete

[Service]
Type=simple
TimeoutStartSec=0
ExecStart=/usr/local/bin/qradar-ocp-ha-setup.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
{{- end }}

