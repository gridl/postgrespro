\set VERBOSITY terse

CREATE SCHEMA test;

CREATE EXTENSION pathman;

CREATE TABLE test.hash_rel (
    id      SERIAL PRIMARY KEY,
    value   INTEGER);
SELECT create_hash_partitions('test.hash_rel', 'value', 3);

CREATE TABLE test.range_rel (
    id SERIAL PRIMARY KEY,
    dt TIMESTAMP,
    txt TEXT);
SELECT create_range_partitions('test.range_rel', 'dt', '2015-01-01'::DATE, '1 month'::INTERVAL, 3);

CREATE TABLE test.num_range_rel (
    id SERIAL PRIMARY KEY,
    txt TEXT);
SELECT create_range_partitions('test.num_range_rel', 'id', 0, 1000, 3);

INSERT INTO test.hash_rel VALUES (1, 1);
INSERT INTO test.hash_rel VALUES (2, 2);
INSERT INTO test.hash_rel VALUES (3, 3);
INSERT INTO test.hash_rel VALUES (4, 4);
INSERT INTO test.hash_rel VALUES (5, 5);
INSERT INTO test.hash_rel VALUES (6, 6);

INSERT INTO test.num_range_rel SELECT g, md5(g::TEXT) FROM generate_series(1, 3000) as g;
VACUUM;

SET enable_indexscan = OFF;
SET enable_bitmapscan = OFF;
SET enable_seqscan = ON;

EXPLAIN (COSTS OFF) SELECT * FROM test.hash_rel;
EXPLAIN (COSTS OFF) SELECT * FROM test.hash_rel WHERE value = 2;
EXPLAIN (COSTS OFF) SELECT * FROM test.hash_rel WHERE value = 2 OR value = 1;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id > 2500;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id >= 1000 AND id < 3000;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id >= 1500 AND id < 2500;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE (id >= 500 AND id < 1500) OR (id > 2500);

SET enable_indexscan = ON;
SET enable_bitmapscan = OFF;
SET enable_seqscan = OFF;

EXPLAIN (COSTS OFF) SELECT * FROM test.hash_rel;
EXPLAIN (COSTS OFF) SELECT * FROM test.hash_rel WHERE value = 2;
EXPLAIN (COSTS OFF) SELECT * FROM test.hash_rel WHERE value = 2 OR value = 1;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id > 2500;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id >= 1000 AND id < 3000;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id >= 1500 AND id < 2500;
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE (id >= 500 AND id < 1500) OR (id > 2500);

/*
 * Test split and merge
 */

/* Split first partition in half */
SELECT split_range_partition('test.num_range_rel_1', 500);
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id BETWEEN 100 AND 700;

SELECT split_range_partition('test.range_rel_1', '2015-01-15'::DATE);

/* Merge two partitions into one */
SELECT merge_range_partitions('test.num_range_rel_1', 'test.num_range_rel_' || currval('test.num_range_rel_seq'));
EXPLAIN (COSTS OFF) SELECT * FROM test.num_range_rel WHERE id BETWEEN 100 AND 700;

SELECT merge_range_partitions('test.range_rel_1', 'test.range_rel_' || currval('test.range_rel_seq'));

/* Append and prepend partitions */
SELECT append_partition('test.num_range_rel');
SELECT prepend_partition('test.num_range_rel');

SELECT append_partition('test.range_rel');
SELECT prepend_partition('test.range_rel');

/*
 * Clean up
 */
SELECT drop_hash_partitions('test.hash_rel');
DROP TABLE test.hash_rel CASCADE;

SELECT drop_range_partitions('test.num_range_rel');
DROP TABLE test.num_range_rel CASCADE;

DROP EXTENSION pathman;
