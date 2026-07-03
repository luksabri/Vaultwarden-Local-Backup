# Vaultwarden Local Backup
⚠️ **Nota de Segurança Importante:** Este guia assume e recomenda estritamente o uso da VPN WireGuard para todo o tráfego de dados. Caso você opte por utilizar um IP público para acessar sua instância 
da Oracle, desconsidere os passos de configuração do `nmcli` (Seção 1). No entanto, expor publicamente portas de SSH ou instâncias de banco de dados é **altamente desencorajada**
---

## 🛠️ Requisitos Prévios

No seu dispositivo local Debian, certifique-se de ter:
* Chave privada SSH válida (`.key`) configurada.
* Perfil de VPN WireGuard criado no NetworkManager do GNOME (nomeado como `oracle`).
* Cliente `curl` e `scp` instalados.

---

## 1. Automatização Dinâmica da VPN para Notebooks

Como notebooks se movem constantemente entre redes diferentes (Wi-Fi de casa, trabalho ou roteamento móvel), a VPN precisa ser inteligente para não quebrar o boot ou falhar caso a internet demore a responder.

Usamos o `nmcli` nativo do NetworkManager para colocar a VPN `oracle` em estado de alerta constante, usando **prioridade negativa**. Isso força o sistema a só tentar conectar a VPN *depois* que uma conexão de transporte (Wi-Fi/Ethernet) já estiver com IP válido.

Execute no terminal do seu notebook:

```bash
# Permite que a conexão suba sozinha em qualquer circunstância
nmcli connection modify "oracle" connection.autoconnect yes

# Ajusta a prioridade para o valor negativo (Modo Lazy Loading)
nmcli connection modify "oracle" connection.autoconnect-priority -10
```


---


## 2. O Script de Sincronização (sync_backups.sh)
Crie o diretório de scripts no seu usuário local e configure o arquivo:

```bash
mkdir -p /home/seu-user/scripts
nano /home/seu-user/scripts/sync_backups.sh
```
Cole o conteúdo abaixo:

```bash
#!/bin/bash

# --- CONFIGURAÇÕES ---
KEY_PATH="/home/seu-user/scripts/ssh-key-xxxx.key"
REMOTE_USER=""
REMOTE_IP=""
REMOTE_DIR="/home/ubuntu/backups"
LOCAL_DEST="/home/seu-user/backups_locais"
N8N_WEBHOOK_URL="[http://SEU-IP/webhook/backup-vaultwarden](http://SEU-IP:5678/webhook/backup-vaultwarden)"

# Garante a existência da pasta local
mkdir -p "$LOCAL_DEST"

echo "=== Iniciando Verificação de Boot ==="

# Aguarda até 2 minutos para o túnel Wireguard responder ao ping interno
MAX_TENTATIVAS=24
CONTADOR=0
VPN_ONLINE=false

while [ \$CONTADOR -lt \$MAX_TENTATIVAS ]; do
    if ping -c 1 -W 2 \$REMOTE_IP > /dev/null 2>&1; then
        echo "Conexão com a rede interna da Oracle estabelecida!"
        VPN_ONLINE=true
        break
    fi
    echo "Aguardando VPN oracle conectar... (\$((\$CONTADOR+1))/\$MAX_TENTATIVAS)"
    sleep 5
    ((CONTADOR++))
done

if [ "\$VPN_ONLINE" = false ]; then
    echo "Erro: VPN não conectou a tempo."
    exit 1
fi

echo "Iniciando cópia segura dos arquivos da Oracle..."

# Executa o SCP usando o ambiente do usuário logado (sem sudo)
DOWNLOAD_LOG=\$(scp -i "\$KEY_PATH" -o StrictHostKeyChecking=no "\$REMOTE_USER"@"\$REMOTE_IP":"\$REMOTE_DIR"/*.sqlite3 "\$LOCAL_DEST/" 2>&1)

if [ \$? -eq 0 ]; then
    STATUS="sucesso"
    ARQUIVOS_BAIXADOS=\$(ls -A "\$LOCAL_DEST" | grep ".sqlite3" | tr '\\n' ' ')
    MENSAGEM="Backup sincronizado com sucesso via WireGuard no boot do Debian."
else
    STATUS="erro"
    ARQUIVOS_BAIXADOS="Nenhum"
    MENSAGEM="Falha ao transferir arquivos via SCP. Erro: \$DOWNLOAD_LOG"
fi

echo "Enviando dados para o n8n..."
curl -X POST "\$N8N_WEBHOOK_URL" \
     -H "Content-Type: application/json" \
     -d '{
       "status": "'"\$STATUS"'",
       "arquivo_criado": "'"\${ARQUIVOS_BAIXADOS//\\"/'\\\\\\"}"'",
       "arquivo_excluido": "Nenhum (Sincronização Local)",
       "mensagem": "'"\${MENSAGEM//\\"/'\\\\\\"}"'"
     }'

echo "=== Processo Finalizado ==="
Defina as permissões corretas de segurança para a sua chave e para o script:
```
 ### 
 ---
```bash
chmod +x /home/seu-user/scripts/sync_backups.sh
chmod 600 /home/seu-user/scripts/ssh-key-xxxx.key

```
##
3. Configuração do Systemd no Espaço de Usuário (User Space)
Serviços globais do sistema (/etc/systemd/system) rodam antes do ambiente gráfico e das credenciais de rede do usuário estarem prontas, quebrando scripts baseados em VPNs de interface. A solução ideal é usar o Systemd em nível de usuário.

Crie o diretório de serviços do seu usuário:

```bash
mkdir -p /home/seu-usuer/.config/systemd/user/
```
Crie o arquivo do serviço:

```Bash
nano /home/seu-user/.config/systemd/user/sync-backup-boot.service
```
Cole a estrutura do serviço:

```Ini, TOML
[Unit]
Description=Sincronizar Backups da Oracle via WireGuard
After=network.target

[Service]
Type=oneshot
ExecStart=/home/luk-dev/scripts/sync_backups.sh
RemainAfterExit=yes

[Install]
WantedBy=default.target
```
Habilite o serviço para rodar no login (Não use sudo aqui):

```Bash
systemctl --user daemon-reload
systemctl --user enable sync-backup-boot.service
```
Para testar a execução manualmente sem reiniciar a máquina, use:

```Bash
systemctl --user start sync-backup-boot.service
```
4. Integração com o n8n e Relatório no Telegram
O script envia um payload estruturado em JSON para o Webhook do n8n. O fluxo do n8n recebe a requisição HTTP POST e extrai dinamicamente as informações para compor a mensagem do Telegram.

Estrutura do JSON Enviado
JSON
```{
  "status": "sucesso",
  "arquivo_criado": "27-06_00-00.sqlite3 27-06_12-00.sqlite3 ",
  "arquivo_excluido": "Nenhum (Sincronização Local)",
  "mensagem": "Backup sincronizado com sucesso via WireGuard no boot do Debian."
}
Template de Mensagem do Nó do Telegram no n8n
Plaintext
💾 *Relatório de Backup - Vaultwarden* 💾

☁️ *IP do Servidor Oracle:* `{{ $json.headers['cf-connecting-ip'] }}`
🛡️ *IP da Cloudflare:* `{{ $json.headers['x-real-ip'] }}`

🔹 *Status:* {{ $json.body.status == "sucesso" ? "✅ Sucesso" : "❌ Erro" }}
📅 *Arquivo Criado:* `{{ $json.body.arquivo_criado }}`
🗑️ *Arquivo Excluído:* `{{ $json.body.arquivo_excluido }}`

📝 _Note:_ {{ $json.body.mensagem }}
```
📄 Licença
Este projeto é de uso pessoal e educacional. Sinta-se livre para clonar e adaptar para as suas necessidades de infraestrutura e homelab.
