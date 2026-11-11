#!/usr/bin/env python3
"""Генерація тестових даних у PostgreSQL (схема lms).

Що створюється (усе детерміновано через seed):
  * студенти, курси BENCH-<n>, модулі, уроки, матеріали, завдання;
  * V версій кожного курсу: між публікаціями структура курсу змінюється
    (перейменування уроку, новий урок з 2 матеріалами, зміна max_score),
    тож версії реально відрізняються, а не є копіями;
  * когорти, прив'язані до версій; зарахування; прогрес уроків;
  * граф пререквізитів (DAG) для Neo4j.

Для швидкості масові вставки йдуть із session_replication_role = replica
(вимикає тригери аудиту/штампів/перевірок). Це потрібно лише для наповнення;
сам бенчмарк працює зі звичайними тригерами. Потрібен суперкористувач.
"""
import argparse
import sys
import time

import psycopg

from config import ACTOR_ID, BENCH_PREFIX, PG_DSN, SEED

PRESETS = {
    # smoke: перевірити, що все працює (хвилина)
    "smoke": dict(courses=100, versions=4, students=300, cohort_size=10),
    # full: основний прогін для звіту
    "full": dict(courses=2000, versions=10, students=5000, cohort_size=25),
}

BENCH_COURSES = f"(SELECT id FROM lms.courses WHERE code LIKE '{BENCH_PREFIX}%')"


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run(conn, sql, label=None):
    t = time.perf_counter()
    cur = conn.execute(sql)
    n = cur.rowcount if cur.rowcount is not None and cur.rowcount >= 0 else ""
    if label:
        log(f"{label}: {n} рядків, {time.perf_counter() - t:.1f} с")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", choices=PRESETS, default="full")
    ap.add_argument("--courses", type=int)
    ap.add_argument("--versions", type=int)
    ap.add_argument("--students", type=int)
    ap.add_argument("--cohort-size", type=int)
    a = ap.parse_args()
    p = dict(PRESETS[a.preset])
    for key in ("courses", "versions", "students"):
        if getattr(a, key) is not None:
            p[key] = getattr(a, key)
    if a.cohort_size is not None:
        p["cohort_size"] = a.cohort_size
    if p["students"] < p["cohort_size"]:
        sys.exit("students має бути >= cohort_size")
    log(f"Параметри: {p}, seed={SEED}")

    conn = psycopg.connect(PG_DSN, autocommit=True)
    exists = conn.execute(
        f"SELECT count(*) FROM lms.courses WHERE code LIKE '{BENCH_PREFIX}%'").fetchone()[0]
    if exists:
        sys.exit("Тестові курси вже існують. Очисти БД: docker compose down -v && ./run_all.sh")

    conn.execute("SET session_replication_role = replica")  # потрібен superuser
    conn.execute(f"SELECT set_config('lms.actor_id', '{ACTOR_ID}', false)")
    conn.execute(f"SELECT setseed({(SEED % 1000) / 1000.0})")
    t0 = time.perf_counter()

    run(conn, f"""
        INSERT INTO lms.users(role_id, email, full_name)
        SELECT (SELECT id FROM lms.roles WHERE code = 'student'),
               'bench_student' || i || '@example.com', 'Bench Student ' || i
        FROM generate_series(1, {p['students']}) i""", "студенти (users)")
    run(conn, """
        INSERT INTO lms.student_profiles(user_id, student_number)
        SELECT id, 'BENCH-S' || substr(email, 14, length(email) - 25)
        FROM lms.users WHERE email LIKE 'bench_student%@example.com'""", "student_profiles")

    run(conn, f"""
        INSERT INTO lms.courses(category_id, code, title, description, status, updated_by)
        SELECT (SELECT min(id) FROM lms.categories) + (i % 2),
               '{BENCH_PREFIX}' || lpad(i::text, 5, '0'), 'Bench course ' || i,
               'Generated course for benchmark', 'published', {ACTOR_ID}
        FROM generate_series(1, {p['courses']}) i""", "курси")
    run(conn, f"""
        INSERT INTO lms.modules(course_id, title, position, updated_by)
        SELECT c.id, 'Module ' || g, g, {ACTOR_ID}
        FROM lms.courses c CROSS JOIN generate_series(1, 6) g
        WHERE c.code LIKE '{BENCH_PREFIX}%'""", "модулі (6 на курс)")
    run(conn, f"""
        INSERT INTO lms.lessons(module_id, title, content, duration_minutes, position, updated_by)
        SELECT m.id, 'Lesson ' || m.position || '.' || g, repeat(md5(random()::text), 12),
               10 + (g * 5), g, {ACTOR_ID}
        FROM lms.modules m CROSS JOIN generate_series(1, 6) g
        WHERE m.course_id IN {BENCH_COURSES}""", "уроки (6 на модуль)")
    run(conn, f"""
        INSERT INTO lms.materials(lesson_id, title, url, kind)
        SELECT l.id, 'Material ' || g, 'https://example.com/m/' || l.id || '/' || g,
               (ARRAY['document','video','link'])[1 + (g + l.id::int) % 3]
        FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id
        CROSS JOIN generate_series(1, 2) g
        WHERE m.course_id IN {BENCH_COURSES}""", "матеріали (2 на урок)")
    run(conn, f"""
        INSERT INTO lms.assignments(lesson_id, title, description, max_score, updated_by)
        SELECT l.id, 'Assignment for lesson ' || l.id, 'Generated assignment',
               (ARRAY[10, 20, 100])[1 + l.id::int % 3], {ACTOR_ID}
        FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id
        WHERE m.course_id IN {BENCH_COURSES} AND l.position % 3 = 0""", "завдання")

    for r in range(1, p["versions"] + 1):
        if r > 1:
            mp, lp = (r % 6) + 1, ((r * 2) % 6) + 1
            run(conn, f"""
                UPDATE lms.lessons l
                SET title = 'Lesson ' || m.position || '.' || l.position || ' rev ' || {r},
                    content = repeat(md5(random()::text), 12), updated_by = {ACTOR_ID}
                FROM lms.modules m
                WHERE m.id = l.module_id AND m.course_id IN {BENCH_COURSES}
                  AND m.position = {mp} AND l.position = {lp}""", f"[v{r}] зміна уроку")
            run(conn, f"""
                INSERT INTO lms.lessons(module_id, title, content, duration_minutes, position, updated_by)
                SELECT m.id, 'Added in rev {r}', repeat(md5(random()::text), 12), 15,
                       (SELECT max(position) + 1 FROM lms.lessons x WHERE x.module_id = m.id),
                       {ACTOR_ID}
                FROM lms.modules m
                WHERE m.course_id IN {BENCH_COURSES} AND m.position = 1""", f"[v{r}] новий урок")
            run(conn, f"""
                INSERT INTO lms.materials(lesson_id, title, url, kind)
                SELECT l.id, 'Material ' || g, 'https://example.com/m/' || l.id || '/' || g, 'link'
                FROM lms.lessons l CROSS JOIN generate_series(1, 2) g
                WHERE l.title = 'Added in rev {r}'""", f"[v{r}] матеріали нового уроку")
            run(conn, f"""
                UPDATE lms.assignments a SET max_score = a.max_score + 5, updated_by = {ACTOR_ID}
                FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id
                WHERE a.lesson_id = l.id AND m.course_id IN {BENCH_COURSES}
                  AND m.position = 2 AND l.position = 3""", f"[v{r}] зміна max_score")
        t = time.perf_counter()
        conn.execute(f"""
            DO $$
            DECLARE c record; v bigint;
            BEGIN
                FOR c IN SELECT id FROM lms.courses WHERE code LIKE '{BENCH_PREFIX}%' ORDER BY id LOOP
                    CALL lms.sp_publish_course_version(c.id, v);
                END LOOP;
            END $$""")
        log(f"[v{r}] опубліковано версії всіх курсів: {time.perf_counter() - t:.1f} с")

    run(conn, f"""
        INSERT INTO lms.cohorts(course_id, name, starts_on, ends_on, capacity, status,
                                updated_by, course_version_id)
        SELECT cv.course_id, n.name, current_date - 30, current_date + 60, 40, 'open',
               {ACTOR_ID}, cv.id
        FROM lms.course_versions cv
        JOIN (VALUES ('Cohort A', 0), ('Cohort B', 1)) AS n(name, back) ON true
        WHERE cv.course_id IN {BENCH_COURSES}
          AND cv.version = greatest(1, {p['versions']} - n.back)""", "когорти (A = остання версія, B = попередня)")
    run(conn, f"""
        WITH s AS (
            SELECT array_agg(user_id ORDER BY user_id) arr, count(*) n
            FROM lms.student_profiles WHERE student_number LIKE 'BENCH-S%'
        )
        INSERT INTO lms.enrollments(cohort_id, student_id, status, updated_by)
        SELECT h.id, s.arr[1 + ((h.id * 37 + g) % s.n)], 'active', {ACTOR_ID}
        FROM lms.cohorts h CROSS JOIN generate_series(1, {p['cohort_size']}) g CROSS JOIN s
        WHERE h.course_id IN {BENCH_COURSES}""", "зарахування")
    run(conn, f"""
        INSERT INTO lms.lesson_progress(enrollment_id, lesson_id)
        SELECT e.id, lv.source_lesson_id
        FROM lms.enrollments e
        JOIN lms.cohorts h ON h.id = e.cohort_id
        JOIN lms.module_versions mv ON mv.course_version_id = h.course_version_id
        JOIN lms.lesson_versions lv ON lv.module_version_id = mv.id
        WHERE h.course_id IN {BENCH_COURSES}
          AND random() < ((e.id % 10) + 1) / 10.0""", "прогрес уроків")
    run(conn, f"""
        WITH bc AS MATERIALIZED (
            SELECT id, row_number() OVER (ORDER BY id) AS n
            FROM lms.courses WHERE code LIKE '{BENCH_PREFIX}%')
        INSERT INTO lms.course_prerequisites(course_id, prerequisite_id)
        SELECT c.id, p.id
        FROM bc c CROSS JOIN generate_series(1, 3) k
        JOIN bc p ON p.n = c.n - 1 - (k * 7 + (c.n * 13) % 11)
        ON CONFLICT DO NOTHING""", "пререквізити (DAG)")

    conn.execute("SET session_replication_role = origin")
    for tab in ("users", "student_profiles", "courses", "modules", "lessons", "materials",
                "assignments", "course_versions", "module_versions", "lesson_versions",
                "material_versions", "assignment_versions", "cohorts", "enrollments",
                "lesson_progress", "course_prerequisites"):
        conn.execute(f"ANALYZE lms.{tab}")
    log(f"Готово за {time.perf_counter() - t0:.0f} с")
    for tab in ("course_versions", "module_versions", "lesson_versions", "material_versions",
                "assignment_versions", "cohorts", "enrollments", "lesson_progress",
                "course_prerequisites"):
        n = conn.execute(f"SELECT count(*) FROM lms.{tab}").fetchone()[0]
        log(f"  lms.{tab}: {n}")


if __name__ == "__main__":
    main()
