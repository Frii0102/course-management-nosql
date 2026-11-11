#!/usr/bin/env bash
# Повний прогін: контейнери -> схема -> дані -> Mongo -> бенчмарк -> Neo4j.
# Використання: ./run_all.sh [full|smoke]     (smoke — швидка перевірка за ~1–2 хв)
set -euo pipefail
cd "$(dirname "$0")"
PRESET="${1:-full}"
case "$PRESET" in smoke|full) ;; *) echo "Використання: $0 smoke|full" >&2; exit 2;; esac
export PATH="$HOME/Applications/Docker.app/Contents/Resources/bin:/Applications/Docker.app/Contents/Resources/bin:/opt/homebrew/bin:$PATH"
command -v docker >/dev/null || { echo "Встанови Docker Desktop і відкрий його." >&2; exit 1; }
docker info >/dev/null || { echo "Запусти Docker Desktop і дочекайся готовності." >&2; exit 1; }
for f in sql/00_installation.sql sql/09_course_versions.sql sql/09b_version_audit_triggers.sql python/requirements.txt; do
  test -f "$f" || { echo "Немає файлу $f" >&2; exit 1; }
done
mkdir -p logs
exec > >(tee "logs/${PRESET}-$(date +%Y%m%d-%H%M%S).log") 2>&1
wait_ready() {
  local service="$1"
  shift
  for ((attempt=1; attempt<=90; attempt++)); do
    if "$@" >/dev/null 2>&1; then return; fi
    sleep 2
  done
  docker compose logs --tail=60 "$service"
  echo "Сервіс $service не готовий за 180 с" >&2
  exit 1
}
PSQL=(docker compose exec -T -w /sql postgres psql -U postgres -d lms -v ON_ERROR_STOP=1 -q)

echo "== 1/7 PostgreSQL + MongoDB"
docker compose up -d postgres mongo
wait_ready postgres docker compose exec -T postgres pg_isready -U postgres -d lms
wait_ready mongo docker compose exec -T mongo mongosh --quiet --eval 'if (!db.runCommand({ping:1}).ok) quit(1)'

echo "== 2/7 SQL-схема (00 + 09 + 09b)"
HAS_SCHEMA="$(docker compose exec -T postgres psql -U postgres -d lms -tAc \
  "SELECT count(*) FROM information_schema.schemata WHERE schema_name='lms'" | tr -d '[:space:]')"
if [ "$HAS_SCHEMA" = "0" ]; then
  "${PSQL[@]}" -f 00_installation.sql
  "${PSQL[@]}" -f 09_course_versions.sql
  "${PSQL[@]}" -f 09b_version_audit_triggers.sql
else
  echo "схема lms уже існує — пропускаю (для чистого старту: docker compose down -v)"
fi

echo "== 3/7 Python-середовище"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -q -r python/requirements.txt
python -m pip freeze > logs/requirements-resolved.txt
cd python

echo "== 4/7 генерація даних ($PRESET)"
python generate_data.py --preset "$PRESET"

echo "== 5/7 завантаження у MongoDB"
python load_mongo.py --drop

echo "== 6/7 бенчмарк"
python benchmark.py
if [ "$PRESET" = "full" ]; then
  # Другий прогін: пул ключів на весь набір (робочий набір більший за кеш)
  python benchmark.py --pool 100000 --tag large_pool --publish-iterations 50 --concurrency-seconds 10
fi

echo "== 7/7 Neo4j (п. 6)"
cd ..
docker compose up -d neo4j
cd python
python neo4j_demo.py
# finalize_report.py вписує таблиці в README між "### 5.4 Результати" і "### 5.5"; у README для GitHub цих розділів немає
if [ "$PRESET" = "full" ] && grep -q "^### 5.4 Результати" ../README.md; then python finalize_report.py; fi
echo "Готово. Результати: results/results.md, results/neo4j_demo.md, results/plans/"
