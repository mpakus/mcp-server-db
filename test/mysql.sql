USE mcp_test;
CREATE TABLE users (id INT PRIMARY KEY, label VARCHAR(100), email VARCHAR(100), balance DECIMAL(20,3), big_id BIGINT, created_at DATETIME);
INSERT INTO users VALUES (1, 'sample', 'john@example.com', 123.450, 9223372036854775000, '2026-09-30 12:30:00');
CREATE DATABASE mcp_locked;
CREATE TABLE mcp_locked.users (id INT PRIMARY KEY, label VARCHAR(100));
INSERT INTO mcp_locked.users VALUES (1, 'locked');
GRANT ALL ON mcp_locked.* TO 'mcp_test'@'%';
GRANT EXECUTE ON mcp_test.* TO 'mcp_test'@'%';
DELIMITER //
CREATE FUNCTION mutate_count() RETURNS INT MODIFIES SQL DATA
BEGIN
  UPDATE users SET label = 'unexpected mutation' WHERE id = 1;
  RETURN 1;
END//
DELIMITER ;
