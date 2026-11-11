DO $$
DECLARE tab text;
BEGIN
    FOREACH tab IN ARRAY ARRAY['users', 'categories', 'courses', 'modules', 'lessons',
        'cohorts', 'enrollments', 'assignments', 'submissions', 'course_reviews'] LOOP
        EXECUTE format('CREATE TRIGGER stamp BEFORE INSERT OR UPDATE ON lms.%I FOR EACH ROW EXECUTE FUNCTION lms.touch_record()', tab);
    END LOOP;
    FOREACH tab IN ARRAY ARRAY['users', 'categories', 'courses', 'course_instructors',
        'course_prerequisites', 'modules', 'lessons', 'materials', 'cohorts', 'enrollments',
        'assignments', 'submissions', 'lesson_progress', 'certificates', 'course_reviews'] LOOP
        EXECUTE format('CREATE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON lms.%I FOR EACH ROW EXECUTE FUNCTION lms.audit_record()', tab);
    END LOOP;
    FOREACH tab IN ARRAY ARRAY['users', 'categories', 'courses', 'assignments'] LOOP
        EXECUTE format('CREATE TRIGGER no_hard_delete BEFORE DELETE ON lms.%I FOR EACH ROW EXECUTE FUNCTION lms.prevent_hard_delete()', tab);
    END LOOP;
END;
$$;

CREATE TRIGGER validate_submission BEFORE INSERT OR UPDATE ON lms.submissions
FOR EACH ROW EXECUTE FUNCTION lms.guard_learning_record();
CREATE TRIGGER validate_progress BEFORE INSERT OR UPDATE ON lms.lesson_progress
FOR EACH ROW EXECUTE FUNCTION lms.guard_learning_record();
CREATE TRIGGER no_prerequisite_cycles BEFORE INSERT OR UPDATE ON lms.course_prerequisites
FOR EACH ROW EXECUTE FUNCTION lms.guard_prerequisite();
