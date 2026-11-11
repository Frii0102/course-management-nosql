CREATE SCHEMA lms;

CREATE TABLE lms.roles (
    id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code varchar(20) NOT NULL UNIQUE CHECK (code IN ('admin', 'instructor', 'student')),
    name varchar(80) NOT NULL
);

CREATE TABLE lms.users (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_id smallint NOT NULL REFERENCES lms.roles(id),
    email varchar(254) NOT NULL CHECK (email = lower(email) AND position('@' IN email) > 1),
    full_name varchar(150) NOT NULL CHECK (length(trim(full_name)) > 0),
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint REFERENCES lms.users(id),
    CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE lms.student_profiles (
    user_id bigint PRIMARY KEY REFERENCES lms.users(id),
    student_number varchar(30) NOT NULL UNIQUE,
    registered_on date NOT NULL DEFAULT current_date
);

CREATE TABLE lms.instructor_profiles (
    user_id bigint PRIMARY KEY REFERENCES lms.users(id),
    specialization varchar(150) NOT NULL,
    biography text NOT NULL DEFAULT ''
);

CREATE TABLE lms.categories (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(100) NOT NULL CHECK (length(trim(name)) > 0),
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE lms.courses (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id bigint NOT NULL REFERENCES lms.categories(id),
    code varchar(30) NOT NULL,
    title varchar(200) NOT NULL CHECK (length(trim(title)) > 0),
    description text NOT NULL DEFAULT '',
    status varchar(20) NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE lms.course_instructors (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id bigint NOT NULL REFERENCES lms.courses(id),
    instructor_id bigint NOT NULL REFERENCES lms.instructor_profiles(user_id),
    UNIQUE (course_id, instructor_id)
);

CREATE TABLE lms.course_prerequisites (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id bigint NOT NULL REFERENCES lms.courses(id),
    prerequisite_id bigint NOT NULL REFERENCES lms.courses(id),
    CHECK (course_id <> prerequisite_id),
    UNIQUE (course_id, prerequisite_id)
);

CREATE TABLE lms.modules (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id bigint NOT NULL REFERENCES lms.courses(id),
    title varchar(200) NOT NULL CHECK (length(trim(title)) > 0),
    position integer NOT NULL CHECK (position > 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    UNIQUE (course_id, position)
);

CREATE TABLE lms.lessons (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module_id bigint NOT NULL REFERENCES lms.modules(id),
    title varchar(200) NOT NULL CHECK (length(trim(title)) > 0),
    content text NOT NULL DEFAULT '',
    duration_minutes integer NOT NULL CHECK (duration_minutes > 0),
    position integer NOT NULL CHECK (position > 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    UNIQUE (module_id, position)
);

CREATE TABLE lms.materials (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lesson_id bigint NOT NULL REFERENCES lms.lessons(id),
    title varchar(200) NOT NULL,
    url text NOT NULL CHECK (url ~ '^https?://'),
    kind varchar(20) NOT NULL CHECK (kind IN ('document', 'video', 'link'))
);

CREATE TABLE lms.cohorts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id bigint NOT NULL REFERENCES lms.courses(id),
    name varchar(100) NOT NULL,
    starts_on date NOT NULL,
    ends_on date NOT NULL,
    capacity integer NOT NULL CHECK (capacity > 0),
    status varchar(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'finished')),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    CHECK (ends_on >= starts_on),
    UNIQUE (course_id, name)
);

CREATE TABLE lms.enrollments (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cohort_id bigint NOT NULL REFERENCES lms.cohorts(id),
    student_id bigint NOT NULL REFERENCES lms.student_profiles(user_id),
    status varchar(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'cancelled')),
    enrolled_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    CHECK ((status = 'completed') = (completed_at IS NOT NULL)),
    UNIQUE (cohort_id, student_id)
);

CREATE TABLE lms.assignments (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lesson_id bigint NOT NULL REFERENCES lms.lessons(id),
    title varchar(200) NOT NULL CHECK (length(trim(title)) > 0),
    description text NOT NULL DEFAULT '',
    max_score numeric(7,2) NOT NULL CHECK (max_score > 0),
    is_deleted boolean NOT NULL DEFAULT false,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    CHECK (is_deleted = (deleted_at IS NOT NULL))
);

CREATE TABLE lms.submissions (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id bigint NOT NULL REFERENCES lms.enrollments(id),
    assignment_id bigint NOT NULL REFERENCES lms.assignments(id),
    answer text NOT NULL CHECK (length(trim(answer)) > 0),
    submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    score numeric(7,2) CHECK (score >= 0),
    feedback text,
    graded_by bigint REFERENCES lms.instructor_profiles(user_id),
    graded_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id),
    CHECK ((score IS NULL AND graded_by IS NULL AND graded_at IS NULL)
        OR (score IS NOT NULL AND graded_by IS NOT NULL AND graded_at IS NOT NULL)),
    UNIQUE (enrollment_id, assignment_id)
);

CREATE TABLE lms.lesson_progress (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id bigint NOT NULL REFERENCES lms.enrollments(id),
    lesson_id bigint NOT NULL REFERENCES lms.lessons(id),
    completed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (enrollment_id, lesson_id)
);

CREATE TABLE lms.certificates (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id bigint NOT NULL UNIQUE REFERENCES lms.enrollments(id),
    certificate_number varchar(60) NOT NULL UNIQUE,
    issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    issued_by bigint NOT NULL REFERENCES lms.users(id)
);

CREATE TABLE lms.course_reviews (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enrollment_id bigint NOT NULL UNIQUE REFERENCES lms.enrollments(id),
    rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment text NOT NULL DEFAULT '',
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by bigint NOT NULL REFERENCES lms.users(id)
);

CREATE TABLE lms.audit_log (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text NOT NULL,
    record_id bigint NOT NULL,
    operation varchar(10) NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    old_data jsonb,
    new_data jsonb,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    changed_by bigint NOT NULL REFERENCES lms.users(id)
);
