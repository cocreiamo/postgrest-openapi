-- Functions that help in building the OpenAPI spec inside PostgreSQL

create or replace function postgrest_pgtype_to_oastype(type text)
returns text language sql immutable as
$$
select case when type like any(array['character', 'character varying', 'text']) then 'string'
            when type like any(array['double precision', 'numeric', 'real']) then 'number'
            when type like any(array['bigint', 'integer', 'smallint']) then 'integer'
            when type like 'boolean' then 'boolean'
            when type like '%[]' then 'array'
            when type like any(array['json', 'jsonb', 'record']) then 'object'
            else 'string' end;
$$;

create or replace function postgrest_unfold_comment(comm text) returns text[]
language sql immutable as
$$
select array[
  substr(comm, 0, break_position),
  trim(leading from substr(comm, break_position), '
 ') -- trims newlines and empty spaces
]
from (select postgrest_comment_text(comm) as comm) c,
     (select strpos(postgrest_comment_text(comm), '
') as break_position)_;
$$;

create or replace function oas_build_reference_to_schemas("schema" text)
returns jsonb language sql immutable as
$$
  select oas_reference_object(
    '#/components/schemas/' || "schema"
  );
$$;

create or replace function oas_build_reference_to_parameters(parameter text)
returns jsonb language sql immutable as
$$
  select oas_reference_object(
    '#/components/parameters/' || parameter
  );
$$;

create or replace function oas_build_reference_to_request_bodies(req_body text)
returns jsonb language sql immutable as
$$
  select oas_reference_object(
    ref := '#/components/requestBodies/' || req_body
  );
$$;

create or replace function oas_build_reference_to_responses(response text, descrip text default null)
returns jsonb language sql immutable as
$$
  select oas_reference_object(
    ref := '#/components/responses/' || response,
    description := descrip
  );
$$;

-- Standard OpenAPI format of a PostgreSQL type when there is one, else the type name itself
create or replace function postgrest_pgtype_to_oasformat(type text)
returns text language sql immutable as
$$
select case type
         when 'uuid' then 'uuid'
         when 'date' then 'date'
         when 'timestamp with time zone' then 'date-time'
         when 'smallint' then 'int32'
         when 'integer' then 'int32'
         when 'bigint' then 'int64'
         when 'real' then 'float'
         when 'double precision' then 'double'
         else type end;
$$;

-- Regular expression (unanchored) of a literal of the type in a filter the database always accepts, or null when
-- the type has none: dates up to the 28th, instants in UTC (a '+' in a query string is a space), bounded numbers,
-- text without the characters the filter syntax reserves
create or replace function postgrest_pgtype_filter_literal(type text)
returns text language sql immutable as
$$
select case
         when type = 'uuid' then '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
         when type = 'date' then '(19|20)[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|1[0-9]|2[0-8])'
         when type = 'timestamp with time zone'
           then '(19|20)[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|1[0-9]|2[0-8])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z'
         when type = 'smallint' then '-?[0-9]{1,4}'
         when type = 'integer' then '-?[0-9]{1,9}'
         when type = 'bigint' then '-?[0-9]{1,18}'
         when type in ('numeric', 'real', 'double precision') then '-?[0-9]{1,9}(\.[0-9]{1,6})?'
         when type = 'boolean' then '(true|false)'
         when type in ('text', 'character varying', 'character') then '[^\u0000,()"\\]{0,100}'
       end;
$$;

-- Pattern of a filter on a column of the type: comparisons, in and is.null, negated or not
create or replace function postgrest_pgtype_filter_pattern(type text)
returns text language sql immutable as
$$
select '^' || postgrest_pgtype_filter_condition(type) || '$';
$$;

create or replace function postgrest_pgtype_filter_condition(type text)
returns text language sql immutable as
$$
select format('(not\.)?((eq|neq|gt|gte|lt|lte)\.%1$s|in\.\((%1$s(,%1$s)*)?\)|is\.null)', l)
from (select postgrest_pgtype_filter_literal(type) as l) _
where l is not null;
$$;

-- Pattern of a value of the type in a request body the database always accepts, or null: an instant with an offset
-- timestamptz takes (RFC 3339 allows up to 23:59, PostgreSQL 15:59), text without the NUL character
create or replace function postgrest_pgtype_value_pattern(type text)
returns text language sql immutable as
$$
select case
         when type = 'timestamp with time zone' then '^.+([Zz]|[+-](0[0-9]|1[0-5]):[0-5][0-9])$'
         when type in ('text', 'character varying', 'character') then '^[^\u0000]*$'
       end;
$$;

-- A schema that may also be null (OpenAPI 3.1: the type becomes an array)
create or replace function oas_nullable(schema jsonb, nullable boolean)
returns jsonb language sql immutable as
$$
select case when nullable and jsonb_typeof(schema -> 'type') = 'string'
            then jsonb_set(schema, '{type}', jsonb_build_array(schema ->> 'type', 'null'))
            else schema end;
$$;

-- Deep merge: objects key by key, arrays concatenated, anything else replaced by the second value
create or replace function oas_merge(a jsonb, b jsonb)
returns jsonb language sql immutable as
$$
select case
         when a is null then b
         when b is null then a
         when jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then (
           select coalesce(jsonb_object_agg(k, oas_merge(a -> k, b -> k)), '{}')
           from (select jsonb_object_keys(a) union select jsonb_object_keys(b)) keys(k)
         )
         when jsonb_typeof(a) = 'array' and jsonb_typeof(b) = 'array' then a || b
         else b end;
$$;

-- A comment may end with a line '--- openapi' followed by a JSON object: OpenAPI the catalog cannot tell (headers,
-- responses, links), merged into the operations of the function or table (or of every operation, on the schema)
create or replace function postgrest_comment_openapi(comm text)
returns jsonb language sql immutable as
$$
select case when strpos(comm, E'\n--- openapi\n') > 0
            then substr(comm, strpos(comm, E'\n--- openapi\n') + length(E'\n--- openapi\n'))::jsonb end;
$$;

create or replace function postgrest_comment_text(comm text)
returns text language sql immutable as
$$
select case when strpos(comm, E'\n--- openapi\n') > 0 then substr(comm, 1, strpos(comm, E'\n--- openapi\n') - 1) else comm end;
$$;
