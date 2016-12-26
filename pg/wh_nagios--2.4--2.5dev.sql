-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION  wh_nagios UPDATE" to load this file. \quit

-- This program is open source, licensed under the PostgreSQL License.
-- For license terms, see the LICENSE file.
--
-- Copyright (C) 2012-2014: Open PostgreSQL Monitoring Development Group

/*
 * Major change of perfdata storage.
 *
 * - lock the hub table, to wait dispatching completin and prevent new ones
 * - lock all needed tables to make sure we won't exhaust locks and prevent
 *   possible deadlock
 * - rewrite the perfdata
 * - drop former perfdata tables
 * - change the triggers
 */

DO $_$
DECLARE
    v_tbl text;
    v_stmt text;
    v_id_service bigint;
    v_id_metric bigint;
BEGIN
    RAISE NOTICE 'Step 1, locking all tables...';

    LOCK TABLE wh_nagios.hub;

    FOR v_tbl IN
        SELECT relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
        AND nspname = 'wh_nagios'
    LOOP
        v_stmt := format('LOCK TABLE "wh_nagios".%I', v_tbl);
        RAISE DEBUG 'step1 - statement: %', v_stmt;
        EXECUTE v_stmt;
    END LOOP;
    RAISE NOTICE 'done';

    RAISE NOTICE 'Step 2, migrate perfdata (this can be quite long)...';

    FOR v_id_service IN
        SELECT id
        FROM wh_nagios.services
    LOOP
        v_stmt := format('CREATE TABLE wh_nagios.service_counters_%s ('
            'id_metric bigint REFERENCES wh_nagios.metrics (id) ON UPDATE CASCADE ON DELETE CASCADE,'
            'date_records date,'
            'records metric_value[])', v_id_service);
        RAISE DEBUG 'step2 - statement: %', v_stmt;
        EXECUTE v_stmt;

        -- We need to drop the partition from the extension for further drop of
        -- the partition won't require any special action
        v_stmt := format('ALTER EXTENSION wh_nagios
            DROP TABLE wh_nagios.service_counters_%s', v_id_service);
        RAISE DEBUG 'step2 - statement: %', v_stmt;
        EXECUTE v_stmt;

        FOR v_id_metric IN
            SELECT id
            FROM wh_nagios.metrics
            WHERE id_service = v_id_service
        LOOP
            v_stmt = format('INSERT INTO wh_nagios.service_counters_%s SELECT '
                '%2$s, date_records, records '
                'FROM wh_nagios.counters_detail_%2$s',
                v_id_service, v_id_metric);
            RAISE DEBUG 'step2 - statement %', v_stmt;
            EXECUTE v_stmt;

            v_stmt = format('DROP TABLE wh_nagios.counters_detail_%s',
                v_id_metric);
            RAISE DEBUG 'step2 - statement %', v_stmt;
            EXECUTE v_stmt;
        END LOOP;

        v_stmt = format('CREATE INDEX ON wh_nagios.service_counters_%s '
            'USING btree (id_metric, date_records)', v_id_service);
        RAISE DEBUG 'step2 - statement %', v_stmt;
        EXECUTE v_stmt;
    END LOOP;

    RAISE NOTICE 'done';
END;
$_$ language plpgsql;

-- Drop old trigger, and replace with new one now that counters are updated
DROP TRIGGER create_partition_on_insert_metric ON wh_nagios.metrics;
DROP TRIGGER drop_partition_on_delete_metric ON wh_nagios.metrics;
DROP FUNCTION wh_nagios.create_partition_on_insert_metric();
DROP FUNCTION wh_nagios.drop_partition_on_delete_metric();


-- Automatically create a new partition when a service is added.
CREATE FUNCTION wh_nagios.create_partition_on_insert_service()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE pg_catalog.format('CREATE TABLE wh_nagios.service_counters_%s (id_metric bigint, date_records date, records public.metric_value[])', NEW.id);
    EXECUTE pg_catalog.format('CREATE INDEX ON wh_nagios.service_counters_%s USING btree(id_metric, date_records)', NEW.id);
    EXECUTE pg_catalog.format('REVOKE ALL ON TABLE wh_nagios.service_counters_%s FROM public', NEW.id);

    RETURN NEW;
EXCEPTION
    WHEN duplicate_table THEN
        -- This can happen when restoring a logical backup, just ignore the
        -- error.
        RAISE LOG 'Table % already exists, continuing anyway',
            pg_catalog.format('wh_nagios.service_counters_%s', NEW.id);
        RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION wh_nagios.create_partition_on_insert_service() FROM public;

COMMENT ON FUNCTION wh_nagios.create_partition_on_insert_service() IS
'Trigger that create a dedicated partition when a new service is inserted in the table wh_nagios.services,
and GRANT the necessary ACL on it.';

--Automatically delete a partition when a service is removed.
CREATE FUNCTION wh_nagios.drop_partition_on_delete_service()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE format('DROP TABLE wh_nagios.service_counters_%s', OLD.id) ;
    RETURN NULL;
EXCEPTION
    WHEN undefined_table THEN
        RETURN NULL;
END
$$;

REVOKE ALL ON FUNCTION wh_nagios.drop_partition_on_delete_service() FROM public;

COMMENT ON FUNCTION wh_nagios.drop_partition_on_delete_service() IS
'Trigger that drop a dedicated partition when a service is deleted from the table wh_nagios.services.';

CREATE TRIGGER create_partition_on_insert_service
    BEFORE INSERT ON wh_nagios.services
    FOR EACH ROW
    EXECUTE PROCEDURE wh_nagios.create_partition_on_insert_service();

CREATE TRIGGER drop_partition_on_delete_service
    BEFORE DELETE ON wh_nagios.services
    FOR EACH ROW
    EXECUTE PROCEDURE wh_nagios.drop_partition_on_delete_service();


-- Fix all functions that were using counters_detail_* tables

/* wh_nagios.dispatch_record(boolean, integer)
Dispatch records from wh_nagios.hub into service_counters_$ID

$ID is found in wh_nagios.services_metric and wh_nagios.services, with correct hostname,servicedesc and label

@log_error: If true, will report errors and details in wh_nagios.hub_reject
@return : true if everything went well.
*/
CREATE OR REPLACE
FUNCTION wh_nagios.dispatch_record(num_lines integer DEFAULT 5000, log_error boolean DEFAULT false,
    OUT processed bigint, OUT failed bigint)
LANGUAGE plpgsql STRICT VOLATILE SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
    --Select current lines and lock them so then can be deleted
    --Use NOWAIT so there can't be two concurrent processes
    c_hub       CURSOR FOR SELECT * FROM wh_nagios.hub LIMIT num_lines FOR UPDATE NOWAIT;
    r_hub       record;
    i           integer;
    cur         hstore;
    msg_err     text;
    servicesrow wh_nagios.services%ROWTYPE;
    metricsrow  wh_nagios.metrics%ROWTYPE;
    serversrow  public.servers%ROWTYPE;
    updates     hstore[2];
BEGIN
/*
TODO: Handle seracl
*/
    processed := 0;
    failed    := 0;

    BEGIN
        FOR r_hub IN c_hub LOOP
            msg_err := NULL;

            --Check 1 dimension,at least 10 vals and even number of data
            IF ( (pg_catalog.array_upper(r_hub.data, 2) IS NOT NULL)
                OR (pg_catalog.array_upper(r_hub.data, 1) < 10)
                OR ((pg_catalog.array_upper(r_hub.data, 1) % 2) <> 0)
            ) THEN
                IF log_error THEN
                    msg_err := NULL;
                    IF (pg_catalog.array_upper(r_hub.data, 2) IS NOT NULL) THEN
                        msg_err := COALESCE(msg_err,'') || 'given array has more than 1 dimension';
                    END IF;
                    IF (pg_catalog.array_upper(r_hub.data, 1) <= 9) THEN
                        msg_err := COALESCE(msg_err || ',','') || 'less than 10 values';
                    END IF;
                    IF ((pg_catalog.array_upper(r_hub.data, 1) % 2) != 0) THEN
                        msg_err := COALESCE(msg_err || ',','') || 'number of parameter not even';
                    END IF;

                    INSERT INTO wh_nagios.hub_reject (id, rolname, data,msg) VALUES (r_hub.id, r_hub.rolname, r_hub.data, msg_err);
                END IF;

                failed := failed + 1;

                DELETE FROM wh_nagios.hub WHERE CURRENT OF c_hub;

                CONTINUE;
            END IF;

            cur := NULL;
            --Get all data as hstore,lowercase
            FOR i IN 1..pg_catalog.array_upper(r_hub.data, 1) BY 2 LOOP
                IF (cur IS NULL) THEN
                    cur := hstore(pg_catalog.lower(r_hub.data[i]), r_hub.data[i+1]);
                ELSE
                    cur := cur || hstore(pg_catalog.lower(r_hub.data[i]), r_hub.data[i+1]);
                END IF;
            END LOOP;

            serversrow  := NULL;
            servicesrow := NULL;
            metricsrow  := NULL;

            --Do we have all informations needed ?
            IF ( ((cur->'hostname') IS NULL)
                OR ((cur->'servicedesc') IS NULL)
                OR ((cur->'label') IS NULL)
                OR ((cur->'timet') IS NULL)
                OR ((cur->'value') IS NULL)
            ) THEN
                IF log_error THEN
                    msg_err := NULL;
                    IF ((cur->'hostname') IS NULL) THEN
                        msg_err := COALESCE(msg_err,'') || 'hostname required';
                    END IF;
                    IF ((cur->'servicedesc') IS NULL) THEN
                        msg_err := COALESCE(msg_err || ',','') || 'servicedesc required';
                    END IF;
                    IF ((cur->'label') IS NULL) THEN
                        msg_err := COALESCE(msg_err || ',','') || 'label required';
                    END IF;
                    IF ((cur->'timet') IS NULL) THEN
                        msg_err := COALESCE(msg_err || ',','') || 'timet required';
                    END IF;
                    IF ((cur->'value') IS NULL) THEN
                        msg_err := COALESCE(msg_err || ',','') || 'value required';
                    END IF;

                    INSERT INTO wh_nagios.hub_reject (id, rolname, data, msg)
                    VALUES (r_hub.id, r_hub.rolname, r_hub.data, msg_err);
                END IF;

                failed := failed + 1;

                DELETE FROM wh_nagios.hub WHERE CURRENT OF c_hub;

                CONTINUE;
            END IF;

            BEGIN
                -- Does the server exists ?
                SELECT * INTO serversrow
                FROM public.servers AS s
                WHERE s.hostname = (cur->'hostname');

                IF NOT FOUND THEN
                    msg_err := 'Error during INSERT OR UPDATE on public.servers: %L - %L';
                    EXECUTE format('INSERT INTO public.servers(hostname) VALUES (%L) RETURNING *', (cur->'hostname')) INTO STRICT serversrow;
                END IF;

                -- Does the service exists ?
                SELECT s2.* INTO servicesrow
                FROM public.servers AS s1
                    JOIN wh_nagios.services AS s2 ON s1.id = s2.id_server
                WHERE s1.hostname = (cur->'hostname')
                    AND s2.service = (cur->'servicedesc');

                IF NOT FOUND THEN
                    msg_err := 'Error during INSERT OR UPDATE on wh_nagios.services: %L - %L';

                    -- The trigger on wh_nagios.services_service will create the partition service_counters_$service_id automatically
                    INSERT INTO wh_nagios.services (id, id_server, warehouse, service, state)
                    VALUES (default, serversrow.id, 'wh_nagios', cur->'servicedesc', cur->'servicestate')
                    RETURNING * INTO STRICT servicesrow;

                    EXECUTE format('UPDATE wh_nagios.services
                        SET oldest_record = timestamp with time zone ''epoch''+%L * INTERVAL ''1 second''
                        WHERE id = $1', (cur->'timet'))
                        USING servicesrow.id;
                END IF;

                -- Store services informations to update them once per batch
                msg_err := 'Error during service statistics collect: %L - %L';
                IF ( updates[0] IS NULL ) THEN
                    -- initialize arrays
                    updates[0] := hstore(servicesrow.id::text,cur->'timet');
                    updates[1] := hstore(servicesrow.id::text,cur->'servicestate');
                END IF;
                IF ( ( updates[0]->(servicesrow.id)::text ) IS NULL ) THEN
                    -- new service found in hstore
                    updates[0] := updates[0] || hstore(servicesrow.id::text,cur->'timet');
                    updates[1] := updates[1] || hstore(servicesrow.id::text,cur->'servicestate');
                ELSE
                    -- service exists in hstore
                    IF ( ( updates[0]->(servicesrow.id)::text )::bigint < (cur->'timet')::bigint ) THEN
                        -- update the timet and state to the latest values
                        updates[0] := updates[0] || hstore(servicesrow.id::text,cur->'timet');
                        updates[1] := updates[1] || hstore(servicesrow.id::text,cur->'servicestate');
                    END IF;
                END IF;

                -- Does the metric exists ? only create if it's real perfdata,
                -- not a " " label
                IF (cur->'label' != ' ') THEN
                    SELECT l.* INTO metricsrow
                    FROM wh_nagios.metrics AS l
                    WHERE id_service = servicesrow.id
                        AND label = (cur->'label');

                    IF NOT FOUND THEN
                        msg_err := 'Error during INSERT on wh_nagios.metrics: %L - %L';

                        INSERT INTO wh_nagios.metrics (id_service, label, unit, min, max, warning, critical)
                        VALUES (servicesrow.id, cur->'label', cur->'uom', (cur->'min')::numeric, (cur->'max')::numeric, (cur->'warning')::numeric, (cur->'critical')::numeric)
                        RETURNING * INTO STRICT metricsrow;
                    END IF;

                    --Do we need to update the metric ?
                    IF ( ( (cur->'uom') IS NOT NULL AND (metricsrow.unit <> (cur->'uom') OR (metricsrow.unit IS NULL)) )
                        OR ( (cur->'min') IS NOT NULL AND (metricsrow.min <> (cur->'min')::numeric OR (metricsrow.min IS NULL)) )
                        OR ( (cur->'max') IS NOT NULL AND (metricsrow.max <> (cur->'max')::numeric OR (metricsrow.max IS NULL)) )
                        OR ( (cur->'warning') IS NOT NULL AND (metricsrow.warning <> (cur->'warning')::numeric OR (metricsrow.warning IS NULL)) )
                        OR ( (cur->'critical') IS NOT NULL AND (metricsrow.critical <> (cur->'critical')::numeric OR (metricsrow.critical IS NULL)) )
                    ) THEN
                        msg_err := 'Error during UPDATE on wh_nagios.metrics: %L - %L';

                        EXECUTE pg_catalog.format('UPDATE wh_nagios.metrics SET
                                unit = %L,
                                min = %L,
                                max = %L,
                                warning = %L,
                                critical = %L
                            WHERE id = $1',
                            cur->'uom',
                            cur->'min',
                            cur->'max',
                            cur->'warning',
                            cur->'critical'
                        ) USING metricsrow.id;
                    END IF;
                END IF;

                IF (servicesrow.id IS NOT NULL AND servicesrow.last_cleanup < now() - '10 days'::interval) THEN
                    PERFORM wh_nagios.cleanup_service(servicesrow.id);
                END IF;


                msg_err := pg_catalog.format('Error during INSERT on service_counters_%s: %%L - %%L', metricsrow.id);

                -- Do we need to insert a value ? if label is " " then perfdata
                -- was empty
                IF (cur->'label' != ' ') THEN
                    EXECUTE pg_catalog.format(
                        'INSERT INTO wh_nagios.service_counters_%s (id_metric, date_records,records)
                        VALUES (
                            %s,
                            date_trunc(''day'',timestamp with time zone ''epoch''+%L * INTERVAL ''1 second''),
                            array[row(timestamp with time zone ''epoch''+%L * INTERVAL ''1 second'',%L )]::public.metric_value[]
                        )',
                        metricsrow.id_service,
                        metricsrow.id,
                        cur->'timet',
                        cur->'timet',
                        cur->'value'
                    );
                END IF;

                -- one line has been processed with success !
                processed := processed  + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    IF log_error THEN
                        INSERT INTO wh_nagios.hub_reject (id, rolname, data, msg) VALUES (r_hub.id, r_hub.rolname, r_hub.data, pg_catalog.format(msg_err, SQLSTATE, SQLERRM)) ;
                    END IF;

                    -- We fail on the way for this one
                    failed := failed + 1;
            END;

            --Delete current line (processed or failed)
            DELETE FROM wh_nagios.hub WHERE CURRENT OF c_hub;
        END LOOP;

        --Update the services, if needed
        FOR r_hub IN SELECT * FROM each(updates[0]) LOOP
            EXECUTE pg_catalog.format('UPDATE wh_nagios.services SET last_modified = CURRENT_DATE,
              state = %L,
              newest_record = timestamp with time zone ''epoch'' +%L * INTERVAL ''1 second''
              WHERE id = %s
              AND ( newest_record IS NULL OR newest_record < timestamp with time zone ''epoch'' +%L * INTERVAL ''1 second'' )',
              updates[1]->r_hub.key,
              r_hub.value,
              r_hub.key,
              r_hub.value );
        END LOOP;
    EXCEPTION
        WHEN lock_not_available THEN
            --Have frendlier exception if concurrent function already running
            RAISE EXCEPTION 'Concurrent function already running.';
    END;
    RETURN;
END
$$;

REVOKE ALL ON FUNCTION wh_nagios.dispatch_record(integer, boolean) FROM public;

COMMENT ON FUNCTION wh_nagios.dispatch_record(integer, boolean) IS
'Parse and dispatch all rows in wh_nagios.hub into the good service_counters_X partition.
If a row concerns a non-existent server, it will create it without owner, so that only admins can see it. If a row concerns a service that didn''t
had a cleanup for more than 10 days, it will perform a cleanup for it. If called with "true", it will log in the table "wh_nagios.hub_reject" all
rows that couldn''t be dispatched, with the exception message.';

/* wh_nagios.cleanup_service(bigint)
Aggregate all data by day in an array, to avoid space overhead and benefit TOAST compression.
This will be done for every metric corresponding to the service.

@p_serviceid: ID of service to cleanup.
@return : true if everything went well.
*/
CREATE OR REPLACE
FUNCTION wh_nagios.cleanup_service(p_serviceid bigint)
RETURNS boolean
LANGUAGE plpgsql STRICT VOLATILE SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_servicefound boolean ;
  v_partid       bigint ;
  v_partname     text ;
BEGIN
    SELECT ( pg_catalog.count(1) = 1 ) INTO v_servicefound
    FROM wh_nagios.services AS s
    WHERE s.id = p_serviceid;

    IF NOT v_servicefound THEN
        RETURN false;
    END IF;

    -- Try to purge data before the cleanup
    PERFORM wh_nagios.purge_services(p_serviceid);

    v_partname := pg_catalog.format('service_counters_%s', p_serviceid);

    EXECUTE pg_catalog.format('CREATE TEMP TABLE tmp (LIKE wh_nagios.%I)', v_partname);

    EXECUTE pg_catalog.format('WITH list AS (SELECT id_metric, date_records, pg_catalog.count(1) AS num
            FROM wh_nagios.%1$I
            GROUP BY id_metric, date_records
        ),
        del AS (DELETE FROM wh_nagios.%1$I c
            USING list l
            WHERE c.id_metric = l.id_metric AND c.date_records = l.date_records AND l.num > 1
            RETURNING c.*
        ),
        rec AS (SELECT id_metric, date_records, (pg_catalog.unnest(records)).*
            FROM del
        )
        INSERT INTO tmp
        SELECT id_metric, date_records, pg_catalog.array_agg(row(timet, value)::public.metric_value)
        FROM rec
        GROUP BY id_metric, date_records
        UNION ALL
        SELECT cd.* FROM wh_nagios.%1$I cd JOIN list l USING (id_metric, date_records)
        WHERE num = 1;
    ', v_partname);
    EXECUTE pg_catalog.format('TRUNCATE wh_nagios.%I', v_partname);
    EXECUTE pg_catalog.format('INSERT INTO wh_nagios.%I SELECT * FROM tmp', v_partname);
    DROP TABLE tmp;

    UPDATE wh_nagios.services SET last_cleanup = pg_catalog.now() WHERE id = p_serviceid;

    RETURN true;
END
$$;

REVOKE ALL ON FUNCTION wh_nagios.cleanup_service(bigint) FROM public;

COMMENT ON FUNCTION wh_nagios.cleanup_service(bigint) IS
'Aggregate all data by day in an array, to avoid space overhead and benefit TOAST compression.';

/* wh_nagios.purge_services(VARIADIC bigint[])
Delete records older than max(date_records) - service.servalid. Doesn't delete
any data if servalid IS NULL

@p_serviceid: ID's of service to purge. All services if null.
@return : number of services purged.
*/
CREATE OR REPLACE
FUNCTION wh_nagios.purge_services(VARIADIC p_servicesid bigint[] = NULL)
RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  i              bigint;
  v_allservices  bigint[];
  v_serviceid    bigint;
  v_servicefound boolean;
  v_partid       bigint;
  v_partname     text;
  v_servalid     interval;
  v_ret          bigint;
  v_oldest       timestamptz;
  v_oldtmp       timestamptz;
BEGIN
    v_ret := 0;

    IF p_servicesid IS NULL THEN
        SELECT pg_catalog.array_agg(id) INTO v_allservices
        FROM wh_nagios.services
        WHERE servalid IS NOT NULL;
    ELSE
        v_allservices := p_servicesid;
    END IF;

    IF v_allservices IS NULL THEN
        return v_ret;
    END IF;

    FOR i IN 1..pg_catalog.array_upper(v_allservices, 1) LOOP
        v_serviceid := v_allservices[i];
        SELECT pg_catalog.COUNT(1) = 1 INTO v_servicefound
        FROM wh_nagios.services
        WHERE id = v_serviceid
            AND servalid IS NOT NULL;

        IF v_servicefound THEN
            v_ret := v_ret + 1;

            SELECT servalid INTO STRICT v_servalid
            FROM wh_nagios.services
            WHERE id = v_serviceid;

            v_partname := pg_catalog.format('service_counters_%s', v_serviceid);

            EXECUTE pg_catalog.format('WITH m as ( SELECT id_metric, pg_catalog.max(date_records) as max
                        FROM wh_nagios.%I
                        GROUP BY id_metric
                    )
                DELETE
                FROM wh_nagios.%I c
                USING m
                WHERE c.id_metric = m.id_metric
                AND age(m.max, c.date_records) >= %L::interval;
            ', v_partname, v_partname, v_servalid);

            EXECUTE pg_catalog.format('SELECT pg_catalog.min(timet)
                FROM (
                  SELECT (pg_catalog.unnest(records)).timet
                  FROM (
                    SELECT records
                    FROM wh_nagios.%I
                    ORDER BY date_records ASC
                    LIMIT 1
                  )s
                )s2', v_partname) INTO v_oldtmp;

            v_oldest := least(v_oldest, v_oldtmp);

            IF v_oldest IS NOT NULL THEN
                EXECUTE pg_catalog.format('UPDATE wh_nagios.services
                  SET oldest_record = %L
                  WHERE id = %s', v_oldest, v_serviceid);
            END IF;
        END IF;
    END LOOP;

    RETURN v_ret;
END
$$;

REVOKE ALL ON FUNCTION wh_nagios.purge_services(VARIADIC bigint[]) FROM public;

COMMENT ON FUNCTION wh_nagios.purge_services(VARIADIC bigint[]) IS
'Delete data older than retention interval.
The age is calculated from newest_record, not server date.';

CREATE OR REPLACE
FUNCTION wh_nagios.get_metric_timespan(IN id_metric bigint)
RETURNS TABLE(min_date date, max_date date)
LANGUAGE plpgsql STABLE STRICT LEAKPROOF SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
    v_id_service bigint;
BEGIN
    -- FIXME check user rights to access these data ?
    SELECT id_service INTO STRICT v_id_service
        FROM wh_nagios.metrics
        WHERE id = id_metric;

    RETURN QUERY EXECUTE format('
        SELECT min(date_records), max(date_records)
        FROM wh_nagios.service_counters_%s
        WHERE id_metric = $1', v_id_service) USING id_metric;
END
$$;

REVOKE ALL ON FUNCTION wh_nagios.get_metric_timespan(bigint) FROM public;

COMMENT ON FUNCTION wh_nagios.get_metric_timespan(bigint) IS
'returns min and max known date for given metric id';

SELECT * FROM public.register_api('wh_nagios.get_metric_timespan(bigint)'::regprocedure);


CREATE OR REPLACE
FUNCTION wh_nagios.get_metric_data(id_metric bigint, timet_begin timestamp with time zone, timet_end timestamp with time zone)
RETURNS TABLE(timet timestamp with time zone, value numeric)
LANGUAGE plpgsql STABLE STRICT SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
    v_id_service bigint;
BEGIN
    -- FIXME check user rights to access these data ?
    SELECT id_service INTO STRICT v_id_service
        FROM wh_nagios.metrics
        WHERE id = id_metric;

    RETURN QUERY EXECUTE format('
        SELECT * FROM (
            SELECT (pg_catalog.unnest(records)).*
            FROM wh_nagios.service_counters_%s
            WHERE id_metric = $3
                AND date_records >= date_trunc(''day'',$1)
                AND date_records <= date_trunc(''day'',$2)
        ) sql
        WHERE timet >= $1 AND timet <= $2', v_id_service
    ) USING timet_begin, timet_end, id_metric;
END
$$;

REVOKE ALL ON FUNCTION wh_nagios.get_metric_data(bigint, timestamp with time zone, timestamp with time zone)
    FROM public;

COMMENT ON FUNCTION wh_nagios.get_metric_data(bigint, timestamp with time zone, timestamp with time zone) IS
'Return metric data for the specified metric unique identifier within the specified interval.';

CREATE OR REPLACE
FUNCTION wh_nagios.merge_service( p_service_src bigint, p_service_dst bigint, drop_old boolean DEFAULT FALSE)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    r_ok record ;
    r_service record ;
    r_metric_src record ;
    r_metric_dst record ;
    v_old_id_metric bigint ;
    v_new_id_metric bigint ;
BEGIN
    -- Does the two services exists, and are they from the same server ?
    SELECT COUNT(*) = 2 AS num_services,
        COUNT(DISTINCT id_server) = 1 AS num_distinct_servers
        INTO r_ok
    FROM wh_nagios.services
    WHERE id IN ( p_service_src, p_service_dst );

    IF ( NOT r_ok.num_services
        OR NOT r_ok.num_distinct_servers
    ) THEN
        RETURN false ;
    END IF ;

    SELECT * INTO r_service FROM wh_nagios.services WHERE id = p_service_src ;

    FOR r_metric_src IN SELECT * FROM wh_nagios.metrics WHERE id_service = p_service_src LOOP
        -- Check if destination service already contains the metrics
        v_old_id_metric = r_metric_src.id ;
        SELECT * INTO r_metric_dst FROM wh_nagios.metrics
            WHERE id_service = p_service_dst
            AND label = r_metric_src.label
            AND unit = r_metric_src.unit ;
        IF r_metric_dst IS NULL THEN
            -- Create a new metric
            SELECT nextval('public.metrics_id_seq'::regclass) INTO v_new_id_metric ;
            r_metric_src.id = v_new_id_metric ;
            INSERT INTO wh_nagios.metrics (id, id_service, label, unit, tags, min, max, critical, warning)
            VALUES (v_new_id_metric, p_service_dst, r_metric_src.label, r_metric_src.unit, r_metric_src.tags, r_metric_src.min, r_metric_src.max, r_metric_src.critical, r_metric_src.warning);
        ELSE
            v_new_id_metric = r_metric_dst.id ;
        END IF ;

        -- merge data from the two services
        EXECUTE format('
            INSERT INTO wh_nagios.service_counters_%s
                SELECT %s, date_records, records
                FROM wh_nagios.service_counters_%s
                WHERE id_metric = %s',
        p_service_dst, v_new_id_metric, p_service_src, v_old_id_metric) ;
    END LOOP ;

    -- update metadata
    WITH meta AS (
        SELECT min(oldest_record) AS oldest,
            max(newest_record) AS newest
        FROM wh_nagios.services
        WHERE id IN ( p_service_src, p_service_dst )
    )
    UPDATE wh_nagios.services s
    SET oldest_record = meta.oldest, newest_record = meta.newest
    FROM meta
    WHERE s.id = p_service_dst ;

    IF drop_old THEN
        DELETE FROM wh_nagios.services WHERE id= p_service_src ;
    END IF;
    PERFORM public.create_graph_for_new_metric( s.id_server )
        FROM (
            SELECT id_server FROM wh_nagios.services
            WHERE id = p_service_src
        ) s;
    RETURN true ;
END ;
$$ ;

REVOKE ALL ON FUNCTION wh_nagios.merge_service( bigint, bigint, boolean ) FROM public ;
COMMENT ON FUNCTION wh_nagios.merge_service( bigint, bigint, boolean ) IS
'Merge data from a wh_nagios service into another.' ;
