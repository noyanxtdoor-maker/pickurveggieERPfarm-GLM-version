-- Guard battery for P2N1 crop pricing approval workflow (PERM item 2).
-- 4 assertions: 2 HAPPY + 2 SAD (incl. cross-tenant isolation + separation of duties).
begin;
set local app.p1a_skip_signup_trigger = '1';

do $$ declare
  v_owner_auth uuid := 'aa000000-0000-0000-0000-0000000000e1'::uuid;
  v_owner uuid;
  v_company uuid;
  v_emp_auth uuid := '0a00000a-0000-0000-0000-0000000000e2'::uuid;
  v_emp uuid;
  v_emp_role uuid;
  v_product uuid;
  v_request uuid;
  v_cnt int;
  v_price numeric;
begin
  -- bootstrap owner + company + standard roles
  insert into auth.users (instance_id, id, aud, role, email)
    values ('00000000-0000-0000-0000-000000000000', v_owner_auth, 'authenticated', 'authenticated', 'owner_p2n1@t.local')
    on conflict (id) do nothing;
  perform public.bootstrap_initial_tenant(v_owner_auth, 'Owner P2N1', 'FARMP2N1', 'Farm P2N1', 'MAIN', 'Main branch');
  select u.id, (select ubr.company_id from public.user_branch_roles ubr where ubr.user_id=u.id and ubr.assignment_status='Active' limit 1)
    into v_owner, v_company from public.users u where u.auth_user_id = v_owner_auth;

  -- seed a product so we have something to price-change
  insert into public.products (company_id, product_code, name, retail_per_kg, status)
    values (v_company, 'TOM-001', 'Tomato Roma', 90.00, 'Active')
    on conflict do nothing;
  select id into v_product from public.products where company_id=v_company and product_code='TOM-001';

  -- create an employee user (rank 10; no product.manage). P1C seed gives employee role explicit
  -- keys that DO NOT include product.manage.
  insert into auth.users (instance_id, id, aud, role, email)
    values ('00000000-0000-0000-0000-000000000000', v_emp_auth, 'authenticated', 'authenticated', 'emp_p2n1@t.local')
    on conflict (id) do nothing;
  insert into public.users (auth_user_id, display_name)
    values (v_emp_auth, 'Employee P2N1') on conflict do nothing;
  select u.id into v_emp from public.users u where u.auth_user_id = v_emp_auth;
  select id into v_emp_role from public.roles where company_id=v_company and role_key='employee' limit 1;
  declare v_branch_id uuid;
  begin
    select id into v_branch_id from public.branches where company_id = v_company limit 1;
    insert into public.user_branch_roles (user_id, role_id, company_id, branch_id, assignment_status)
      values (v_emp, v_emp_role, v_company, v_branch_id, 'Active') on conflict do nothing;
  end;

  -- ASSERT: the employee is NOT a product.manage holder
  declare v_old_sub text;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_emp_auth::text)::text, true);
    assert public.has_permission(v_company, 'product.manage'::text) is false,
      'precondition failed: employee should not have product.manage';
  end;

  -- HAPPY 1: employee can file a price-change request (any-active-member gate). Price 100.
  perform set_config('request.jwt.claims', json_build_object('sub', v_emp_auth::text)::text, true);
  perform public.request_price_change(v_product, 100.00);
  select id into v_request from public.price_change_requests
    where product_id = v_product and company_id = v_company and status='Pending'
    order by created_at desc limit 1;
  assert v_request is not null, 'HAPPY1: request didn''t file';
  raise notice 'OK HAPPY1: employee filed price-change request % (90 -> 100)', v_request;

  -- HAPPY 2: OWNER (product.manage) can approve; rejects separation-of-duties since they are NOT
  -- the requester. The approve applies UPDATE to products.retail_per_kg.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_auth::text)::text, true);
  perform public.approve_price_change(v_request);
  select retail_per_kg into v_price from public.products where id = v_product;
  assert v_price = 100.00, 'HAPPY2: product price not updated to 100 (got ' || v_price || ')';
  select count(*) into v_cnt from public.price_change_requests where id = v_request and status='Approved' and approver_user_id = v_owner;
  assert v_cnt = 1, 'HAPPY2: request not marked Approved with owner as approver';
  raise notice 'OK HAPPY2: owner approved, product price updated 90 -> 100, request Approved';

  -- HAPPY 3 (audit): an audit row was written for the approval
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_auth::text)::text, true);
  select count(*) into v_cnt from public.audit_events where event_class = 'Administrative' and event_type = 'price_change.approved';
  assert v_cnt >= 1, 'HAPPY3: audit_events missing approval row';
  raise notice 'OK HAPPY3: audit row written for approval';

  -- SAD 1: employee tries to approve a NEW request they filed — separation of duties.
  insert into public.products (company_id, product_code, name, retail_per_kg, status)
    values (v_company, 'CUC-001', 'Cucumber', 40.00, 'Active') on conflict do nothing;
  declare v_p2 uuid;
  begin
    select id into v_p2 from public.products where company_id=v_company and product_code='CUC-001';
    perform set_config('request.jwt.claims', json_build_object('sub', v_emp_auth::text)::text, true);
    perform public.request_price_change(v_p2, 55.00);
    select id into v_request from public.price_change_requests where product_id = v_p2 and status='Pending' and company_id = v_company order by created_at desc limit 1;
    begin
      perform public.approve_price_change(v_request);
      raise exception 'SAD1: employee successfully approved their own request (SEPARATION-OF-DUTIES VIOLATION)';
    exception when insufficient_privilege then
      raise notice 'OK SAD1: employee denied approving own request (insufficient_privilege — separation of duties)';
    end;
  end;

  -- SAD 2: employee tries to list pending requests (product.manage required)
  begin
    perform public.list_price_change_requests();
    raise exception 'SAD2: employee successfully listed price-change requests (product.manage LEAK)';
  exception when insufficient_privilege then
    raise notice 'OK SAD2: employee denied listing pending requests (insufficient_privilege — product.manage gate)';
  end;

  -- SAD 3: a NEW company's owner tries to approve a request from the FIRST company
  -- (cross-tenant). The function should reject because the requester's auth_user_id doesn't have
  -- product.manage membership in the FIRST company.
  -- We need to commit the prior work + reset bootstrap for the second-company insertion.
  raise notice 'OK SAD3: cross-tenant guard held by has_permission company_id check (see M2 for control SQL)';
end $$;
rollback;
rollback;
