-- Functions to build the Paths Object of the OAS document

create or replace function oas_build_paths(schemas text[], profile text default null)
returns jsonb language sql stable as
$$
  select oas_build_path_item_root() ||
         oas_with_operation_extras(oas_build_path_items_from_tables(schemas) || oas_build_path_items_from_functions(schemas), profile);
$$;

-- Every operation: an operationId (<method>.<schema>.<name>, rpc.<method>.<schema>.<function>), the profile header of
-- its schema, and the OpenAPI fragment of the comment of its table or function
create or replace function oas_with_operation_extras(path_items jsonb, profile text)
returns jsonb language sql stable as
$$
select coalesce(jsonb_object_agg(path, item), '{}')
from (
  select p.path, jsonb_object_agg(o.method,
      oas_merge(
        oas_merge(o.operation, jsonb_build_object('operationId', o.method || '.' || (o.operation ->> 'x-name'))
          || case when profile is null then '{}'::jsonb else jsonb_build_object('parameters', jsonb_build_array(
               oas_build_reference_to_parameters(case when o.method in ('get', 'head') then 'acceptProfile' else 'contentProfile' end))) end),
        postgrest_comment_openapi(o.operation ->> 'x-comment')
      ) - 'x-name' - 'x-comment' - 'x-internal'
    ) as item
  from jsonb_each(path_items) p(path, methods),
       jsonb_each(p.methods) o(method, operation)
  where jsonb_typeof(o.operation) = 'object'
    -- x-internal: true in the fragment leaves the operation out (e.g. the function behind db-root-spec)
    and coalesce(postgrest_comment_openapi(o.operation ->> 'x-comment') ->> 'x-internal', 'false') <> 'true'
  group by p.path
) x;
$$;

create or replace function oas_build_path_items_from_tables(schemas text[])
returns jsonb language sql stable as
$$
select coalesce(jsonb_object_agg(x.path, x.oas_path_item), '{}')
from (
  select '/' || table_name as path,
    oas_path_item_object(
      get :=oas_named_operation(table_full_name, table_description, 
        summary := (postgrest_unfold_comment(table_description))[1],
        description := (postgrest_unfold_comment(table_description))[2],
        tags := array[table_name],
        parameters := jsonb_agg(
          oas_build_reference_to_parameters(format('rowFilter.%1$s.%2$s', table_full_name, column_name))
        ) ||
        jsonb_build_array(
          oas_build_reference_to_parameters('select.' || table_full_name),
          oas_build_reference_to_parameters('order.' || table_full_name),
          oas_build_reference_to_parameters('limit'),
          oas_build_reference_to_parameters('offset'),
          oas_build_reference_to_parameters('or'),
          oas_build_reference_to_parameters('and'),
          oas_build_reference_to_parameters('not.or'),
          oas_build_reference_to_parameters('not.and'),
          oas_build_reference_to_parameters('range'),
          oas_build_reference_to_parameters('preferGet')
        ),
        responses := jsonb_build_object(
          '200',
          oas_build_reference_to_responses('notEmpty.' || table_full_name, 'OK'),
          '206',
          oas_build_reference_to_responses('notEmpty.' || table_full_name, 'Partial Content'),
          'default',
          oas_build_reference_to_responses('defaultError', 'Error')
        )
      ),
      post :=
        case when insertable then
          oas_named_operation(table_full_name, table_description, 
            summary := (postgrest_unfold_comment(table_description))[1],
            description := (postgrest_unfold_comment(table_description))[2],
            tags := array[table_name],
            requestBody := oas_build_reference_to_request_bodies(table_full_name),
            parameters := jsonb_build_array(
              oas_build_reference_to_parameters('select.' || table_full_name),
              oas_build_reference_to_parameters('columns'),
              oas_build_reference_to_parameters('preferPost')
            ),
            responses := jsonb_build_object(
              '201',
              oas_build_reference_to_responses('mayBeEmpty.' || table_full_name, 'Created'),
              'default',
              oas_build_reference_to_responses('defaultError', 'Error')
            )
          )
        end,
      patch :=
        case when updatable then
          oas_named_operation(table_full_name, table_description, 
            summary := (postgrest_unfold_comment(table_description))[1],
            description := (postgrest_unfold_comment(table_description))[2],
            tags := array[table_name],
            requestBody := oas_build_reference_to_request_bodies(table_full_name),
            parameters := jsonb_agg(
              oas_build_reference_to_parameters(format('rowFilter.%1$s.%2$s', table_full_name, column_name))
            ) ||
            jsonb_build_array(
              oas_build_reference_to_parameters('select.' || table_full_name),
              oas_build_reference_to_parameters('columns'),
              oas_build_reference_to_parameters('order.' || table_full_name),
              oas_build_reference_to_parameters('limit'),
              oas_build_reference_to_parameters('or'),
              oas_build_reference_to_parameters('and'),
              oas_build_reference_to_parameters('not.or'),
              oas_build_reference_to_parameters('not.and'),
              oas_build_reference_to_parameters('preferPatch')
            ),
            responses := jsonb_build_object(
              '200',
              oas_build_reference_to_responses('notEmpty.' || table_full_name, 'OK'),
              '204',
              oas_build_reference_to_responses('empty', 'No Content'),
              'default',
              oas_build_reference_to_responses('defaultError', 'Error')
            )
          )
        end,
      delete :=
        case when deletable then
          oas_named_operation(table_full_name, table_description, 
            summary := (postgrest_unfold_comment(table_description))[1],
            description := (postgrest_unfold_comment(table_description))[2],
            tags := array[table_name],
            parameters := jsonb_agg(
              oas_build_reference_to_parameters(format('rowFilter.%1$s.%2$s', table_full_name, column_name))
            ) ||
            jsonb_build_array(
              oas_build_reference_to_parameters('select.' || table_full_name),
              oas_build_reference_to_parameters('order.' || table_full_name),
              oas_build_reference_to_parameters('limit'),
              oas_build_reference_to_parameters('or'),
              oas_build_reference_to_parameters('and'),
              oas_build_reference_to_parameters('not.or'),
              oas_build_reference_to_parameters('not.and'),
              oas_build_reference_to_parameters('preferDelete')
            ),
            responses := jsonb_build_object(
              '200',
              oas_build_reference_to_responses('notEmpty.' || table_full_name, 'OK'),
              '204',
              oas_build_reference_to_responses('empty', 'No Content'),
              'default',
              oas_build_reference_to_responses('defaultError', 'Error')
            )
          )
        end
    ) as oas_path_item
  from (
   select table_schema, table_name, table_full_name, table_description, insertable, updatable, deletable, column_name
   from postgrest_get_all_tables_and_composite_types()
   where table_schema = any(schemas)
     and (is_table or is_view)
   order by table_schema, table_name, column_position
  ) _
  group by table_schema, table_name, table_full_name, table_description, insertable, updatable, deletable
) x;
$$;

create or replace function oas_build_path_items_from_functions(schemas text[])
returns jsonb language sql stable as
$$
select coalesce(jsonb_object_agg(x.path, x.oas_path_item), '{}')
from (
  select '/rpc/' || function_name as path,
    oas_path_item_object(
      -- like PostgREST, which answers GET only for functions that are not volatile
      get := case when not is_volatile then oas_named_operation('rpc.' || function_full_name, function_description, 
        summary := (postgrest_unfold_comment(function_description))[1],
        description := (postgrest_unfold_comment(function_description))[2],
        tags := array['(rpc) ' || function_name],
        parameters :=
          coalesce(
            jsonb_agg(
              oas_build_reference_to_parameters(format('rpcParam.%1$s.%2$s', function_full_name, argument_name))
            ) filter ( where argument_name <> '' and (argument_is_in or argument_is_inout or argument_is_variadic)),
            '[]'
          ) ||
          case when return_type_is_table or return_type_is_out or return_type_composite_relid <> 0 then
            jsonb_build_array(
              oas_build_reference_to_table_parameter('select', return_type_composite_full_name, schemas),
              oas_build_reference_to_table_parameter('order', return_type_composite_full_name, schemas),
              oas_build_reference_to_parameters('limit'),
              oas_build_reference_to_parameters('offset'),
              oas_build_reference_to_parameters('or'),
              oas_build_reference_to_parameters('and'),
              oas_build_reference_to_parameters('not.or'),
              oas_build_reference_to_parameters('not.and'),
              oas_build_reference_to_parameters('range'),
              oas_build_reference_to_parameters('preferGet')
            )
          else
            jsonb_build_array(
              oas_build_reference_to_parameters('preferGet')
            )
          end,
        responses :=
          case when return_type_is_set then
            jsonb_build_object(
              '200',
              oas_build_reference_to_responses('rpc.' || function_full_name, 'OK'),
              '206',
              oas_build_reference_to_responses('rpc.' || function_full_name, 'Partial Content')
            )
          else
            jsonb_build_object(
              '200',
              oas_build_reference_to_responses('rpc.' || function_full_name, 'OK')
            )
          end ||
          jsonb_build_object(
            'default',
            oas_build_reference_to_responses('defaultError', 'Error')
          )
      ) end,
      post := oas_named_operation('rpc.' || function_full_name, function_description, 
        summary := (postgrest_unfold_comment(function_description))[1],
        description := (postgrest_unfold_comment(function_description))[2],
        tags := array['(rpc) ' || function_name],
        requestBody := case when argument_input_qty > 0 then oas_build_reference_to_request_bodies('rpc.' || function_full_name) end,
        parameters :=
          -- TODO: The row filters for functions returning TABLE, OUT, INOUT and composite types should also work for the GET path.
          --       Right now they're not included in GET, because the argument names (in rpcParams) could clash with the name of the return type columns (in rowFilter).
          coalesce(
            jsonb_agg(
              oas_build_reference_to_parameters(format('rowFilter.rpc.%1$s.%2$s', function_full_name, argument_name))
            ) filter ( where argument_name <> '' and (argument_is_inout or argument_is_out or argument_is_table)),
            '[]'
          ) ||
          return_composite_param_ref ||
          case when return_type_is_table or return_type_is_out or return_type_composite_relid <> 0 then
            jsonb_build_array(
              oas_build_reference_to_table_parameter('select', return_type_composite_full_name, schemas),
              oas_build_reference_to_table_parameter('order', return_type_composite_full_name, schemas),
              oas_build_reference_to_parameters('limit'),
              oas_build_reference_to_parameters('offset'),
              oas_build_reference_to_parameters('or'),
              oas_build_reference_to_parameters('and'),
              oas_build_reference_to_parameters('not.or'),
              oas_build_reference_to_parameters('not.and'),
              oas_build_reference_to_parameters('preferPostRpc')
            )
          else
            jsonb_build_array(
              oas_build_reference_to_parameters('preferPostRpc')
            )
          end,
        responses :=
          case when return_type_is_set then
            jsonb_build_object(
              '200',
              oas_build_reference_to_responses('rpc.' || function_full_name, 'OK'),
              '206',
              oas_build_reference_to_responses('rpc.' || function_full_name, 'Partial Content')
            )
          else
            jsonb_build_object(
              '200',
              oas_build_reference_to_responses('rpc.' || function_full_name, 'OK')
            )
          end ||
          jsonb_build_object(
            'default',
            oas_build_reference_to_responses('defaultError', 'Error')
          )
      )
    ) as oas_path_item
  from (
    select function_name, function_full_name, function_description, return_type_name, return_type_is_set, return_type_is_table, return_type_is_out, return_type_composite_relid, argument_name, argument_is_in, argument_is_inout, argument_is_out, argument_is_table, argument_is_variadic, argument_input_qty, is_volatile, return_type_composite_full_name,
           coalesce(comp.return_composite_param_ref, '[]') as return_composite_param_ref
    from postgrest_get_all_functions(schemas) f
    -- the composite types read once, not once per function argument
    left join (
      select c.table_oid, jsonb_agg(oas_build_reference_to_parameters(format('rowFilter.%1$s.%2$s', c.table_full_name, c.column_name))) as return_composite_param_ref
      from postgrest_get_all_tables_and_composite_types() c
      group by c.table_oid
    ) comp on comp.table_oid = f.return_type_composite_relid
  ) _
  group by function_name, function_full_name, function_description, return_type_name, return_type_is_set, return_type_is_table, return_type_is_out, return_type_composite_relid, argument_input_qty, return_composite_param_ref, is_volatile, return_type_composite_full_name
) x;
$$;

create or replace function oas_build_path_item_root()
returns jsonb language sql stable as
$$
select
  jsonb_build_object(
    '/',
    oas_path_item_object(
      get := oas_operation_object(
        description := 'OpenAPI description (this document)',
        tags := array['Introspection'],
        responses := jsonb_build_object(
          '200',
          oas_response_object(
            description := 'OK',
            content := jsonb_build_object(
              'application/json',
              oas_media_type_object(
                schema := oas_schema_object(
                  type := 'object'
                )
              ),
              'application/openapi+json',
              oas_media_type_object(
                schema := oas_schema_object(
                  type := 'object'
                )
              )
            )
          ),
          'default',
          oas_build_reference_to_responses('defaultError', 'Error')
        )
      )
    )
  );
$$;

-- An operation carrying the name and the comment of its table or function, for oas_with_operation_extras
create or replace function oas_named_operation(
  x_name text,
  x_comment text,
  tags text[] default null,
  summary text default null,
  description text default null,
  operationId text default null,
  parameters jsonb default null,
  requestBody jsonb default null,
  responses jsonb default null
)
returns jsonb language sql stable as
$$
  select jsonb_strip_nulls(oas_operation_object(tags := tags, summary := summary, description := description, operationId := operationId,
                                                parameters := parameters, requestBody := requestBody, responses := responses))
         || jsonb_strip_nulls(jsonb_build_object('x-name', x_name, 'x-comment', x_comment));
$$;

-- The parameter of the table a function returns rows of, when that table is exposed; else the generic one
create or replace function oas_build_reference_to_table_parameter(parameter text, table_full_name text, schemas text[])
returns jsonb language sql stable as
$$
  select oas_build_reference_to_parameters(
    case when exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                      where c.oid = to_regclass(oas_build_reference_to_table_parameter.table_full_name)
                        and n.nspname = any(schemas) and c.relkind in ('r', 'v', 'm', 'f', 'p'))
         then parameter || '.' || table_full_name else parameter end);
$$;
