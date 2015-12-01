/*
 * Relations using partitioning
 */
CREATE TABLE IF NOT EXISTS pg_pathman_rels (
	id         SERIAL PRIMARY KEY,
	relname    VARCHAR(127),
	attr       VARCHAR(127),
	parttype   INTEGER
);

/*
 * Relations using hash strategy
 */
CREATE TABLE IF NOT EXISTS pg_pathman_hash_rels (
	id         SERIAL PRIMARY KEY,
	parent     VARCHAR(127),
	hash       INTEGER,
	child      VARCHAR(127)
);

/*
 * Creates hash partitions for specified relation
 */
CREATE OR REPLACE FUNCTION public.create_hash_partitions(
	IN relation TEXT, IN attribute TEXT, IN partitions_count INTEGER
) RETURNS VOID AS
$$
DECLARE
	row       INTEGER;
	q         TEXT;
	relid     INTEGER;
	attnum    INTEGER;
	child_oid INTEGER;
BEGIN
	relid := relfilenode FROM pg_class WHERE relname = relation;
	attnum := pg_attribute.attnum FROM pg_attribute WHERE attrelid = relid AND attname = attribute;

	IF EXISTS (SELECT * FROM pg_pathman_rels WHERE relname = relation) THEN
		RAISE EXCEPTION 'Reltion "%s" has already been partitioned', relation;
	END IF;

	/* Create partitions and update pg_pathman configuration */
	FOR partnum IN 0..partitions_count-1
	LOOP
		-- EXECUTE format('CREATE TABLE %s_%s (LIKE %1$s INCLUDING ALL)', relation, partnum);
		EXECUTE format('CREATE TABLE %s_%s () INHERITS (%1$s)', relation, partnum);
		-- child_oid := relfilenode FROM pg_class WHERE relname = format('%s_%s', relation, partnum);
		INSERT INTO pg_pathman_hash_rels (parent, hash, child)
		VALUES (relation, partnum, format('%s_%s', relation, partnum));
	END LOOP;
	INSERT INTO pg_pathman_rels (relname, attr, parttype) VALUES (relation, attribute, 1);

	/* Create triggers */
	PERFORM create_hash_insert_trigger(relation, attribute, partitions_count);
	PERFORM create_hash_update_trigger(relation, attribute, partitions_count);
	/* Notify backend about changes */
	PERFORM pg_pathman_on_create_partitions(relid);
END
$$ LANGUAGE plpgsql;

/*
 * Creates hash trigger for specified relation
 */
CREATE OR REPLACE FUNCTION public.create_hash_insert_trigger(IN relation TEXT, IN attr TEXT, IN partitions_count INTEGER)
RETURNS VOID AS
$$
DECLARE
	func TEXT := 'CREATE OR REPLACE FUNCTION %s_hash_insert_trigger_func() ' ||
		'RETURNS TRIGGER AS $body$ DECLARE hash INTEGER; BEGIN ' ||
		'hash := NEW.%s %% %s; %s ' ||
		'RETURN NULL; END $body$ LANGUAGE plpgsql;';
	trigger TEXT := 'CREATE TRIGGER %s_insert_trigger ' ||
		'BEFORE INSERT ON %1$s ' ||
		'FOR EACH ROW EXECUTE PROCEDURE %1$s_hash_insert_trigger_func();';
	relid INTEGER;
	fields TEXT;
	fields_format TEXT;
	insert_stmt TEXT;
BEGIN
	/* drop trigger and corresponding function */
	PERFORM drop_hash_triggers(relation);

	/* determine fields for INSERT */
	relid := relfilenode FROM pg_class WHERE relname = relation;
	SELECT string_agg('NEW.' || attname, ', '), string_agg('$' || attnum, ', ')
	FROM pg_attribute
	WHERE attrelid=relid AND attnum>0
	INTO fields, fields_format;

	/* generate INSERT statement for trigger */
	insert_stmt = format('EXECUTE format(''INSERT INTO %s_%%s VALUES (%s)'', hash) USING %s;',
		relation, fields_format, fields);

	/* format and create new trigger for relation */
	func := format(func, relation, attr, partitions_count, insert_stmt);

	trigger := format(trigger, relation);
	EXECUTE func;
	EXECUTE trigger;
END
$$ LANGUAGE plpgsql;

/*
 * Drops all partitions for specified relation
 */
CREATE OR REPLACE FUNCTION public.drop_hash_partitions(IN relation TEXT)
RETURNS VOID AS
$$
DECLARE
	relid INTEGER;
	partitions_count INTEGER;
	q TEXT := 'DROP TABLE %s_%s';
BEGIN
	/* Drop trigger first */
	PERFORM drop_hash_triggers(relation);

	relid := relfilenode FROM pg_class WHERE relname = relation;
	partitions_count := COUNT(*) FROM pg_pathman_hash_rels WHERE parent = relation;

	FOR partnum IN 0..partitions_count-1
	LOOP
		EXECUTE format(q, relation, partnum);
	END LOOP;

	DELETE FROM pg_pathman_rels WHERE relname = relation;
	DELETE FROM pg_pathman_hash_rels WHERE parent = relation;

	/* Notify backend about changes */
	PERFORM pg_pathman_on_remove_partitions(relid);
END
$$ LANGUAGE plpgsql;

/*
 * Drops hash trigger
 */
CREATE OR REPLACE FUNCTION public.drop_hash_triggers(IN relation TEXT)
RETURNS VOID AS
$$
BEGIN
	EXECUTE format('DROP TRIGGER IF EXISTS %s_insert_trigger ON %1$s', relation);
	EXECUTE format('DROP FUNCTION IF EXISTS %s_hash_insert_trigger_func()', relation);
	EXECUTE format('DROP TRIGGER IF EXISTS %s_update_trigger ON %1$s', relation);
	EXECUTE format('DROP FUNCTION IF EXISTS %s_hash_update_trigger_func()', relation);
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pg_pathman_on_create_partitions(relid INTEGER)
RETURNS VOID AS 'pathman', 'on_partitions_created' LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION pg_pathman_on_remove_partitions(relid INTEGER)
RETURNS VOID AS 'pathman', 'on_partitions_removed' LANGUAGE C STRICT;


CREATE OR REPLACE FUNCTION public.create_hash_update_trigger(IN relation TEXT, IN attr TEXT, IN partitions_count INTEGER)
RETURNS VOID AS
$$
DECLARE
	func TEXT := 'CREATE OR REPLACE FUNCTION %s_update_trigger_func() RETURNS TRIGGER AS ' ||
				 '$body$ DECLARE old_hash INTEGER; new_hash INTEGER; q TEXT; BEGIN '       ||
				 'old_hash := OLD.%2$s %% %3$s; '                                          ||
				 'new_hash := NEW.%2$s %% %3$s; '                                          ||
				 'IF old_hash = new_hash THEN RETURN NEW; END IF; '                        ||
				 'q := format(''DELETE FROM %1$s_%%s WHERE %4$s'', old_hash); '            ||
				 'EXECUTE q USING %5$s; '                                                  ||
				 'q := format(''INSERT INTO %1$s_%%s VALUES (%6$s)'', new_hash); '         ||
				 'EXECUTE q USING %7$s; '                                                  ||
				 'RETURN NULL; '                                                           ||
				 'END $body$ LANGUAGE plpgsql';
	trigger TEXT := 'CREATE TRIGGER %s_update_trigger ' ||	
		'BEFORE UPDATE ON %1$s_%s ' ||
		'FOR EACH ROW EXECUTE PROCEDURE %1$s_update_trigger_func()';
	att_names   TEXT;
	old_fields  TEXT;
	new_fields  TEXT;
	att_val_fmt TEXT;
	att_fmt     TEXT;
	relid       INTEGER;
BEGIN
	relid := relfilenode FROM pg_class WHERE relname = relation;
	SELECT string_agg(attname, ', '),
		   string_agg('OLD.' || attname, ', '),
		   string_agg('NEW.' || attname, ', '),
		   string_agg(attname || '=$' || attnum, ' AND '),
		   string_agg('$' || attnum, ', ')
	FROM pg_attribute
	WHERE attrelid=relid AND attnum>0
	INTO   att_names,
		   old_fields,
		   new_fields,
		   att_val_fmt,
		   att_fmt;

	EXECUTE format(func, relation, attr, partitions_count, att_val_fmt,
				   old_fields, att_fmt, new_fields);
	FOR num IN 0..partitions_count-1
	LOOP
		EXECUTE format(trigger, relation, num);
	END LOOP;
END
$$ LANGUAGE plpgsql;

-- CREATE OR REPLACE FUNCTION sample_rel_trigger_func()
-- RETURNS TRIGGER AS $$
-- DECLARE
-- 	hash integer := 0;
-- 	-- q TEXT = 'INSERT INTO sample_rel_% VALUES (NEW.*)';
-- BEGIN
-- 	hash := NEW.val % 1000;
-- 	EXECUTE format('INSERT INTO sample_rel_%s VALUES ($1, $2)', hash)
-- 		USING NEW.id, NEW.val;
-- 	RETURN NULL;
-- END
-- $$ LANGUAGE plpgsql;

-- CREATE TRIGGER sample_rel_trigger
-- 	BEFORE INSERT ON sample_rel
-- 	FOR EACH ROW EXECUTE PROCEDURE sample_rel_trigger_func();



/* INHERITANCE TEST */
-- CREATE OR REPLACE FUNCTION public.create_children_tables(IN relation TEXT)
-- RETURNS INTEGER AS $$
-- DECLARE
-- 	q TEXT := 'CREATE TABLE %s_%s (CHECK (val IN (%s))) INHERITS (%s)';
-- BEGIN
-- 	FOR partnum IN 0..999
-- 	LOOP
-- 		EXECUTE format(q, relation, partnum, partnum, relation);
-- 	END LOOP;
-- 	RETURN 0;
-- END
-- $$ LANGUAGE plpgsql;

/* sample data */
-- insert into pg_pathman_rels (oid, attnum, parttype) values (49350, 2, 1);
-- insert into pg_pathman_hash_rels (parent_oid, hash, child_oid) values (49350, 1, 49355);
-- insert into pg_pathman_hash_rels (parent_oid, hash, child_oid) values (49350, 0, 49360);
