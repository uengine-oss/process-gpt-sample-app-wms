-- ============================================================
-- Self-service WMS membership for ProcessGPT SSO users.
--
-- wms-frontend already hydrates a Supabase session from ProcessGPT's own
-- access_token/refresh_token cookies on first visit (see
-- frontend/src/stores/auth.ts restoreSession()) — no separate wms login
-- screen exists. What was still missing: a wms.memberships row for that
-- user, without which every RLS policy in this schema hides all data (the
-- user is authenticated but has no role). wms_ensure_tenant_provisioned
-- already grants membership by email (p_trainee_email), but it is
-- service_role-only by design (20260807_wms_tenant_auto_provisioning.sql)
-- and requires an admin/instructor to run it out-of-band per user
-- (scripts/onboard_trainee.py) — too manual for "every ProcessGPT user of
-- a tenant should just see the WMS dashboard".
--
-- This RPC closes that gap for the general case: any authenticated
-- ProcessGPT user may grant *themselves* wms membership, but only for the
-- tenant_id already stamped in their own JWT's app_metadata claim — the
-- same claim ProcessGPT's gateway (ForwardHostHeaderFilter) validates
-- before ever routing a request here (frontend/src/lib/tenant.ts). There is
-- no caller-supplied tenant_id or email parameter, so this cannot be used
-- to self-grant access to someone else's tenant the way a param-based RPC
-- could — the identity and tenant come from the session, not the caller's
-- input. That's what makes it safe to grant to `authenticated` where
-- wms_ensure_tenant_provisioned deliberately is not.
--
-- Delegates to wms_ensure_tenant_provisioned (as p_trainee_email/role) so
-- tenant/warehouse auto-creation, idempotency, and the advisory lock all
-- stay in one place. The call succeeds despite that function being
-- revoked from `authenticated`/PUBLIC because a SECURITY DEFINER function
-- body executes as its owner, and both functions share the same owner
-- (the migration role) — this is an internal call, not a re-exposed grant.
--
-- Default role is WMS_ADMIN (every ProcessGPT member of a tenant gets full
-- WMS access, matching onboard_trainee.py's default). This is a deliberate
-- least-privilege trade-off: revisit with a narrower default (e.g. a new
-- read-only role) if a tenant ever needs to distinguish WMS operators from
-- ordinary ProcessGPT members.
-- ============================================================

create or replace function wms.wms_self_provision_membership(
  p_role text default 'WMS_ADMIN'
) returns void
language plpgsql
security definer
set search_path = wms, public, auth
as $$
declare
  v_tenant_id text;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'FORBIDDEN: no authenticated session';
  end if;

  v_tenant_id := auth.jwt() -> 'app_metadata' ->> 'tenant_id';
  v_email := auth.jwt() ->> 'email';

  if v_tenant_id is null or v_tenant_id = '' then
    raise exception 'INVALID: session has no app_metadata.tenant_id claim';
  end if;
  if v_email is null or v_email = '' then
    raise exception 'INVALID: session has no email claim';
  end if;

  perform wms.wms_ensure_tenant_provisioned(
    p_tenant_id => v_tenant_id,
    p_trainee_email => v_email,
    p_trainee_role => coalesce(nullif(p_role, ''), 'WMS_ADMIN')
  );
end;
$$;

revoke execute on function wms.wms_self_provision_membership(text) from public;
grant execute on function wms.wms_self_provision_membership(text) to authenticated;
