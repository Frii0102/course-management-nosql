CREATE UNIQUE INDEX uq_users_active_email ON lms.users USING btree(email) WHERE NOT is_deleted;
CREATE UNIQUE INDEX uq_categories_active_name ON lms.categories USING btree(lower(name)) WHERE NOT is_deleted;
CREATE UNIQUE INDEX uq_courses_active_code ON lms.courses USING btree(code) WHERE NOT is_deleted;
CREATE INDEX ix_courses_category ON lms.courses(category_id);
CREATE INDEX ix_course_instructors_instructor ON lms.course_instructors(instructor_id);
CREATE INDEX ix_prerequisite_reverse ON lms.course_prerequisites(prerequisite_id);
CREATE INDEX ix_enrollments_student ON lms.enrollments(student_id);
CREATE INDEX ix_submissions_assignment ON lms.submissions(assignment_id);
CREATE INDEX ix_progress_lesson ON lms.lesson_progress(lesson_id);
CREATE INDEX ix_audit_record ON lms.audit_log(table_name, record_id, id);
CREATE INDEX ix_courses_search ON lms.courses USING gin
    (to_tsvector('simple', title || ' ' || description)) WHERE NOT is_deleted;
CREATE INDEX ix_audit_new_data ON lms.audit_log USING gin(new_data);
