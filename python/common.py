"""Єдине джерело правди про форму документа course_version.

Той самий SQL і та сама функція assemble() використовуються:
  * у load_mongo.py, щоб Mongo містив ТОЧНО ті самі дані, що й PostgreSQL;
  * у benchmark.py, щоб порівняння було чесним (SQL + збирання вкладеної структури).
"""
from decimal import Decimal

# Плоский запит структури опублікованої версії (5 таблиць).
FLAT_VERSION_SQL = """
SELECT mv.source_module_id, mv.title, mv.position,
       lv.source_lesson_id, lv.title, lv.content, lv.duration_minutes, lv.position,
       mt.title, mt.url, mt.kind,
       av.source_assignment_id, av.title, av.max_score
FROM lms.module_versions mv
JOIN lms.lesson_versions lv ON lv.module_version_id = mv.id
LEFT JOIN lms.material_versions mt ON mt.lesson_version_id = lv.id
LEFT JOIN lms.assignment_versions av ON av.lesson_version_id = lv.id
WHERE mv.course_version_id = %s
ORDER BY mv.position, lv.position, mt.id
"""

# Той самий вигляд, але з "живих" таблиць курсу (для публікації з боку Mongo).
FLAT_LIVE_SQL = """
SELECT m.id, m.title, m.position,
       l.id, l.title, l.content, l.duration_minutes, l.position,
       mt.title, mt.url, mt.kind,
       a.id, a.title, a.max_score
FROM lms.modules m
JOIN lms.lessons l ON l.module_id = m.id
LEFT JOIN lms.materials mt ON mt.lesson_id = l.id
LEFT JOIN lms.assignments a ON a.lesson_id = l.id AND NOT a.is_deleted
WHERE m.course_id = %s
ORDER BY m.position, l.position, mt.id
"""

# Збирання всього документа на боці сервера (jsonb).
JSON_AGG_SQL = """
SELECT jsonb_build_object(
  'modules', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'moduleId', mv.source_module_id, 'position', mv."position", 'title', mv.title,
      'lessons', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
          'lessonId', lv.source_lesson_id, 'title', lv.title, 'content', lv.content,
          'durationMinutes', lv.duration_minutes, 'position', lv."position",
          'materials', coalesce((
            SELECT jsonb_agg(jsonb_build_object('title', mt.title, 'url', mt.url, 'kind', mt.kind)
                             ORDER BY mt.id)
            FROM lms.material_versions mt WHERE mt.lesson_version_id = lv.id), '[]'::jsonb),
          'assignment', (
            SELECT jsonb_build_object('id', av.source_assignment_id, 'title', av.title,
                                      'maxScore', av.max_score)
            FROM lms.assignment_versions av WHERE av.lesson_version_id = lv.id LIMIT 1)
        ) ORDER BY lv."position")
        FROM lms.lesson_versions lv WHERE lv.module_version_id = mv.id), '[]'::jsonb)
    ) ORDER BY mv."position")
    FROM lms.module_versions mv WHERE mv.course_version_id = cv.id), '[]'::jsonb))
FROM lms.course_versions cv WHERE cv.id = %s
"""


def assemble(rows):
    """Плоскі рядки -> список модулів із вкладеними уроками, матеріалами і завданням."""
    modules, mod_by_id, lesson_by_id = [], {}, {}
    for (mid, mtitle, mpos, lid, ltitle, lcontent, ldur, lpos,
         mt_title, mt_url, mt_kind, a_id, a_title, a_score) in rows:
        mod = mod_by_id.get(mid)
        if mod is None:
            mod = {"moduleId": mid, "position": mpos, "title": mtitle, "lessons": []}
            mod_by_id[mid] = mod
            modules.append(mod)
        lesson = lesson_by_id.get(lid)
        if lesson is None:
            lesson = {
                "lessonId": lid, "title": ltitle, "content": lcontent,
                "durationMinutes": ldur, "position": lpos, "materials": [],
                "assignment": None if a_id is None else
                {"id": a_id, "title": a_title, "maxScore": float(a_score)},
            }
            lesson_by_id[lid] = lesson
            mod["lessons"].append(lesson)
        existing = lesson["assignment"]
        if existing is not None and a_id is not None and existing["id"] != a_id:
            raise ValueError("Цей формат версії підтримує лише одне активне завдання на урок")
        if mt_title is not None:
            lesson["materials"].append({"title": mt_title, "url": mt_url, "kind": mt_kind})
    return modules


def lesson_count(modules):
    return sum(len(m["lessons"]) for m in modules)


def total_max_score(modules):
    total = Decimal(0)
    for m in modules:
        for l in m["lessons"]:
            if l["assignment"]:
                total += Decimal(str(l["assignment"]["maxScore"]))
    return float(total)


def build_document(cv_id, course_id, version, published_at, published_by, modules):
    return {
        "_id": cv_id, "courseId": course_id, "version": version,
        "publishedAt": published_at, "publishedBy": published_by,
        "lessonCount": lesson_count(modules), "totalMaxScore": total_max_score(modules),
        "modules": modules,
    }


def percentile(sorted_values, p):
    if not sorted_values:
        return float("nan")
    k = (len(sorted_values) - 1) * p
    f = int(k)
    c = min(f + 1, len(sorted_values) - 1)
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)
