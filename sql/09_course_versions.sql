-- Незмінні версії курсу (SQL-еквівалент документа course_versions у MongoDB).
-- Запускати ПІСЛЯ 00_installation.sql.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE lms.course_versions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id bigint NOT NULL REFERENCES lms.courses(id),
    version integer NOT NULL CHECK (version > 0),
    published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    published_by bigint NOT NULL REFERENCES lms.users(id),
    -- Порахувано під час публікації (як lessonCount / totalMaxScore у документі).
    lesson_count integer NOT NULL CHECK (lesson_count >= 0),
    total_max_score numeric(9,2) NOT NULL CHECK (total_max_score >= 0),
    UNIQUE (course_id, version)
);

-- source_*_id навмисно БЕЗ FK: це знімок, а не жива залежність.
CREATE TABLE lms.module_versions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_version_id bigint NOT NULL REFERENCES lms.course_versions(id),
    source_module_id bigint NOT NULL,
    title varchar(200) NOT NULL,
    position integer NOT NULL CHECK (position > 0),
    UNIQUE (course_version_id, position)
);

CREATE TABLE lms.lesson_versions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module_version_id bigint NOT NULL REFERENCES lms.module_versions(id),
    source_lesson_id bigint NOT NULL,
    title varchar(200) NOT NULL,
    content text NOT NULL DEFAULT '',
    duration_minutes integer NOT NULL CHECK (duration_minutes > 0),
    position integer NOT NULL CHECK (position > 0),
    UNIQUE (module_version_id, position)
);

CREATE TABLE lms.material_versions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lesson_version_id bigint NOT NULL REFERENCES lms.lesson_versions(id),
    title varchar(200) NOT NULL,
    url text NOT NULL CHECK (url ~ '^https?://'),
    kind varchar(20) NOT NULL CHECK (kind IN ('document', 'video', 'link'))
);

CREATE TABLE lms.assignment_versions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lesson_version_id bigint NOT NULL REFERENCES lms.lesson_versions(id),
    source_assignment_id bigint NOT NULL,
    title varchar(200) NOT NULL,
    max_score numeric(7,2) NOT NULL CHECK (max_score > 0)
);

-- Когорта вчиться за конкретною версією (NULL допускається для старих когорт).
ALTER TABLE lms.cohorts ADD COLUMN course_version_id bigint REFERENCES lms.course_versions(id);

-- Індекси на FK, яких ще немає. Решту покривають префікси UNIQUE-індексів:
--   module_versions(course_version_id, ...), lesson_versions(module_version_id, ...)
--   course_versions(course_id, version)
CREATE INDEX ix_material_versions_lesson ON lms.material_versions(lesson_version_id);
CREATE INDEX ix_assignment_versions_lesson ON lms.assignment_versions(lesson_version_id);
CREATE INDEX ix_cohorts_course_version ON lms.cohorts(course_version_id);

-- Опублікована версія незмінна.
CREATE FUNCTION lms.forbid_version_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Published course versions are immutable (%)', TG_TABLE_NAME;
END;
$$;

DO $$
DECLARE tab text;
BEGIN
    FOREACH tab IN ARRAY ARRAY['course_versions', 'module_versions', 'lesson_versions',
        'material_versions', 'assignment_versions'] LOOP
        EXECUTE format('CREATE TRIGGER immutable BEFORE UPDATE OR DELETE ON lms.%I
            FOR EACH ROW EXECUTE FUNCTION lms.forbid_version_change()', tab);
    END LOOP;
END;
$$;

-- Публікація версії: копіює поточну структуру курсу set-based запитами.
-- Потрібен встановлений актор: SELECT set_config('lms.actor_id', '1', false);
CREATE PROCEDURE lms.sp_publish_course_version(p_course bigint, INOUT p_version_id bigint DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE next_version integer;
BEGIN
    PERFORM lms.require_editor(p_course);
    -- Блокуємо рядок курсу, щоб дві публікації не отримали однаковий номер версії.
    PERFORM 1 FROM lms.courses WHERE id = p_course AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Course % not found or deleted', p_course;
    END IF;

    SELECT coalesce(max(version), 0) + 1 INTO next_version
    FROM lms.course_versions WHERE course_id = p_course;

    INSERT INTO lms.course_versions(course_id, version, published_by, lesson_count, total_max_score)
    SELECT p_course, next_version, lms.current_actor(),
        (SELECT count(*) FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id
         WHERE m.course_id = p_course),
        (SELECT coalesce(sum(a.max_score), 0) FROM lms.assignments a
         JOIN lms.lessons l ON l.id = a.lesson_id JOIN lms.modules m ON m.id = l.module_id
         WHERE m.course_id = p_course AND NOT a.is_deleted)
    RETURNING id INTO p_version_id;

    WITH new_modules AS (
        INSERT INTO lms.module_versions(course_version_id, source_module_id, title, position)
        SELECT p_version_id, m.id, m.title, m.position
        FROM lms.modules m WHERE m.course_id = p_course
        RETURNING id, source_module_id
    )
    INSERT INTO lms.lesson_versions(module_version_id, source_lesson_id, title, content,
        duration_minutes, position)
    SELECT nm.id, l.id, l.title, l.content, l.duration_minutes, l.position
    FROM lms.lessons l JOIN new_modules nm ON nm.source_module_id = l.module_id;

    INSERT INTO lms.material_versions(lesson_version_id, title, url, kind)
    SELECT lv.id, mt.title, mt.url, mt.kind
    FROM lms.materials mt
    JOIN lms.lesson_versions lv ON lv.source_lesson_id = mt.lesson_id
    JOIN lms.module_versions mv ON mv.id = lv.module_version_id
    WHERE mv.course_version_id = p_version_id;

    INSERT INTO lms.assignment_versions(lesson_version_id, source_assignment_id, title, max_score)
    SELECT lv.id, a.id, a.title, a.max_score
    FROM lms.assignments a
    JOIN lms.lesson_versions lv ON lv.source_lesson_id = a.lesson_id
    JOIN lms.module_versions mv ON mv.id = lv.module_version_id
    WHERE mv.course_version_id = p_version_id AND NOT a.is_deleted;
END;
$$;

COMMIT;
