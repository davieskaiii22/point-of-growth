#!/bin/bash
# Починка запуска n8n после смены домена
cd /home/docker-app || { echo "Нет папки /home/docker-app"; exit 1; }
G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; N='\033[0m'
DC="docker compose"; $DC version >/dev/null 2>&1 || DC="docker-compose"

wait_n8n(){ for i in $(seq 1 30); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:5678/healthz)
  [ "$c" = "200" ] && return 0; sleep 3; done; return 1; }

echo -e "${G}==> Запускаю контейнеры${N}"
timeout 120 $DC up -d 2>&1 | tail -4
echo -e "${G}==> Жду n8n (до 90 сек)${N}"
if wait_n8n; then
  echo -e "\n${G}ГОТОВО! n8n работает. Открой https://n8nanton333.ru${N}"; exit 0
fi

echo -e "${Y}n8n не поднялся. Диагностика:${N}"
docker ps -a --format '{{.Names}}: {{.Status}}'
echo "--- postgres ---"; docker logs n8n_postgres --tail 8 2>&1
echo "--- n8n ---"; docker logs n8n --tail 8 2>&1

echo -e "\n${Y}==> Возвращаю настройки из резервной копии${N}"
B=$(ls -1 docker-compose.yml.backup-* 2>/dev/null | sort | tail -1)
E=$(ls -1 .env.backup-* 2>/dev/null | sort | tail -1)
[ -n "$B" ] && cp "$B" docker-compose.yml && echo "compose восстановлен из $B"
[ -n "$E" ] && cp "$E" .env && echo ".env восстановлен из $E"
$DC down 2>&1 | tail -2
timeout 120 $DC up -d 2>&1 | tail -4
if wait_n8n; then
  echo -e "\n${G}n8n снова работает (со старыми настройками).${N}"
  echo -e "${Y}Открой https://n8nanton333.ru и пришли скриншот этого окна — доделаем настройку.${N}"
else
  echo -e "${R}n8n не запускается даже со старыми настройками. Пришли скриншот этого окна.${N}"
  docker ps -a --format '{{.Names}}: {{.Status}}'
  docker logs n8n --tail 10 2>&1
fi
