-- Необов'язково: аудит на таблицях версій, як у решті схеми (lms.audit_record).
-- Для бенчмарка публікації версії порівнюємо дві серії:
--   "з тригерами":  ALTER TABLE lms.<table> ENABLE TRIGGER audit;
--   "без тригерів": ALTER TABLE lms.<table> DISABLE TRIGGER audit;
-- Обидві серії запиши у звіт окремо, інакше неясно, що саме міряємо.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE tab text;
BEGIN
    FOREACH tab IN ARRAY ARRAY['course_versions', 'module_versions', 'lesson_versions',
        'material_versions', 'assignment_versions'] LOOP
        EXECUTE format('CREATE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON lms.%I
            FOR EACH ROW EXECUTE FUNCTION lms.audit_record()', tab);
    END LOOP;
END;
$$;

COMMIT;
