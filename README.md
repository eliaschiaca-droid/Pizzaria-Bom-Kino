# Bom Kino

Site da pizzaria Bom Kino, publicado no GitHub Pages:
<https://eliaschiaca-droid.github.io/Pizzaria-Bom-Kino/>

## Pedidos e reservas

- Os formulários enviam os dados ao Supabase através das funções `create_order` e `create_table_booking`.
- As encomendas e reservas ficam na base de dados com o estado inicial `pending`; a pizzaria confirma a disponibilidade separadamente pelo WhatsApp.
- Os dados ficam nas tabelas `public.orders` e `public.table_bookings`. A equipa pode consultá-los no Table Editor do Supabase.
- O acesso público às tabelas está bloqueado por RLS e privilégios SQL. Os visitantes só podem executar as funções de registo; não podem ler os dados enviados.
- A chave `anonKey` em `supabase/config.js` é publicável e ficará visível no site. Nunca coloques nesse ficheiro a palavra-passe da base de dados, uma chave `secret` ou `service_role`.

## Configuração do Supabase

1. Cria um projeto Supabase.
2. No **SQL Editor**, executa o conteúdo de [`supabase/schema.sql`](./supabase/schema.sql).
3. Em **Project Settings → API Keys**, copia a chave **Publishable** e o URL do projeto para `supabase/config.js`.
4. Publica os ficheiros. Os pedidos e reservas só podem ser enviados depois de o esquema e as credenciais públicas estarem configurados.

A chave publicável não é um segredo. A segurança dos dados depende de manter RLS ativa, não conceder acesso de leitura e nunca publicar uma chave secreta.
