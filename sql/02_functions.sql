CREATE FUNCTION lms.current_actor() RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE actor bigint;
BEGIN
    actor := nullif(current_setting('lms.actor_id', true), '')::bigint;
    IF actor IS NULL OR NOT EXISTS (SELECT 1 FROM lms.users WHERE id = actor AND NOT is_deleted) THEN
        RAISE EXCEPTION 'An active actor must be set with sp_set_actor';
    END IF;
    RETURN actor;
END;
$$;

CREATE FUNCTION lms.touch_record() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    NEW.updated_by := lms.current_actor();
    RETURN NEW;
END;
$$;

CREATE FUNCTION lms.audit_record() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE before_row jsonb; after_row jsonb;
BEGIN
    IF TG_OP <> 'INSERT' THEN before_row := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN after_row := to_jsonb(NEW); END IF;
    INSERT INTO lms.audit_log(table_name, record_id, operation, old_data, new_data, changed_by)
    VALUES (TG_TABLE_NAME, (coalesce(after_row, before_row)->>'id')::bigint, TG_OP, before_row, after_row, lms.current_actor());
    RETURN NULL;
END;
$$;

CREATE FUNCTION lms.progress_percent(p_enrollment bigint) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT coalesce(round(100.0 * (
        SELECT count(*) FROM lms.lesson_progress p WHERE p.enrollment_id = e.id
    ) / nullif((
        SELECT count(*) FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id
        WHERE m.course_id = c.course_id
    ), 0), 2), 0)
    FROM lms.enrollments e JOIN lms.cohorts c ON c.id = e.cohort_id
    WHERE e.id = p_enrollment;
$$;

CREATE FUNCTION lms.guard_learning_record() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE enrolled_course bigint; item_course bigint; state text; maximum numeric;
BEGIN
    SELECT c.course_id, e.status INTO enrolled_course, state
    FROM lms.enrollments e JOIN lms.cohorts c ON c.id = e.cohort_id
    WHERE e.id = NEW.enrollment_id;
    IF TG_TABLE_NAME = 'submissions' THEN
        SELECT m.course_id, a.max_score INTO item_course, maximum
        FROM lms.assignments a JOIN lms.lessons l ON l.id = a.lesson_id
        JOIN lms.modules m ON m.id = l.module_id
        WHERE a.id = NEW.assignment_id AND NOT a.is_deleted;
        IF NEW.score IS NOT NULL AND NEW.score > maximum THEN
            RAISE EXCEPTION 'Score exceeds maximum %', maximum;
        END IF;
    ELSE
        SELECT m.course_id INTO item_course FROM lms.lessons l
        JOIN lms.modules m ON m.id = l.module_id WHERE l.id = NEW.lesson_id;
    END IF;
    IF item_course IS NULL OR enrolled_course IS DISTINCT FROM item_course THEN
        RAISE EXCEPTION 'The learning item belongs to another course or is deleted';
    END IF;
    IF state IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'Enrollment must be active';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lms.prevent_hard_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Use the soft-delete procedure for %', TG_TABLE_NAME;
END;
$$;

CREATE FUNCTION lms.guard_prerequisite() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(713001);
    IF EXISTS (
        WITH RECURSIVE path(id) AS (
            SELECT NEW.prerequisite_id
            UNION
            SELECT p.prerequisite_id FROM lms.course_prerequisites p JOIN path x ON p.course_id = x.id
            WHERE p.id <> NEW.id
        ) SELECT 1 FROM path WHERE id = NEW.course_id
    ) THEN RAISE EXCEPTION 'Prerequisite cycle is not allowed'; END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION lms.require_admin() RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM lms.users u JOIN lms.roles r ON r.id = u.role_id
        WHERE u.id = lms.current_actor() AND r.code = 'admin') THEN
        RAISE EXCEPTION 'Administrator role required';
    END IF;
END;
$$;

CREATE FUNCTION lms.require_editor(p_course bigint) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM lms.users u JOIN lms.roles r ON r.id = u.role_id
        WHERE u.id = lms.current_actor() AND (r.code = 'admin' OR EXISTS (
            SELECT 1 FROM lms.course_instructors ci
            WHERE ci.course_id = p_course AND ci.instructor_id = u.id))) THEN
        RAISE EXCEPTION 'Administrator or assigned instructor required';
    END IF;
END;
$$;
