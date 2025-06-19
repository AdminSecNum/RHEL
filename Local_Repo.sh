#!/bin/bash

set -e

# === CONFIGURATION ===
REPO_DIR="/var/www/repos"
SSL_DIR="/etc/pki/tls/private"
DOMAIN="mirror.local"
REPO_HOST="https://$DOMAIN"
CERT_FILE="/etc/pki/tls/certs/${DOMAIN}.crt"
KEY_FILE="$SSL_DIR/${DOMAIN}.key"
GPG_NAME="Repo Signing Key"

# === INSTALL DEPENDENCIES ===
echo "[1/8] Installation des paquets requis..."
dnf install -y httpd mod_ssl dnf-utils createrepo rpm-sign gnupg2 firewalld

systemctl enable --now httpd
systemctl enable --now firewalld

# === SSL SETUP ===
echo "[2/8] Génération du certificat SSL autofabriqué..."
mkdir -p "$SSL_DIR"
openssl req -newkey rsa:2048 -nodes -keyout "$KEY_FILE" -x509 -days 365 -out "$CERT_FILE" -subj "/C=FR/ST=Local/L=Local/O=MyOrg/OU=IT/CN=$DOMAIN"


# Modifier la conf Apache
echo "[3/8] Configuration Apache SSL..."
cat > /etc/httpd/conf.d/repo.conf <<EOF
<VirtualHost *:443>
    ServerName $DOMAIN

    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE

    DocumentRoot "$REPO_DIR"
    <Directory "$REPO_DIR">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>
EOF

# === FIREWALL ===
echo "[4/8] Ouverture du port HTTPS dans le pare-feu..."
firewall-cmd --permanent --add-service=https
firewall-cmd --reload


# === GPG KEY ===
echo "[5/8] Création d'une clé GPG pour signer les métadonnées..."
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: $GPG_NAME
Name-Email: repo@$DOMAIN
Expire-Date: 0
%commit
EOF

GPG_KEY_ID=$(gpg --list-keys --with-colons | grep pub | cut -d: -f5 | head -n1)
gpg --export -a "$GPG_KEY_ID" > /etc/pki/rpm-gpg/RPM-GPG-KEY-$DOMAIN

# === SYNCHRONISE REPOS ===
echo "[6/8] Synchronisation des dépôts RPM..."

mkdir -p "$REPO_DIR"/{baseos,appstream,epel}

reposync --repoid=rhel-8-for-x86_64-baseos-rpms --download-path="$REPO_DIR"/baseos --download-metadata

reposync --repoid=rhel-8-for-x86_64-appstream-rpms --download-path="$REPO_DIR"/appstream --download-metadata

reposync --repoid=epel --download-path="$REPO_DIR"/epel --download-metadata

# === CREATION METADATA + SIGNATURE GPG ===
echo "[7/8] Création des métadonnées et signature GPG..."

for path in baseos appstream epel; do
  repo_path="$REPO_DIR/$path"
  createrepo "$repo_path"
  gpg --detach-sign --armor "$repo_path/repodata/repomd.xml"
done

# === REDEMARRAGE APACHE AVEC SSL ===
echo "[8/8] Redémarrage de httpd..."
systemctl restart httpd

# === FIN ===
echo ""
echo "🎉 Serveur HTTPS prêt : $REPO_HOST"
echo "📎 Clé GPG copiée dans /etc/pki/rpm-gpg/RPM-GPG-KEY-$DOMAIN"
echo "🔒 Les métadonnées sont signées avec GPG"

# === REPO FILE FOR CLIENTS ===
echo ""
echo "=== Fichier .repo pour vos clients ==="
cat <<EOF
[local-baseos]
name=Depot local sécurisé - BaseOS
baseurl=$REPO_HOST/baseos/rhel-8-for-x86_64-baseos-rpms/
enabled=1
gpgcheck=1
gpgkey=$REPO_HOST/RPM-GPG-KEY-$DOMAIN
sslverify=1

[local-appstream]
name=Depot local sécurisé - AppStream
baseurl=$REPO_HOST/appstream/rhel-8-for-x86_64-appstream-rpms/
enabled=1
gpgcheck=1
gpgkey=$REPO_HOST/RPM-GPG-KEY-$DOMAIN
sslverify=1

[local-epel]
name=Depot local sécurisé - EPEL
baseurl=$REPO_HOST/epel/epel/
enabled=1
gpgcheck=1
gpgkey=$REPO_HOST/RPM-GPG-KEY-$DOMAIN
sslverify=1
EOF

echo ""
echo "💡 Copiez ce fichier dans /etc/yum.repos.d/ sur les clients"
echo "ajouter une entrée /etc/hosts sur les clients : Exemple : 192.168.1.10 mirror.local"
echo "dnf repolist"
