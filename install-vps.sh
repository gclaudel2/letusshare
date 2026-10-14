#!/usr/bin/env bash
# Installation du relais TURN "Let Us Share" sur Debian 12 (à lancer en root).
# Usage : bash install-vps.sh <nom-de-domaine> <votre-email | none> [url-du-binaire]
#   (mettre none à la place de l'email pour s'en passer : pratique si le @ est difficile à taper)
#   ex. : bash install-vps.sh turn.mondomaine.fr moi@mail.com
# Le binaire p2p-relay-linux-amd64 doit être dans le même dossier que ce script,
# sinon donnez en 3e argument l'adresse où le télécharger.
set -euo pipefail

DOMAIN="${1:-}"; EMAIL="${2:-}"; BIN_URL="${3:-}"
[ -n "$DOMAIN" ] && [ -n "$EMAIL" ] || { echo "Usage : bash install-vps.sh <domaine> <email> [url-du-binaire]"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "Lancez ce script en root (utilisateur root de la console)."; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1/7 Paquets =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y certbot ufw curl ca-certificates openssl

echo "== 2/7 Vérification du nom de domaine =="
PUBIP="$(curl -4 -fsS https://api.ipify.org || true)"
DNSIP="$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)"
echo "IP publique de ce serveur : ${PUBIP:-inconnue}"
echo "IP vers laquelle pointe $DOMAIN : ${DNSIP:-aucune}"
if [ -z "$PUBIP" ] || [ "$PUBIP" != "$DNSIP" ]; then
  echo "ERREUR : le domaine $DOMAIN doit pointer (enregistrement DNS de type A) vers $PUBIP."
  echo "Corrigez le DNS, attendez quelques minutes, puis relancez ce script."
  exit 1
fi

echo "== 3/7 Pare-feu du serveur (SSH conservé) =="
ufw allow 22/tcp
ufw allow 80/tcp          # uniquement pour obtenir / renouveler le certificat
ufw allow 443/tcp         # TURN sur TLS (passe les pare-feu d'entreprise)
ufw allow 3478/tcp
ufw allow 3478/udp
ufw allow 50000:50999/udp # ports de relais média
ufw --force enable

echo "== 4/7 Certificat Let's Encrypt =="
if [ "$EMAIL" = "none" ]; then MAILARG="--register-unsafely-without-email"; else MAILARG="-m $EMAIL"; fi
certbot certonly --standalone -d "$DOMAIN" $MAILARG --agree-tos --non-interactive

echo "== 5/7 Programme du relais =="
id p2prelay >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin p2prelay
if [ -f "$HERE/p2p-relay-linux-amd64" ]; then cp "$HERE/p2p-relay-linux-amd64" /usr/local/bin/p2p-relay
elif [ -n "$BIN_URL" ]; then curl -fsSL "$BIN_URL" -o /usr/local/bin/p2p-relay
else echo "ERREUR : binaire p2p-relay-linux-amd64 introuvable (ni à côté du script, ni en 3e argument)."; exit 1; fi
chmod 755 /usr/local/bin/p2p-relay
/usr/local/bin/p2p-relay -h >/dev/null 2>&1 || true

echo "== 6/7 Certificat pour le service + renouvellement automatique =="
install -d -m 755 /etc/p2p-relay
cat > /etc/letsencrypt/renewal-hooks/deploy/p2p-relay.sh <<HOOK
#!/bin/sh
cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/p2p-relay/fullchain.pem
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/p2p-relay/privkey.pem
chown p2prelay:p2prelay /etc/p2p-relay/fullchain.pem /etc/p2p-relay/privkey.pem
chmod 600 /etc/p2p-relay/privkey.pem
systemctl restart p2p-relay
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/p2p-relay.sh
# première copie (sans redémarrer un service qui n'existe pas encore)
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/p2p-relay/fullchain.pem
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /etc/p2p-relay/privkey.pem
chown p2prelay:p2prelay /etc/p2p-relay/fullchain.pem /etc/p2p-relay/privkey.pem
chmod 600 /etc/p2p-relay/privkey.pem

if [ ! -f /etc/p2p-relay/env ]; then
  umask 077
  echo "P2P_RELAY_SECRET=$(openssl rand -hex 16)" > /etc/p2p-relay/env
fi
chmod 600 /etc/p2p-relay/env
SECRET="$(sed -n 's/^P2P_RELAY_SECRET=//p' /etc/p2p-relay/env)"

echo "== 7/7 Service =="
cat > /etc/systemd/system/p2p-relay.service <<UNIT
[Unit]
Description=Let Us Share - relais TURN
After=network-online.target
Wants=network-online.target

[Service]
User=p2prelay
EnvironmentFile=/etc/p2p-relay/env
ExecStart=/usr/local/bin/p2p-relay -listen 0.0.0.0 -relay-ip $PUBIP -port 3478 -tls-port 443 -cert /etc/p2p-relay/fullchain.pem -key /etc/p2p-relay/privkey.pem
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65535
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now p2p-relay
sleep 2

echo
if systemctl is-active --quiet p2p-relay; then
  echo "=== RELAIS ACTIF ==="
  ss -tulpn | grep p2p-relay || true
else
  echo "=== LE RELAIS NE DÉMARRE PAS ===  Détails : journalctl -u p2p-relay -n 40 --no-pager"; exit 1
fi
cat <<INFO

À saisir dans Let Us Share > Paramètres et tests :
  Relais TURN (une adresse par ligne) :
    turns:$DOMAIN:443?transport=tcp
    turn:$DOMAIN:3478?transport=udp
    turn:$DOMAIN:3478?transport=tcp
  Mode : Secret du relais
  Secret : $SECRET

Gardez ce secret pour vous et vos utilisateurs. Pour le revoir plus tard : cat /etc/p2p-relay/env
Journal du relais : journalctl -u p2p-relay -f
INFO
