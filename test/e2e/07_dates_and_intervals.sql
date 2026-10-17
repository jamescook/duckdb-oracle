-- e2e: DATE, TIMESTAMP, TIMESTAMP WITH (LOCAL) TIME ZONE, INTERVAL DAY TO SECOND / YEAR TO MONTH
CREATE TEMP TABLE r AS SELECT * FROM oracle_query('@DSN@', 'SELECT
  TO_DATE(''2024-02-29 13:45:30'', ''YYYY-MM-DD HH24:MI:SS'')                  AS d,
  TO_DATE(''1900-01-01'', ''YYYY-MM-DD'')                                       AS d_1900,
  TO_DATE(''9999-12-31 23:59:59'', ''YYYY-MM-DD HH24:MI:SS'')                  AS d_max,
  TIMESTAMP ''2024-02-29 13:45:30.123456''                                     AS ts,
  TIMESTAMP ''2024-02-29 13:45:30.123456789''                                  AS ts9,
  TIMESTAMP ''2024-01-01 10:00:00 +05:30''                                     AS tstz,
  TIMESTAMP ''2024-01-01 10:00:00 -03:30''                                     AS tstz_neg,
  CAST(TIMESTAMP ''2024-01-01 10:00:00 +05:30'' AS TIMESTAMP WITH LOCAL TIME ZONE) AS tsltz,
  INTERVAL ''3 04:05:06.007'' DAY TO SECOND                                    AS ids,
  INTERVAL ''-1 02:03:04'' DAY TO SECOND                                       AS ids_neg,
  INTERVAL ''2-3'' YEAR TO MONTH                                               AS iym,
  INTERVAL ''-2-3'' YEAR TO MONTH                                              AS iym_neg
FROM dual');
DESCRIBE SELECT * FROM r;
SELECT * FROM r;
CREATE TEMP TABLE checks AS
SELECT 'DATE is TIMESTAMP' AS name, typeof(d) = 'TIMESTAMP' AS ok FROM r
UNION ALL SELECT 'DATE value', d = TIMESTAMP '2024-02-29 13:45:30' FROM r
UNION ALL SELECT 'DATE 1900-01-01 (before the epoch)', epoch_us(d_1900) = -2208988800000000 FROM r
UNION ALL SELECT 'DATE 9999-12-31 23:59:59', epoch_us(d_max) = 253402300799000000 FROM r
UNION ALL SELECT 'TIMESTAMP microseconds', ts = TIMESTAMP '2024-02-29 13:45:30.123456' FROM r
UNION ALL SELECT 'TIMESTAMP(9) truncated to microseconds', epoch_us(ts9) % 1000000 = 123456 FROM r
UNION ALL SELECT 'TIMESTAMP WITH TIME ZONE is TIMESTAMPTZ', typeof(tstz) = 'TIMESTAMP WITH TIME ZONE' FROM r
UNION ALL SELECT 'TSTZ +05:30 is 04:30 UTC', epoch_us(tstz) = 1704083400000000 FROM r
UNION ALL SELECT 'TSTZ -03:30 is 13:30 UTC', epoch_us(tstz_neg) = 1704115800000000 FROM r
UNION ALL SELECT 'TSLTZ is the same instant', epoch_us(tsltz) = 1704083400000000 FROM r
UNION ALL SELECT 'INTERVAL DS is INTERVAL', typeof(ids) = 'INTERVAL' FROM r
UNION ALL SELECT 'INTERVAL DS value', ids = INTERVAL '3 days 4 hours 5 minutes 6.007 seconds' FROM r
UNION ALL SELECT 'INTERVAL DS negative', ids_neg = INTERVAL '-1 days -2 hours -3 minutes -4 seconds' FROM r
UNION ALL SELECT 'INTERVAL YM value', iym = INTERVAL '27 months' FROM r
UNION ALL SELECT 'INTERVAL YM negative', iym_neg = INTERVAL '-27 months' FROM r;

SELECT * FROM checks WHERE ok IS NOT TRUE;
SELECT CASE WHEN count(*) FILTER (WHERE ok IS NOT TRUE) = 0
            THEN 'PASS: ' || count(*) || ' checks'
            ELSE error('FAILED: ' || string_agg(name, ', ') FILTER (WHERE ok IS NOT TRUE)) END AS result
FROM checks;
