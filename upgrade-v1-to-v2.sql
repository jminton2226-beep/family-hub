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
