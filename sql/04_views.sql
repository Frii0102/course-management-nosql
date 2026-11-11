CREATE VIEW lms.v_users AS
SELECT u.id, u.email, u.full_name, r.code AS role, u.updated_at, u.updated_by
FROM lms.users u JOIN lms.roles r ON r.id = u.role_id WHERE NOT u.is_deleted;

CREATE VIEW lms.v_categories AS
SELECT id, name, updated_at, updated_by FROM lms.categories WHERE NOT is_deleted;

CREATE VIEW lms.v_courses AS
SELECT c.id, c.code, c.title, c.description, c.category_id, cat.name AS category,
    c.status, c.updated_at, c.updated_by
FROM lms.courses c JOIN lms.categories cat ON cat.id = c.category_id
WHERE NOT c.is_deleted AND NOT cat.is_deleted;

CREATE VIEW lms.v_course_structure AS
SELECT c.id AS course_id, m.id AS module_id, m.title AS module_title, m.position AS module_position,
    l.id AS lesson_id, l.title AS lesson_title, l.position AS lesson_position, l.duration_minutes
FROM lms.v_courses c LEFT JOIN lms.modules m ON m.course_id = c.id
LEFT JOIN lms.lessons l ON l.module_id = m.id;

CREATE VIEW lms.v_cohorts AS
SELECT h.id, h.course_id, h.name, h.starts_on, h.ends_on, h.capacity, h.status,
    count(e.id) FILTER (WHERE e.status <> 'cancelled') AS occupied_places,
    h.capacity - count(e.id) FILTER (WHERE e.status <> 'cancelled') AS available_places
FROM lms.cohorts h JOIN lms.v_courses c ON c.id = h.course_id
LEFT JOIN lms.enrollments e ON e.cohort_id = h.id GROUP BY h.id;

CREATE VIEW lms.v_enrollments AS
SELECT e.id, e.student_id, u.full_name AS student_name, e.cohort_id, h.course_id,
    c.title AS course_title, e.status, e.enrolled_at, e.completed_at,
    lms.progress_percent(e.id) AS progress_percent, e.updated_at, e.updated_by
FROM lms.enrollments e JOIN lms.users u ON u.id = e.student_id
JOIN lms.cohorts h ON h.id = e.cohort_id JOIN lms.courses c ON c.id = h.course_id;

CREATE VIEW lms.v_assignments AS
SELECT a.id, a.lesson_id, m.course_id, a.title, a.description, a.max_score, a.updated_at, a.updated_by
FROM lms.assignments a JOIN lms.lessons l ON l.id = a.lesson_id
JOIN lms.modules m ON m.id = l.module_id JOIN lms.v_courses c ON c.id = m.course_id
WHERE NOT a.is_deleted;

CREATE VIEW lms.v_submissions AS
SELECT s.id, s.enrollment_id, s.assignment_id, a.title AS assignment_title,
    s.answer, s.score, a.max_score, s.feedback, s.graded_by, s.graded_at
FROM lms.submissions s JOIN lms.assignments a ON a.id = s.assignment_id;

CREATE VIEW lms.v_certificates AS
SELECT c.id, c.enrollment_id, c.certificate_number, c.issued_at, c.issued_by,
    e.student_id, e.student_name, e.course_title
FROM lms.certificates c JOIN lms.v_enrollments e ON e.id = c.enrollment_id;

CREATE VIEW lms.v_change_history AS
SELECT a.*, u.full_name AS changed_by_name FROM lms.audit_log a
JOIN lms.users u ON u.id = a.changed_by;

CREATE VIEW lms.v_recycle_bin AS
SELECT 'courses'::text AS entity, id, title AS name, deleted_at FROM lms.courses WHERE is_deleted
UNION ALL SELECT 'categories', id, name, deleted_at FROM lms.categories WHERE is_deleted
UNION ALL SELECT 'users', id, full_name, deleted_at FROM lms.users WHERE is_deleted
UNION ALL SELECT 'assignments', id, title, deleted_at FROM lms.assignments WHERE is_deleted;
