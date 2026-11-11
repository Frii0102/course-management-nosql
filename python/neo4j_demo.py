#!/usr/bin/env python3
"""П. 6: друга NoSQL-база іншого типу — графова (Neo4j).

Граф: (:Course)-[:REQUIRES]->(:Course) побудований з lms.course_prerequisites.
Скрипт (1) імпортує граф ідемпотентно (MERGE), (2) виконує базові запити
(створення, читання, фільтр, оновлення, видалення, обхід, найкоротший шлях,
"які курси доступні"), (3) необов'язково порівнює транзитивні пререквізити
з рекурсивним CTE у PostgreSQL. Результат пишеться в results/neo4j_demo.md.
"""
import argparse
import os
import random
import statistics
import time

import psycopg
from neo4j import GraphDatabase

from common import percentile
from config import BENCH_PREFIX, NEO4J_AUTH, NEO4J_URI, PG_DSN, RESULTS_DIR, SEED

MAX_DEPTH = 6
CTE = f"""
WITH RECURSIVE r(id, depth) AS (
    SELECT prerequisite_id, 1 FROM lms.course_prerequisites WHERE course_id = %s
    UNION
    SELECT cp.prerequisite_id, r.depth + 1
    FROM lms.course_prerequisites cp JOIN r ON cp.course_id = r.id
    WHERE r.depth < {MAX_DEPTH})
SELECT count(DISTINCT id) FROM r"""
CYPHER_CLOSURE = (f"MATCH (c:Course {{id: $id}})-[:REQUIRES*1..{MAX_DEPTH}]->(p:Course) "
                  "RETURN count(DISTINCT p) AS n")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def connect():
    driver = GraphDatabase.driver(NEO4J_URI, auth=NEO4J_AUTH)
    for attempt in range(30):
        try:
            driver.verify_connectivity()
            return driver
        except Exception as e:  # Neo4j стартує до хвилини
            if attempt == 29:
                raise
            log(f"Очікую Neo4j ({e.__class__.__name__}) ...")
            time.sleep(3)


def import_graph(session, pg):
    session.run("CREATE CONSTRAINT course_id_unique IF NOT EXISTS "
                "FOR (c:Course) REQUIRE c.id IS UNIQUE").consume()
    courses = pg.execute("SELECT id, code, title FROM lms.courses WHERE NOT is_deleted "
                         "ORDER BY id").fetchall()
    edges = pg.execute("SELECT course_id, prerequisite_id FROM lms.course_prerequisites").fetchall()
    for i in range(0, len(courses), 1000):
        rows = [{"id": c[0], "code": c[1], "title": c[2]} for c in courses[i:i + 1000]]
        session.run("UNWIND $rows AS r MERGE (c:Course {id: r.id}) "
                    "SET c.code = r.code, c.title = r.title", rows=rows).consume()
    for i in range(0, len(edges), 1000):
        rows = [{"c": e[0], "p": e[1]} for e in edges[i:i + 1000]]
        session.run("UNWIND $rows AS r MATCH (c:Course {id: r.c}), (p:Course {id: r.p}) "
                    "MERGE (c)-[:REQUIRES]->(p)", rows=rows).consume()
    log(f"Імпортовано курсів: {len(courses)}, зв'язків REQUIRES: {len(edges)}")
    return courses


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compare-samples", type=int, default=100,
                    help="скільки курсів порівняти з рекурсивним CTE (0 = пропустити)")
    a = ap.parse_args()
    os.makedirs(RESULTS_DIR, exist_ok=True)
    pg = psycopg.connect(PG_DSN, autocommit=True)
    driver = connect()
    md = ["# Neo4j: базові запити (п. 6)", ""]

    def show(session, title, cypher, **params):
        t = time.perf_counter()
        records = [r.data() for r in session.run(cypher, **params)]
        ms = (time.perf_counter() - t) * 1000
        md.extend([f"## {title}", "", "```cypher", cypher.strip(), "```", ""])
        if params:
            md.append(f"Параметри: `{ {k: (v if not isinstance(v, list) else f'[{len(v)} id]') for k, v in params.items()} }`")
            md.append("")
        md.append(f"Рядків: {len(records)}, час: {ms:.1f} мс. Перші рядки:")
        md.append("")
        md.append("```")
        md.extend(str(r) for r in records[:8])
        md.append("```")
        md.append("")
        log(f"{title}: {len(records)} рядків, {ms:.1f} мс")
        return records

    with driver.session() as s:
        courses = import_graph(s, pg)
        bench = [c for c in courses if c[1].startswith(BENCH_PREFIX)] or courses
        first, last = bench[0], bench[-1]

        show(s, "1. CREATE: новий курс і зв'язок (MERGE — повтор не дублює)",
             "MERGE (d:Course {id: -1}) SET d.code = 'DEMO-1', d.title = 'Demo course' "
             "WITH d MATCH (p:Course {code: $prereq}) MERGE (d)-[:REQUIRES]->(p) "
             "RETURN d.code AS code, p.code AS requires", prereq=first[1])
        show(s, "2. READ: курс за кодом", "MATCH (c:Course {code: $code}) "
             "RETURN c.id AS id, c.code AS code, c.title AS title", code=last[1])
        show(s, "3a. FILTER: курси без пререквізитів (точки входу)",
             "MATCH (c:Course) WHERE NOT (c)-[:REQUIRES]->() RETURN count(c) AS entry_courses")
        show(s, "3b. FILTER: курси з ≥ 3 прямими пререквізитами",
             "MATCH (c:Course)-[:REQUIRES]->(p) WITH c, count(p) AS n WHERE n >= 3 "
             "RETURN c.code AS code, n ORDER BY n DESC, code LIMIT 5")
        show(s, "4. UPDATE: зміна властивості", "MATCH (d:Course {id: -1}) "
             "SET d.title = 'Demo course (updated)' RETURN d.title AS title")
        show(s, "5. DELETE: видалення демо-вершини разом зі зв'язками",
             "MATCH (d:Course {id: -1}) DETACH DELETE d RETURN count(*) AS deleted")
        show(s, f"6. Транзитивні пререквізити (до {MAX_DEPTH} кроків)",
             f"MATCH (c:Course {{code: $code}})-[:REQUIRES*1..{MAX_DEPTH}]->(p:Course) "
             "RETURN DISTINCT p.code AS prerequisite ORDER BY prerequisite", code=last[1])
        show(s, "7. Зворотний обхід: які курси залежать від цього (до 3 кроків)",
             "MATCH (p:Course {code: $code})<-[:REQUIRES*1..3]-(c:Course) "
             "RETURN count(DISTINCT c) AS dependents", code=first[1])
        target = show(s, "8a. Найвіддаленіший пререквізит у межах 6 кроків (ціль для шляху)",
                      f"MATCH path = (c:Course {{code: $code}})-[:REQUIRES*1..{MAX_DEPTH}]->(q:Course) "
                      "RETURN q.code AS target, length(path) AS depth ORDER BY depth DESC, target LIMIT 1",
                      code=last[1])
        if target:
            show(s, "8b. Найкоротший шлях між курсами",
                 "MATCH (a:Course {code: $a}), (b:Course {code: $b}) "
                 "MATCH path = shortestPath((a)-[:REQUIRES*..30]->(b)) "
                 "RETURN [n IN nodes(path) | n.code] AS route, length(path) AS hops",
                 a=last[1], b=target[0]["target"])
        done = [c[0] for c in bench[:30]]
        show(s, "9. Які курси доступні, якщо пройдено перші 30 (усі пререквізити виконані)",
             "MATCH (c:Course) WHERE NOT c.id IN $done "
             "AND all(p IN [(c)-[:REQUIRES]->(q) | q] WHERE p.id IN $done) "
             "RETURN c.code AS code ORDER BY code LIMIT 10", done=done)

        if a.compare_samples:
            rng = random.Random(SEED)
            sample = rng.sample(bench, min(a.compare_samples, len(bench)))
            t_pg, t_neo = [], []
            for c in sample:
                t = time.perf_counter_ns()
                n_pg = pg.execute(CTE, (c[0],)).fetchone()[0]
                t_pg.append((time.perf_counter_ns() - t) / 1e6)
                t = time.perf_counter_ns()
                n_neo = s.run(CYPHER_CLOSURE, id=c[0]).single()["n"]
                t_neo.append((time.perf_counter_ns() - t) / 1e6)
                if n_pg != n_neo:
                    raise SystemExit(f"Різні результати для курсу {c[1]}: PG={n_pg}, Neo4j={n_neo}")
            md.extend(["## Бонус: транзитивні пререквізити, PostgreSQL (рекурсивний CTE) vs Neo4j", "",
                       f"Глибина ≤ {MAX_DEPTH}, {len(sample)} випадкових курсів, результати збігаються. "
                       "Це не обов'язкове порівняння (для п. 6 швидкодію міряти не потрібно) — "
                       "лише ілюстрація, де граф доречний.", "",
                       "| Система | медіана, мс | p95, мс |", "|---|---|---|"])
            for name, v in (("PostgreSQL recursive CTE", t_pg), ("Neo4j variable-length", t_neo)):
                sv = sorted(v)
                md.append(f"| {name} | {percentile(sv, 0.5):.2f} | {percentile(sv, 0.95):.2f} |")
            md.append("")
            log(f"CTE медіана {statistics.median(t_pg):.2f} мс, Neo4j {statistics.median(t_neo):.2f} мс")

    driver.close()
    path = os.path.join(RESULTS_DIR, "neo4j_demo.md")
    with open(path, "w") as f:
        f.write("\n".join(md))
    log(f"Звіт: {path}")


if __name__ == "__main__":
    main()
