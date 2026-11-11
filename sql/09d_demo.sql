-- Демо циклу версіонування (потрібні 00, 09, 09c; 09b — за бажанням).
-- Усе виконується в одній транзакції і в кінці відкочується (ROLLBACK),
-- тому сценарій можна запускати скільки завгодно разів, і він не чіпає дані бенчмарка.
-- Запуск:  docker exec -i course-nosql-lab-postgres-1 psql -U postgres -d lms < sql/09d_demo.sql
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
    category_key bigint; course_key bigint; module_key bigint; lesson_key bigint; assignment_key bigint;
    v1 bigint; v2 bigint; cohort_a bigint; cohort_b bigint;
    first_lesson bigint; second_lesson bigint; new_lesson bigint; enrollment_a bigint; submission_key bigint;
BEGIN
    -- Адміністратор (07_seed.sql): курс і призначення викладача
    CALL lms.sp_set_actor(1);
    SELECT min(id) INTO category_key FROM lms.categories WHERE NOT is_deleted;
    CALL lms.sp_create_course('DEMO-VER', 'Демо: версії курсу', category_key, 'Демонстрація 09c', course_key);
    CALL lms.sp_assign_instructor(course_key, 2);

    -- Далі все робить призначений викладач (require_editor)
    CALL lms.sp_set_actor(2);
    CALL lms.sp_add_module(course_key, 'Вступ', 1, module_key);
    CALL lms.sp_add_lesson(module_key, 'Урок 1', 'Текст уроку 1', 20, 1, first_lesson);
    CALL lms.sp_add_material(first_lesson, 'Слайди', 'https://example.com/slides-1', 'document');
    CALL lms.sp_add_lesson(module_key, 'Урок 2', 'Текст уроку 2', 25, 2, second_lesson);
    CALL lms.sp_add_assignment(second_lesson, 'Завдання 1', 'Опис', 10, assignment_key);

    CALL lms.sp_release_course_version(course_key, v1);
    RAISE NOTICE 'v1: course_versions.id = %', v1;
    CALL lms.sp_create_cohort(course_key, 'Когорта A', current_date, current_date + 60, 30, cohort_a);

    -- Опублікований курс змінювати не можна (перевірка з 05_procedures.sql)
    BEGIN
        CALL lms.sp_add_lesson(module_key, 'Зайвий урок', '', 10, 3, lesson_key);
        RAISE EXCEPTION 'unexpected: published course was modified';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'unexpected%' THEN RAISE; END IF;
        RAISE NOTICE 'Очікувана помилка: %', SQLERRM;
    END;

    CALL lms.sp_reopen_course(course_key);
    CALL lms.sp_add_lesson(module_key, 'Урок 3 (новий у v2)', 'Текст уроку 3', 30, 3, new_lesson);
    CALL lms.sp_release_course_version(course_key, v2);
    RAISE NOTICE 'v2: course_versions.id = %', v2;
    CALL lms.sp_create_cohort(course_key, 'Когорта B', current_date + 7, current_date + 67, 30, cohort_b);

    -- Когорту не можна «перевести» на іншу версію
    BEGIN
        UPDATE lms.cohorts SET course_version_id = v2 WHERE id = cohort_a;
        RAISE EXCEPTION 'unexpected: cohort version was changed';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'unexpected%' THEN RAISE; END IF;
        RAISE NOTICE 'Очікувана помилка: %', SQLERRM;
    END;

    -- Студентка когорти A (v1) проходить урок зі своєї версії, але не урок, доданий у v2
    CALL lms.sp_set_actor(1);
    CALL lms.sp_enroll(cohort_a, 3, enrollment_a);
    CALL lms.sp_set_actor(3);
    CALL lms.sp_complete_lesson(enrollment_a, first_lesson);
    RAISE NOTICE 'Урок % з v1 зараховано когорті A', first_lesson;
    BEGIN
        CALL lms.sp_complete_lesson(enrollment_a, new_lesson);
        RAISE EXCEPTION 'unexpected: lesson from v2 accepted for cohort A';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'unexpected%' THEN RAISE; END IF;
        RAISE NOTICE 'Очікувана помилка: %', SQLERRM;
    END;

    -- Фінал: студентка проходить усі уроки v1 і здає завдання v1
    CALL lms.sp_complete_lesson(enrollment_a, second_lesson);
    CALL lms.sp_submit(enrollment_a, assignment_key, 'Моя відповідь', submission_key);
    CALL lms.sp_set_actor(2);
    CALL lms.sp_grade(submission_key, 9, 'Добре');
    RAISE NOTICE 'Прогрес: за живою структурою % %%, за версією когорти % %%',
        lms.progress_percent(enrollment_a), lms.progress_percent_by_version(enrollment_a);
    -- Курс уже має v2 з третім уроком, але когорта A завершує навчання за v1
    CALL lms.sp_finish_enrollment(enrollment_a);
    RAISE NOTICE 'Зарахування % завершено, сертифікат %', enrollment_a,
        (SELECT certificate_number FROM lms.certificates WHERE enrollment_id = enrollment_a);
END;
$$;

-- Результат: A вчиться за v1 (2 уроки), B — за v2 (3 уроки), жива структура = 3
SELECT h.name AS cohort, cv.version, cv.lesson_count AS lessons_in_version,
       (SELECT count(*) FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id
        WHERE m.course_id = h.course_id) AS lessons_live_now
FROM lms.cohorts h
JOIN lms.courses c ON c.id = h.course_id
JOIN lms.course_versions cv ON cv.id = h.course_version_id
WHERE c.code = 'DEMO-VER'
ORDER BY h.name;

-- Історія статусів курсу з audit_log (тригер audit на courses)
SELECT a.id, a.operation, a.old_data->>'status' AS old_status, a.new_data->>'status' AS new_status,
       u.full_name AS changed_by
FROM lms.audit_log a JOIN lms.users u ON u.id = a.changed_by
WHERE a.table_name = 'courses'
  AND a.record_id = (SELECT id FROM lms.courses WHERE code = 'DEMO-VER' AND NOT is_deleted)
ORDER BY a.id;

-- Завершене зарахування: статус, обидва прогреси, сертифікат
SELECT e.id AS enrollment, h.name AS cohort, cv.version, e.status,
       lms.progress_percent(e.id) AS progress_live,
       lms.progress_percent_by_version(e.id) AS progress_by_version,
       c.certificate_number
FROM lms.enrollments e
JOIN lms.cohorts h ON h.id = e.cohort_id
JOIN lms.course_versions cv ON cv.id = h.course_version_id
LEFT JOIN lms.certificates c ON c.enrollment_id = e.id
WHERE h.course_id = (SELECT id FROM lms.courses WHERE code = 'DEMO-VER' AND NOT is_deleted);

ROLLBACK;  -- заміни на COMMIT, якщо хочеш залишити демо-дані
