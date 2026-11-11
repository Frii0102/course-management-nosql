-- Робочий цикл версіонування через процедури:
--   draft --sp_release_course_version--> published (+ версія N)
--         <--sp_reopen_course-----------  (структуру знову можна змінювати)
--   нова когорта автоматично отримує останню версію курсу;
--   прогрес і здачі приймаються лише для уроків/завдань версії когорти;
--   завершення навчання (sp_finish_enrollment) рахується за версією когорти.
-- Запускати ПІСЛЯ 00_installation.sql, 09_course_versions.sql (09b — за бажанням).
-- Файли 00–09b не змінюються; sp_finish_enrollment з 05 замінюється через
-- CREATE OR REPLACE (див. розділ 6). progress_percent і v_enrollments не змінюються.
--
-- Чому обгортка, а не CREATE OR REPLACE sp_publish_course_version:
--   * sp_publish_course уже перевіряє «є урок і викладач» і робить draft -> published.
--     Обгортка викликає її, а потім робить знімок, тому ці перевірки
--     спрацьовують під час КОЖНОГО випуску, а не лише першого.
--   * sp_publish_course_version лишається такою самою, як під час вимірювань:
--     benchmark.py (сценарій 3) і generate_data.py викликають її напряму для
--     курсів зі статусом 'published'. Якщо додати в неї вимогу draft, ці скрипти
--     перестануть працювати, а виміряна процедура вже не збігатиметься з тією, що у звіті.
--   * Обидва виклики йдуть в одній транзакції: якщо знімок упаде, статус
--     курсу теж відкотиться.
\set ON_ERROR_STOP on
BEGIN;

-- 1. Випуск версії: перевірки + draft -> published + знімок структури.
CREATE PROCEDURE lms.sp_release_course_version(p_course bigint, INOUT p_version_id bigint DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    -- require_editor, FOR UPDATE, «є урок і викладач», status = 'published'
    CALL lms.sp_publish_course(p_course);
    -- номер версії = max + 1 під тим самим блокуванням рядка курсу
    CALL lms.sp_publish_course_version(p_course, p_version_id);
END;
$$;

-- 2. Повернення курсу в чернетку для підготовки наступної версії.
--    Аудит і штамп updated_at/updated_by дають наявні тригери stamp/audit на courses.
CREATE PROCEDURE lms.sp_reopen_course(p_course bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_editor(p_course);
    PERFORM 1 FROM lms.courses WHERE id = p_course AND NOT is_deleted AND status = 'published' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active published course not found'; END IF;
    -- Без жодної версії когорти вчаться за «живою» структурою, і правки одразу
    -- змінили б їм програму. Відкривати можна лише курс, у якого вже є знімок.
    IF NOT EXISTS (SELECT 1 FROM lms.course_versions WHERE course_id = p_course) THEN
        RAISE EXCEPTION 'Course % has no published version: release one before reopening', p_course;
    END IF;
    -- Та сама причина для старих когорт без прив'язки до версії (створених до 09).
    IF EXISTS (SELECT 1 FROM lms.cohorts WHERE course_id = p_course
               AND course_version_id IS NULL AND status <> 'finished') THEN
        RAISE EXCEPTION 'Course % has unfinished cohorts without a fixed version', p_course;
    END IF;
    UPDATE lms.courses SET status = 'draft' WHERE id = p_course;
END;
$$;

-- 3. Когорта прив'язується до версії під час створення.
--    Якщо версій немає — ПОМИЛКА, а не NULL: когорта з NULL навчалася б за живою
--    структурою, і саме цей дрейф (31,3% у тестових даних) ми прибираємо.
--    Версію когорти, яка вже стартувала, змінювати не можна.
CREATE FUNCTION lms.bind_cohort_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.course_version_id IS NOT NULL
        AND NEW.course_version_id IS DISTINCT FROM OLD.course_version_id THEN
        RAISE EXCEPTION 'Cohort % is already bound to course version %', OLD.id, OLD.course_version_id;
    END IF;
    IF TG_OP = 'INSERT' AND NEW.course_version_id IS NULL THEN
        SELECT id INTO NEW.course_version_id FROM lms.course_versions
        WHERE course_id = NEW.course_id ORDER BY version DESC LIMIT 1;
        IF NEW.course_version_id IS NULL THEN
            RAISE EXCEPTION 'Course % has no published version: use sp_release_course_version', NEW.course_id;
        END IF;
    END IF;
    IF NEW.course_version_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM lms.course_versions WHERE id = NEW.course_version_id AND course_id = NEW.course_id) THEN
        RAISE EXCEPTION 'Course version % belongs to another course', NEW.course_version_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER bind_version BEFORE INSERT OR UPDATE OF course_id, course_version_id ON lms.cohorts
FOR EACH ROW EXECUTE FUNCTION lms.bind_cohort_version();

-- 4. Прогрес і здачі — лише в межах версії когорти.
--    Наявний guard_learning_record перевіряє тільки КУРС уроку/завдання; без цієї
--    перевірки студент когорти на v1 міг би позначити урок, який з'явився лише у v2.
--    Когорти без версії (старі, до 09) не перевіряються — для них версії немає.
CREATE FUNCTION lms.guard_version_item() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE version_key bigint;
BEGIN
    SELECT h.course_version_id INTO version_key
    FROM lms.enrollments e JOIN lms.cohorts h ON h.id = e.cohort_id
    WHERE e.id = NEW.enrollment_id;
    IF version_key IS NULL THEN RETURN NEW; END IF;
    IF TG_TABLE_NAME = 'lesson_progress' THEN
        IF NOT EXISTS (SELECT 1 FROM lms.module_versions mv
            JOIN lms.lesson_versions lv ON lv.module_version_id = mv.id
            WHERE mv.course_version_id = version_key AND lv.source_lesson_id = NEW.lesson_id) THEN
            RAISE EXCEPTION 'Lesson % is not part of course version % of this cohort', NEW.lesson_id, version_key;
        END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM lms.module_versions mv
            JOIN lms.lesson_versions lv ON lv.module_version_id = mv.id
            JOIN lms.assignment_versions av ON av.lesson_version_id = lv.id
            WHERE mv.course_version_id = version_key AND av.source_assignment_id = NEW.assignment_id) THEN
            RAISE EXCEPTION 'Assignment % is not part of course version % of this cohort', NEW.assignment_id, version_key;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_version BEFORE INSERT OR UPDATE OF enrollment_id, lesson_id ON lms.lesson_progress
FOR EACH ROW EXECUTE FUNCTION lms.guard_version_item();
CREATE TRIGGER validate_version BEFORE INSERT OR UPDATE OF enrollment_id, assignment_id ON lms.submissions
FOR EACH ROW EXECUTE FUNCTION lms.guard_version_item();

-- 5. Прогрес за версією когорти.
--    lms.progress_percent і v_enrollments свідомо НЕ змінюються: це «жива» семантика,
--    з якою бенчмарк порівнює прогрес за версією (дрейф 31,3%).
--    Чисельник рахує лише уроки версії: обхід іде від версії (індекси на
--    module_versions / lesson_versions) до lesson_progress (UNIQUE (enrollment_id, lesson_id)).
--    Когорта без версії -> стара функція progress_percent.
CREATE FUNCTION lms.progress_percent_by_version(p_enrollment bigint) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN h.course_version_id IS NULL THEN lms.progress_percent(e.id)
        ELSE coalesce(round(100.0 * (
            SELECT count(*) FROM lms.module_versions mv
            JOIN lms.lesson_versions lv ON lv.module_version_id = mv.id
            WHERE mv.course_version_id = h.course_version_id
              AND EXISTS (SELECT 1 FROM lms.lesson_progress p
                          WHERE p.enrollment_id = e.id AND p.lesson_id = lv.source_lesson_id)
        ) / nullif(cv.lesson_count, 0), 2), 0)
    END
    FROM lms.enrollments e JOIN lms.cohorts h ON h.id = e.cohort_id
    LEFT JOIN lms.course_versions cv ON cv.id = h.course_version_id
    WHERE e.id = p_enrollment;
$$;

-- 6. Завершення навчання за версією когорти.
--    CREATE OR REPLACE скидає атрибути, не вказані явно, тому SECURITY DEFINER і
--    search_path (їх у 05 ставив блок DO) записано прямо у визначенні.
--    Права (REVOKE від PUBLIC, GRANT для course_app з 08) при CREATE OR REPLACE зберігаються.
--    Когорта без версії: та сама перевірка, що в 05 (живі уроки й завдання).
CREATE OR REPLACE PROCEDURE lms.sp_finish_enrollment(p_enrollment bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, lms, pg_temp AS $$
DECLARE course_key bigint; current_state text; version_key bigint;
BEGIN
    SELECT c.course_id, e.status, c.course_version_id INTO STRICT course_key, current_state, version_key
    FROM lms.enrollments e JOIN lms.cohorts c ON c.id = e.cohort_id WHERE e.id = p_enrollment FOR UPDATE OF e;
    PERFORM lms.require_editor(course_key);
    IF current_state <> 'active' THEN RAISE EXCEPTION 'Enrollment must be active'; END IF;
    IF lms.progress_percent_by_version(p_enrollment) <> 100 THEN RAISE EXCEPTION 'All lessons must be completed'; END IF;
    IF version_key IS NULL THEN
        IF EXISTS (SELECT 1 FROM lms.assignments a JOIN lms.lessons l ON l.id = a.lesson_id
            JOIN lms.modules m ON m.id = l.module_id
            WHERE m.course_id = course_key AND NOT a.is_deleted AND NOT EXISTS (
                SELECT 1 FROM lms.submissions s WHERE s.assignment_id = a.id AND s.enrollment_id = p_enrollment
                AND s.score >= a.max_score * 0.6)) THEN
            RAISE EXCEPTION 'Every assignment needs a grade of at least 60 percent';
        END IF;
    ELSE
        -- Завдання й max_score беруться зі знімка версії, а не з живого курсу.
        IF EXISTS (SELECT 1 FROM lms.module_versions mv
            JOIN lms.lesson_versions lv ON lv.module_version_id = mv.id
            JOIN lms.assignment_versions av ON av.lesson_version_id = lv.id
            WHERE mv.course_version_id = version_key AND NOT EXISTS (
                SELECT 1 FROM lms.submissions s WHERE s.assignment_id = av.source_assignment_id
                AND s.enrollment_id = p_enrollment AND s.score >= av.max_score * 0.6)) THEN
            RAISE EXCEPTION 'Every assignment needs a grade of at least 60 percent';
        END IF;
    END IF;
    UPDATE lms.enrollments SET status = 'completed', completed_at = clock_timestamp() WHERE id = p_enrollment;
    INSERT INTO lms.certificates(enrollment_id, certificate_number, issued_by)
    VALUES (p_enrollment, 'LMS-' || p_enrollment::text, lms.current_actor());
END;
$$;

-- 7. Права — як у 05_procedures.sql і 08_app_role.sql.
ALTER PROCEDURE lms.sp_release_course_version(bigint, bigint) SECURITY DEFINER;
ALTER PROCEDURE lms.sp_release_course_version(bigint, bigint) SET search_path = pg_catalog, lms, pg_temp;
ALTER PROCEDURE lms.sp_reopen_course(bigint) SECURITY DEFINER;
ALTER PROCEDURE lms.sp_reopen_course(bigint) SET search_path = pg_catalog, lms, pg_temp;
ALTER FUNCTION lms.bind_cohort_version() SET search_path = pg_catalog, lms, pg_temp;
ALTER FUNCTION lms.guard_version_item() SET search_path = pg_catalog, lms, pg_temp;
-- Як progress_percent у 08: SECURITY DEFINER, щоб course_app міг викликати без доступу до таблиць.
ALTER FUNCTION lms.progress_percent_by_version(bigint) SECURITY DEFINER;
ALTER FUNCTION lms.progress_percent_by_version(bigint) SET search_path = pg_catalog, lms, pg_temp;
REVOKE EXECUTE ON PROCEDURE lms.sp_release_course_version(bigint, bigint) FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE lms.sp_reopen_course(bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION lms.bind_cohort_version() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION lms.guard_version_item() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION lms.progress_percent_by_version(bigint) FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'course_app') THEN
        GRANT EXECUTE ON PROCEDURE lms.sp_release_course_version(bigint, bigint) TO course_app;
        GRANT EXECUTE ON PROCEDURE lms.sp_reopen_course(bigint) TO course_app;
        GRANT EXECUTE ON FUNCTION lms.progress_percent_by_version(bigint) TO course_app;
        -- CREATE OR REPLACE права зберігає; повторний GRANT — страховка, він ідемпотентний.
        GRANT EXECUTE ON PROCEDURE lms.sp_finish_enrollment(bigint) TO course_app;
    END IF;
END;
$$;

COMMIT;
