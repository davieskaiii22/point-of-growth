#!/bin/bash
# Настройка домена + бесплатного SSL для n8n (Docker) за Nginx
set -u
DOMAIN="n8nanton333.ru"
G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; N='\033[0m'
step(){ echo -e "\n${G}==> $1${N}"; }
fail(){ echo -e "${R}ОШИБКА: $1${N}"; exit 1; }

[ "$(id -u)" = 0 ] || fail "запусти от root"

step "1/5 Проверяю, что домен указывает на этот сервер"
MYIP=$(curl -4 -s --max-time 10 https://ifconfig.me || hostname -I | awk '{print $1}')
DNSIP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')
echo "IP сервера: $MYIP   IP домена: ${DNSIP:-не найден}"
[ "$MYIP" = "$DNSIP" ] || fail "домен $DOMAIN пока не указывает на этот сервер. Подожди и запусти ещё раз."

step "2/5 Настраиваю Nginx для $DOMAIN"
cat > /etc/nginx/sites-available/n8n-domain <<EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    client_max_body_size 50m;
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        chunked_transfer_encoding off;
    }
}
EOF
# если map с таким именем уже есть в другом конфиге — убираем свой, чтобы не было конфликта
if grep -rls '\$connection_upgrade' /etc/nginx/nginx.conf /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ 2>/dev/null | grep -qv n8n-domain; then
  sed -i '1d' /etc/nginx/sites-available/n8n-domain
fi
ln -sf /etc/nginx/sites-available/n8n-domain /etc/nginx/sites-enabled/n8n-domain
nginx -t || fail "ошибка в настройке Nginx (ничего не сломано, просто пришли скриншот)"
systemctl reload nginx

step "3/5 Получаю бесплатный SSL-сертификат (Let's Encrypt)"
if ! command -v certbot >/dev/null; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx || fail "не удалось установить certbot"
fi
WWW=""
[ "$(getent ahostsv4 www.$DOMAIN | awk 'NR==1{print $1}')" = "$MYIP" ] && WWW="-d www.$DOMAIN"
certbot --nginx -d "$DOMAIN" $WWW --non-interactive --agree-tos --register-unsafely-without-email --redirect \
  || fail "сертификат не выдан. Пришли скриншот."

step "4/5 Прописываю домен в настройках n8n"
WD=$(docker inspect n8n --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null)
CF=$(docker inspect n8n --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null)
echo "Папка n8n: ${WD:-не найдена}"
echo "Файл: ${CF:-не найден}"
[ -n "$WD" ] && [ -d "$WD" ] || fail "не нашёл, где лежат настройки n8n. Nginx и SSL уже готовы — пришли скриншот, доделаем вручную."
cd "$WD"
TS=$(date +%Y%m%d-%H%M%S)
[ -f .env ] && cp .env ".env.backup-$TS"
for f in ${CF//,/ }; do [ -f "$f" ] && cp "$f" "$f.backup-$TS"; done
echo -e "${Y}Резервные копии сохранены с пометкой backup-$TS${N}"

setvar(){ # setvar KEY VALUE  -> в .env
  if [ -f .env ] && grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}
setvar N8N_HOST "$DOMAIN"
setvar N8N_PROTOCOL "https"
setvar N8N_PORT "5678"
setvar WEBHOOK_URL "https://$DOMAIN/"
setvar N8N_EDITOR_BASE_URL "https://$DOMAIN/"
setvar N8N_PROXY_HOPS "1"

# убеждаемся, что compose передаёт эти переменные в контейнер
MAIN=$(echo "${CF//,/ }" | awk '{print $1}')
if [ -f "$MAIN" ] && ! grep -qE 'env_file|WEBHOOK_URL' "$MAIN"; then
  echo -e "${Y}В $MAIN нет env_file — добавляю его для сервиса n8n${N}"
  python3 - "$MAIN" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
m=re.search(r'(?m)^(\s+)n8n:\s*\n', s)
if m:
    ind=m.group(1); sub=ind+'  '
    s=s[:m.end()]+f"{sub}env_file:\n{sub}  - .env\n"+s[m.end():]
    open(p,'w').write(s); print("ok")
else: print("service n8n not found")
PY
fi
# если переменные заданы прямо в compose — обновляем и там
if [ -f "$MAIN" ]; then
  for k in N8N_HOST N8N_PROTOCOL WEBHOOK_URL N8N_EDITOR_BASE_URL; do
    v=$(grep "^$k=" .env | cut -d= -f2-)
    sed -i -E "s|(- *$k=).*|\1$v|; s|($k: *).*|\1$v|" "$MAIN"
  done
fi

step "5/5 Перезапускаю n8n"
if docker compose version >/dev/null 2>&1; then docker compose -f "$MAIN" up -d; else docker-compose -f "$MAIN" up -d; fi
sleep 8
docker ps --format '{{.Names}}: {{.Status}}' | grep n8n
echo
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/")
if [ "$CODE" = "200" ]; then
  echo -e "${G}ГОТОВО! Открой https://$DOMAIN${N}"
else
  echo -e "${Y}n8n отвечает кодом $CODE. Подожди минуту и открой https://$DOMAIN. Если не открывается — пришли скриншот.${N}"
fi
