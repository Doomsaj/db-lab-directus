CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'order_status') THEN
    CREATE TYPE order_status AS ENUM ('draft','placed','paid','shipped','completed','cancelled','refunded');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'invoice_status') THEN
    CREATE TYPE invoice_status AS ENUM ('draft','issued','paid','overdue','cancelled');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'time_event_type') THEN
    CREATE TYPE time_event_type AS ENUM ('in','out','break_start','break_end');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_status') THEN
    CREATE TYPE lead_status AS ENUM ('new','contacted','qualified','lost','won');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'activity_type') THEN
    CREATE TYPE activity_type AS ENUM ('call','email','meeting','note','task');
  END IF;
END$$;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION trg_set_full_name()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.full_name := trim(coalesce(NEW.first_name, '') || ' ' || coalesce(NEW.last_name, ''));
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS products (
  id bigserial PRIMARY KEY,
  sku text UNIQUE,
  title text NOT NULL,
  description text,
  brand text,
  category text,
  price numeric(12,2) NOT NULL DEFAULT 0,
  cost_price numeric(12,2),
  stock_threshold integer DEFAULT 0,
  attributes jsonb DEFAULT '{}'::jsonb,
  is_active boolean DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_products_sku_title ON products(sku, title);
CREATE INDEX IF NOT EXISTS idx_products_title_tsv ON products USING gin (to_tsvector('english', coalesce(title,'')));

DROP TRIGGER IF EXISTS trg_products_updated ON products;
CREATE TRIGGER trg_products_updated
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS customers (
  id bigserial PRIMARY KEY,
  external_id text UNIQUE,
  first_name text,
  last_name text,
  full_name text,
  email text,
  phone text,
  dob date,
  billing_address jsonb,
  shipping_address jsonb,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_customers_email ON customers(email);

DROP TRIGGER IF EXISTS trg_customers_full_name ON customers;
CREATE TRIGGER trg_customers_full_name
BEFORE INSERT OR UPDATE ON customers
FOR EACH ROW EXECUTE FUNCTION trg_set_full_name();

DROP TRIGGER IF EXISTS trg_customers_updated ON customers;
CREATE TRIGGER trg_customers_updated
BEFORE UPDATE ON customers
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS orders (
  id bigserial PRIMARY KEY,
  order_number text UNIQUE,
  customer_id bigint REFERENCES customers(id) ON DELETE SET NULL,
  store_code text,
  status order_status DEFAULT 'draft',
  subtotal numeric(12,2) DEFAULT 0,
  tax numeric(12,2) DEFAULT 0,
  shipping numeric(12,2) DEFAULT 0,
  discount numeric(12,2) DEFAULT 0,
  total numeric(12,2) DEFAULT 0,
  placed_at timestamptz,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  notes text
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);

DROP TRIGGER IF EXISTS trg_orders_updated ON orders;
CREATE TRIGGER trg_orders_updated
BEFORE UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS order_items (
  id bigserial PRIMARY KEY,
  order_id bigint NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id bigint REFERENCES products(id) ON DELETE SET NULL,
  sku text,
  description text,
  unit_price numeric(12,2) NOT NULL DEFAULT 0,
  quantity integer NOT NULL DEFAULT 1,
  line_total numeric(14,2) GENERATED ALWAYS AS (unit_price * quantity) STORED,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orderitems_order ON order_items(order_id);

CREATE TABLE IF NOT EXISTS invoices (
  id bigserial PRIMARY KEY,
  invoice_number text UNIQUE,
  order_id bigint REFERENCES orders(id) ON DELETE SET NULL,
  customer_id bigint REFERENCES customers(id) ON DELETE SET NULL,
  issued_at timestamptz DEFAULT now(),
  due_at timestamptz,
  status invoice_status DEFAULT 'draft',
  subtotal numeric(12,2) DEFAULT 0,
  tax numeric(12,2) DEFAULT 0,
  discount numeric(12,2) DEFAULT 0,
  total numeric(12,2) DEFAULT 0,
  paid_at timestamptz,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_invoices_order ON invoices(order_id);
CREATE INDEX IF NOT EXISTS idx_invoices_customer ON invoices(customer_id);

DROP TRIGGER IF EXISTS trg_invoices_updated ON invoices;
CREATE TRIGGER trg_invoices_updated
BEFORE UPDATE ON invoices
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS invoice_items (
  id bigserial PRIMARY KEY,
  invoice_id bigint NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  product_id bigint REFERENCES products(id) ON DELETE SET NULL,
  description text,
  unit_price numeric(12,2) NOT NULL DEFAULT 0,
  quantity integer NOT NULL DEFAULT 1,
  line_total numeric(14,2) GENERATED ALWAYS AS (unit_price * quantity) STORED
);

CREATE INDEX IF NOT EXISTS idx_invoiceitems_invoice ON invoice_items(invoice_id);

CREATE TABLE IF NOT EXISTS employees (
  id bigserial PRIMARY KEY,
  employee_code text UNIQUE,
  first_name text,
  last_name text,
  full_name text,
  email text UNIQUE,
  phone text,
  role text,
  hire_date date,
  active boolean DEFAULT true,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_employees_code ON employees(employee_code);

DROP TRIGGER IF EXISTS trg_employees_full_name ON employees;
CREATE TRIGGER trg_employees_full_name
BEFORE INSERT OR UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_set_full_name();

DROP TRIGGER IF EXISTS trg_employees_updated ON employees;
CREATE TRIGGER trg_employees_updated
BEFORE UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS employee_time_logs (
  id bigserial PRIMARY KEY,
  employee_id bigint NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  event_type time_event_type NOT NULL DEFAULT 'in',
  event_at timestamptz NOT NULL DEFAULT now(),
  location text,
  note text,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_time_logs_employee_at ON employee_time_logs(employee_id, event_at);

CREATE TABLE IF NOT EXISTS crm_companies (
  id bigserial PRIMARY KEY,
  name text NOT NULL,
  website text,
  address jsonb,
  industry text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_crm_companies_updated ON crm_companies;
CREATE TRIGGER trg_crm_companies_updated
BEFORE UPDATE ON crm_companies
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS crm_contacts (
  id bigserial PRIMARY KEY,
  company_id bigint REFERENCES crm_companies(id) ON DELETE SET NULL,
  customer_id bigint REFERENCES customers(id) ON DELETE SET NULL,
  first_name text,
  last_name text,
  email text,
  phone text,
  title text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_contacts_email ON crm_contacts(email);

CREATE TABLE IF NOT EXISTS crm_leads (
  id bigserial PRIMARY KEY,
  title text NOT NULL,
  source text,
  contact_id bigint REFERENCES crm_contacts(id) ON DELETE SET NULL,
  company_id bigint REFERENCES crm_companies(id) ON DELETE SET NULL,
  status lead_status DEFAULT 'new',
  value numeric(12,2),
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_crm_leads_updated ON crm_leads;
CREATE TRIGGER trg_crm_leads_updated
BEFORE UPDATE ON crm_leads
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS crm_activities (
  id bigserial PRIMARY KEY,
  related_type text,
  related_id bigint,
  activity_type activity_type NOT NULL DEFAULT 'note',
  subject text,
  body text,
  performed_by bigint REFERENCES employees(id),
  performed_at timestamptz DEFAULT now(),
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_crm_activities_related ON crm_activities(related_type, related_id);