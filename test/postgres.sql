CREATE TABLE public.users (id INTEGER PRIMARY KEY, label TEXT, email TEXT, balance NUMERIC(20,3), big_id BIGINT, created_at TIMESTAMP);
INSERT INTO public.users VALUES (1, 'sample', 'john@example.com', 123.450, 9223372036854775000, '2026-09-30 12:30:00');
CREATE SCHEMA locked;
CREATE TABLE locked.users (id INTEGER PRIMARY KEY, label TEXT);
INSERT INTO locked.users VALUES (1, 'locked');
CREATE FUNCTION public.mutate_count() RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.users SET label = 'unexpected mutation' WHERE id = 1;
  RETURN 1;
END;
$$;
CREATE FUNCTION mcp_test_sleep(double precision) RETURNS void
LANGUAGE sql AS $$ SELECT pg_sleep($1); $$;
