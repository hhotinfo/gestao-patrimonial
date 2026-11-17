# Gestão Patrimonial

Cadastro de bens por titular (pessoa física e empresas), com os módulos de IPTU e de seguros ligados a cada bem. Publicada pelo GitHub Pages, com os dados guardados no Supabase e acesso só com login.

- `index.html` — o sistema
- `config.js` — endereço e chave pública do projeto Supabase (o mesmo do Controle de IPTU e do Controle de Seguros)
- `historico.sql` — cria o histórico de alterações (tabela `gp_log` e os gatilhos que registram quem incluiu, alterou ou excluiu cada registro)
- `banco.sql` — cria as tabelas `gp_titulares`, `gp_bens`, `gp_iptu` e `gp_seguros` e copia os dados das tabelas `imoveis` e `seguros`

Os dados **não** ficam neste repositório; ficam no banco do Supabase, protegidos por login.

Endereço: https://hhotinfo.github.io/gestao-patrimonial/
