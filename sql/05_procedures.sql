CREATE PROCEDURE lms.sp_set_actor(p_user bigint)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM lms.users WHERE id = p_user AND NOT is_deleted) THEN
        RAISE EXCEPTION 'Active user not found';
    END IF;
    PERFORM set_config('lms.actor_id', p_user::text, true);
END;
$$;

CREATE PROCEDURE lms.sp_create_user(p_email text, p_name text, p_role text, p_detail text, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE role_key smallint;
BEGIN
    PERFORM lms.require_admin();
    SELECT id INTO STRICT role_key FROM lms.roles WHERE code = p_role;
    INSERT INTO lms.users(role_id, email, full_name)
    VALUES (role_key, lower(trim(p_email)), p_name) RETURNING id INTO p_id;
    IF p_role = 'student' THEN
        INSERT INTO lms.student_profiles(user_id, student_number) VALUES (p_id, p_detail);
    ELSIF p_role = 'instructor' THEN
        INSERT INTO lms.instructor_profiles(user_id, specialization) VALUES (p_id, p_detail);
    END IF;
END;
$$;

CREATE PROCEDURE lms.sp_create_category(p_name text, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_admin();
    INSERT INTO lms.categories(name, updated_by) VALUES (p_name, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_create_course(p_code text, p_title text, p_category bigint, p_description text, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_admin();
    PERFORM 1 FROM lms.categories WHERE id = p_category AND NOT is_deleted FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active category not found'; END IF;
    INSERT INTO lms.courses(code, title, category_id, description, updated_by)
    VALUES (p_code, p_title, p_category, p_description, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_update_course(p_id bigint, p_title text, p_description text)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_editor(p_id);
    UPDATE lms.courses SET title = p_title, description = p_description WHERE id = p_id AND NOT is_deleted;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active course not found'; END IF;
END;
$$;

CREATE PROCEDURE lms.sp_assign_instructor(p_course bigint, p_instructor bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_admin();
    PERFORM 1 FROM lms.courses WHERE id = p_course AND NOT is_deleted FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active course not found'; END IF;
    PERFORM 1 FROM lms.users u JOIN lms.instructor_profiles i ON i.user_id = u.id
    WHERE u.id = p_instructor AND NOT u.is_deleted FOR SHARE OF u;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active instructor not found'; END IF;
    INSERT INTO lms.course_instructors(course_id, instructor_id) VALUES (p_course, p_instructor);
END;
$$;

CREATE PROCEDURE lms.sp_add_prerequisite(p_course bigint, p_prerequisite bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_admin();
    PERFORM pg_advisory_xact_lock(713001);
    IF (SELECT count(*) FROM lms.courses WHERE id IN (p_course, p_prerequisite) AND NOT is_deleted) <> 2 THEN
        RAISE EXCEPTION 'Two distinct active courses required';
    END IF;
    INSERT INTO lms.course_prerequisites(course_id, prerequisite_id) VALUES (p_course, p_prerequisite);
END;
$$;

CREATE PROCEDURE lms.sp_add_module(p_course bigint, p_title text, p_position integer, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_editor(p_course);
    PERFORM 1 FROM lms.courses WHERE id = p_course AND NOT is_deleted AND status = 'draft' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Only an active draft can be structured'; END IF;
    INSERT INTO lms.modules(course_id, title, position, updated_by)
    VALUES (p_course, p_title, p_position, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_add_lesson(p_module bigint, p_title text, p_content text, p_minutes integer, p_position integer, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE course_key bigint;
BEGIN
    SELECT course_id INTO STRICT course_key FROM lms.modules WHERE id = p_module;
    PERFORM lms.require_editor(course_key);
    PERFORM 1 FROM lms.courses WHERE id = course_key AND NOT is_deleted AND status = 'draft' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Only an active draft can be structured'; END IF;
    INSERT INTO lms.lessons(module_id, title, content, duration_minutes, position, updated_by)
    VALUES (p_module, p_title, p_content, p_minutes, p_position, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_add_material(p_lesson bigint, p_title text, p_url text, p_kind text)
LANGUAGE plpgsql AS $$
DECLARE course_key bigint;
BEGIN
    SELECT m.course_id INTO STRICT course_key FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id WHERE l.id = p_lesson;
    PERFORM lms.require_editor(course_key);
    PERFORM 1 FROM lms.courses WHERE id = course_key AND NOT is_deleted AND status = 'draft' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Only an active draft can be structured'; END IF;
    INSERT INTO lms.materials(lesson_id, title, url, kind) VALUES (p_lesson, p_title, p_url, p_kind);
END;
$$;

CREATE PROCEDURE lms.sp_add_assignment(p_lesson bigint, p_title text, p_description text, p_max_score numeric, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE course_key bigint;
BEGIN
    SELECT m.course_id INTO STRICT course_key FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id WHERE l.id = p_lesson;
    PERFORM lms.require_editor(course_key);
    PERFORM 1 FROM lms.courses WHERE id = course_key AND NOT is_deleted AND status = 'draft' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Only an active draft can be structured'; END IF;
    INSERT INTO lms.assignments(lesson_id, title, description, max_score, updated_by)
    VALUES (p_lesson, p_title, p_description, p_max_score, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_publish_course(p_course bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_editor(p_course);
    PERFORM 1 FROM lms.courses WHERE id = p_course AND NOT is_deleted AND status = 'draft' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active draft not found'; END IF;
    IF NOT EXISTS (SELECT 1 FROM lms.lessons l JOIN lms.modules m ON m.id = l.module_id WHERE m.course_id = p_course)
        OR NOT EXISTS (SELECT 1 FROM lms.course_instructors WHERE course_id = p_course) THEN
        RAISE EXCEPTION 'A course needs a lesson and an instructor before publication';
    END IF;
    UPDATE lms.courses SET status = 'published' WHERE id = p_course;
END;
$$;

CREATE PROCEDURE lms.sp_create_cohort(p_course bigint, p_name text, p_start date, p_end date, p_capacity integer, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM lms.require_editor(p_course);
    PERFORM 1 FROM lms.courses WHERE id = p_course AND NOT is_deleted AND status = 'published' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Published active course required'; END IF;
    INSERT INTO lms.cohorts(course_id, name, starts_on, ends_on, capacity, updated_by)
    VALUES (p_course, p_name, p_start, p_end, p_capacity, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_enroll(p_cohort bigint, p_student bigint, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE course_key bigint; places integer;
BEGIN
    IF p_student <> lms.current_actor() THEN PERFORM lms.require_admin(); END IF;
    PERFORM 1 FROM lms.users u JOIN lms.student_profiles s ON s.user_id = u.id
    WHERE u.id = p_student AND NOT u.is_deleted FOR SHARE OF u;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active student not found'; END IF;
    SELECT course_id INTO STRICT course_key FROM lms.cohorts WHERE id = p_cohort;
    PERFORM 1 FROM lms.courses WHERE id = course_key AND NOT is_deleted AND status = 'published' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Published active course required'; END IF;
    SELECT capacity INTO places FROM lms.cohorts
    WHERE id = p_cohort AND status = 'open' AND ends_on >= current_date FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Open cohort not found'; END IF;
    IF (SELECT count(*) FROM lms.enrollments WHERE cohort_id = p_cohort AND status <> 'cancelled') >= places THEN
        RAISE EXCEPTION 'Cohort is full';
    END IF;
    IF EXISTS (SELECT 1 FROM lms.course_prerequisites p WHERE p.course_id = course_key AND NOT EXISTS (
        SELECT 1 FROM lms.enrollments e JOIN lms.cohorts c ON c.id = e.cohort_id
        WHERE e.student_id = p_student AND e.status = 'completed' AND c.course_id = p.prerequisite_id)) THEN
        RAISE EXCEPTION 'Prerequisites are not completed';
    END IF;
    INSERT INTO lms.enrollments(cohort_id, student_id, updated_by)
    VALUES (p_cohort, p_student, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_cancel_enrollment(p_enrollment bigint)
LANGUAGE plpgsql AS $$
DECLARE student_key bigint; cohort_key bigint;
BEGIN
    SELECT student_id, cohort_id INTO STRICT student_key, cohort_key FROM lms.enrollments WHERE id = p_enrollment;
    IF student_key <> lms.current_actor() THEN PERFORM lms.require_admin(); END IF;
    PERFORM 1 FROM lms.cohorts WHERE id = cohort_key FOR UPDATE;
    UPDATE lms.enrollments SET status = 'cancelled' WHERE id = p_enrollment AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Active enrollment not found'; END IF;
END;
$$;

CREATE PROCEDURE lms.sp_complete_lesson(p_enrollment bigint, p_lesson bigint)
LANGUAGE plpgsql AS $$
DECLARE student_key bigint;
BEGIN
    SELECT student_id INTO STRICT student_key FROM lms.enrollments WHERE id = p_enrollment FOR UPDATE;
    IF student_key <> lms.current_actor() THEN PERFORM lms.require_admin(); END IF;
    INSERT INTO lms.lesson_progress(enrollment_id, lesson_id) VALUES (p_enrollment, p_lesson)
    ON CONFLICT (enrollment_id, lesson_id) DO NOTHING;
END;
$$;

CREATE PROCEDURE lms.sp_submit(p_enrollment bigint, p_assignment bigint, p_answer text, INOUT p_id bigint)
LANGUAGE plpgsql AS $$
DECLARE student_key bigint;
BEGIN
    SELECT student_id INTO STRICT student_key FROM lms.enrollments WHERE id = p_enrollment FOR UPDATE;
    IF student_key <> lms.current_actor() THEN RAISE EXCEPTION 'Only the enrolled student may submit'; END IF;
    INSERT INTO lms.submissions(enrollment_id, assignment_id, answer, updated_by)
    VALUES (p_enrollment, p_assignment, p_answer, lms.current_actor()) RETURNING id INTO p_id;
END;
$$;

CREATE PROCEDURE lms.sp_grade(p_submission bigint, p_score numeric, p_feedback text)
LANGUAGE plpgsql AS $$
DECLARE course_key bigint; enrollment_key bigint;
BEGIN
    SELECT m.course_id, s.enrollment_id INTO STRICT course_key, enrollment_key
    FROM lms.submissions s JOIN lms.assignments a ON a.id = s.assignment_id
    JOIN lms.lessons l ON l.id = a.lesson_id JOIN lms.modules m ON m.id = l.module_id WHERE s.id = p_submission;
    IF NOT EXISTS (SELECT 1 FROM lms.course_instructors
        WHERE course_id = course_key AND instructor_id = lms.current_actor()) THEN
        RAISE EXCEPTION 'Only an assigned instructor may grade';
    END IF;
    PERFORM 1 FROM lms.enrollments WHERE id = enrollment_key FOR UPDATE;
    IF p_score IS NULL THEN RAISE EXCEPTION 'Score is required'; END IF;
    UPDATE lms.submissions SET score = p_score, feedback = p_feedback,
        graded_by = lms.current_actor(), graded_at = clock_timestamp() WHERE id = p_submission;
END;
$$;

CREATE PROCEDURE lms.sp_finish_enrollment(p_enrollment bigint)
LANGUAGE plpgsql AS $$
DECLARE course_key bigint; current_state text;
BEGIN
    SELECT c.course_id, e.status INTO STRICT course_key, current_state
    FROM lms.enrollments e JOIN lms.cohorts c ON c.id = e.cohort_id WHERE e.id = p_enrollment FOR UPDATE OF e;
    PERFORM lms.require_editor(course_key);
    IF current_state <> 'active' THEN RAISE EXCEPTION 'Enrollment must be active'; END IF;
    IF lms.progress_percent(p_enrollment) <> 100 THEN RAISE EXCEPTION 'All lessons must be completed'; END IF;
    IF EXISTS (SELECT 1 FROM lms.assignments a JOIN lms.lessons l ON l.id = a.lesson_id
        JOIN lms.modules m ON m.id = l.module_id
        WHERE m.course_id = course_key AND NOT a.is_deleted AND NOT EXISTS (
            SELECT 1 FROM lms.submissions s WHERE s.assignment_id = a.id AND s.enrollment_id = p_enrollment
            AND s.score >= a.max_score * 0.6)) THEN
        RAISE EXCEPTION 'Every assignment needs a grade of at least 60 percent';
    END IF;
    UPDATE lms.enrollments SET status = 'completed', completed_at = clock_timestamp() WHERE id = p_enrollment;
    INSERT INTO lms.certificates(enrollment_id, certificate_number, issued_by)
    VALUES (p_enrollment, 'LMS-' || p_enrollment::text, lms.current_actor());
END;
$$;

CREATE PROCEDURE lms.sp_review(p_enrollment bigint, p_rating integer, p_comment text)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM lms.enrollments WHERE id = p_enrollment AND student_id = lms.current_actor() AND status = 'completed' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Only a graduate may review the course'; END IF;
    INSERT INTO lms.course_reviews(enrollment_id, rating, comment, updated_by)
    VALUES (p_enrollment, p_rating, p_comment, lms.current_actor())
    ON CONFLICT (enrollment_id) DO UPDATE SET rating = excluded.rating, comment = excluded.comment;
END;
$$;

CREATE PROCEDURE lms.sp_set_deleted(p_entity text, p_id bigint, p_deleted boolean)
LANGUAGE plpgsql AS $$
DECLARE parent_key bigint;
BEGIN
    PERFORM lms.require_admin();
    IF p_entity NOT IN ('users', 'categories', 'courses', 'assignments') OR p_entity IS NULL OR p_deleted IS NULL THEN
        RAISE EXCEPTION 'Unsupported entity or missing deletion flag';
    END IF;
    EXECUTE format('SELECT id FROM lms.%I WHERE id = $1 FOR UPDATE', p_entity) INTO parent_key USING p_id;
    IF parent_key IS NULL THEN RAISE EXCEPTION 'Record not found'; END IF;
    IF p_entity = 'users' AND p_deleted THEN
        IF p_id = lms.current_actor() THEN RAISE EXCEPTION 'Cannot delete the current actor'; END IF;
        IF EXISTS (SELECT 1 FROM lms.enrollments WHERE student_id = p_id AND status = 'active')
            OR EXISTS (SELECT 1 FROM lms.course_instructors ci JOIN lms.courses c ON c.id = ci.course_id
                WHERE ci.instructor_id = p_id AND NOT c.is_deleted AND c.status <> 'archived') THEN
            RAISE EXCEPTION 'User has active enrollments or teaching courses';
        END IF;
    ELSIF p_entity = 'categories' AND p_deleted THEN
        IF EXISTS (SELECT 1 FROM lms.courses WHERE category_id = p_id AND NOT is_deleted) THEN
            RAISE EXCEPTION 'Category contains active courses';
        END IF;
    ELSIF p_entity = 'courses' THEN
        IF p_deleted AND EXISTS (SELECT 1 FROM lms.cohorts c JOIN lms.enrollments e ON e.cohort_id = c.id
            WHERE c.course_id = p_id AND e.status = 'active') THEN
            RAISE EXCEPTION 'Course has active enrollments';
        END IF;
        IF NOT p_deleted THEN
            PERFORM 1 FROM lms.courses c JOIN lms.categories cat ON cat.id = c.category_id
            WHERE c.id = p_id AND NOT cat.is_deleted FOR SHARE OF cat;
            IF NOT FOUND THEN RAISE EXCEPTION 'Restore the category first'; END IF;
        END IF;
    ELSIF p_entity = 'assignments' THEN
        SELECT m.course_id INTO parent_key FROM lms.assignments a JOIN lms.lessons l ON l.id = a.lesson_id
        JOIN lms.modules m ON m.id = l.module_id WHERE a.id = p_id;
        PERFORM 1 FROM lms.courses WHERE id = parent_key AND status = 'draft' AND NOT is_deleted FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Only draft assignments can be deleted or restored'; END IF;
    END IF;
    EXECUTE format('UPDATE lms.%I SET is_deleted = $1, deleted_at = CASE WHEN $1 THEN clock_timestamp() ELSE NULL END WHERE id = $2', p_entity)
    USING p_deleted, p_id;
END;
$$;

DO $$
DECLARE obj record;
BEGIN
    FOR obj IN SELECT p.oid::regprocedure AS signature, p.prokind FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'lms' LOOP
        IF obj.prokind = 'p' THEN
            EXECUTE format('ALTER PROCEDURE %s SECURITY DEFINER', obj.signature);
            EXECUTE format('ALTER PROCEDURE %s SET search_path = pg_catalog, lms, pg_temp', obj.signature);
        ELSE
            EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, lms, pg_temp', obj.signature);
        END IF;
    END LOOP;
END;
$$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA lms FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA lms FROM PUBLIC;
