-- Dawrak production foundation (PostgreSQL / Supabase)
create extension if not exists pgcrypto;

create type public.account_role as enum ('customer', 'owner', 'admin');
create type public.booking_status as enum ('waiting', 'called', 'in_service', 'completed', 'cancelled', 'no_show');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  role public.account_role not null default 'customer',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete restrict,
  name text not null,
  slug text not null unique,
  category text not null,
  description text not null default '',
  address text not null default '',
  area text not null default '',
  latitude double precision,
  longitude double precision,
  phone text,
  cover_image text,
  is_open boolean not null default false,
  accepts_bookings boolean not null default false,
  workers_count integer not null default 1 check (workers_count between 1 and 100),
  average_service_minutes integer not null default 20 check (average_service_minutes between 1 and 600),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index shops_owner_id_idx on public.shops(owner_id);
create index shops_area_category_idx on public.shops(area, category);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null,
  description text not null default '',
  duration_minutes integer not null check (duration_minutes between 1 and 600),
  price numeric(10,2),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index services_shop_id_idx on public.services(shop_id);

create table public.shop_photos (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  storage_path text not null,
  caption text not null default '',
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.offers (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  title text not null,
  description text not null default '',
  original_price numeric(10,2),
  offer_price numeric(10,2),
  image_path text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  check (original_price is null or offer_price is null or offer_price <= original_price)
);
create index offers_shop_active_idx on public.offers(shop_id, is_active, ends_at);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete restrict,
  service_id uuid references public.services(id) on delete set null,
  customer_id uuid not null references public.profiles(id) on delete restrict,
  ticket_number bigint not null,
  customer_name text not null,
  status public.booking_status not null default 'waiting',
  estimated_wait_minutes integer not null default 0 check (estimated_wait_minutes >= 0),
  estimated_start_at timestamptz,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(shop_id, ticket_number)
);
create index bookings_shop_queue_idx on public.bookings(shop_id, status, ticket_number);
create index bookings_customer_idx on public.bookings(customer_id, created_at desc);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete set null,
  rating smallint not null check (rating between 1 and 5),
  comment text not null default '',
  owner_reply text not null default '',
  created_at timestamptz not null default now(),
  unique(customer_id, booking_id)
);
create index reviews_shop_idx on public.reviews(shop_id, created_at desc);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  body text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications(user_id, created_at desc);

-- Automatically create a customer profile when an account signs up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name',''), new.phone);
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_shop_owner(target_shop uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.shops where id = target_shop and owner_id = auth.uid());
$$;
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- Atomic booking: lock the shop row, verify availability, allocate a unique ticket.
create or replace function public.create_booking(
  p_shop_id uuid,
  p_service_id uuid default null,
  p_customer_name text default null,
  p_notes text default ''
) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  s public.shops%rowtype;
  next_ticket bigint;
  service_duration integer;
  waiting_before integer;
  result public.bookings%rowtype;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  select * into s from public.shops where id = p_shop_id for update;
  if not found then raise exception 'المحل غير موجود'; end if;
  if not s.is_open or not s.accepts_bookings then raise exception 'المحل لا يستقبل حجوزات حاليًا'; end if;
  if p_service_id is not null and not exists (
    select 1 from public.services where id = p_service_id and shop_id = p_shop_id and is_active
  ) then raise exception 'الخدمة غير متاحة'; end if;
  select coalesce(duration_minutes, s.average_service_minutes) into service_duration
    from public.services where id = p_service_id;
  service_duration := coalesce(service_duration, s.average_service_minutes);
  select count(*) into waiting_before from public.bookings
    where shop_id = p_shop_id and status in ('waiting','called','in_service');
  select coalesce(max(ticket_number),0)+1 into next_ticket from public.bookings where shop_id = p_shop_id;
  insert into public.bookings(shop_id, service_id, customer_id, ticket_number, customer_name, estimated_wait_minutes, estimated_start_at, notes)
  values (p_shop_id, p_service_id, auth.uid(), next_ticket,
    coalesce(nullif(trim(p_customer_name),''),'عميل'),
    ceil(waiting_before * service_duration::numeric / greatest(s.workers_count,1))::integer,
    now() + make_interval(mins => ceil(waiting_before * service_duration::numeric / greatest(s.workers_count,1))::integer),
    coalesce(p_notes,'')) returning * into result;
  return result;
end;
$$;
revoke all on function public.create_booking(uuid,uuid,text,text) from public;
grant execute on function public.create_booking(uuid,uuid,text,text) to authenticated;

-- Row-level security
alter table public.profiles enable row level security;
alter table public.shops enable row level security;
alter table public.services enable row level security;
alter table public.shop_photos enable row level security;
alter table public.offers enable row level security;
alter table public.bookings enable row level security;
alter table public.reviews enable row level security;
alter table public.notifications enable row level security;

create policy "profiles read self or admin" on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy "profiles update self" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid() and role = (select p.role from public.profiles p where p.id = auth.uid()));
create policy "public reads open shops" on public.shops for select to anon, authenticated using (is_open or owner_id = auth.uid() or public.is_admin());
create policy "owners create shops" on public.shops for insert to authenticated with check (owner_id = auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and role in ('owner','admin')));
create policy "owners update own shops" on public.shops for update to authenticated using (owner_id = auth.uid() or public.is_admin()) with check (owner_id = auth.uid() or public.is_admin());
create policy "services public read active" on public.services for select to anon, authenticated using (is_active or public.is_shop_owner(shop_id) or public.is_admin());
create policy "owners manage services" on public.services for all to authenticated using (public.is_shop_owner(shop_id) or public.is_admin()) with check (public.is_shop_owner(shop_id) or public.is_admin());
create policy "photos public read" on public.shop_photos for select to anon, authenticated using (true);
create policy "owners manage photos" on public.shop_photos for all to authenticated using (public.is_shop_owner(shop_id) or public.is_admin()) with check (public.is_shop_owner(shop_id) or public.is_admin());
create policy "offers public read active" on public.offers for select to anon, authenticated using (is_active and (ends_at is null or ends_at >= now()) or public.is_shop_owner(shop_id) or public.is_admin());
create policy "owners manage offers" on public.offers for all to authenticated using (public.is_shop_owner(shop_id) or public.is_admin()) with check (public.is_shop_owner(shop_id) or public.is_admin());
create policy "customers read own bookings and owners read shop bookings" on public.bookings for select to authenticated using (customer_id = auth.uid() or public.is_shop_owner(shop_id) or public.is_admin());
create policy "customers cancel own waiting bookings" on public.bookings for update to authenticated using (customer_id = auth.uid() and status = 'waiting') with check (customer_id = auth.uid() and status in ('waiting','cancelled'));
create policy "owners update bookings" on public.bookings for update to authenticated using (public.is_shop_owner(shop_id) or public.is_admin()) with check (public.is_shop_owner(shop_id) or public.is_admin());
create policy "reviews public read" on public.reviews for select to anon, authenticated using (true);
create policy "customers create own reviews" on public.reviews for insert to authenticated with check (customer_id = auth.uid());
create policy "review owner reply" on public.reviews for update to authenticated using (public.is_shop_owner(shop_id) or public.is_admin()) with check (public.is_shop_owner(shop_id) or public.is_admin());
create policy "users read own notifications" on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "users update own notifications" on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- NOTE: Storage bucket and storage.objects policies are configured separately in the setup guide.
