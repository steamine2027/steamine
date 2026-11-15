-- Migration de production (cahier des charges AMINE Tunis Centre, phase 1) :
--   • livraison des commandes de dépôt gratuite dès 150 DT de produits, 5 DT fixe en dessous
--     (montants en millimes : 150 DT = 150000, 5 DT = 5000), quelle que soit la distance ;
--   • « Prix du jour » : le catalogue renvoie les 4 produits les plus commandés au dépôt sur 30 jours (daily_ids) ;
--   • fidélité : 1 point par dinar, le point vaut 20 millimes (1 000 DT d'achats = 20 DT de réduction, au lieu de 10 DT).
-- Contenu : 2 nouvelles fonctions de tarif, 3 fonctions modifiées (catalogue, devis, création de commande),
-- puis la promotion permanente « livraison offerte » (code LIVRAISON) est désactivée.
-- Les colis (place_parcel, amine.fee_for) ne changent pas. Aucune table, aucun compte, aucune commande n'est modifié.
-- Retour arrière : update amine.promotions set always_on = true, is_active = true where code = 'LIVRAISON';
-- update amine.settings set value = value || '{"point_value": 10}' where key = 'loyalty';
-- puis recharger les 3 fonctions depuis la version précédente de amine.sql.

create or replace function amine.store_delivery_fee(p_subtotal bigint) returns int
language sql immutable set search_path = '' as $$
  select case when p_subtotal >= 150000 then 0 else 5000 end
$$;

create or replace function amine.store_delivery_threshold() returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('free_from', 150000, 'fee', 5000)
$$;

create or replace function public.get_catalog(p_zone_id uuid default null, p_lat numeric default null, p_lng numeric default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  z amine.zones;
  s amine.stores;
  sz amine.zones;
  v_lat numeric;
  v_lng numeric;
  v_km numeric;
  v_delivers boolean;
  v_zone jsonb;
  -- Client connecté : ses prix négociés et sa remise sont affichés avec les produits.
  v_uid uuid := auth.uid();
  v_terms boolean := false;
begin
  perform amine.maintenance();
  if v_uid is not null then
    v_terms := exists (select 1 from amine.client_prices cp where cp.customer_id = v_uid)
      or exists (select 1 from amine.profiles pr where pr.id = v_uid and pr.discount_bps > 0);
  end if;
  if p_lat is not null and p_lng is not null then
    perform amine.check_point(p_lat, p_lng);
    v_lat := p_lat;
    v_lng := p_lng;
    z := amine.zone_for(p_lat, p_lng);
  elsif p_zone_id is not null then
    select zz.* into z from amine.zones zz join amine.cities c on c.id = zz.city_id
    where zz.id = p_zone_id and zz.is_active and c.is_active;
    v_lat := z.center_lat;
    v_lng := z.center_lng;
  end if;
  if z.id is not null then
    v_zone := jsonb_build_object('id', z.id, 'name_fr', z.name_fr, 'name_ar', z.name_ar, 'name_en', z.name_en);
    s := amine.depot_for(v_lat, v_lng);
  end if;

  if s.id is not null then
    v_delivers := true;
  else
    -- Consultation seulement : dépôt actif le plus proche (le plus ancien si l'endroit est inconnu).
    v_delivers := case when v_lat is null then null else false end;
    select st.* into s from amine.stores st
    where st.status = 'active' and st.kind = 'grocery'
    order by case when v_lat is null then 0 else amine.distance_km(st.lat, st.lng, v_lat, v_lng) end, st.created_at, st.id
    limit 1;
  end if;
  if s.id is null then
    return jsonb_build_object('zone', v_zone, 'depot', null, 'sections', '[]'::jsonb, 'products', '[]'::jsonb);
  end if;

  if v_lat is not null then
    v_km := amine.distance_km(s.lat, s.lng, v_lat, v_lng);
  end if;
  if v_delivers then
    select * into sz from amine.zones where id = s.zone_id;
  end if;
  return jsonb_build_object(
    'zone', v_zone,
    'depot', amine.store_card(s) || jsonb_build_object('phone', s.phone, 'hours', s.hours, 'distance_km', v_km,
      'delivery_fee', case when v_delivers then amine.store_delivery_fee(0) end, 'delivery_free_from', 150000, 'delivers', v_delivers),
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object('id', sc.id, 'name', sc.name, 'name_ar', sc.name_ar, 'name_en', sc.name_en)
        order by sc.sort, sc.name)
      from amine.sections sc where sc.store_id = s.id), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(amine.product_json(p) || case when not v_terms then '{}'::jsonb
          else jsonb_build_object('client_price', nullif(amine.unit_price(p, v_uid, 1), p.price)) end
          || amine.flash_card(p, v_uid)
        order by p.sort, p.name)
      from amine.products p where p.store_id = s.id and p.deleted_at is null and p.is_available), '[]'::jsonb),
    -- « Prix du jour » de l'accueil : les 4 produits disponibles les plus commandés au dépôt sur 30 jours
    -- (puis l'ordre du catalogue quand il y a peu de commandes). Le prix affiché est celui du produit, modifié par l'administration.
    'daily_ids', coalesce((
      select jsonb_agg(x.id order by x.rank)
      from (
        select p.id, row_number() over (order by coalesce(t.sold, 0) desc, p.sort, p.name) as rank
        from amine.products p
        left join (
          select it.product_id, sum(it.quantity) as sold
          from amine.order_items it join amine.orders o on o.id = it.order_id
          where o.store_id = s.id and o.status not in ('cancelled', 'rejected') and o.placed_at > now() - interval '30 days'
          group by it.product_id) t on t.product_id = p.id
        where p.store_id = s.id and p.deleted_at is null and p.is_available and (p.stock is null or p.stock > 0)
        order by coalesce(t.sold, 0) desc, p.sort, p.name
        limit 4) x), '[]'::jsonb));
end $$;

create or replace function public.quote_order(
  p_store_id uuid, p_items jsonb, p_address_id uuid default null, p_promo_code text default null,
  p_use_points boolean default false
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s amine.stores;
  sz amine.zones;
  a amine.addresses;
  dz amine.zones;
  v_cart jsonb;
  v_sub int;
  v_fee int;
  v_km numeric;
  v_service int := greatest(0, coalesce((amine.setting('orders') ->> 'service_fee')::int, 0));
  v_max_km numeric := coalesce((amine.setting('orders') ->> 'max_distance_km')::numeric, 15);
  v_reason text;
  v_promo jsonb;
  v_discount int := 0;
  v_loyalty jsonb;
  v_loy_discount int := 0;
  v_stamp int := amine.stamp_fee();
  v_uid uuid := auth.uid();
  cu amine.profiles;
  v_exposure bigint;
begin
  select * into s from amine.stores where id = p_store_id;
  if not found or s.status <> 'active' then
    perform amine.err('STORE_NOT_FOUND');
  end if;
  select * into sz from amine.zones where id = s.zone_id;
  v_cart := amine.price_cart(s.id, p_items, false, v_uid);
  if v_uid is not null then
    select * into cu from amine.profiles where id = v_uid;
    v_exposure := amine.account_exposure(v_uid);
  end if;
  v_sub := (v_cart ->> 'subtotal')::int;

  if p_address_id is not null then
    select * into a from amine.addresses where id = p_address_id and user_id = amine.uid();
    if not found then
      perform amine.err('NOT_FOUND');
    end if;
    v_km := amine.distance_km(s.lat, s.lng, a.lat, a.lng);
    dz := amine.zone_for(a.lat, a.lng);
    if dz.id is null then
      v_reason := 'ADDRESS_OUT_OF_ZONE';
    elsif v_km > v_max_km then
      v_reason := 'TOO_FAR';
    end if;
    v_fee := amine.store_delivery_fee(v_sub);
  else
    v_fee := amine.store_delivery_fee(v_sub);
  end if;
  if not sz.is_active or not (s.kind = any (sz.services)) then
    v_reason := 'SERVICE_UNAVAILABLE';
  end if;
  v_promo := amine.promo_eval(p_promo_code, auth.uid(), s, v_sub, v_fee, v_service);
  if coalesce((v_promo ->> 'ok')::boolean, false) then
    v_discount := (v_promo ->> 'discount')::int;
  end if;
  -- Points de fidélité : utilisables par un client connecté, sur ce qui reste à payer après le code promo.
  if v_uid is not null then
    v_loyalty := amine.loyalty_redeem_calc(v_uid, v_sub, v_sub + v_fee + v_service + v_stamp - v_discount);
    if coalesce(p_use_points, false) and (v_loyalty ->> 'points')::int > 0 then
      v_loy_discount := (v_loyalty ->> 'discount')::int;
    end if;
    v_loyalty := v_loyalty || jsonb_build_object('applied', v_loy_discount > 0);
  end if;

  return jsonb_build_object(
    'lines', v_cart -> 'lines', 'issues', v_cart -> 'issues',
    'subtotal', v_sub, 'delivery_fee', v_fee, 'fee_is_estimate', p_address_id is null,
    'service_fee', v_service, 'discount', v_discount + v_loy_discount, 'promo_discount', v_discount,
    'loyalty', v_loyalty, 'loyalty_discount', v_loy_discount, 'promo', v_promo, 'stamp_fee', v_stamp,
    'total', v_sub + v_fee + v_service + v_stamp - v_discount - v_loy_discount,
    -- Paiement sur compte : seulement pour les clients qui en bénéficient, dans la limite de l'encours.
    'account', case when cu.id is null or cu.payment_terms <> 'account' then null else jsonb_build_object(
      'payment_days', cu.payment_days, 'credit_limit', cu.credit_limit, 'used', v_exposure,
      'available', greatest(0, cu.credit_limit - v_exposure)) end,
    'distance_km', v_km, 'min_order', s.min_order, 'min_order_ok', v_sub >= s.min_order,
    'open_now', amine.store_open_now(s), 'couriers_online', amine.couriers_online(s.zone_id),
    'prep_minutes', s.prep_minutes, 'slots', amine.slots(s),
    'deliverable', v_reason is null, 'reason', v_reason);
end $$;

create or replace function amine.create_store_order(
  p amine.profiles, p_store_id uuid, p_address_id uuid, p_items jsonb, p_note text, p_key text, p_promo_code text,
  p_slot text, p_source text, p_actor text, p_actor_id uuid, p_payment text default 'cod', p_recurring uuid default null,
  p_use_points boolean default false
) returns amine.orders
language plpgsql set search_path = '' as $$
declare
  s amine.stores;
  sz amine.zones;
  a amine.addresses;
  dz amine.zones;
  v_cart jsonb;
  v_sub int;
  v_km numeric;
  v_fee int;
  v_service int := greatest(0, coalesce((amine.setting('orders') ->> 'service_fee')::int, 0));
  v_share int := least(10000, greatest(0, coalesce((amine.setting('couriers') ->> 'share_bps')::int, 8000)));
  v_note text := amine.txt(p_note, 'note', 300, false, 1, true);
  v_promo jsonb;
  v_discount int := 0;
  v_loyalty jsonb;
  v_loy_points int := 0;
  v_loy_discount int := 0;
  v_stamp int := amine.stamp_fee();
  v_total int;
  v_code text;
  v_day date;
  o amine.orders;
begin
  if p.business_name is null then
    perform amine.err('BUSINESS_REQUIRED');
  end if;
  select * into s from amine.stores where id = p_store_id for share;
  if not found or s.status <> 'active' then
    perform amine.err('STORE_NOT_FOUND');
  end if;
  v_day := amine.check_slot(s, p_slot);
  select * into sz from amine.zones where id = s.zone_id;
  if not sz.is_active or not (s.kind = any (sz.services)) then
    perform amine.err('SERVICE_UNAVAILABLE');
  end if;
  select * into a from amine.addresses where id = p_address_id and user_id = p.id;
  if not found then
    perform amine.err('ADDRESS_REQUIRED');
  end if;
  dz := amine.zone_for(a.lat, a.lng);
  if dz.id is null then
    perform amine.err('ADDRESS_OUT_OF_ZONE');
  end if;
  v_km := amine.distance_km(s.lat, s.lng, a.lat, a.lng);
  if v_km > coalesce((amine.setting('orders') ->> 'max_distance_km')::numeric, 15) then
    perform amine.err('TOO_FAR');
  end if;

  v_cart := amine.price_cart(s.id, p_items, true, p.id);
  v_sub := (v_cart ->> 'subtotal')::int;
  if v_sub < s.min_order then
    perform amine.err('MIN_ORDER_NOT_REACHED', s.min_order::text);
  end if;
  v_fee := amine.store_delivery_fee(v_sub);
  -- Code promo (la ligne est verrouillée : deux commandes simultanées ne dépassent pas les limites).
  v_promo := amine.promo_eval(p_promo_code, p.id, s, v_sub, v_fee, v_service, true);
  if v_promo is not null then
    if (v_promo ->> 'ok')::boolean then
      v_discount := (v_promo ->> 'discount')::int;
    elsif coalesce((v_promo ->> 'auto')::boolean, false) then
      -- Offre automatique qui ne s'applique pas à ce panier : pas de remise, pas d'erreur.
      v_promo := null;
    else
      perform amine.err(v_promo ->> 'error', v_promo ->> 'min_subtotal');
    end if;
  end if;
  -- Points de fidélité : utilisés seulement à la demande du client, dans les limites du programme.
  if coalesce(p_use_points, false) then
    v_loyalty := amine.loyalty_redeem_calc(p.id, v_sub, v_sub + v_fee + v_service + v_stamp - v_discount);
    v_loy_points := (v_loyalty ->> 'points')::int;
    v_loy_discount := (v_loyalty ->> 'discount')::int;
    if v_loy_points < 1 then
      perform amine.err('POINTS_NOT_USABLE');
    end if;
  end if;
  v_total := v_sub + v_fee + v_service + v_stamp - v_discount - v_loy_discount;
  perform amine.check_payment(p, coalesce(p_payment, 'cod'), v_total);
  v_code := amine.new_order_code();
  -- Prix flash : les quantités vendues sont recomptées sous verrou (deux commandes simultanées ne dépassent pas le stock offert).
  perform amine.flash_claim(v_cart -> 'lines');
  perform amine.stock_context('sale', v_code);
  perform amine.reserve_stock(v_cart -> 'lines');

  insert into amine.orders (
    code, kind, customer_id, store_id, zone_id, status,
    pickup_name, pickup_phone, pickup_address, pickup_lat, pickup_lng,
    dropoff_name, dropoff_phone, dropoff_address, dropoff_details, dropoff_lat, dropoff_lng, dropoff_located_by,
    payer, distance_km, subtotal, delivery_fee, service_fee, discount, promo_code, stamp_fee, total, commission,
    courier_earning, customer_note, idempotency_key, source, delivery_slot, deliver_on, payment_method, recurring_id,
    loyalty_points, loyalty_discount)
  values (
    v_code, 'store', p.id, s.id, s.zone_id, 'placed',
    s.name, s.phone, s.address, s.lat, s.lng,
    p.business_name, p.phone, a.line, a.details, a.lat, a.lng, a.located_by,
    'customer', v_km, v_sub, v_fee, v_service, v_discount + v_loy_discount, v_promo ->> 'code', v_stamp, v_total,
    round(v_sub::numeric * s.commission_bps / 10000)::int, round(v_fee::numeric * v_share / 10000)::int,
    v_note, p_key, p_source, coalesce(p_slot, 'asap'), v_day, coalesce(p_payment, 'cod'), p_recurring,
    v_loy_points, v_loy_discount)
  returning * into o;

  insert into amine.order_items (order_id, product_id, name, unit, unit_price, list_price, vat_rate, quantity, total, flash_sale_id)
  select o.id, (e.value ->> 'product_id')::uuid, e.value ->> 'name', e.value ->> 'unit',
    (e.value ->> 'unit_price')::int, (e.value ->> 'list_price')::int, (e.value ->> 'vat_rate')::smallint,
    (e.value ->> 'quantity')::int, (e.value ->> 'total')::int, (e.value ->> 'flash_sale_id')::uuid
  from jsonb_array_elements(v_cart -> 'lines') e;
  if v_loy_points > 0 then
    perform amine.loyalty_add(p.id, -v_loy_points, 'redeem', o.id, o.code);
  end if;

  perform amine.log_order(o.id, 'placed', 'status', p_actor, p_actor_id, case when p_source <> 'app' then p_source end);
  perform amine.notify_store(s.id, 'order_new', jsonb_build_object('code', o.code, 'total', o.total),
    '#/depot/orders/' || o.code || '?store=' || s.id::text);
  return o;
end $$;

update amine.promotions
set always_on = false, is_active = false
where code = 'LIVRAISON' and kind = 'free_delivery' and always_on;

-- Fidélité : 1 000 DT d'achats = 20 DT de réduction (le point vaut 20 millimes).
insert into amine.settings (key, value)
values ('loyalty', amine.default_setting('loyalty') || '{"point_value": 20}'::jsonb)
on conflict (key) do update set value = amine.settings.value || '{"point_value": 20}'::jsonb;
