#!/bin/sh
set -e

# -------------------------------------------------------
# fewohbee interactive setup
# Reads .env.dist from /config (mount),
# asks a few questions, generates passwords and writes
# .env ready for "docker compose up -d".
# -------------------------------------------------------

echo ""
echo "=== fewohbee Setup ==="
echo ""

is_valid_port() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
    esac

    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Stores the validated answer in selected_port.
prompt_port() {
    prompt_label="$1"
    prompt_default="$2"
    prompt_excluded="${3:-}"

    while true; do
        printf "%s [%s]: " "$prompt_label" "$prompt_default"
        read -r selected_port
        selected_port="${selected_port:-$prompt_default}"

        if ! is_valid_port "$selected_port"; then
            echo "Please enter a port between 1 and 65535."
            continue
        fi

        if [ -n "$prompt_excluded" ] && [ "$selected_port" = "$prompt_excluded" ]; then
            echo "Please choose a different port than $prompt_excluded."
            continue
        fi

        return 0
    done
}

# ---- sanity checks ----
if [ -f "/config/.env" ]; then
    echo "Configuration already exists (.env found). Remove it to reconfigure."
    exit 0
fi

if [ ! -f "/config/.env.dist" ]; then
    echo "Error: .env.dist not found in the mounted directory."
    echo ""
    echo "Make sure to run this container from the fewohbee-dockerized directory:"
    echo "  Linux/Mac:  docker run --rm -it -v \$(pwd):/config developeregrem/fewohbee-setup"
    echo "  Windows PS: docker run --rm -it -v \${PWD}:/config developeregrem/fewohbee-setup"
    exit 1
fi

# ---- detect host OS for COMPOSE_FILE separator ----
# Windows does not allow ':' in filenames; Linux/macOS do.
if touch "/config/.os_detect:test" 2>/dev/null; then
    rm -f "/config/.os_detect:test"
    COMPOSE_SEP=":"
else
    COMPOSE_SEP=";"
fi

# ---- copy template to tmp ----
umask 0177
cp /config/.env.dist /tmp/.env.tmp

# set platform-specific COMPOSE_FILE separator
sed "s@COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml@COMPOSE_FILE=docker-compose.yml${COMPOSE_SEP}docker-compose.override.yml@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- hostname ----
hostname_default="localhost"
printf "Server hostname [%s]: " "$hostname_default"
read -r pveHost
pveHost="${pveHost:-$hostname_default}"

sed "s/HOST_NAME=fewohbee/HOST_NAME=$pveHost/" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s/RELYING_PARTY_ID=example.com/RELYING_PARTY_ID=$pveHost/" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- SSL ----
ssl=""
while ! printf '%s' "$ssl" | grep -qE "^(self-signed|letsencrypt|reverse-proxy)$"; do
    printf "SSL mode (self-signed/letsencrypt/reverse-proxy) [self-signed]: "
    read -r ssl
    ssl="${ssl:-self-signed}"
done

if [ "$ssl" = "letsencrypt" ]; then
    printf "Email address for Let's Encrypt notifications: "
    read -r leMail

    leDomains="$pveHost"
    printf "Also add www subdomain (www.%s)? (yes/no) [yes]: " "$pveHost"
    read -r leWww
    leWww="${leWww:-yes}"
    if [ "$leWww" = "yes" ]; then
        leDomains="$leDomains www.$pveHost"
    fi

    sed 's@LETSENCRYPT=false@LETSENCRYPT=true@g' /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed 's@SELF_SIGNED=true@SELF_SIGNED=false@g' /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed "s@LETSENCRYPT_DOMAINS=\"<domain.tld>\"@LETSENCRYPT_DOMAINS=\"$leDomains\"@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed "s|EMAIL=\"<your mail address>\"|EMAIL=\"$leMail\"|g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
fi

# reverse-proxy: SSL is handled externally — disable both SSL options in .env
# and switch to the no-ssl compose file
if [ "$ssl" = "reverse-proxy" ]; then
    sed 's@SELF_SIGNED=true@SELF_SIGNED=false@g' /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
    sed "s@COMPOSE_FILE=docker-compose.yml${COMPOSE_SEP}docker-compose.override.yml@COMPOSE_FILE=docker-compose.no-ssl.yml${COMPOSE_SEP}docker-compose.override.yml@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
fi
# ---- host ports ----
echo ""
echo "Host port availability cannot be checked reliably from inside the setup container."
echo "Keep the defaults unless another service already uses these ports on the Docker host."
prompt_port "HTTP host port (LISTEN_PORT)" 80
listenPort="$selected_port"
httpsListenPort=443

if [ "$ssl" != "reverse-proxy" ]; then
    prompt_port "HTTPS host port (HTTPS_LISTEN_PORT)" 443 "$listenPort"
    httpsListenPort="$selected_port"
fi

sed "s@^LISTEN_PORT=.*@LISTEN_PORT=$listenPort@" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@^HTTPS_LISTEN_PORT=.*@HTTPS_LISTEN_PORT=$httpsListenPort@" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

if [ "$ssl" = "letsencrypt" ] && [ "$listenPort" != "80" ]; then
    echo "Warning: Let's Encrypt HTTP-01 validation requires public port 80."
    echo "Forward public port 80 to host port $listenPort or certificate issuance will fail."
fi

if [ "$ssl" = "letsencrypt" ] && [ "$httpsListenPort" != "443" ]; then
    echo "Note: Browsers use HTTPS port 443 by default."
    echo "Forward public port 443 to host port $httpsListenPort or include the port in the URL."
fi

# ---- language ----
pveLang=""
while ! printf '%s' "$pveLang" | grep -qE "^(de|en)$"; do
    printf "Language (de/en) [de]: "
    read -r pveLang
    pveLang="${pveLang:-de}"
done
sed "s@LOCALE=de@LOCALE=$pveLang@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- generate secrets & passwords ----
echo ""
echo "Generating passwords and secrets ..."

mariadbRootPw=$(openssl rand -hex 20)
mariadbPw=$(openssl rand -hex 20)
mysqlBackupPw=$(openssl rand -hex 20)
appSecret=$(openssl rand -base64 23)

sed "s@MARIADB_ROOT_PASSWORD=<pw>@MARIADB_ROOT_PASSWORD=$mariadbRootPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@MARIADB_PASSWORD=<pw>@MARIADB_PASSWORD=$mariadbPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@MYSQL_BACKUP_PASSWORD=<backuppassword>@MYSQL_BACKUP_PASSWORD=$mysqlBackupPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@APP_SECRET=<secret>@APP_SECRET=$appSecret@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp
sed "s@db_password@$mariadbPw@g" /tmp/.env.tmp > /tmp/.env.tmp2 && mv /tmp/.env.tmp2 /tmp/.env.tmp

# ---- write final file ----
cp /tmp/.env.tmp /config/.env && rm -f /tmp/.env.tmp

echo ""
echo "==================================="
echo " Setup complete!"
echo "==================================="
echo ""
echo "File created: .env"
echo ""
echo "Next steps:"
echo ""
echo "  1. Optionally review and adjust .env"
echo ""
echo "  2. Start the application:"
echo "       docker compose up -d"
if [ "$ssl" = "reverse-proxy" ]; then
    echo ""
    echo "     Configure your reverse proxy to forward requests to port $listenPort."
fi
echo ""
echo "  3. Wait for the php container to become healthy:"
echo "       docker compose ps"
echo ""
echo "     Once 'php' is reported as 'healthy', run the following command once"
echo "     to initialize the application (creates the first admin user, loads base templates,"
echo "     and optionally loads sample data):"
echo ""
echo "       docker compose exec --user www-data php sh -c 'php bin/console app:first-run'"
echo ""
if [ "$ssl" = "reverse-proxy" ]; then
    printf "  Application will be available at: http://%s (via reverse proxy)\n" "$pveHost"
else
    if [ "$httpsListenPort" = "443" ]; then
        printf "  Application will be available at: https://%s\n" "$pveHost"
    else
        printf "  Application will be available at: https://%s:%s\n" "$pveHost" "$httpsListenPort"
    fi
    if [ "$ssl" = "self-signed" ]; then
        echo "  (Accept the browser security warning on first visit - self-signed certificate)"
    fi
fi
echo ""
