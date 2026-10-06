-- Santa Squad: private family wishlists, accessed through unguessable links.
create extension if not exists pgcrypto;

create type public.portal_role as enum ('admin', 'child_editor', 'family_viewer');
create type public.wish_priority as enum ('lovely', 'would_love', 'dream_gift');

create table public.family_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table public.children (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_groups(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  created_at timestamptz not null default now()
);

create table public.access_links (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.family_groups(id) on delete cascade,
  child_id uuid references public.children(id) on delete cascade,
  role public.portal_role not null,
  token text not null unique default encode(gen_random_bytes(24), 'hex'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint child_editor_requires_child check ((role = 'child_editor') = (child_id is not null))
);

create table public.wishes (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 180),
  url text,
  notes text,
  priority public.wish_priority not null default 'would_love',
  occasion text not null default 'santa' check (occasion in ('santa', 'birthday')),
  created_at timestamptz not null default now()
);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  wish_id uuid not null unique references public.wishes(id) on delete cascade,
  reserved_by text not null check (char_length(reserved_by) between 1 and 80),
  note text,
  created_at timestamptz not null default now()
);

alter table public.family_groups enable row level security;
alter table public.children enable row level security;
alter table public.access_links enable row level security;
alter table public.wishes enable row level security;
alter table public.reservations enable row level security;

-- The tables are never directly readable by the anonymous browser client.
-- Each function checks a random, revocable access-link token.
create function public.portal_for(p_token text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare link_row public.access_links; result jsonb;
begin
  select * into link_row from public.access_links where token = p_token and active;
  if not found then raise exception 'That family link is no longer active.' using errcode = 'P0001'; end if;
  select jsonb_build_object(
    'role', link_row.role,
    'group', jsonb_build_object('id', g.id, 'name', g.name),
    'childId', link_row.child_id,
    'children', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.display_name) order by c.created_at)
      from public.children c where c.group_id = g.id and (link_row.role <> 'child_editor' or c.id = link_row.child_id)), '[]'::jsonb),
    'wishes', coalesce((select jsonb_agg(jsonb_build_object(
      'id', w.id, 'childId', w.child_id, 'title', w.title, 'url', w.url, 'notes', w.notes,
      'priority', w.priority, 'occasion', w.occasion,
      'reserved', exists(select 1 from public.reservations r where r.wish_id = w.id),
      'reservedBy', case when link_row.role = 'family_viewer' then (
        select r.reserved_by from public.reservations r where r.wish_id = w.id order by r.created_at desc limit 1
      ) else null end
    ) order by w.created_at desc) from public.wishes w join public.children c on c.id = w.child_id
      where c.group_id = g.id and (link_row.role <> 'child_editor' or c.id = link_row.child_id)), '[]'::jsonb)
  ) into result from public.family_groups g where g.id = link_row.group_id;
  return result;
end $$;

create function public.add_wish(p_token text, p_title text, p_url text default null, p_notes text default null, p_priority public.wish_priority default 'would_love', p_occasion text default 'santa')
returns uuid language plpgsql security definer set search_path = public as $$
declare link_row public.access_links; new_id uuid;
begin
  select * into link_row from public.access_links where token = p_token and active and role = 'child_editor';
  if not found then raise exception 'Only a child’s edit link can add wishes.' using errcode = 'P0001'; end if;
  if p_occasion not in ('santa', 'birthday') then raise exception 'Choose Santa or Birthday for this wish.' using errcode = 'P0001'; end if;
  insert into public.wishes(child_id,title,url,notes,priority,occasion) values (link_row.child_id,trim(p_title),nullif(trim(p_url),''),nullif(trim(p_notes),''),p_priority,p_occasion) returning id into new_id;
  return new_id;
end $$;

create function public.remove_wish(p_token text, p_wish_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare link_row public.access_links;
begin
  select * into link_row from public.access_links where token = p_token and active and role = 'child_editor';
  if not found then raise exception 'Only a child’s edit link can remove wishes.' using errcode = 'P0001'; end if;
  delete from public.wishes where id = p_wish_id and child_id = link_row.child_id and not exists (select 1 from public.reservations where wish_id = p_wish_id);
end $$;

create function public.reserve_wish(p_token text, p_wish_id uuid, p_name text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare link_row public.access_links;
begin
  select * into link_row from public.access_links where token = p_token and active and role = 'family_viewer';
  if not found then raise exception 'Use the family gift link to reserve a gift.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.wishes w join public.children c on c.id = w.child_id where w.id = p_wish_id and c.group_id = link_row.group_id) then
    raise exception 'That wish is not in this family list.' using errcode = 'P0001';
  end if;
  insert into public.reservations(wish_id,reserved_by,note) values (p_wish_id,trim(p_name),nullif(trim(p_note),''));
exception when unique_violation then raise exception 'Someone has already reserved this gift.' using errcode = 'P0001';
end $$;

create function public.create_child_link(p_token text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare link_row public.access_links; child_row public.children; child_token text;
begin
  select * into link_row from public.access_links where token = p_token and active and role = 'admin';
  if not found then raise exception 'Only the family organiser can add a child.' using errcode = 'P0001'; end if;
  insert into public.children(group_id,display_name) values(link_row.group_id,trim(p_name)) returning * into child_row;
  insert into public.access_links(group_id,child_id,role) values(link_row.group_id,child_row.id,'child_editor') returning token into child_token;
  return jsonb_build_object('childId',child_row.id,'name',child_row.display_name,'token',child_token);
end $$;

create function public.create_family_viewer_link(p_token text)
returns text language plpgsql security definer set search_path = public as $$
declare link_row public.access_links; new_token text;
begin
  select * into link_row from public.access_links where token = p_token and active and role = 'admin';
  if not found then raise exception 'Only the family organiser can create a family link.' using errcode = 'P0001'; end if;
  insert into public.access_links(group_id,role) values(link_row.group_id,'family_viewer') returning token into new_token;
  return new_token;
end $$;

revoke all on all tables in schema public from anon, authenticated;
grant usage on schema public to anon;
grant execute on function public.portal_for(text), public.add_wish(text,text,text,text,public.wish_priority,text), public.remove_wish(text,uuid), public.reserve_wish(text,uuid,text,text), public.create_child_link(text,text), public.create_family_viewer_link(text) to anon;

-- One family administrator link. Save the returned token in your first URL:
-- select token from public.access_links where role = 'admin';
insert into public.family_groups(name) values ('Our Family Christmas 2026');
insert into public.access_links(group_id, role) select id, 'admin' from public.family_groups where name = 'Our Family Christmas 2026';
