\set ON_ERROR_STOP on
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'course_app') THEN
        CREATE ROLE course_app NOLOGIN;
    END IF;
END;
$$;
GRANT USAGE ON SCHEMA lms TO course_app;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA lms TO course_app;
GRANT EXECUTE ON FUNCTION lms.progress_percent(bigint) TO course_app;
ALTER FUNCTION lms.progress_percent(bigint) SECURITY DEFINER;
DO $$
DECLARE item record;
BEGIN
    FOR item IN SELECT viewname FROM pg_views WHERE schemaname = 'lms' LOOP
        EXECUTE format('GRANT SELECT ON lms.%I TO course_app', item.viewname);
    END LOOP;
END;
$$;
