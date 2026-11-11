#!/usr/bin/env python3
"""Вставляє фактичні full-результати в README. Не редагує сирі results.*."""
import re
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def compare(a, b):
    if a['median_ms'] * 1.2 <= b['median_ms'] and a['p95_ms'] <= b['p95_ms']:
        return 'A'
    if b['median_ms'] * 1.2 <= a['median_ms'] and b['p95_ms'] <= a['p95_ms']:
        return 'B'
    return 'паритет'


def pair(rows, a, b):
    names = list(rows)
    x, y = names[a], names[b]
    verdict = compare(rows[x], rows[y])
    winner = x if verdict == 'A' else y if verdict == 'B' else 'паритет'
    return f'«{x}» проти «{y}»: **{winner}** за критерієм 5.3.'


def analysis(data, folder):
    r = data['results']
    plan = f'{folder}/plans'
    lines = ['#### Інтерпретація сценаріїв', '']
    s = r['s1_load_structure']; v = list(s.values())
    lines += ['**1. Структура версії.** ' + pair(s, 1, 3) + ' ' + pair(s, 2, 3),
              'Гіпотеза порівнянності для SQL зі збиранням у Python і Mongo ' +
              ('підтвердилась: паритет.' if compare(v[1], v[3]) == 'паритет' else 'не підтвердилась: є перевага за зафіксованим критерієм.') +
              f' SQL має з’єднати окремі рядки, а Mongo повертає вкладений документ. Фактичні оператори й кількість оброблених рядків: [SQL]({plan}/pg_load_structure.txt), [SQL jsonb]({plan}/pg_load_structure_jsonb.txt), [Mongo]({plan}/mongo_find_by_id.json). Плани пояснюють роботу сервера, але не вимірюють окремо передачу даних і декодування Python.', '']
    s = r['s2_cohort_progress']; v = list(s.values())
    success = compare(v[1],v[0]) == 'A' and compare(v[2],v[0]) == 'A' and compare(v[3],v[2]) != 'A'
    lines += ['**2. Прогрес когорти.** ' + ' '.join(pair(s,a,b) for a,b in [(1,0),(2,0),(2,3)]),
              'Сукупна гіпотеза ' + ('підтвердилась.' if success else 'не підтвердилась повністю; висновки для окремих пар наведені вище.') +
              f' Готовий lesson_count прибирає підрахунок знаменника; гібрид додає мережевий запит Mongo. Порівняти фактичну роботу можна у планах [поточної View]({plan}/pg_progress_live_view.txt), [JOIN]({plan}/pg_progress_version_join.txt), [готового знаменника]({plan}/pg_progress_version_cached.txt). View з живим знаменником має іншу семантику; різниця прогресу наведена в таблицях як окремий результат.', '']
    s = r['s3_publish']; v = list(s.values())
    lines += ['**3. Публікація.** ' + ' '.join(pair(s,a,b) for a,b in [(0,2),(0,3),(0,1)]),
              'Гіпотеза швидшого окремого Mongo insert ' + ('підтвердилась.' if compare(v[2],v[0]) == 'A' else 'не підтвердилась за критерієм 5.3.') +
              ' Гіпотеза суттєвої вартості SQL-аудиту ' + ('підтвердилась.' if compare(v[0],v[1]) == 'A' else 'не підтвердилась за критерієм 5.3.') +
              ' Наскрізний Mongo-запис додатково читає PostgreSQL і збирає документ. Аудит створює рядок журналу для кожного вставленого SQL-рядка. Прямий план CALL та окремий план наскрізної публікації цим бенчмарком не зберігаються; причинний висновок про їхню точну частку часу за планами зробити не можна. Обидва SQL-варіанти і обидва Mongo-варіанти залишені у звіті.', '']
    s = r['s4_diff']; v = list(s.values()); result = compare(v[0],v[1])
    lines += ['**4. Дифф уроків.** ' + pair(s,0,1),
              'Гіпотеза переваги або паритету SQL ' + ('підтвердилась.' if result != 'B' else 'не підтвердилась.') +
              f' SQL повертає тільки змінені ідентифікатори, Mongo читає два документи і порівнює їх у Python. Див. [FULL JOIN]({plan}/pg_diff.txt) і [доступ до документа]({plan}/mongo_find_by_id.json). Це пояснення різниці обсягу роботи; воно не гарантує переможця на іншому наборі даних.', '']
    s = r['s5_size']; pg = s['postgres_total_bytes']; mongo = s['mongo']['total_bytes']
    lines += [f'**5. Розмір.** PostgreSQL: {pg/1024**2:.2f} MiB; MongoDB: {mongo/1024**2:.2f} MiB. Менше місця займає ' + ('MongoDB.' if mongo < pg else 'PostgreSQL.' if pg < mongo else 'жодне: значення однакові.') +
              ' Початкова передумова про нестисливий md5-контент некоректна: генератор повторює один md5 12 разів. Тому гіпотезу «Mongo не виграє від стиснення» цей дослід не підтверджує і не ізолює. EXPLAIN не пояснює дисковий розмір: джерела — pg_table_size, pg_indexes_size та collStats; WAL, журнал Mongo і спільні дані не включені. Критерій медіана/p95 до байтів не застосовується.', '']
    s = r['s6_concurrency']
    lines += ['**6. Конкурентне читання.** ' + pair(s,0,2) + ' ' + pair(s,1,2),
              'Throughput кожного варіанта наведено в таблиці. Гіпотеза обмеження клієнтом не доведена окремо: профілювання CPU клієнта не виконувалося. Вісім потоків запускають ті самі запити, що у сценарії 1, тому відповідні плани пов’язані вище; вони отримані поза конкурентним запуском. Серії виконуються послідовно, без повторних незалежних прогонів; це оцінка цього стенду, а не граничної продуктивності СУБД.', '']
    lines += ['#### Факти зі збережених планів', '',
              '| План | Рядків на виході | Shared buffer hits | Execution Time мс |',
              '|---|---|---|---|']
    for name in ['pg_load_structure','pg_load_structure_jsonb','pg_progress_live_view','pg_progress_version_join','pg_progress_version_cached','pg_diff']:
        content = (ROOT / plan / (name+'.txt')).read_text()
        rows = re.search(r'actual time=.*?rows=(\d+)', content)
        hits = re.search(r'Buffers: shared hit=(\d+)', content)
        elapsed = re.search(r'Execution Time: ([0-9.]+) ms', content)
        lines.append(f"| [{name}]({plan}/{name}.txt) | {rows[1] if rows else '—'} | {hits[1] if hits else '—'} | {elapsed[1] if elapsed else '—'} |")
    mongo = json.loads((ROOT / plan / 'mongo_find_by_id.json').read_text())
    e = mongo['executionStats']
    lines += ['', f"Mongo використовує {mongo['queryPlanner']['winningPlan']['stage']}: ключів перевірено {e['totalKeysExamined']}, документів {e['totalDocsExamined']}, повернуто {e['nReturned']}. "
              'У SQL-структурі — індексні Nested Loop та Incremental Sort; у диффі — Hash Full Join, який повертає лише 2 зміни. '
              'View прогресу має 1545 buffer hits проти 219 для готового знаменника; jsonb-структура має 331 проти 328 у flat, але додатково будує JSON на сервері. '
              'Це одиничні плани для вибраних ключів, не медіани 300 ітерацій і не повний розподіл причин затримки.', '']
    return '\n'.join(lines)


def main():
    parts = []
    for tag, title in [('', 'Основний пул'), ('large_pool', 'Пул із усього набору')]:
        folder = 'results' + ('/' + tag if tag else '')
        path = ROOT / folder
        data = json.loads((path/'results.json').read_text())
        if data['dataset']['рядків lms.course_versions'] != 20000:
            raise SystemExit('До підсумкового README допускається лише full: 20 000 версій')
        required = {'s1_load_structure','s2_cohort_progress','s3_publish','s4_diff','s5_size','s6_concurrency'}
        if not required <= data['results'].keys():
            raise SystemExit('Не всі сценарії виконано')
        if len(list((path/'plans').glob('*'))) < 8:
            raise SystemExit('Немає всіх планів виконання')
        raw = (path/'results.md').read_text()
        raw = '\n'.join('##'+line if line.startswith('#') else line for line in raw.splitlines())
        parts += [f'### {title}', '', raw, '', f'![Медіана і p95]({folder}/benchmark.png)', '', analysis(data,folder)]
    if not (ROOT/'results/neo4j_demo.md').is_file():
        raise SystemExit('Немає звіту Neo4j')
    readme = ROOT/'README.md'
    s = readme.read_text()
    a = s.index('### 5.4 Результати'); b = s.index('### 5.5',a)
    s = s[:a] + '### 5.4 Результати\n\n' + '\n'.join(parts) + '\n\n' + s[b:]
    readme.write_text(s)
    print('OK: фактичні таблиці та інтерпретація внесені в README 5.4')


if __name__ == '__main__':
    main()
