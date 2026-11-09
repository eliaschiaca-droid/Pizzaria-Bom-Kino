create table if not exists public.orders (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  submission_id uuid not null unique,
  customer_name text not null,
  customer_phone text not null,
  fulfillment text not null,
  delivery_address text,
  requested_date date not null,
  requested_time time without time zone not null,
  items jsonb not null,
  total_kz integer not null,
  notes text,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'preparing', 'ready', 'completed', 'cancelled')),
  created_at timestamp with time zone not null default pg_catalog.now(),
  constraint orders_name_length check (pg_catalog.length(customer_name) between 2 and 100),
  constraint orders_phone_format check (customer_phone ~ '^[+0-9 ()-]{7,24}$'),
  constraint orders_fulfillment check (fulfillment in ('pickup', 'delivery')),
  constraint orders_delivery_address check (
    (fulfillment = 'delivery' and delivery_address is not null
      and pg_catalog.length(delivery_address) between 5 and 300)
    or (fulfillment = 'pickup' and delivery_address is null)
  ),
  constraint orders_requested_time check (
    requested_time between time '12:00' and time '21:30'
    and extract(minute from requested_time)::integer in (0, 30)
    and extract(second from requested_time) = 0
  ),
  constraint orders_items_array check (
    pg_catalog.jsonb_typeof(items) = 'array'
    and pg_catalog.jsonb_array_length(items) between 1 and 6
  ),
  constraint orders_total_positive check (total_kz > 0),
  constraint orders_notes_length check (notes is null or pg_catalog.length(notes) <= 500)
);

create table if not exists public.table_bookings (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  submission_id uuid not null unique,
  customer_name text not null,
  customer_phone text not null,
  requested_date date not null,
  requested_time time without time zone not null,
  party_size integer not null check (party_size between 1 and 30),
  notes text,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'cancelled')),
  created_at timestamp with time zone not null default pg_catalog.now(),
  constraint bookings_name_length check (pg_catalog.length(customer_name) between 2 and 100),
  constraint bookings_phone_format check (customer_phone ~ '^[+0-9 ()-]{7,24}$'),
  constraint bookings_requested_time check (
    requested_time between time '12:00' and time '21:30'
    and extract(minute from requested_time)::integer in (0, 30)
    and extract(second from requested_time) = 0
  ),
  constraint bookings_notes_length check (notes is null or pg_catalog.length(notes) <= 500)
);

alter table public.orders enable row level security;
alter table public.table_bookings enable row level security;

revoke all on table public.orders from public, anon, authenticated;
revoke all on table public.table_bookings from public, anon, authenticated;

create or replace function public.create_order(
  p_submission_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_fulfillment text,
  p_delivery_address text,
  p_requested_date date,
  p_requested_time time without time zone,
  p_items jsonb,
  p_total_kz integer,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_item jsonb;
  v_name text;
  v_quantity_text text;
  v_price_text text;
  v_quantity integer;
  v_expected_price integer;
  v_calculated_total integer := 0;
  v_order_id uuid;
  v_seen_names text[] := array[]::text[];
  v_luanda_now timestamp without time zone := pg_catalog.timezone('Africa/Luanda', pg_catalog.now());
begin
  if p_submission_id is null
    or p_customer_name is null or pg_catalog.length(pg_catalog.btrim(p_customer_name)) not between 2 and 100
    or p_customer_phone is null or pg_catalog.length(p_customer_phone) not between 7 and 24
    or p_customer_phone !~ '^[+0-9 ()-]{7,24}$'
    or p_fulfillment is null or p_fulfillment not in ('pickup', 'delivery')
    or p_requested_date is null or p_requested_time is null
    or (p_notes is not null and pg_catalog.length(p_notes) > 500) then
    raise exception using errcode = '22023', message = 'Invalid order details.';
  end if;

  if p_fulfillment = 'delivery' then
    if p_delivery_address is null or pg_catalog.length(pg_catalog.btrim(p_delivery_address)) not between 5 and 300 then
      raise exception using errcode = '22023', message = 'A valid delivery address is required.';
    end if;
  elsif p_delivery_address is not null then
    raise exception using errcode = '22023', message = 'A delivery address is only valid for delivery.';
  end if;

  if p_requested_date < v_luanda_now::date
    or (p_requested_date = v_luanda_now::date and p_requested_time <= v_luanda_now::time)
    or p_requested_time < time '12:00' or p_requested_time > time '21:30'
    or extract(minute from p_requested_time)::integer not in (0, 30)
    or extract(second from p_requested_time) <> 0 then
    raise exception using errcode = '22023', message = 'The requested order date or time is unavailable.';
  end if;

  if p_items is null or pg_catalog.jsonb_typeof(p_items) is distinct from 'array'
    or pg_catalog.jsonb_array_length(p_items) not between 1 and 6 then
    raise exception using errcode = '22023', message = 'Select between 1 and 6 menu items.';
  end if;

  for v_item in
    select item.value from pg_catalog.jsonb_array_elements(p_items) as item(value)
  loop
    v_name := v_item ->> 'name';
    v_quantity_text := v_item ->> 'quantity';
    v_price_text := v_item ->> 'unitPrice';

    if v_name = any(v_seen_names) then
      raise exception using errcode = '22023', message = 'Menu items must be unique.';
    end if;

    v_expected_price := case v_name
      when 'Margherita' then 3500
      when 'Pepperoni' then 4500
      when 'Verde Kino' then 4200
      when 'Quatro Queijos' then 4800
      when 'Horta Fresca' then 4000
      when 'Kino Especial' then 5000
      else null
    end;

    if v_expected_price is null
      or pg_catalog.jsonb_typeof(v_item -> 'quantity') is distinct from 'number'
      or v_quantity_text !~ '^[1-9][0-9]?$'
      or pg_catalog.jsonb_typeof(v_item -> 'unitPrice') is distinct from 'number'
      or v_price_text !~ '^[0-9]{1,7}$'
      or v_price_text::integer <> v_expected_price then
      raise exception using errcode = '22023', message = 'An order contains an invalid menu item.';
    end if;

    v_quantity := v_quantity_text::integer;
    if v_quantity not between 1 and 20 then
      raise exception using errcode = '22023', message = 'Menu item quantities must be between 1 and 20.';
    end if;

    v_seen_names := pg_catalog.array_append(v_seen_names, v_name);
    v_calculated_total := v_calculated_total + v_quantity * v_expected_price;
  end loop;

  if p_total_kz is distinct from v_calculated_total then
    raise exception using errcode = '22023', message = 'The order total does not match the menu.';
  end if;

  insert into public.orders (
    submission_id, customer_name, customer_phone, fulfillment, delivery_address,
    requested_date, requested_time, items, total_kz, notes
  ) values (
    p_submission_id, pg_catalog.btrim(p_customer_name), pg_catalog.btrim(p_customer_phone),
    p_fulfillment, case when p_fulfillment = 'delivery' then pg_catalog.btrim(p_delivery_address) else null end,
    p_requested_date, p_requested_time, p_items, v_calculated_total,
    case when p_notes is null or pg_catalog.btrim(p_notes) = '' then null else pg_catalog.btrim(p_notes) end
  )
  on conflict (submission_id) do nothing
  returning id into v_order_id;

  if v_order_id is null then
    select order_row.id into v_order_id
    from public.orders as order_row
    where order_row.submission_id = p_submission_id;
  end if;

  return v_order_id;
end;
$function$;

create or replace function public.create_table_booking(
  p_submission_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_requested_date date,
  p_requested_time time without time zone,
  p_party_size integer,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_booking_id uuid;
  v_luanda_now timestamp without time zone := pg_catalog.timezone('Africa/Luanda', pg_catalog.now());
begin
  if p_submission_id is null
    or p_customer_name is null or pg_catalog.length(pg_catalog.btrim(p_customer_name)) not between 2 and 100
    or p_customer_phone is null or pg_catalog.length(p_customer_phone) not between 7 and 24
    or p_customer_phone !~ '^[+0-9 ()-]{7,24}$'
    or p_requested_date is null or p_requested_time is null
    or p_party_size is null or p_party_size not between 1 and 30
    or (p_notes is not null and pg_catalog.length(p_notes) > 500) then
    raise exception using errcode = '22023', message = 'Invalid booking details.';
  end if;

  if p_requested_date < v_luanda_now::date
    or (p_requested_date = v_luanda_now::date and p_requested_time <= v_luanda_now::time)
    or p_requested_time < time '12:00' or p_requested_time > time '21:30'
    or extract(minute from p_requested_time)::integer not in (0, 30)
    or extract(second from p_requested_time) <> 0 then
    raise exception using errcode = '22023', message = 'The requested booking date or time is unavailable.';
  end if;

  insert into public.table_bookings (
    submission_id, customer_name, customer_phone, requested_date, requested_time, party_size, notes
  ) values (
    p_submission_id, pg_catalog.btrim(p_customer_name), pg_catalog.btrim(p_customer_phone),
    p_requested_date, p_requested_time, p_party_size,
    case when p_notes is null or pg_catalog.btrim(p_notes) = '' then null else pg_catalog.btrim(p_notes) end
  )
  on conflict (submission_id) do nothing
  returning id into v_booking_id;

  if v_booking_id is null then
    select booking_row.id into v_booking_id
    from public.table_bookings as booking_row
    where booking_row.submission_id = p_submission_id;
  end if;

  return v_booking_id;
end;
$function$;

revoke all on function public.create_order(
  uuid, text, text, text, text, date, time without time zone, jsonb, integer, text
) from public, anon, authenticated;
grant execute on function public.create_order(
  uuid, text, text, text, text, date, time without time zone, jsonb, integer, text
) to anon;

revoke all on function public.create_table_booking(
  uuid, text, text, date, time without time zone, integer, text
) from public, anon, authenticated;
grant execute on function public.create_table_booking(
  uuid, text, text, date, time without time zone, integer, text
) to anon;
