# Neo4j: базові запити (п. 6)

## 1. CREATE: новий курс і зв'язок (MERGE — повтор не дублює)

```cypher
MERGE (d:Course {id: -1}) SET d.code = 'DEMO-1', d.title = 'Demo course' WITH d MATCH (p:Course {code: $prereq}) MERGE (d)-[:REQUIRES]->(p) RETURN d.code AS code, p.code AS requires
```

Параметри: `{'prereq': 'BENCH-00001'}`

Рядків: 1, час: 181.1 мс. Перші рядки:

```
{'code': 'DEMO-1', 'requires': 'BENCH-00001'}
```

## 2. READ: курс за кодом

```cypher
MATCH (c:Course {code: $code}) RETURN c.id AS id, c.code AS code, c.title AS title
```

Параметри: `{'code': 'BENCH-02000'}`

Рядків: 1, час: 65.3 мс. Перші рядки:

```
{'id': 2000, 'code': 'BENCH-02000', 'title': 'Bench course 2000'}
```

## 3a. FILTER: курси без пререквізитів (точки входу)

```cypher
MATCH (c:Course) WHERE NOT (c)-[:REQUIRES]->() RETURN count(c) AS entry_courses
```

Рядків: 1, час: 139.4 мс. Перші рядки:

```
{'entry_courses': 13}
```

## 3b. FILTER: курси з ≥ 3 прямими пререквізитами

```cypher
MATCH (c:Course)-[:REQUIRES]->(p) WITH c, count(p) AS n WHERE n >= 3 RETURN c.code AS code, n ORDER BY n DESC, code LIMIT 5
```

Рядків: 5, час: 173.2 мс. Перші рядки:

```
{'code': 'BENCH-00028', 'n': 3}
{'code': 'BENCH-00029', 'n': 3}
{'code': 'BENCH-00030', 'n': 3}
{'code': 'BENCH-00031', 'n': 3}
{'code': 'BENCH-00032', 'n': 3}
```

## 4. UPDATE: зміна властивості

```cypher
MATCH (d:Course {id: -1}) SET d.title = 'Demo course (updated)' RETURN d.title AS title
```

Рядків: 1, час: 54.6 мс. Перші рядки:

```
{'title': 'Demo course (updated)'}
```

## 5. DELETE: видалення демо-вершини разом зі зв'язками

```cypher
MATCH (d:Course {id: -1}) DETACH DELETE d RETURN count(*) AS deleted
```

Рядків: 1, час: 86.1 мс. Перші рядки:

```
{'deleted': 1}
```

## 6. Транзитивні пререквізити (до 6 кроків)

```cypher
MATCH (c:Course {code: $code})-[:REQUIRES*1..6]->(p:Course) RETURN DISTINCT p.code AS prerequisite ORDER BY prerequisite
```

Параметри: `{'code': 'BENCH-02000'}`

Рядків: 98, час: 111.0 мс. Перші рядки:

```
{'prerequisite': 'BENCH-01835'}
{'prerequisite': 'BENCH-01839'}
{'prerequisite': 'BENCH-01842'}
{'prerequisite': 'BENCH-01843'}
{'prerequisite': 'BENCH-01846'}
{'prerequisite': 'BENCH-01849'}
{'prerequisite': 'BENCH-01850'}
{'prerequisite': 'BENCH-01853'}
```

## 7. Зворотний обхід: які курси залежать від цього (до 3 кроків)

```cypher
MATCH (p:Course {code: $code})<-[:REQUIRES*1..3]-(c:Course) RETURN count(DISTINCT c) AS dependents
```

Параметри: `{'code': 'BENCH-00001'}`

Рядків: 1, час: 59.6 мс. Перші рядки:

```
{'dependents': 31}
```

## 8a. Найвіддаленіший пререквізит у межах 6 кроків (ціль для шляху)

```cypher
MATCH path = (c:Course {code: $code})-[:REQUIRES*1..6]->(q:Course) RETURN q.code AS target, length(path) AS depth ORDER BY depth DESC, target LIMIT 1
```

Параметри: `{'code': 'BENCH-02000'}`

Рядків: 1, час: 97.3 мс. Перші рядки:

```
{'target': 'BENCH-01835', 'depth': 6}
```

## 8b. Найкоротший шлях між курсами

```cypher
MATCH (a:Course {code: $a}), (b:Course {code: $b}) MATCH path = shortestPath((a)-[:REQUIRES*..30]->(b)) RETURN [n IN nodes(path) | n.code] AS route, length(path) AS hops
```

Параметри: `{'a': 'BENCH-02000', 'b': 'BENCH-01835'}`

Рядків: 1, час: 87.3 мс. Перші рядки:

```
{'route': ['BENCH-02000', 'BENCH-01971', 'BENCH-01945', 'BENCH-01916', 'BENCH-01890', 'BENCH-01861', 'BENCH-01835'], 'hops': 6}
```

## 9. Які курси доступні, якщо пройдено перші 30 (усі пререквізити виконані)

```cypher
MATCH (c:Course) WHERE NOT c.id IN $done AND all(p IN [(c)-[:REQUIRES]->(q) | q] WHERE p.id IN $done) RETURN c.code AS code ORDER BY code LIMIT 10
```

Параметри: `{'done': '[30 id]'}`

Рядків: 10, час: 197.5 мс. Перші рядки:

```
{'code': 'BENCH-00031'}
{'code': 'BENCH-00032'}
{'code': 'BENCH-00033'}
{'code': 'BENCH-00034'}
{'code': 'BENCH-00035'}
{'code': 'BENCH-00036'}
{'code': 'BENCH-00037'}
{'code': 'BENCH-00038'}
```

## Бонус: транзитивні пререквізити, PostgreSQL (рекурсивний CTE) vs Neo4j

Глибина ≤ 6, 100 випадкових курсів, результати збігаються. Це не обов'язкове порівняння (для п. 6 швидкодію міряти не потрібно) — лише ілюстрація, де граф доречний.

| Система | медіана, мс | p95, мс |
|---|---|---|
| PostgreSQL recursive CTE | 0.59 | 1.15 |
| Neo4j variable-length | 2.85 | 6.12 |
