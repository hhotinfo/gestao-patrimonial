-- Gestão Patrimonial: tabelas no mesmo projeto Supabase do Controle de IPTU e do Controle de Seguros.
-- Rode no SQL Editor do projeto. Pode rodar mais de uma vez: nada é duplicado.
-- As tabelas antigas (imoveis e seguros) NÃO são alteradas; os dados delas são copiados.

-- 1. Tabelas ------------------------------------------------------------------
create table if not exists public.gp_titulares (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  tipo text not null default 'Empresa',          -- 'Pessoa física' ou 'Empresa'
  doc text not null default '',                  -- CPF ou CNPJ
  obs text not null default '',
  criado_em timestamptz not null default now()
);

create table if not exists public.gp_bens (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  tipo text not null default 'Imóvel',
  status text not null default 'Ativo',          -- Ativo, À venda, Vendido, Baixado
  titular_id uuid references public.gp_titulares(id) on delete restrict,
  perc numeric(7,3) not null default 100,        -- percentual de titularidade
  local text not null default '',                -- município ou localização
  ident text not null default '',                -- matrícula, placa, CNPJ...
  ident2 text not null default '',               -- sequencial na prefeitura, RENAVAM...
  data_aq date,
  v_aq numeric(16,2) not null default 0,         -- valor de aquisição
  v_ir numeric(16,2) not null default 0,         -- valor declarado no IR
  v_merc numeric(16,2) not null default 0,       -- valor de mercado
  data_aval date,
  obs text not null default '',
  origem text unique,                            -- de onde veio na importação (ex.: imoveis:12)
  criado_em timestamptz not null default now()
);

create table if not exists public.gp_iptu (
  id uuid primary key default gen_random_uuid(),
  bem_id uuid not null references public.gp_bens(id) on delete cascade,
  ano int not null,                              -- exercício
  venc date,
  valor numeric(14,2) not null default 0,        -- IPTU
  itbi numeric(14,2) not null default 0,
  taxas numeric(14,2) not null default 0,
  status text not null default 'Pendente',       -- Pendente, Pago, Parcelado, Contestado, Isento, Cancelado
  data_pag date,
  valor_pag numeric(14,2) not null default 0,
  obs text not null default '',
  criado_em timestamptz not null default now(),
  unique (bem_id, ano)
);

create table if not exists public.gp_seguros (
  id uuid primary key default gen_random_uuid(),
  bem_id uuid references public.gp_bens(id) on delete set null,
  produto text not null,
  categoria text not null default '',
  status text not null default 'Ativo',          -- Ativo, Em cotação, Sem seguro, Cancelado, Transferido
  seguradora text not null default '',
  corretor text not null default '',
  apolice text not null default '',
  premio numeric(14,2) not null default 0,
  segurado numeric(16,2) not null default 0,     -- importância segurada
  pagamento text not null default '',
  vig_ini date,
  vig_fim date,
  alerta date,
  obs text not null default '',
  origem text unique,                            -- de onde veio na importação (ex.: seguros:7)
  criado_em timestamptz not null default now()
);

create index if not exists gp_bens_titular_idx on public.gp_bens (titular_id);
create index if not exists gp_seguros_bem_idx on public.gp_seguros (bem_id);

-- 2. Acesso só com login (mesma regra das tabelas imoveis e seguros) e atualização em tempo real ----------------------------
do $$
declare t text;
begin
  foreach t in array array['gp_titulares','gp_bens','gp_iptu','gp_seguros'] loop
    execute format('alter table public.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and policyname = 'usuarios logados') then
      execute format('create policy "usuarios logados" on public.%I for all to authenticated using (true) with check (true)', t);
    end if;
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 3. Importação do Controle de IPTU (tabela imoveis) ------------------------------
-- Cada "empresa" vira um titular; cada imóvel vira um bem; IPTU 2026 e dívidas 2025/2024 viram lançamentos.
insert into public.gp_titulares (nome)
select distinct trim(emp) from public.imoveis where coalesce(trim(emp), '') <> ''
on conflict (nome) do nothing;

insert into public.gp_bens (nome, tipo, status, titular_id, local, ident2, obs, origem)
select i.nome, 'Imóvel', case when i.status = 'Vendido' then 'Vendido' else 'Ativo' end,
       t.id, coalesce(i.mun, ''), coalesce(i.seq::text, ''), coalesce(i.obs, ''), 'imoveis:' || i.id::text
from public.imoveis i
left join public.gp_titulares t on t.nome = trim(i.emp)
order by i.ordem
on conflict (origem) do nothing;

with src as (
  select b.id as bem_id,
         coalesce(i.iptu, 0)::numeric as iptu, coalesce(i.itbi, 0)::numeric as itbi,
         coalesce(i.d2025, 0)::numeric as d2025, coalesce(i.d2024, 0)::numeric as d2024,
         coalesce(i.valor_pag, 0)::numeric as pago,
         nullif(i.data_pag::text, '')::date as data_pag,
         case when i.status = 'Vendido' then 'Cancelado' else coalesce(nullif(i.status, ''), 'Pendente') end as st
  from public.imoveis i
  join public.gp_bens b on b.origem = 'imoveis:' || i.id::text
), pg as (
  -- o valor pago quita primeiro a dívida mais antiga
  select *, least(pago, d2024) as p24, least(greatest(pago - d2024, 0), d2025) as p25 from src
)
insert into public.gp_iptu (bem_id, ano, venc, valor, itbi, status, data_pag, valor_pag, obs)
select bem_id, 2026, date '2026-03-02', iptu, itbi, st, data_pag, pago - p24 - p25, '' from pg
union all
select bem_id, 2025, null, d2025, 0, st, case when p25 > 0 then data_pag end, p25, 'Dívida ativa' from pg where d2025 > 0
union all
select bem_id, 2024, null, d2024, 0, st, case when p24 > 0 then data_pag end, p24, 'Dívida ativa' from pg where d2024 > 0
on conflict (bem_id, ano) do nothing;

-- 4. Importação do Controle de Seguros (tabela seguros) ---------------------------
-- Os seguros entram sem vínculo; ligue cada um ao bem pela ficha do seguro.
insert into public.gp_seguros (produto, categoria, status, seguradora, corretor, apolice, premio, pagamento, vig_ini, vig_fim, alerta, obs, origem)
select s.produto, coalesce(s.categoria, ''), coalesce(nullif(s.status, ''), 'Ativo'), coalesce(s.seguradora, ''), coalesce(s.corretor, ''),
       coalesce(s.apolice, ''), coalesce(s.premio, 0), coalesce(s.pagamento, ''),
       nullif(s.vig_ini::text, '')::date, nullif(s.vig_fim::text, '')::date, nullif(s.alerta::text, '')::date,
       coalesce(s.obs, ''), 'seguros:' || s.id::text
from public.seguros s
order by s.ordem
on conflict (origem) do nothing;

-- 5. Conferência ------------------------------------------------------------------
select 'titulares' as tabela, count(*) as registros from public.gp_titulares
union all select 'bens', count(*) from public.gp_bens
union all select 'iptu', count(*) from public.gp_iptu
union all select 'seguros', count(*) from public.gp_seguros;
