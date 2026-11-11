INSERT INTO lms.roles(code, name) VALUES
('admin', 'Адміністратор'), ('instructor', 'Викладач'), ('student', 'Студент');
INSERT INTO lms.users(role_id, email, full_name) VALUES
(1, 'admin@example.com', 'Адміністратор системи'),
(2, 'teacher@example.com', 'Олена Коваль'),
(3, 'ilona@example.com', 'Венчак Ілона'),
(3, 'student@example.com', 'Андрій Мельник');
INSERT INTO lms.student_profiles(user_id, student_number) VALUES (3, 'TK-31-001'), (4, 'TK-31-002');
INSERT INTO lms.instructor_profiles(user_id, specialization) VALUES (2, 'Бази даних та Python');
INSERT INTO lms.categories(name, updated_by) VALUES ('Програмування', 1), ('Бази даних', 1);
