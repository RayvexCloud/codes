#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

trap 'error "Installation failed on line $LINENO."' ERR

[[ $EUID -eq 0 ]] || { error "Run as root."; exit 1; }

banner() {
clear
cat << "EOF"
╔════════════════════════════════════╗
║          RayvexCloud               ║
║      Paymenter Installer           ║
╚════════════════════════════════════╝
EOF
}

prompt_inputs() {
while true; do
read -rp "Domain: " DOMAIN
[[ -n "$DOMAIN" ]] && break
error "Domain cannot be blank."
done

read -rp "Database Name [paymenter]: " DB_NAME
DB_NAME=${DB_NAME:-paymenter}

read -rp "Database User [paymenter]: " DB_USER
DB_USER=${DB_USER:-paymenter}

while true; do
read -rsp "Database Password: " DB_PASS
echo
[[ -n "$DB_PASS" ]] && break
error "Database Password cannot be blank."
done
}

install_ubuntu() {
apt update
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
apt update
apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} mariadb-server nginx tar unzip git redis-server
}

install_debian12() {
apt update
apt -y install curl ca-certificates gnupg2 sudo lsb-release
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg
curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-10.11"
apt update
apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} mariadb-server nginx tar unzip git redis-server
}

install_debian13() {
apt update
apt -y install curl ca-certificates gnupg2 sudo lsb-release
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg
apt update
apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} mariadb-server nginx tar unzip git redis-server
}

install_paymenter() {
mkdir -p /var/www/paymenter
cd /var/www/paymenter
curl -Lo paymenter.tar.gz https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz
tar -xzvf paymenter.tar.gz
chmod -R 755 storage/* bootstrap/cache/ || true

cp .env.example .env
php artisan key:generate --force
php artisan storage:link

mysql -u root <<MYSQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL

sed -i "s/^DB_HOST=.*/DB_HOST=127.0.0.1/" .env
sed -i "s/^DB_PORT=.*/DB_PORT=3306/" .env
sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env

php artisan migrate --force --seed
php artisan db:seed --class=CustomPropertySeeder

cat > /etc/nginx/sites-available/paymenter.conf <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    root /var/www/paymenter/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ ^/index\.php(/|\$) {
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }
}
EOF

ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/paymenter.conf
rm -f /etc/nginx/sites-enabled/default
chown -R www-data:www-data /var/www/paymenter

nginx -t
systemctl restart nginx

apt install -y python3-certbot-nginx

SERVER_IP=$(curl -4 -s https://api.ipify.org || true)
DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)

if [[ -n "$SERVER_IP" && "$SERVER_IP" == "$DOMAIN_IP" ]]; then
    certbot --nginx --redirect --agree-tos --register-unsafely-without-email -d "$DOMAIN"
else
    warn "Domain does not resolve to this server IP. Skipping SSL."
fi

cat > /etc/systemd/system/paymenter.service <<'EOF'
[Unit]
Description=Paymenter Queue Worker

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/paymenter/artisan queue:work
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now paymenter
systemctl enable --now redis-server

(crontab -l 2>/dev/null; echo "* * * * * php /var/www/paymenter/artisan schedule:run >> /dev/null 2>&1") | crontab -

cd /var/www/paymenter
php artisan app:init
php artisan app:user:create

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Paymenter Installed Successfully${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Domain        : $DOMAIN"
echo "Database Name : $DB_NAME"
echo "Database User : $DB_USER"
}

install_blueprint() {
read -rp "Pterodactyl Directory [/var/www/pterodactyl]: " PTERO_DIR
PTERO_DIR=${PTERO_DIR:-/var/www/pterodactyl}

if [[ ! -d "$PTERO_DIR" ]]; then
    error "Directory does not exist: $PTERO_DIR"
    exit 1
fi

apt update
apt install -y ca-certificates curl git gnupg unzip wget zip

mkdir -p /etc/apt/keyrings

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
> /etc/apt/sources.list.d/nodesource.list

apt update
apt install -y nodejs

cd "$PTERO_DIR"

npm i -g yarn

wget "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip" \
-O "$PTERO_DIR/release.zip"

unzip -o release.zip

yarn install

cat > "$PTERO_DIR/.blueprintrc" <<EOF
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF

chmod +x "$PTERO_DIR/blueprint.sh"
bash "$PTERO_DIR/blueprint.sh"

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Blueprint Installed Successfully${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "Directory: $PTERO_DIR"
}

banner
echo "1) Install Paymenter"
echo "2) Install Blueprint"
echo "0) Exit"
read -rp "Select option: " MAIN

case "$MAIN" in
1)
echo "1) Ubuntu 24.04"
echo "2) Debian 11/12"
echo "3) Debian 13"
read -rp "Select OS: " OS

prompt_inputs

case "$OS" in
1) install_ubuntu ;;
2) install_debian12 ;;
3) install_debian13 ;;
*) error "Invalid OS option."; exit 1 ;;
esac

install_paymenter
;;
2)
install_blueprint
;;
0)
exit 0
;;
*)
error "Invalid option."
exit 1
;;
esac
