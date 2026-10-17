-- e2e: oracle_tables lists tables, views and synonyms (with a synonym's target) of the current schema, of another schema, and PUBLIC
-- (needs test/e2e/setup/common/00_schema.sql)
-- timeout: 120
CREATE TEMP TABLE mine AS SELECT * FROM oracle_tables('@DSN@');
CREATE TEMP TABLE theirs AS SELECT * FROM oracle_tables('@DSN@', schema := 'e2e_owner');
CREATE TEMP TABLE pubs AS SELECT * FROM oracle_tables('@DSN@', schema := 'PUBLIC');
CREATE TEMP TABLE switched AS SELECT * FROM oracle_tables('@DSN@', current_schema := 'E2E_OWNER');
CREATE TEMP TABLE one AS SELECT * FROM oracle_tables('@DSN@', schema := 'e2e_owner') LIMIT 1;
DESCRIBE SELECT * FROM mine;
SELECT * FROM theirs ORDER BY name;
CREATE TEMP TABLE checks AS
SELECT 'columns are owner, name, type, synonym_target' AS name,
       (SELECT list(column_name ORDER BY ordinal_position) FROM information_schema.columns WHERE table_name = 'mine') = ['owner', 'name', 'type', 'synonym_target'] AS ok
UNION ALL SELECT 'all columns are VARCHAR', (SELECT count(DISTINCT data_type) FROM information_schema.columns WHERE table_name = 'mine') = 1
       AND (SELECT any_value(data_type) FROM information_schema.columns WHERE table_name = 'mine') = 'VARCHAR'
UNION ALL SELECT 'the current schema: a table', type = 'TABLE' AND synonym_target IS NULL FROM mine WHERE name = 'E2E_SHADOWED'
UNION ALL SELECT 'the current schema: a private synonym and its target', type = 'SYNONYM' AND synonym_target = 'E2E_OWNER.PEOPLE' FROM mine WHERE name = 'PEOPLE_SYN'
UNION ALL SELECT 'the current schema: one owner only', count(DISTINCT owner) = 1 FROM mine
UNION ALL SELECT 'no recycle-bin objects', count(*) FILTER (WHERE name LIKE 'BIN$%') = 0 FROM mine
UNION ALL SELECT 'another schema: exactly its table, view and quoted table',
       list(name || ':' || type ORDER BY name) = ['MixedCase:TABLE', 'PEOPLE:TABLE', 'PEOPLE_V:VIEW'] FROM theirs
UNION ALL SELECT 'another schema: the owner column', count(*) FILTER (WHERE owner = 'E2E_OWNER') = 3 FROM theirs
UNION ALL SELECT 'PUBLIC: a public synonym and its target', type = 'SYNONYM' AND synonym_target = 'E2E_OWNER.PEOPLE' FROM pubs WHERE name = 'E2E_PUB_PEOPLE'
UNION ALL SELECT 'PUBLIC: the shadowed name is a public synonym too', owner = 'PUBLIC' AND type = 'SYNONYM' FROM pubs WHERE name = 'E2E_SHADOWED'
UNION ALL SELECT 'current_schema changes the default schema', list(name ORDER BY name) = (SELECT list(name ORDER BY name) FROM theirs) FROM switched
UNION ALL SELECT 'LIMIT 1', count(*) = 1 FROM one;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
