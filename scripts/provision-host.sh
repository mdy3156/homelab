#!/usr/bin/env bash
# Run once as: sudo bash /home/mdy/homelab/scripts/provision-host.sh
set -Eeuo pipefail
umask 027

[[ $EUID -eq 0 ]] || { echo 'Run this script using sudo.' >&2; exit 1; }
target_user=mdy
id "$target_user" >/dev/null
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 26.04 ]] || {
    echo 'This provisioner is scoped to Ubuntu 26.04.' >&2; exit 1;
}
ip -4 -o addr show | grep -q '192\.168\.0\.8/24' || {
    echo 'Expected LAN address 192.168.0.8/24 is missing.' >&2; exit 1;
}

if ! command -v docker >/dev/null; then
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
            echo "Existing conflicting package: $package. Review it before provisioning." >&2
            exit 1
        fi
    done
    for path in /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc; do
        [[ ! -e $path ]] || { echo "Existing Docker APT file: $path; refusing overwrite." >&2; exit 1; }
    done
    apt-get update
    apt-get install -y ca-certificates curl
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --show-error --silent --location --proto '=https' \
        https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    architecture=$(dpkg --print-architecture)
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    chmod 0644 /etc/apt/sources.list.d/docker.sources
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    dpkg-query -W -f='${db:Status-Status}' docker-ce 2>/dev/null | grep -qx installed || {
        echo 'Existing Docker is not docker-ce. Review its installation first.' >&2; exit 1;
    }
    docker compose version
fi

bash "$(dirname -- "${BASH_SOURCE[0]}")/install-boot-readiness.sh"
systemctl enable --now docker.service containerd.service
usermod -aG docker "$target_user"

# Create only missing directories; never chown or chmod existing data.
create_dir() {
    local path=$1 owner=$2 group=$3 mode=$4
    if [[ -L $path ]]; then
        echo "Refusing symlink: $path" >&2; exit 1
    elif [[ -e $path ]]; then
        [[ -d $path ]] || { echo "Not a directory: $path" >&2; exit 1; }
        echo "Preserving existing directory: $path"
    else
        install -d -o "$owner" -g "$group" -m "$mode" "$path"
    fi
}
create_dir /srv/homelab root root 0755
create_dir /srv/homelab/postgres root root 0755
create_dir /srv/homelab/postgres/data 999 999 0700
create_dir /srv/homelab/postgres/data/18 999 999 0700
create_dir /srv/homelab/postgres/data/18/docker 999 999 0700
create_dir /srv/homelab/seaweedfs root root 0755
create_dir /srv/homelab/seaweedfs/data "$target_user" "$target_user" 0700
create_dir /srv/homelab/uptime-kuma root root 0755
create_dir /srv/homelab/uptime-kuma/data "$target_user" "$target_user" 0700
create_dir /srv/homelab/backups "$target_user" "$target_user" 0700

docker version
docker compose version
echo 'Host provisioning complete. Log in again to apply docker group membership.'
echo 'The agent can also use: sg docker -c <command>'
