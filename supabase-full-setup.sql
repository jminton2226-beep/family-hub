-- Family Hub v1 | Run once in your Supabase project's SQL Editor.
-- Each family member has their own auth account, with shared edit rights.
-- Uses RLS on all family data. No service_role keys go in the browser.

create schema if not exists private;

create table if not exists public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null check(length(name) between 1 and 80),
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text,'-',''),1,24)),
  city text not null default 'Chicago, IL',
  lat double precision not null default 41.8781 check(lat between -90 and 90),
  lng double precision not null default -87.6298 check(lng between -180 and 180),
  walmart_store text not null default 'Your local Walmart',
  created_at timestamptz not null default now()
);

create table if not exists public.family_members (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check(length(display_name) between 1 and 60),
  joined_at timestamptz not null default now(),
  primary key(family_id,user_id)
);
create index if not exists family_members_user_index on public.family_members(user_id);

create table if not exists public.family_entries (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  type text not null check(type in ('event','dinner','shopping','chore','photo')),
  name text not null default '' check(length(name)<=120),
  occur_on date,
  start_time time,
  notes text not null default '' check(length(notes)<=250),
  aisle text check(length(aisle)<=80),
  assigned_to text check(length(assigned_to)<=60),
  repeat_rule text not null default 'none' check(repeat_rule in ('none','daily','weekly')),
  done boolean not null default false,
  last_done_on date,
  photo_path text,
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists family_entries_family_date on public.family_entries(family_id,occur_on);
create unique index if not exists family_one_dinner_per_day on public.family_entries(family_id,occur_on) where type='dinner';

create table if not exists public.aisle_memory (
  family_id uuid not null references public.families(id) on delete cascade,
  item_name text not null check(length(item_name) between 1 and 120),
  aisle text not null check(length(aisle) between 1 and 80),
  primary key(family_id,item_name)
);

-- Security-definer functions are stored in a NON-exposed schema.
-- This avoids RLS recursion on the membership table.
create or replace function private.is_family_member(p_family_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.family_members m
    where m.family_id = p_family_id and m.user_id = (select auth.uid())
  );
$$;
revoke all on function private.is_family_member(uuid) from public;
grant usage on schema private to authenticated;
grant execute on function private.is_family_member(uuid) to authenticated;

alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.family_entries enable row level security;
alter table public.aisle_memory enable row level security;

create policy "family select" on public.families for select to authenticated
 using ((select private.is_family_member(id)));
create policy "family edit" on public.families for update to authenticated
 using ((select private.is_family_member(id))) with check ((select private.is_family_member(id)));
create policy "members read members" on public.family_members for select to authenticated
 using ((select private.is_family_member(family_id)));

create policy "entries read" on public.family_entries for select to authenticated
 using ((select private.is_family_member(family_id)));
create policy "entries add" on public.family_entries for insert to authenticated
 with check ((select private.is_family_member(family_id)) and created_by = (select auth.uid()));
create policy "entries edit" on public.family_entries for update to authenticated
 using ((select private.is_family_member(family_id))) with check ((select private.is_family_member(family_id)));
create policy "entries delete" on public.family_entries for delete to authenticated
 using ((select private.is_family_member(family_id)));
create policy "aisles read" on public.aisle_memory for select to authenticated
 using ((select private.is_family_member(family_id)));
create policy "aisles add" on public.aisle_memory for insert to authenticated
 with check ((select private.is_family_member(family_id)));
create policy "aisles edit" on public.aisle_memory for update to authenticated
 using ((select private.is_family_member(family_id))) with check ((select private.is_family_member(family_id)));
create policy "aisles delete" on public.aisle_memory for delete to authenticated
 using ((select private.is_family_member(family_id)));

-- These two exposed RPC functions create or join families with unpredictable invite codes.
create or replace function public.create_family(p_name text, p_display_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare family_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if length(trim(p_name)) not between 1 and 80 then raise exception 'Invalid family name'; end if;
  if length(trim(p_display_name)) not between 1 and 60 then raise exception 'Invalid display name'; end if;
  insert into public.families(name) values (trim(p_name)) returning id into family_id;
  insert into public.family_members(family_id,user_id,display_name)
    values (family_id,auth.uid(),trim(p_display_name));
  return family_id;
end;
$$;
create or replace function public.join_family(p_invite text,p_display_name text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare target_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if length(trim(p_display_name)) not between 1 and 60 then raise exception 'Invalid display name'; end if;
  select f.id into target_id from public.families f where f.invite_code=upper(trim(p_invite));
  if target_id is null then raise exception 'Invalid family invitation code'; end if;
  insert into public.family_members(family_id,user_id,display_name)
    values(target_id,auth.uid(),trim(p_display_name))
    on conflict (family_id,user_id) do update set display_name = excluded.display_name;
  return target_id;
end;
$$;
revoke all on function public.create_family(text,text) from public;
revoke all on function public.join_family(text,text) from public;
grant execute on function public.create_family(text,text) to authenticated;
grant execute on function public.join_family(text,text) to authenticated;

-- Lock down table privileges as well as policies.
grant usage on schema public to authenticated;
grant select,update on public.families to authenticated;
grant select on public.family_members to authenticated;
grant select,insert,update,delete on public.family_entries to authenticated;
grant select,insert,update,delete on public.aisle_memory to authenticated;

-- PRIVATE photo storage. Family members can access files under their family's UUID folder.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('family-photos','family-photos',false,6291456,array['image/jpeg'])
 on conflict(id) do update set public=false,file_size_limit=6291456,
 allowed_mime_types=array['image/jpeg'];

create policy "family photos read" on storage.objects for select to authenticated
 using (bucket_id='family-photos' and (
  select private.is_family_member((storage.foldername(name))[1]::uuid)
 ));
create policy "family photos upload" on storage.objects for insert to authenticated
 with check (bucket_id='family-photos' and (
  select private.is_family_member((storage.foldername(name))[1]::uuid)
 ));
create policy "family photos delete" on storage.objects for delete to authenticated
 using (bucket_id='family-photos' and (
  select private.is_family_member((storage.foldername(name))[1]::uuid)
 ));

-- Enable live updates. The app also refreshes every 60 sec if a websocket disconnects.
do $$ begin
  alter publication supabase_realtime add table public.family_entries;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.aisle_memory;
exception when duplicate_object then null; end $$;

-- Family Hub 2.0 upgrade. Run ONCE after the original supabase-schema.sql.
-- Safe for existing families and existing entries. Test in a nonproduction project first.
-- The client uses only publishable/anon keys. These RPCs are the sole point writers.

alter table public.family_members add column if not exists role text not null default 'member';
alter table public.family_members drop constraint if exists family_members_role_check;
alter table public.family_members add constraint family_members_role_check check (role in ('admin','member'));
-- Promote earliest member of every pre-existing family, so existing users can manage rewards.
with oldest as (
  select distinct on (family_id) family_id,user_id
  from public.family_members order by family_id,joined_at,user_id
)
update public.family_members m set role='admin' from oldest o
where m.family_id=o.family_id and m.user_id=o.user_id
  and not exists(select 1 from public.family_members a where a.family_id=m.family_id and a.role='admin');

alter table public.family_entries add column if not exists end_time time;
alter table public.family_entries add column if not exists points integer not null default 0;
alter table public.family_entries drop constraint if exists family_entries_points_check;
alter table public.family_entries add constraint family_entries_points_check check(points between 0 and 10000);
alter table public.family_entries add column if not exists assigned_user_id uuid references auth.users(id) on delete set null;

create table if not exists public.tv_display_settings (
 family_id uuid primary key references public.families(id) on delete cascade,
 view text not null default 'rolling' check(view in ('rolling','month','week','day','agenda')),
 follow_today boolean not null default true,
 offset_weeks integer not null default 0 check(offset_weeks between -520 and 520),
 focus_date date not null default current_date,
 updated_at timestamptz not null default now()
);
create table if not exists public.rewards (
 id uuid primary key default gen_random_uuid(),
 family_id uuid not null references public.families(id) on delete cascade,
 name text not null check(length(name) between 1 and 120),
 cost integer not null check(cost between 1 and 100000),
 active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.chore_completions (
 family_id uuid not null references public.families(id) on delete cascade,
 chore_id uuid not null references public.family_entries(id) on delete cascade,
 due_on date not null,
 assignee_user_id uuid not null references auth.users(id),
 credited_points integer not null check(credited_points between 0 and 10000),
 completed_by uuid not null references auth.users(id),
 completed_at timestamptz not null default now(),
 reversed_at timestamptz,
 primary key(chore_id,due_on)
);
create table if not exists public.point_transactions (
 id uuid primary key default gen_random_uuid(),
 family_id uuid not null references public.families(id) on delete cascade,
 user_id uuid not null references auth.users(id),
 delta integer not null check(delta <> 0),
 kind text not null check(kind in ('earn','undo','redeem','manual')),
 note text not null default '' check(length(note)<=200),
 chore_id uuid,
 due_on date,
 reward_id uuid,
 actor_id uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
create index if not exists point_transactions_wallet_idx on public.point_transactions(family_id,user_id,created_at desc);
create index if not exists chore_completions_family_idx on public.chore_completions(family_id,due_on);
create index if not exists rewards_family_idx on public.rewards(family_id);

-- Membership helper lives in a nonexposed schema, exactly as in v1.
create or replace function private.is_family_admin(p_family_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.family_members
 where family_id=p_family_id and user_id=(select auth.uid()) and role='admin');
$$;
revoke all on function private.is_family_admin(uuid) from public,anon;
grant execute on function private.is_family_admin(uuid) to authenticated;

alter table public.tv_display_settings enable row level security;
alter table public.rewards enable row level security;
alter table public.chore_completions enable row level security;
alter table public.point_transactions enable row level security;
create policy "tv read" on public.tv_display_settings for select to authenticated using ((select private.is_family_member(family_id)));
create policy "tv add" on public.tv_display_settings for insert to authenticated with check ((select private.is_family_member(family_id)));
create policy "tv edit" on public.tv_display_settings for update to authenticated using ((select private.is_family_member(family_id))) with check ((select private.is_family_member(family_id)));
create policy "rewards read" on public.rewards for select to authenticated using ((select private.is_family_member(family_id)));
create policy "rewards add" on public.rewards for insert to authenticated with check ((select private.is_family_admin(family_id)));
create policy "rewards edit" on public.rewards for update to authenticated using ((select private.is_family_admin(family_id))) with check ((select private.is_family_admin(family_id)));
create policy "rewards delete" on public.rewards for delete to authenticated using ((select private.is_family_admin(family_id)));
create policy "chore completion read" on public.chore_completions for select to authenticated using ((select private.is_family_member(family_id)));
create policy "point ledger read" on public.point_transactions for select to authenticated using ((select private.is_family_member(family_id)));
-- Deliberately NO client INSERT/UPDATE/DELETE on completions or points.
grant select,insert,update on public.tv_display_settings to authenticated;
grant select,insert,update,delete on public.rewards to authenticated;
grant select on public.chore_completions,public.point_transactions to authenticated;

-- New family creator is an admin. Existing families are migrated above.
create or replace function public.create_family(p_name text,p_display_name text)
returns uuid language plpgsql security definer set search_path='' as $$
declare family_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if length(trim(p_name)) not between 1 and 80 then raise exception 'Invalid family name'; end if;
 if length(trim(p_display_name)) not between 1 and 60 then raise exception 'Invalid display name'; end if;
 insert into public.families(name) values (trim(p_name)) returning id into family_id;
 insert into public.family_members(family_id,user_id,display_name,role)
 values (family_id,auth.uid(),trim(p_display_name),'admin');
 return family_id;
end;
$$;

-- Read-only, RLS-protected wallet balances. Keeps balances accurate with long histories.
create or replace function public.get_family_wallets(p_family_id uuid)
returns table(user_id uuid,balance bigint)
language sql stable security invoker set search_path='' as $$
 select m.user_id, coalesce(sum(t.delta),0)::bigint as balance
 from public.family_members m
 left join public.point_transactions t on t.family_id=m.family_id and t.user_id=m.user_id
 where m.family_id=p_family_id and private.is_family_member(p_family_id)
 group by m.user_id;
$$;
revoke all on function public.get_family_wallets(uuid) from public,anon;
grant execute on function public.get_family_wallets(uuid) to authenticated;

-- Parent/admin can grant another member admin capability.
create or replace function public.set_family_admin(p_family_id uuid,p_user_id uuid,p_admin boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.is_family_admin(p_family_id) then raise exception 'Admin access required'; end if;
 if p_user_id=auth.uid() and not p_admin then raise exception 'An admin cannot remove their own admin status'; end if;
 update public.family_members set role=case when p_admin then 'admin' else 'member' end
 where family_id=p_family_id and user_id=p_user_id;
 if not found then raise exception 'Family member not found'; end if;
end;
$$;

-- Atomic single-occurrence earning / undo. Serializes competing completions by locking chore.
-- For v1 chores, select an assigned family member in the editor before earning.
create or replace function public.set_chore_completion(p_chore_id uuid,p_due_on date,p_complete boolean)
returns void language plpgsql security definer set search_path='' as $$
declare c public.family_entries%rowtype; old public.chore_completions%rowtype;
  is_due boolean; points_to_reverse integer; wallet_owner uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into c from public.family_entries where id=p_chore_id and type='chore' for update;
 if not found then raise exception 'Chore not found'; end if;
 if not private.is_family_member(c.family_id) then raise exception 'Family access denied'; end if;
 if c.assigned_user_id is null then raise exception 'Assign this chore to a family member first'; end if;
 if not exists(select 1 from public.family_members where family_id=c.family_id and user_id=c.assigned_user_id)
 then raise exception 'Assignee is not a member of this family'; end if;
 if auth.uid() <> c.assigned_user_id and not private.is_family_admin(c.family_id)
 then raise exception 'Only the assignee or a parent can complete this chore'; end if;
 if p_due_on is null or p_due_on<c.occur_on or p_due_on < (current_date-1) or p_due_on > (current_date+1)
 then raise exception 'Chores can only be completed for today'; end if;
 is_due := (c.repeat_rule='daily') or
   (c.repeat_rule='weekly' and extract(dow from p_due_on)=extract(dow from c.occur_on)) or
   (c.repeat_rule='none' and p_due_on=c.occur_on);
 if not is_due then raise exception 'Chore is not scheduled on that day'; end if;
 -- Lock the chore occurrence first, then the actual wallet owner. If a chore was
 -- reassigned after earning, undo must reverse the ORIGINAL assignee's credits.
 select * into old from public.chore_completions where chore_id=p_chore_id and due_on=p_due_on for update;
 wallet_owner := case when not p_complete and old.chore_id is not null
   then old.assignee_user_id else c.assigned_user_id end;
 perform 1 from public.family_members where family_id=c.family_id and user_id=wallet_owner for update;
 if p_complete then
   if old.chore_id is not null and old.reversed_at is null then return; end if;
   if old.chore_id is not null then
     update public.chore_completions set reversed_at=null, completed_at=now(), completed_by=auth.uid(),
       credited_points=c.points, assignee_user_id=c.assigned_user_id where chore_id=p_chore_id and due_on=p_due_on;
   else
     insert into public.chore_completions(family_id,chore_id,due_on,assignee_user_id,credited_points,completed_by)
     values(c.family_id,p_chore_id,p_due_on,c.assigned_user_id,c.points,auth.uid());
   end if;
   if c.points>0 then
     insert into public.point_transactions(family_id,user_id,delta,kind,note,chore_id,due_on,actor_id)
     values(c.family_id,c.assigned_user_id,c.points,'earn',c.name,p_chore_id,p_due_on,auth.uid());
   end if;
 else
   if old.chore_id is null or old.reversed_at is not null then return; end if;
   points_to_reverse:=old.credited_points;
   if points_to_reverse>0 and
      (select coalesce(sum(delta),0) from public.point_transactions where family_id=c.family_id and user_id=old.assignee_user_id)<points_to_reverse
   then raise exception 'Cannot undo: some earned points have already been spent. Make a parent adjustment instead'; end if;
   update public.chore_completions set reversed_at=now() where chore_id=p_chore_id and due_on=p_due_on;
   if points_to_reverse>0 then
     insert into public.point_transactions(family_id,user_id,delta,kind,note,chore_id,due_on,actor_id)
     values(c.family_id,old.assignee_user_id,-points_to_reverse,'undo','Undid: '||c.name,p_chore_id,p_due_on,auth.uid());
   end if;
 end if;
end;
$$;

create or replace function public.redeem_family_reward(p_reward_id uuid,p_user_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare r public.rewards%rowtype; balance integer;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into r from public.rewards where id=p_reward_id and active;
 if not found then raise exception 'Reward not available'; end if;
 if not private.is_family_member(r.family_id) then raise exception 'Family access denied'; end if;
 if auth.uid()<>p_user_id and not private.is_family_admin(r.family_id) then raise exception 'Only parents can redeem for another member'; end if;
 perform 1 from public.family_members where family_id=r.family_id and user_id=p_user_id for update;
 if not found then raise exception 'Wallet owner not found'; end if;
 select coalesce(sum(delta),0) into balance from public.point_transactions where family_id=r.family_id and user_id=p_user_id;
 if balance < r.cost then raise exception 'Not enough points for this reward'; end if;
 insert into public.point_transactions(family_id,user_id,delta,kind,note,reward_id,actor_id)
 values(r.family_id,p_user_id,-r.cost,'redeem',r.name,r.id,auth.uid());
end;
$$;

create or replace function public.adjust_family_points(p_family_id uuid,p_user_id uuid,p_delta integer,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare balance integer;
begin
 if not private.is_family_admin(p_family_id) then raise exception 'Admin access required'; end if;
 if p_delta is null or p_delta=0 or abs(p_delta)>100000 then raise exception 'Invalid point adjustment'; end if;
 if length(trim(coalesce(p_reason,''))) not between 2 and 200 then raise exception 'Please provide a reason'; end if;
 perform 1 from public.family_members where family_id=p_family_id and user_id=p_user_id for update;
 if not found then raise exception 'Wallet owner not found'; end if;
 select coalesce(sum(delta),0) into balance from public.point_transactions where family_id=p_family_id and user_id=p_user_id;
 if balance+p_delta < 0 then raise exception 'Cannot deduct more points than are available'; end if;
 insert into public.point_transactions(family_id,user_id,delta,kind,note,actor_id)
 values(p_family_id,p_user_id,p_delta,'manual',trim(p_reason),auth.uid());
end;
$$;

revoke all on function public.create_family(text,text) from public,anon;
revoke all on function public.set_family_admin(uuid,uuid,boolean) from public,anon;
revoke all on function public.set_chore_completion(uuid,date,boolean) from public,anon;
revoke all on function public.redeem_family_reward(uuid,uuid) from public,anon;
revoke all on function public.adjust_family_points(uuid,uuid,integer,text) from public,anon;
grant execute on function public.create_family(text,text) to authenticated;
grant execute on function public.set_family_admin(uuid,uuid,boolean) to authenticated;
grant execute on function public.set_chore_completion(uuid,date,boolean) to authenticated;
grant execute on function public.redeem_family_reward(uuid,uuid) to authenticated;
grant execute on function public.adjust_family_points(uuid,uuid,integer,text) to authenticated;

-- Enable websocket updates. Polling also refreshes every minute as fallback.
do $$ begin alter publication supabase_realtime add table public.tv_display_settings; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.chore_completions; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.point_transactions; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.rewards; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.families; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.family_members; exception when duplicate_object then null; end $$;
