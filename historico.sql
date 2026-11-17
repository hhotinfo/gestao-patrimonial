-- Gestão Patrimonial: histórico de alterações (quem alterou o quê e quando).
-- Rode no SQL Editor do projeto Supabase, depois do banco.sql. Pode rodar mais de uma vez.
-- O registro é feito pelo próprio banco, por gatilhos: toda inclusão, alteração ou exclusão
-- em titulares, bens, IPTU e seguros gera uma linha em gp_log, venha de onde vier.
-- Os usuários com login podem ler o histórico, mas ninguém o altera nem apaga pelo sistema.

-- 1. Tabela do histórico -----------------------------------------------------------
create table if not exists public.gp_log (
  id bigint generated always as identity primary key,
  em timestamptz not null default now(),          -- data e hora da alteração
  usuario_id uuid,                                -- id do usuário logado (vazio se veio de fora do sistema)
  usuario text not null default '',               -- e-mail do usuário
  tabela text not null,                           -- gp_titulares, gp_bens, gp_iptu ou gp_seguros
  registro uuid,                                  -- id do registro alterado
  acao text not null,                             -- Inclusão, Alteração ou Exclusão
  descricao text not null default '',             -- nome do registro na hora da alteração
  antes jsonb,                                    -- valores antes (só os campos que mudaram, numa alteração)
  depois jsonb                                    -- valores depois (só os campos que mudaram, numa alteração)
);
create index if not exists gp_log_em_idx on public.gp_log (em desc);
create index if not exists gp_log_registro_idx on public.gp_log (tabela, registro);

-- 2. Função que grava o histórico ----------------------------------------------------
create or replace function public.gp_registrar_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb; v_new jsonb; v_row jsonb; v_desc text; v_email text;
begin
  if tg_op = 'UPDATE' then
    -- guarda só os campos que mudaram
    select jsonb_object_agg(n.key, o.value), jsonb_object_agg(n.key, n.value)
      into v_old, v_new
      from jsonb_each(to_jsonb(new)) n
      join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value;
    if v_new is null then return null; end if;    -- salvou sem mudar nada: não registra
    v_row := to_jsonb(new);
  elsif tg_op = 'INSERT' then
    v_new := to_jsonb(new); v_row := v_new;
  else
    v_old := to_jsonb(old); v_row := v_old;
  end if;

  v_desc := coalesce(v_row->>'nome', v_row->>'produto', '');
  if tg_table_name = 'gp_iptu' then
    select b.nome into v_desc from public.gp_bens b where b.id = (v_row->>'bem_id')::uuid;
    v_desc := coalesce(v_desc, 'Bem excluído') || ' · ' || coalesce(v_row->>'ano', '');
  end if;

  v_email := coalesce(nullif(auth.jwt() ->> 'email', ''), 'Supabase (fora do sistema)');

  insert into public.gp_log (usuario_id, usuario, tabela, registro, acao, descricao, antes, depois)
  values (auth.uid(), v_email, tg_table_name, (v_row->>'id')::uuid,
          case tg_op when 'INSERT' then 'Inclusão' when 'UPDATE' then 'Alteração' else 'Exclusão' end,
          v_desc, v_old, v_new);
  return null;
end $$;

-- 3. Gatilhos nas quatro tabelas -------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['gp_titulares','gp_bens','gp_iptu','gp_seguros'] loop
    execute format('drop trigger if exists gp_log_trg on public.%I', t);
    execute format('create trigger gp_log_trg after insert or update or delete on public.%I for each row execute function public.gp_registrar_log()', t);
  end loop;
end $$;

-- 4. Proteção: com login, só leitura ----------------------------------------------------
alter table public.gp_log enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'gp_log' and policyname = 'leitura com login') then
    create policy "leitura com login" on public.gp_log for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'gp_log') then
    alter publication supabase_realtime add table public.gp_log;
  end if;
end $$;
revoke all on public.gp_log from anon, authenticated;
grant select on public.gp_log to authenticated;
revoke execute on function public.gp_registrar_log() from public, anon, authenticated;

-- 5. Conferência --------------------------------------------------------------------------
select (select count(*) from pg_trigger where tgname = 'gp_log_trg') as gatilhos,
       (select count(*) from public.gp_log) as registros_no_historico;
