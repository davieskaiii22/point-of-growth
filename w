#!/bin/bash
# Webhook-адрес n8n через Cloudflare-переходник (для Telegram)
PROXY="https://snowy-math-cada.maxidrom615-000.workers.dev/"
G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; N='\033[0m'
cd /home/docker-app || { echo -e "${R}Нет папки /home/docker-app${N}"; exit 1; }
DC="docker compose"; $DC version >/dev/null 2>&1 || DC="docker-compose"

echo -e "${G}==> Проверяю, что Cloudflare достаёт до сервера${N}"
C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${PROXY}healthz")
echo "Ответ через Cloudflare: $C"

cp .env ".env.backup-w-$(date +%H%M%S)" 2>/dev/null
cp docker-compose.yml "docker-compose.yml.backup-w-$(date +%H%M%S)"
if [ -f .env ] && grep -q '^WEBHOOK_URL=' .env; then
  sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=$PROXY|" .env
else
  echo "WEBHOOK_URL=$PROXY" >> .env
fi
# если адрес прописан прямо в compose — меняем и там
sed -i -E "s|(- *WEBHOOK_URL=).*|\1$PROXY|; s|(WEBHOOK_URL: *).*|\1$PROXY|" docker-compose.yml
# compose должен читать .env для n8n
if ! grep -qE 'env_file|WEBHOOK_URL' docker-compose.yml; then
  python3 - <<'PY'
import re
p='docker-compose.yml'; s=open(p).read()
m=re.search(r'(?m)^(\s+)n8n:\s*\n', s)
if m:
    sub=m.group(1)+'  '
    s=s[:m.end()]+f"{sub}env_file:\n{sub}  - .env\n"+s[m.end():]
    open(p,'w').write(s)
PY
fi

echo -e "${G}==> Перезапускаю n8n${N}"
timeout 120 $DC up -d 2>&1 | tail -3
for i in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:5678/healthz)" = "200" ] && break; sleep 3
done
V=$(docker inspect n8n --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^WEBHOOK_URL=')
echo "Сейчас в n8n: $V"
if [ "$V" = "WEBHOOK_URL=$PROXY" ]; then
  echo -e "\n${G}ГОТОВО! Теперь в n8n выключи и снова включи (Publish) сценарий.${N}"
else
  echo -e "\n${R}Адрес не применился. Пришли скриншот этого окна.${N}"
fi
