-- SmartHR AI - HRMS PostgreSQL schema (Step 02.00)
-- Notes:
-- - Designed for multi-tenant use via org_id on most domain tables.
-- - Includes RBAC, employees/hierarchy, onboarding, attendance, leave, holidays, payroll metadata, and audit logs.
-- - Uses idempotent CREATE statements and INSERT ... ON CONFLICT to allow re-runs during preview startup.

BEGIN;

-- Extensions (safe to run multiple times)
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- -----------------------------------------------------------------------------
-- Tenancy / Organizations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_organizations_slug ON organizations (slug);

-- -----------------------------------------------------------------------------
-- Users / Auth (DB stores password hash; auth/JWT handled by backend)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email text NOT NULL,
  password_hash text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  must_change_password boolean NOT NULL DEFAULT true,
  last_login_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_users_email_format CHECK (position('@' in email) > 1)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_org_email ON users (org_id, lower(email));
CREATE INDEX IF NOT EXISTS ix_users_org_id ON users (org_id);

-- -----------------------------------------------------------------------------
-- RBAC (org-scoped roles and permissions)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name text NOT NULL,                -- e.g., Admin, HR, Manager, Employee
  description text NULL,
  is_system boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_roles_org_name ON roles (org_id, lower(name));
CREATE INDEX IF NOT EXISTS ix_roles_org_id ON roles (org_id);

CREATE TABLE IF NOT EXISTS permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text NOT NULL,                 -- e.g., employee.read
  description text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_permissions_key ON permissions (lower(key));

CREATE TABLE IF NOT EXISTS role_permissions (
  role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, permission_id)
);

CREATE INDEX IF NOT EXISTS ix_role_permissions_permission_id ON role_permissions (permission_id);

CREATE TABLE IF NOT EXISTS user_roles (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);

CREATE INDEX IF NOT EXISTS ix_user_roles_role_id ON user_roles (role_id);

-- -----------------------------------------------------------------------------
-- Employees / Hierarchy
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id uuid NULL UNIQUE REFERENCES users(id) ON DELETE SET NULL,

  employee_code text NOT NULL,
  first_name text NOT NULL,
  last_name text NULL,
  display_name text GENERATED ALWAYS AS (
    trim(coalesce(first_name,'') || ' ' || coalesce(last_name,''))
  ) STORED,

  work_email text NULL,
  personal_email text NULL,
  phone text NULL,

  job_title text NULL,
  department text NULL,
  location text NULL,
  employment_type text NOT NULL DEFAULT 'full_time'
    CHECK (employment_type IN ('full_time','part_time','contractor','intern')),
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','inactive','terminated')),

  date_of_joining date NULL,
  date_of_exit date NULL,

  manager_employee_id uuid NULL REFERENCES employees(id) ON DELETE SET NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT ck_employees_email_format CHECK (
    (work_email IS NULL OR position('@' in work_email) > 1)
    AND (personal_email IS NULL OR position('@' in personal_email) > 1)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_employees_org_code ON employees (org_id, lower(employee_code));
CREATE INDEX IF NOT EXISTS ix_employees_org_id ON employees (org_id);
CREATE INDEX IF NOT EXISTS ix_employees_manager ON employees (org_id, manager_employee_id);
CREATE INDEX IF NOT EXISTS ix_employees_status ON employees (org_id, status);

-- Many HRMS systems separate reporting lines; we keep manager_employee_id on employees
-- and add an optional adjacency table for future effective-dated hierarchy.
CREATE TABLE IF NOT EXISTS employee_hierarchy (
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  manager_employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  effective_to date NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, employee_id, effective_from),
  CONSTRAINT ck_employee_hierarchy_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS ix_employee_hierarchy_manager ON employee_hierarchy (org_id, manager_employee_id, effective_from);

-- -----------------------------------------------------------------------------
-- Onboarding
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS onboarding_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_onboarding_templates_org_name ON onboarding_templates (org_id, lower(name));

CREATE TABLE IF NOT EXISTS onboarding_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  template_id uuid NULL REFERENCES onboarding_templates(id) ON DELETE SET NULL,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text NULL,
  assigned_to_employee_id uuid NULL REFERENCES employees(id) ON DELETE SET NULL,
  due_date date NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','in_progress','completed','blocked','cancelled')),
  completed_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_onboarding_tasks_employee ON onboarding_tasks (org_id, employee_id, status);
CREATE INDEX IF NOT EXISTS ix_onboarding_tasks_assignee ON onboarding_tasks (org_id, assigned_to_employee_id, status);

-- -----------------------------------------------------------------------------
-- Attendance
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS attendance_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  timezone text NOT NULL DEFAULT 'UTC',
  workday_start time NOT NULL DEFAULT '09:30',
  workday_end time NOT NULL DEFAULT '18:30',
  weekly_working_days smallint NOT NULL DEFAULT 5 CHECK (weekly_working_days BETWEEN 1 AND 7),
  allow_remote boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_attendance_policies_org_name ON attendance_policies (org_id, lower(name));

CREATE TABLE IF NOT EXISTS employee_attendance_policy (
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  policy_id uuid NOT NULL REFERENCES attendance_policies(id) ON DELETE CASCADE,
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  effective_to date NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, employee_id, effective_from),
  CONSTRAINT ck_employee_attendance_policy_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS ix_employee_attendance_policy_policy ON employee_attendance_policy (org_id, policy_id, effective_from);

CREATE TABLE IF NOT EXISTS attendance_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  session_date date NOT NULL,
  work_mode text NOT NULL DEFAULT 'onsite' CHECK (work_mode IN ('onsite','remote','hybrid')),
  clock_in_at timestamptz NULL,
  clock_out_at timestamptz NULL,
  minutes_worked integer NOT NULL DEFAULT 0 CHECK (minutes_worked >= 0),
  source text NOT NULL DEFAULT 'web' CHECK (source IN ('web','mobile','api','import')),
  notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_attendance_clock_order CHECK (clock_out_at IS NULL OR clock_in_at IS NULL OR clock_out_at >= clock_in_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_attendance_sessions_unique_day ON attendance_sessions (org_id, employee_id, session_date);
CREATE INDEX IF NOT EXISTS ix_attendance_sessions_date ON attendance_sessions (org_id, session_date);
CREATE INDEX IF NOT EXISTS ix_attendance_sessions_employee ON attendance_sessions (org_id, employee_id, session_date);

-- -----------------------------------------------------------------------------
-- Holidays
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS holiday_calendars (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  timezone text NOT NULL DEFAULT 'UTC',
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_holiday_calendars_org_name ON holiday_calendars (org_id, lower(name));
CREATE INDEX IF NOT EXISTS ix_holiday_calendars_default ON holiday_calendars (org_id, is_default);

CREATE TABLE IF NOT EXISTS holidays (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  calendar_id uuid NOT NULL REFERENCES holiday_calendars(id) ON DELETE CASCADE,
  holiday_date date NOT NULL,
  name text NOT NULL,
  type text NOT NULL DEFAULT 'public' CHECK (type IN ('public','optional')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, calendar_id, holiday_date)
);

CREATE INDEX IF NOT EXISTS ix_holidays_date ON holidays (org_id, holiday_date);

CREATE TABLE IF NOT EXISTS employee_holiday_calendar (
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  calendar_id uuid NOT NULL REFERENCES holiday_calendars(id) ON DELETE CASCADE,
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  effective_to date NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, employee_id, effective_from),
  CONSTRAINT ck_employee_holiday_calendar_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

-- -----------------------------------------------------------------------------
-- Leave Management
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leave_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code text NOT NULL, -- e.g., CL, SL, PL
  name text NOT NULL,
  unit text NOT NULL DEFAULT 'day' CHECK (unit IN ('day','hour')),
  is_paid boolean NOT NULL DEFAULT true,
  allow_negative_balance boolean NOT NULL DEFAULT false,
  requires_approval boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, lower(code))
);

CREATE INDEX IF NOT EXISTS ix_leave_types_org ON leave_types (org_id);

CREATE TABLE IF NOT EXISTS leave_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text NULL,
  accrual_period text NOT NULL DEFAULT 'monthly' CHECK (accrual_period IN ('monthly','quarterly','yearly','none')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, lower(name))
);

CREATE TABLE IF NOT EXISTS leave_policy_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  policy_id uuid NOT NULL REFERENCES leave_policies(id) ON DELETE CASCADE,
  leave_type_id uuid NOT NULL REFERENCES leave_types(id) ON DELETE CASCADE,
  annual_entitlement numeric(10,2) NOT NULL DEFAULT 0 CHECK (annual_entitlement >= 0),
  carry_forward_limit numeric(10,2) NOT NULL DEFAULT 0 CHECK (carry_forward_limit >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, policy_id, leave_type_id)
);

CREATE INDEX IF NOT EXISTS ix_leave_policy_rules_policy ON leave_policy_rules (org_id, policy_id);

CREATE TABLE IF NOT EXISTS employee_leave_policy (
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  policy_id uuid NOT NULL REFERENCES leave_policies(id) ON DELETE CASCADE,
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  effective_to date NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, employee_id, effective_from),
  CONSTRAINT ck_employee_leave_policy_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE TABLE IF NOT EXISTS leave_balances (
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  leave_type_id uuid NOT NULL REFERENCES leave_types(id) ON DELETE CASCADE,
  balance numeric(10,2) NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, employee_id, leave_type_id)
);

CREATE INDEX IF NOT EXISTS ix_leave_balances_employee ON leave_balances (org_id, employee_id);

CREATE TABLE IF NOT EXISTS leave_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  leave_type_id uuid NOT NULL REFERENCES leave_types(id) ON DELETE RESTRICT,
  start_date date NOT NULL,
  end_date date NOT NULL,
  unit text NOT NULL DEFAULT 'day' CHECK (unit IN ('day','hour')),
  quantity numeric(10,2) NOT NULL DEFAULT 1 CHECK (quantity > 0),
  reason text NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled','withdrawn')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_leave_request_dates CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS ix_leave_requests_employee_status ON leave_requests (org_id, employee_id, status, start_date);
CREATE INDEX IF NOT EXISTS ix_leave_requests_status ON leave_requests (org_id, status, requested_at);

CREATE TABLE IF NOT EXISTS leave_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  leave_request_id uuid NOT NULL REFERENCES leave_requests(id) ON DELETE CASCADE,
  approver_employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
  decision text NOT NULL CHECK (decision IN ('approved','rejected')),
  comment text NULL,
  decided_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_leave_approvals_request ON leave_approvals (org_id, leave_request_id);

-- -----------------------------------------------------------------------------
-- Payroll metadata (not full payroll processing; designed for extensibility)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payroll_cycles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code text NOT NULL, -- e.g., 2026-01
  start_date date NOT NULL,
  end_date date NOT NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','processing','closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, lower(code)),
  CONSTRAINT ck_payroll_cycles_dates CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS ix_payroll_cycles_status ON payroll_cycles (org_id, status);

CREATE TABLE IF NOT EXISTS employee_compensation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  currency text NOT NULL DEFAULT 'INR',
  annual_ctc numeric(14,2) NOT NULL CHECK (annual_ctc >= 0),
  effective_from date NOT NULL DEFAULT CURRENT_DATE,
  effective_to date NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_employee_comp_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS ix_employee_comp_employee ON employee_compensation (org_id, employee_id, effective_from);

-- -----------------------------------------------------------------------------
-- Audit logs
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NULL REFERENCES organizations(id) ON DELETE SET NULL,
  actor_user_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
  actor_employee_id uuid NULL REFERENCES employees(id) ON DELETE SET NULL,
  action text NOT NULL,                 -- e.g., leave.approve
  entity_type text NOT NULL,            -- e.g., leave_request
  entity_id uuid NULL,
  ip inet NULL,
  user_agent text NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_audit_logs_org_time ON audit_logs (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_audit_logs_entity ON audit_logs (entity_type, entity_id);

-- -----------------------------------------------------------------------------
-- Seed data (initial org, roles, and admin)
-- -----------------------------------------------------------------------------
-- Default org
INSERT INTO organizations (id, name, slug, status)
VALUES ('00000000-0000-0000-0000-000000000001', 'SmartHR Demo Org', 'demo', 'active')
ON CONFLICT (slug) DO NOTHING;

-- Core roles for demo org
INSERT INTO roles (id, org_id, name, description, is_system)
VALUES
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000001', 'Admin', 'System administrator with full access', true),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000001', 'HR', 'HR role with employee and leave management', true),
  ('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000001', 'Manager', 'People manager role for approvals and team oversight', true),
  ('00000000-0000-0000-0000-000000000104', '00000000-0000-0000-0000-000000000001', 'Employee', 'Standard employee role', true)
ON CONFLICT (org_id, lower(name)) DO NOTHING;

-- Minimal permissions seed (expand in backend iterations)
INSERT INTO permissions (id, key, description)
VALUES
  ('00000000-0000-0000-0000-000000001001', 'auth.login', 'Login to the system'),
  ('00000000-0000-0000-0000-000000001002', 'employee.read', 'Read employees'),
  ('00000000-0000-0000-0000-000000001003', 'employee.write', 'Create/update employees'),
  ('00000000-0000-0000-0000-000000001004', 'leave.read', 'Read leave requests'),
  ('00000000-0000-0000-0000-000000001005', 'leave.apply', 'Apply for leave'),
  ('00000000-0000-0000-0000-000000001006', 'leave.approve', 'Approve/reject leave')
ON CONFLICT (lower(key)) DO NOTHING;

-- Assign a basic permission set to roles (demo)
-- Admin gets all permissions we seeded
INSERT INTO role_permissions (role_id, permission_id)
SELECT '00000000-0000-0000-0000-000000000101'::uuid, p.id
FROM permissions p
WHERE lower(p.key) IN ('auth.login','employee.read','employee.write','leave.read','leave.apply','leave.approve')
ON CONFLICT DO NOTHING;

-- HR
INSERT INTO role_permissions (role_id, permission_id)
SELECT '00000000-0000-0000-0000-000000000102'::uuid, p.id
FROM permissions p
WHERE lower(p.key) IN ('auth.login','employee.read','employee.write','leave.read','leave.approve')
ON CONFLICT DO NOTHING;

-- Manager
INSERT INTO role_permissions (role_id, permission_id)
SELECT '00000000-0000-0000-0000-000000000103'::uuid, p.id
FROM permissions p
WHERE lower(p.key) IN ('auth.login','employee.read','leave.read','leave.approve')
ON CONFLICT DO NOTHING;

-- Employee
INSERT INTO role_permissions (role_id, permission_id)
SELECT '00000000-0000-0000-0000-000000000104'::uuid, p.id
FROM permissions p
WHERE lower(p.key) IN ('auth.login','employee.read','leave.read','leave.apply')
ON CONFLICT DO NOTHING;

-- Default admin user (password: admin123) - bcrypt hash for "admin123"
-- IMPORTANT: backend should enforce must_change_password=true on first login.
INSERT INTO users (id, org_id, email, password_hash, is_active, must_change_password)
VALUES (
  '00000000-0000-0000-0000-000000000201',
  '00000000-0000-0000-0000-000000000001',
  'admin@demo.local',
  '$2b$12$7uZgB7L2l1w7kq9qkqQO8e6q8f2m1QxPpQ1J5q5Hqg1iXl1T0bQjW', -- bcrypt("admin123")
  true,
  true
)
ON CONFLICT (org_id, lower(email)) DO NOTHING;

-- Assign Admin role to admin user
INSERT INTO user_roles (user_id, role_id)
VALUES ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000101')
ON CONFLICT DO NOTHING;

-- Seed a default employee record for admin (optional but useful)
INSERT INTO employees (id, org_id, user_id, employee_code, first_name, last_name, work_email, job_title, department, status, employment_type, date_of_joining)
VALUES (
  '00000000-0000-0000-0000-000000000301',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000201',
  'EMP0001',
  'System',
  'Admin',
  'admin@demo.local',
  'Administrator',
  'Administration',
  'active',
  'full_time',
  CURRENT_DATE
)
ON CONFLICT (org_id, lower(employee_code)) DO NOTHING;

-- Minimal defaults for demo org: holiday calendar, leave types/policy
INSERT INTO holiday_calendars (id, org_id, name, timezone, is_default)
VALUES (
  '00000000-0000-0000-0000-000000002001',
  '00000000-0000-0000-0000-000000000001',
  'Default Calendar',
  'UTC',
  true
)
ON CONFLICT (org_id, lower(name)) DO NOTHING;

INSERT INTO leave_types (id, org_id, code, name, unit, is_paid, allow_negative_balance, requires_approval)
VALUES
  ('00000000-0000-0000-0000-000000003001', '00000000-0000-0000-0000-000000000001', 'CL', 'Casual Leave', 'day', true, false, true),
  ('00000000-0000-0000-0000-000000003002', '00000000-0000-0000-0000-000000000001', 'SL', 'Sick Leave', 'day', true, false, true),
  ('00000000-0000-0000-0000-000000003003', '00000000-0000-0000-0000-000000000001', 'LOP', 'Loss of Pay', 'day', false, true, true)
ON CONFLICT (org_id, lower(code)) DO NOTHING;

INSERT INTO leave_policies (id, org_id, name, description, accrual_period)
VALUES
  ('00000000-0000-0000-0000-000000003101', '00000000-0000-0000-0000-000000000001', 'Default Policy', 'Default leave policy for demo org', 'monthly')
ON CONFLICT (org_id, lower(name)) DO NOTHING;

INSERT INTO leave_policy_rules (org_id, policy_id, leave_type_id, annual_entitlement, carry_forward_limit)
VALUES
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000003101', '00000000-0000-0000-0000-000000003001', 12, 6),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000003101', '00000000-0000-0000-0000-000000003002', 12, 0),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000003101', '00000000-0000-0000-0000-000000003003', 0, 0)
ON CONFLICT (org_id, policy_id, leave_type_id) DO NOTHING;

-- Assign default leave policy to admin employee
INSERT INTO employee_leave_policy (org_id, employee_id, policy_id, effective_from)
VALUES ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000301', '00000000-0000-0000-0000-000000003101', CURRENT_DATE)
ON CONFLICT DO NOTHING;

COMMIT;
