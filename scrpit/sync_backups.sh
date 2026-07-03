#!/bin/bash

# --- CONFIGURAÇÕES ---
KEY_PATH="/home/seu-user/scripts/ssh-key-xxxxx.key"
REMOTE_USER=""
REMOTE_IP=""
REMOTE_DIR="/home/ubuntu/backups"
LOCAL_DEST="/home/seu-user/backups_locais"
N8N_WEBHOOK_URL="http://SEU-IP/webhook/backup-vaultwarden"

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
