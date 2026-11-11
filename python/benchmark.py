#!/usr/bin/env python3
"""Бенчмарк: незмінні версії курсу — PostgreSQL (5 таблиць) проти MongoDB (1 документ).

Принципи (їх варто озвучити на захисті):
  1. Дані тотожні: Mongo заповнено з тих самих таблиць PostgreSQL; перед тестом
     скрипт ПЕРЕВІРЯЄ рівність відповідей (verify_equivalence).
  2. Однакові умови: контейнери з однаковими ліміти CPU/RAM і розміром кешу (docker-compose).
  3. Прогрів + багато повторів; медіана та p95/p99, а не одне вимірювання.
  4. Варіанти запускаються ПЕРЕМІЖНО (порядок обертається), щоб кеш і дрейф
     навантаження не давали переваги тому, хто йде першим.
  5. SQL-варіанти включають і "збирання вкладеної структури" (те, що робить застосунок),
     і серверне збирання jsonb — щоб не порівнювати яблука з грушами.
  6. Запис порівнюємо з однаковою довговічністю: PG commit (fsync) ↔ Mongo j=true.
  7. Є сценарії, де SQL має виграти (дифф версій, обчислення за готовими числами) —
     результат інтерпретується чесно, незалежно від переможця.
  8. Критерії інтерпретації зафіксовані в README ДО запуску.
"""
import argparse
import datetime
import json
import os
import platform
import random
import statistics
import sys
import threading
import time

import psycopg
from bson import json_util
from pymongo import ASCENDING, MongoClient
from pymongo.write_concern import WriteConcern

from common import (FLAT_LIVE_SQL, FLAT_VERSION_SQL, JSON_AGG_SQL, assemble, build_document,
                    percentile)
from config import (ACTOR_ID, BENCH_PREFIX, MONGO_COLLECTION, MONGO_DB, MONGO_URI, PG_DSN,
                    RESULTS_DIR, SEED)

OUT_DIR = RESULTS_DIR  # перевизначається через --tag

VERSION_TABLES = ["course_versions", "module_versions", "lesson_versions",
                  "material_versions", "assignment_versions"]
BENCH_COURSES = f"(SELECT id FROM lms.courses WHERE code LIKE '{BENCH_PREFIX}%')"

# ---------------------------------------------------------------- SQL для сценаріїв
PROGRESS_LIVE_VIEW = "SELECT id, progress_percent FROM lms.v_enrollments WHERE cohort_id = %s ORDER BY id"
PROGRESS_VERSION_JOIN = """
SELECT e.id, round(100.0 * count(lp.id) / nullif(den.cnt, 0), 2)
FROM lms.enrollments e
JOIN lms.cohorts h ON h.id = e.cohort_id
CROSS JOIN LATERAL (SELECT count(*) AS cnt FROM lms.lesson_versions lv
                    JOIN lms.module_versions mv ON mv.id = lv.module_version_id
                    WHERE mv.course_version_id = h.course_version_id) den
LEFT JOIN lms.lesson_progress lp ON lp.enrollment_id = e.id
WHERE e.cohort_id = %s
GROUP BY e.id, den.cnt ORDER BY e.id"""
PROGRESS_VERSION_CACHED = """
SELECT e.id, round(100.0 * count(lp.id) / nullif(cv.lesson_count, 0), 2)
FROM lms.enrollments e
JOIN lms.cohorts h ON h.id = e.cohort_id
JOIN lms.course_versions cv ON cv.id = h.course_version_id
LEFT JOIN lms.lesson_progress lp ON lp.enrollment_id = e.id
WHERE e.cohort_id = %s
GROUP BY e.id, cv.lesson_count ORDER BY e.id"""
PROGRESS_COUNTS = """
SELECT e.id, count(lp.id), h.course_version_id
FROM lms.enrollments e
JOIN lms.cohorts h ON h.id = e.cohort_id
LEFT JOIN lms.lesson_progress lp ON lp.enrollment_id = e.id
WHERE e.cohort_id = %s
GROUP BY e.id, h.course_version_id ORDER BY e.id"""
DIFF_SQL = """
WITH a AS (SELECT lv.source_lesson_id AS id, mv.source_module_id AS mid, lv.title, lv.content,
                  lv.duration_minutes AS dur, lv.position AS pos
           FROM lms.lesson_versions lv JOIN lms.module_versions mv ON mv.id = lv.module_version_id
           WHERE mv.course_version_id = %s),
     b AS (SELECT lv.source_lesson_id AS id, mv.source_module_id AS mid, lv.title, lv.content,
                  lv.duration_minutes AS dur, lv.position AS pos
           FROM lms.lesson_versions lv JOIN lms.module_versions mv ON mv.id = lv.module_version_id
           WHERE mv.course_version_id = %s)
SELECT coalesce(a.id, b.id),
       CASE WHEN a.id IS NULL THEN 'added' WHEN b.id IS NULL THEN 'removed' ELSE 'changed' END
FROM a FULL JOIN b ON a.id = b.id
WHERE a.id IS NULL OR b.id IS NULL
   OR (a.mid, a.title, a.content, a.dur, a.pos) IS DISTINCT FROM (b.mid, b.title, b.content, b.dur, b.pos)
ORDER BY 1"""


# ---------------------------------------------------------------- утиліти
def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def pg_connect(replica=False):
    conn = psycopg.connect(PG_DSN, autocommit=True)
    conn.execute(f"SELECT set_config('lms.actor_id', '{ACTOR_ID}', false)")
    if replica:
        conn.execute("SET session_replication_role = replica")
    return conn


def stats(samples_ms):
    s = sorted(samples_ms)
    mean = statistics.fmean(s)
    return {
        "n": len(s), "median_ms": percentile(s, 0.5), "mean_ms": mean,
        "p95_ms": percentile(s, 0.95), "p99_ms": percentile(s, 0.99),
        "min_ms": s[0], "max_ms": s[-1],
        "stdev_ms": statistics.pstdev(s) if len(s) > 1 else 0.0,
        "ops_per_s_single_thread": 1000.0 / mean if mean else float("inf"),
    }


def run_interleaved(variants, n, warmup):
    """variants: {назва: f(i)}. Порядок виклику обертається на кожній ітерації."""
    names = list(variants)
    k = len(names)
    samples = {name: [] for name in names}
    for i in range(-warmup, n):
        shift = (i % k) if i >= 0 else 0
        for name in names[shift:] + names[:shift]:
            idx = i + warmup
            t = time.perf_counter_ns()
            variants[name](idx)
            dt = (time.perf_counter_ns() - t) / 1e6
            if i >= 0:
                samples[name].append(dt)
    return {name: stats(v) for name, v in samples.items()}


class Ctx:
    def __init__(self, args):
        self.args = args
        self.rng = random.Random(SEED)
        self.pg = pg_connect()
        self.mongo = MongoClient(MONGO_URI)
        self.db = self.mongo[MONGO_DB]
        self.col = self.db[MONGO_COLLECTION]
        self.results = {}
        self.dataset = {}

    def sample_pool(self, rows, size):
        rows = list(rows)
        self.rng.shuffle(rows)
        return rows[:size]


# ---------------------------------------------------------------- перевірка тотожності
def verify_equivalence(ctx, version_ids):
    log("Перевірка тотожності даних SQL ↔ Mongo ...")
    sample = ctx.rng.sample(version_ids, min(60, len(version_ids)))
    for vid in sample:
        sql_modules = assemble(ctx.pg.execute(FLAT_VERSION_SQL, (vid,)).fetchall())
        doc = ctx.col.find_one({"_id": vid})
        if doc is None:
            raise SystemExit(f"У Mongo немає версії {vid}. Запусти load_mongo.py")
        if doc["modules"] != sql_modules:
            raise SystemExit(f"Розбіжність структури для версії {vid} між SQL і Mongo")
        meta = ctx.pg.execute("SELECT lesson_count, total_max_score FROM lms.course_versions "
                              "WHERE id = %s", (vid,)).fetchone()
        if doc["lessonCount"] != meta[0] or abs(doc["totalMaxScore"] - float(meta[1])) > 1e-6:
            raise SystemExit(f"Розбіжність lessonCount/totalMaxScore для версії {vid}")
        js = ctx.pg.execute(JSON_AGG_SQL, (vid,)).fetchone()[0]
        if js["modules"] != sql_modules:
            raise SystemExit(f"Розбіжність jsonb-збирання для версії {vid}")
    n_mongo = ctx.col.count_documents({})
    n_pg = ctx.pg.execute("SELECT count(*) FROM lms.course_versions "
                          f"WHERE course_id IN {BENCH_COURSES}").fetchone()[0]
    if n_mongo != n_pg:
        raise SystemExit(f"Кількість документів Mongo не збігається з PG ({n_mongo}), ніж версій у PG ({n_pg})")
    log(f"  OK: {len(sample)} версій ідентичні; документів Mongo={n_mongo}, версій PG={n_pg}")


# ---------------------------------------------------------------- сценарій 1
def scenario_load_structure(ctx):
    pool = ctx.pools["versions"]
    pg, col = ctx.pg, ctx.col

    def sql_flat(i):
        pg.execute(FLAT_VERSION_SQL, (pool[i % len(pool)],)).fetchall()

    def sql_assembled(i):
        assemble(pg.execute(FLAT_VERSION_SQL, (pool[i % len(pool)],)).fetchall())

    def sql_json(i):
        pg.execute(JSON_AGG_SQL, (pool[i % len(pool)],)).fetchone()

    def mongo_by_id(i):
        col.find_one({"_id": pool[i % len(pool)]})

    return run_interleaved({
        "sql_flat_rows (без збирання)": sql_flat,
        "sql_flat_rows + збирання у Python": sql_assembled,
        "sql_jsonb (збирання на сервері)": sql_json,
        "mongo find_one(_id)": mongo_by_id,
    }, ctx.args.iterations, ctx.args.warmup)


# ---------------------------------------------------------------- сценарій 2
def scenario_cohort_progress(ctx):
    pool = ctx.pools["cohorts"]
    pg, col = ctx.pg, ctx.col

    def live_view(i):
        pg.execute(PROGRESS_LIVE_VIEW, (pool[i % len(pool)],)).fetchall()

    def version_join(i):
        pg.execute(PROGRESS_VERSION_JOIN, (pool[i % len(pool)],)).fetchall()

    def version_cached(i):
        pg.execute(PROGRESS_VERSION_CACHED, (pool[i % len(pool)],)).fetchall()

    def hybrid(i):
        rows = pg.execute(PROGRESS_COUNTS, (pool[i % len(pool)],)).fetchall()
        if rows:
            d = col.find_one({"_id": rows[0][2]}, {"lessonCount": 1})
            [round(100.0 * done / d["lessonCount"], 2) for _, done, _ in rows]

    return run_interleaved({
        "sql_існуюча v_enrollments (жива структура)": live_view,
        "sql_версії: знаменник через JOIN": version_join,
        "sql_версії: готовий lesson_count": version_cached,
        "гібрид: PG (прогрес) + Mongo (lessonCount)": hybrid,
    }, ctx.args.iterations, ctx.args.warmup)


def check_progress_drift(ctx):
    """Скільки зарахувань показують різний прогрес за живою структурою і за версією."""
    pg = ctx.pg
    total = drift = 0
    for cid in ctx.pools["cohorts"][:200]:
        live = dict(pg.execute(PROGRESS_LIVE_VIEW, (cid,)).fetchall())
        ver = dict(pg.execute(PROGRESS_VERSION_CACHED, (cid,)).fetchall())
        for eid, v in ver.items():
            total += 1
            if abs(float(live[eid]) - float(v)) > 0.005:
                drift += 1
    return {"enrollments_checked": total, "progress_differs": drift,
            "share": drift / total if total else 0.0}


# ---------------------------------------------------------------- сценарій 3
def _set_audit(pg, enabled):
    for tab in VERSION_TABLES:
        pg.execute(f"ALTER TABLE lms.{tab} {'ENABLE' if enabled else 'DISABLE'} TRIGGER audit")


def _cleanup_sql(admin, cv_baseline, audit_baseline):
    admin.execute("""DELETE FROM lms.assignment_versions av USING lms.lesson_versions lv,
                     lms.module_versions mv WHERE lv.id = av.lesson_version_id
                     AND mv.id = lv.module_version_id AND mv.course_version_id > %s""", (cv_baseline,))
    admin.execute("""DELETE FROM lms.material_versions m USING lms.lesson_versions lv,
                     lms.module_versions mv WHERE lv.id = m.lesson_version_id
                     AND mv.id = lv.module_version_id AND mv.course_version_id > %s""", (cv_baseline,))
    admin.execute("""DELETE FROM lms.lesson_versions lv USING lms.module_versions mv
                     WHERE mv.id = lv.module_version_id AND mv.course_version_id > %s""", (cv_baseline,))
    admin.execute("DELETE FROM lms.module_versions WHERE course_version_id > %s", (cv_baseline,))
    admin.execute("DELETE FROM lms.course_versions WHERE id > %s", (cv_baseline,))
    admin.execute("DELETE FROM lms.audit_log WHERE id > %s AND table_name = ANY(%s)",
                  (audit_baseline, VERSION_TABLES))
    for tab in VERSION_TABLES:
        admin.execute(f"VACUUM ANALYZE lms.{tab}")


def scenario_publish(ctx):
    pg = ctx.pg
    n = min(ctx.args.publish_iterations, len(ctx.bench_courses) - 10)
    warm = 5
    courses = ctx.rng.sample(ctx.bench_courses, n + warm)
    admin = pg_connect(replica=True)
    cv_base = pg.execute("SELECT coalesce(max(id), 0) FROM lms.course_versions").fetchone()[0]
    audit_base = pg.execute("SELECT coalesce(max(id), 0) FROM lms.audit_log").fetchone()[0]
    has_audit = pg.execute("""SELECT 1 FROM pg_trigger WHERE tgname = 'audit'
                              AND tgrelid = 'lms.course_versions'::regclass""").fetchone()
    out = {}

    def sql_series(label, audit_on):
        _set_audit(pg, audit_on)
        for c in courses[:warm]:
            pg.execute("CALL lms.sp_publish_course_version(%s, NULL)", (c,))
        samples = []
        for c in courses[warm:]:
            t = time.perf_counter_ns()
            pg.execute("CALL lms.sp_publish_course_version(%s, NULL)", (c,))
            samples.append((time.perf_counter_ns() - t) / 1e6)
        out[label] = stats(samples)
        _cleanup_sql(admin, cv_base, audit_base)

    log("  SQL публікація без аудиту ...")
    if has_audit:
        sql_series("sql CALL sp_publish_course_version (без тригерів аудиту)", False)
        log("  SQL публікація з аудитом ...")
        sql_series("sql CALL sp_publish_course_version (з тригерами аудиту)", True)
        _set_audit(pg, True)
    else:
        log("  Тригерів audit на версіях немає (09b не встановлено) — серія 'з аудитом' пропущена")
        sql_series("sql CALL sp_publish_course_version (без тригерів аудиту)", True)

    # Mongo: запис із довговічністю j=true (аналог fsync при commit у PG)
    scratch_name = "course_versions_publish_test"
    ctx.db.drop_collection(scratch_name)
    scratch = ctx.db.get_collection(scratch_name, write_concern=WriteConcern(w=1, j=True))
    scratch.create_index([("courseId", ASCENDING), ("version", ASCENDING)], unique=True)
    counter = [10 ** 9]

    def build_doc_for(course_id):
        last = ctx.col.find_one({"courseId": course_id}, {"version": 1}, sort=[("version", -1)])
        rows = pg.execute(FLAT_LIVE_SQL, (course_id,)).fetchall()
        modules = assemble(rows)
        counter[0] += 1
        return build_document(counter[0], course_id, (last["version"] if last else 0) + 1,
                              datetime.datetime.now(datetime.timezone.utc),
                              ACTOR_ID, modules)

    log("  Mongo: лише insert (документ підготовлено заздалегідь) ...")
    docs = [build_doc_for(c) for c in courses]
    for d in docs[:warm]:
        scratch.insert_one(d)
    samples = []
    for d in docs[warm:]:
        d = dict(d, _id=d["_id"] + 5_000_000)
        t = time.perf_counter_ns()
        scratch.insert_one(d)
        samples.append((time.perf_counter_ns() - t) / 1e6)
    out["mongo insert_one (лише запис, j=true)"] = stats(samples)
    scratch.drop()
    scratch = ctx.db.get_collection(scratch_name, write_concern=WriteConcern(w=1, j=True))
    scratch.create_index([("courseId", ASCENDING), ("version", ASCENDING)], unique=True)

    log("  Mongo: наскрізно (читання живої структури з PG + збирання + insert) ...")
    for c in courses[:warm]:
        scratch.insert_one(build_doc_for(c))
    total, read_part = [], []
    for c in courses[warm:]:
        t0 = time.perf_counter_ns()
        rows = pg.execute(FLAT_LIVE_SQL, (c,)).fetchall()
        last = ctx.col.find_one({"courseId": c}, {"version": 1}, sort=[("version", -1)])
        modules = assemble(rows)
        t1 = time.perf_counter_ns()
        counter[0] += 1
        doc = build_document(counter[0] + 7_000_000, c, (last["version"] if last else 0) + 1,
                             datetime.datetime.now(datetime.timezone.utc),
                             ACTOR_ID, modules)
        scratch.insert_one(doc)
        t2 = time.perf_counter_ns()
        read_part.append((t1 - t0) / 1e6)
        total.append((t2 - t0) / 1e6)
    out["mongo наскрізно (читання PG + збирання + insert)"] = stats(total)
    out["   з них: читання живої структури + збирання"] = stats(read_part)
    scratch.drop()
    return out


# ---------------------------------------------------------------- сценарій 4
def _lessons_map(doc):
    m = {}
    for mod in doc["modules"]:
        for l in mod["lessons"]:
            m[l["lessonId"]] = (mod["moduleId"], l["title"], l["content"],
                                l["durationMinutes"], l["position"])
    return m


def mongo_diff(col, old_id, new_id):
    a, b = _lessons_map(col.find_one({"_id": old_id})), _lessons_map(col.find_one({"_id": new_id}))
    out = []
    for lid in sorted(set(a) | set(b)):
        if lid not in a:
            out.append((lid, "added"))
        elif lid not in b:
            out.append((lid, "removed"))
        elif a[lid] != b[lid]:
            out.append((lid, "changed"))
    return out


def scenario_diff(ctx):
    pool = ctx.pools["pairs"]
    pg, col = ctx.pg, ctx.col
    for old, new in pool[:30]:
        if [tuple(r) for r in pg.execute(DIFF_SQL, (old, new)).fetchall()] != mongo_diff(col, old, new):
            raise SystemExit(f"Дифф версій {old}->{new} відрізняється між SQL і Mongo")

    def sql_diff(i):
        old, new = pool[i % len(pool)]
        pg.execute(DIFF_SQL, (old, new)).fetchall()

    def mongo_diff_fn(i):
        old, new = pool[i % len(pool)]
        mongo_diff(col, old, new)

    return run_interleaved({"sql FULL JOIN двох версій": sql_diff,
                            "mongo: 2 документи + дифф у Python": mongo_diff_fn},
                           ctx.args.iterations, ctx.args.warmup)


# ---------------------------------------------------------------- сценарій 5
def scenario_size(ctx):
    pg = ctx.pg
    rows = {}
    for tab in VERSION_TABLES:
        n, tbl, idx, tot = pg.execute(
            f"""SELECT (SELECT count(*) FROM lms.{tab}), pg_table_size('lms.{tab}'),
                       pg_indexes_size('lms.{tab}'), pg_total_relation_size('lms.{tab}')""").fetchone()
        rows[tab] = {"rows": n, "table_bytes": tbl, "index_bytes": idx, "total_bytes": tot}
    pg_total = sum(r["total_bytes"] for r in rows.values())
    cs = ctx.db.command("collStats", MONGO_COLLECTION)
    return {"postgres": rows, "postgres_total_bytes": pg_total,
            "mongo": {"documents": cs["count"], "avg_doc_bytes": cs.get("avgObjSize"),
                      "uncompressed_bytes": cs["size"], "storage_bytes": cs["storageSize"],
                      "index_bytes": cs["totalIndexSize"],
                      "total_bytes": cs["storageSize"] + cs["totalIndexSize"]}}


# ---------------------------------------------------------------- сценарій 6
def scenario_concurrency(ctx):
    pool = ctx.pools["versions"]
    seconds, workers = ctx.args.concurrency_seconds, ctx.args.workers
    out = {}

    def run(label, make_worker):
        lat, counts, stop = [], [], threading.Event()
        errors = []
        lock = threading.Lock()

        def worker(seed):
            rnd = random.Random(seed)
            close = lambda: None
            local = []
            try:
                call, close = make_worker()
                while not stop.is_set():
                    vid = pool[rnd.randrange(len(pool))]
                    t = time.perf_counter_ns()
                    call(vid)
                    local.append((time.perf_counter_ns() - t) / 1e6)
            except Exception as exc:
                with lock:
                    errors.append(exc)
                stop.set()
            finally:
                close()
                with lock:
                    lat.extend(local)
                    counts.append(len(local))

        threads = [threading.Thread(target=worker, args=(SEED + i,)) for i in range(workers)]
        for t in threads:
            t.start()
        time.sleep(seconds)
        stop.set()
        for t in threads:
            t.join()
        if errors:
            raise RuntimeError(f"Помилка потоку: {label}") from errors[0]
        s = stats(lat)
        s["throughput_ops_s"] = sum(counts) / seconds
        s["workers"] = workers
        out[label] = s

    def pg_assembled():
        c = pg_connect()
        return (lambda vid: assemble(c.execute(FLAT_VERSION_SQL, (vid,)).fetchall())), c.close

    def pg_json():
        c = pg_connect()
        return (lambda vid: c.execute(JSON_AGG_SQL, (vid,)).fetchone()), c.close

    def mongo_find():
        return (lambda vid: ctx.col.find_one({"_id": vid})), (lambda: None)

    for label, factory in (("sql flat + збирання", pg_assembled), ("sql jsonb", pg_json),
                           ("mongo find_one(_id)", mongo_find)):
        log(f"  конкурентність: {label} ({workers} потоків, {seconds} с)")
        run(label, factory)
    return out


# ---------------------------------------------------------------- плани виконання
def save_plans(ctx):
    d = os.path.join(OUT_DIR, "plans")
    os.makedirs(d, exist_ok=True)
    vid = ctx.pools["versions"][0]
    cid = ctx.pools["cohorts"][0]
    old, new = ctx.pools["pairs"][0]
    plans = {
        "pg_load_structure": (FLAT_VERSION_SQL, (vid,)),
        "pg_load_structure_jsonb": (JSON_AGG_SQL, (vid,)),
        "pg_progress_live_view": (PROGRESS_LIVE_VIEW, (cid,)),
        "pg_progress_version_join": (PROGRESS_VERSION_JOIN, (cid,)),
        "pg_progress_version_cached": (PROGRESS_VERSION_CACHED, (cid,)),
        "pg_diff": (DIFF_SQL, (old, new)),
    }
    for name, (sql, params) in plans.items():
        rows = ctx.pg.execute("EXPLAIN (ANALYZE, BUFFERS) " + sql, params).fetchall()
        with open(os.path.join(d, name + ".txt"), "w") as f:
            f.write("\n".join(r[0] for r in rows))
    for name, cmd in {
        "mongo_find_by_id": {"find": MONGO_COLLECTION, "filter": {"_id": vid}},
        "mongo_find_by_course_version": {"find": MONGO_COLLECTION, "filter": {"courseId": ctx.bench_courses[0], "version": 2}},
    }.items():
        res = ctx.db.command({"explain": cmd, "verbosity": "executionStats"})
        with open(os.path.join(d, name + ".json"), "w") as f:
            f.write(json_util.dumps(res, indent=2))
    log(f"  плани збережено в {d}")


# ---------------------------------------------------------------- звіт
def fmt_bytes(n):
    return f"{n / 1024 / 1024:.1f} МБ"


def write_report(ctx):
    r = ctx.results
    lines = ["# Результати бенчмарка", "", "## Середовище та дані", ""]
    for k, v in ctx.dataset.items():
        lines.append(f"- {k}: {v}")
    lines.append("")
    titles = {
        "s1_load_structure": "Сценарій 1. Завантаження структури опублікованої версії курсу",
        "s2_cohort_progress": "Сценарій 2. Прогрес усієї когорти",
        "s3_publish": "Сценарій 3. Публікація нової версії курсу (запис)",
        "s4_diff": "Сценарій 4. Дифф двох послідовних версій",
        "s6_concurrency": "Сценарій 6. Конкурентне читання структури версії",
    }
    for key, title in titles.items():
        if key not in r:
            continue
        lines += [f"## {title}", "", "| Варіант | n | медіана, мс | p95, мс | p99, мс | середнє, мс |"
                  + (" ops/с (паралельно) |" if key == "s6_concurrency" else ""),
                  "|---|---|---|---|---|---|" + ("---|" if key == "s6_concurrency" else "")]
        for name, s in r[key].items():
            row = (f"| {name} | {s['n']} | {s['median_ms']:.2f} | {s['p95_ms']:.2f} | "
                   f"{s['p99_ms']:.2f} | {s['mean_ms']:.2f} |")
            if key == "s6_concurrency":
                row += f" {s['throughput_ops_s']:.0f} |"
            lines.append(row)
        lines.append("")
    if "s2_drift" in r:
        d = r["s2_drift"]
        lines += ["## Дрейф прогресу (чому потрібні версії)", "",
                  f"З {d['enrollments_checked']} перевірених зарахувань прогрес за ЖИВОЮ структурою курсу "
                  f"відрізняється від прогресу за версією когорти у {d['progress_differs']} "
                  f"({d['share'] * 100:.1f}%).", ""]
    if "s5_size" in r:
        s = r["s5_size"]
        lines += ["## Сценарій 5. Розмір на диску", "", "| Сховище | Дані | Індекси | Разом |", "|---|---|---|---|"]
        pdat = sum(t["table_bytes"] for t in s["postgres"].values())
        pidx = sum(t["index_bytes"] for t in s["postgres"].values())
        lines.append(f"| PostgreSQL (5 таблиць) | {fmt_bytes(pdat)} | {fmt_bytes(pidx)} | {fmt_bytes(s['postgres_total_bytes'])} |")
        m = s["mongo"]
        lines.append(f"| MongoDB (стиснуто) | {fmt_bytes(m['storage_bytes'])} | {fmt_bytes(m['index_bytes'])} | {fmt_bytes(m['total_bytes'])} |")
        lines += ["", f"Документів: {m['documents']}, середній розмір документа: "
                      f"{(m['avg_doc_bytes'] or 0) / 1024:.1f} КБ, нестиснутий розмір колекції: "
                      f"{fmt_bytes(m['uncompressed_bytes'])}.", ""]
    path = os.path.join(OUT_DIR, "results.md")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    with open(os.path.join(OUT_DIR, "results.json"), "w") as f:
        json.dump({"dataset": ctx.dataset, "results": r}, f, indent=2, default=str)
    log(f"Звіт: {path}")


def plot(ctx):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        log("matplotlib недоступний — графік пропущено")
        return
    keys = [k for k in ("s1_load_structure", "s2_cohort_progress", "s3_publish", "s4_diff")
            if k in ctx.results]
    fig, axes = plt.subplots(len(keys), 1, figsize=(10, 3.2 * len(keys)))
    if len(keys) == 1:
        axes = [axes]
    for ax, key in zip(axes, keys):
        items = [(n, s) for n, s in ctx.results[key].items() if not n.startswith("   ")]
        names = [n for n, _ in items]
        med = [s["median_ms"] for _, s in items]
        p95 = [s["p95_ms"] for _, s in items]
        y = range(len(names))
        ax.barh(y, med, color="#4c78a8", label="медіана")
        ax.plot(p95, y, "k|", markersize=14, label="p95")
        ax.set_yticks(list(y))
        ax.set_yticklabels(names, fontsize=8)
        ax.invert_yaxis()
        ax.set_xlabel("мс")
        ax.set_title(key)
        ax.legend(loc="lower right")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, "benchmark.png"), dpi=130)


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=300)
    ap.add_argument("--warmup", type=int, default=30)
    ap.add_argument("--pool", type=int, default=1000, help="розмір пулу випадкових ключів")
    ap.add_argument("--publish-iterations", type=int, default=100)
    ap.add_argument("--concurrency-seconds", type=int, default=15)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--only", default="", help="через кому: s1,s2,s3,s4,s5,s6")
    ap.add_argument("--no-explain", action="store_true")
    ap.add_argument("--tag", default="", help="підпапка results/<tag> для цього прогону")
    args = ap.parse_args()
    global OUT_DIR
    OUT_DIR = os.path.join(RESULTS_DIR, args.tag) if args.tag else RESULTS_DIR
    want = set(args.only.split(",")) if args.only else {"s1", "s2", "s3", "s4", "s5", "s6"}
    os.makedirs(OUT_DIR, exist_ok=True)

    ctx = Ctx(args)
    pg = ctx.pg
    all_versions = [r[0] for r in pg.execute(
        f"SELECT id FROM lms.course_versions WHERE course_id IN {BENCH_COURSES} ORDER BY id")]
    if not all_versions:
        sys.exit("Немає даних. Запусти generate_data.py")
    ctx.bench_courses = [r[0] for r in pg.execute(f"SELECT id FROM lms.courses WHERE id IN {BENCH_COURSES} ORDER BY id")]
    ctx.pools = {
        "versions": ctx.sample_pool(all_versions, args.pool),
        "cohorts": ctx.sample_pool([r[0] for r in pg.execute(
            "SELECT id FROM lms.cohorts WHERE course_version_id IS NOT NULL")], args.pool),
        "pairs": ctx.sample_pool(pg.execute(
            """SELECT a.id, b.id FROM lms.course_versions a JOIN lms.course_versions b
               ON b.course_id = a.course_id AND b.version = a.version + 1""").fetchall(), args.pool),
    }
    counts = {t: pg.execute(f"SELECT count(*) FROM lms.{t}").fetchone()[0]
              for t in VERSION_TABLES + ["enrollments", "lesson_progress"]}
    ctx.dataset = {
        "PostgreSQL": pg.execute("SHOW server_version").fetchone()[0],
        "shared_buffers": pg.execute("SHOW shared_buffers").fetchone()[0],
        "MongoDB": ctx.mongo.server_info().get("version"),
        "Python": platform.python_version(), "Платформа": platform.platform(),
        "seed": SEED, "ітерацій на варіант": args.iterations, "прогрів": args.warmup,
        "заданий розмір пулу ключів": args.pool,
        "фактичні розміри пулів": {k: len(v) for k, v in ctx.pools.items()}, "тег прогону": args.tag or "(основний)",
        **{f"рядків lms.{k}": v for k, v in counts.items()},
    }
    log(f"Дані: {counts}")
    verify_equivalence(ctx, all_versions)

    steps = [("s1", "s1_load_structure", scenario_load_structure),
             ("s2", "s2_cohort_progress", scenario_cohort_progress),
             ("s4", "s4_diff", scenario_diff),
             ("s3", "s3_publish", scenario_publish),
             ("s5", "s5_size", scenario_size),
             ("s6", "s6_concurrency", scenario_concurrency)]
    for short, key, fn in steps:
        if short in want:
            log(f"Сценарій {short} ...")
            ctx.results[key] = fn(ctx)
    if "s2" in want:
        ctx.results["s2_drift"] = check_progress_drift(ctx)
    if not args.no_explain:
        save_plans(ctx)
    write_report(ctx)
    plot(ctx)


if __name__ == "__main__":
    main()
