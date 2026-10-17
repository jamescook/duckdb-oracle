-- e2e: oracle_scan resolves a name the way Oracle does (the current schema first, then public synonyms) and reads tables, views,
-- private and public synonyms, qualified, quoted and case-sensitive names, and names in another schema via current_schema
-- (needs the objects of test/e2e/setup/common/00_schema.sql, run first by tools/e2e-setup.sh)
-- timeout: 120
CREATE TEMP TABLE shadow AS SELECT * FROM oracle_scan('@DSN@', 'e2e_shadowed');
CREATE TEMP TABLE shadow_upper AS SELECT * FROM oracle_scan('@DSN@', 'E2E_SHADOWED');
CREATE TEMP TABLE pub AS SELECT * FROM oracle_scan('@DSN@', 'e2e_pub_people');
CREATE TEMP TABLE priv AS SELECT * FROM oracle_scan('@DSN@', 'people_syn');
CREATE TEMP TABLE qual AS SELECT * FROM oracle_scan('@DSN@', 'e2e_owner.people');
CREATE TEMP TABLE vw AS SELECT * FROM oracle_scan('@DSN@', ' E2E_OWNER . PEOPLE_V ');
CREATE TEMP TABLE mixed AS SELECT * FROM oracle_scan('@DSN@', 'e2e_owner."MixedCase"');
CREATE TEMP TABLE mixed_bare AS SELECT * FROM oracle_scan('@DSN@', '"MixedCase"', current_schema := 'e2e_owner');
CREATE TEMP TABLE switched AS SELECT * FROM oracle_scan('@DSN@', 'people', current_schema := 'E2E_OWNER');
CREATE TEMP TABLE lim AS SELECT * FROM oracle_scan('@DSN@', 'e2e_owner.people') LIMIT 2;
DESCRIBE SELECT * FROM mixed;
CREATE TEMP TABLE checks AS
SELECT 'the schema''s own table beats a public synonym of the same name' AS name,
       count(*) = 1 AND any_value(id) = 99 AND any_value(name) = 'local table' AS ok FROM shadow
UNION ALL SELECT 'an unquoted name is folded to upper case', count(*) = 1 AND any_value(id) = 99 FROM shadow_upper
UNION ALL SELECT 'a public synonym', list(name ORDER BY id) = ['Ada', 'Grace', NULL] FROM pub
UNION ALL SELECT 'a private synonym', list(name ORDER BY id) = ['Ada', 'Grace', NULL] FROM priv
UNION ALL SELECT 'a qualified name', list(name ORDER BY id) = ['Ada', 'Grace', NULL] FROM qual
UNION ALL SELECT 'a view, and spaces around the dot are ignored',
       list(name_upper ORDER BY id) = ['ADA', 'GRACE', NULL] FROM vw
UNION ALL SELECT 'a quoted case-sensitive table and column', list("Odd Col" ORDER BY id) = ['ten', 'twenty'] FROM mixed
UNION ALL SELECT 'the column names keep their case',
       (SELECT list(column_name ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name = 'mixed') = ['id', 'Odd Col']
UNION ALL SELECT 'a bare quoted name resolved in current_schema', list("Odd Col" ORDER BY id) = ['ten', 'twenty'] FROM mixed_bare
UNION ALL SELECT 'a bare name resolved in current_schema', list(name ORDER BY id) = ['Ada', 'Grace', NULL] FROM switched
UNION ALL SELECT 'NUMBER(10) is BIGINT', (SELECT data_type FROM information_schema.columns WHERE table_name = 'qual' AND column_name = 'id') = 'BIGINT'
UNION ALL SELECT 'LIMIT 2', count(*) = 2 FROM lim;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
