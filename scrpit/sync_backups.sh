#!/bin/bash

# --- CONFIGURAÇÕES ---
KEY_PATH="/home/seu-user/scripts/ssh-key-xxxxx.key"
REMOTE_USER="seu-user"
REMOTE_IP="seu-ip"
REMOTE_DIR="/home/ubuntu/backups"
LOCAL_DEST="/home/seu-user/backups_locais"
N8N_WEBHOOK_URL="http://SEU-IP/webhook/backup-vaultwarden"

# Garante que a pasta local existe
mkdir -p "$LOCAL_DEST"

echo "=== Iniciando Verificação de Boot ==="

# 1. Aguarda até 120 segundos para a VPN WireGuard conectar e responder ao ping interno
MAX_TENTATIVAS=24
CONTADOR=0
VPN_ONLINE=false

echo "Aguardando túnel Wireguard responder em $REMOTE_IP..."
while [ $CONTADOR -lt $MAX_TENTATIVAS ]; do
    if ping -c 1 -W 2 $REMOTE_IP > /dev/null 2>&1; then
        echo "Conexão com a rede interna da Oracle estabelecida com sucesso!"
        VPN_ONLINE=true
        break
    fi
    echo "Aguardando VPN conectar... (Tentativa $((CONTADOR+1))/$MAX_TENTATIVAS)"
    sleep 5
    ((CONTADOR++))
done

# Se a VPN não conectar após o tempo limite, avisa o erro (se houver internet geral) e encerra
if [ "$VPN_ONLINE" = false ]; then
    echo "Erro: Tempo limite esgotado. A VPN não ficou online."
    exit 1
fi

# 2. Executa o download seguro via IP Interno da VPN
echo "Iniciando cópia segura dos arquivos da Oracle..."

# Usamos o scp apontando explicitamente para a chave privada
DOWNLOAD_LOG=$(scp -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER"@"$REMOTE_IP":"$REMOTE_DIR"/*.tar.gz "$LOCAL_DEST/" 2>&1)

ARQUIVOS_EXCLUIDOS="Nenhum"

if [ $? -eq 0 ]; then
    STATUS="sucesso"
    # Captura a lista de arquivos baixados na pasta local para enviar no relatório
    ARQUIVOS_BAIXADOS=$(ls -A "$LOCAL_DEST" | grep ".tar.gz" | tr '\n' ' ')
    MENSAGEM="Backup sincronizado com sucesso via túnel WireGuard (10.13.13.1) no início do sistema."
    HOSTNAME=$(hostname)

    # --- NOVA LOGICA: MANTER APENAS OS 10 MAIS RECENTES ---
    echo "Verificando limite de 10 arquivos em $LOCAL_DEST..."
    cd "$LOCAL_DEST" || exit
    
    # Conta quantos arquivos .tar.gz existem
    TOTAL_ARQUIVOS=$(ls -1 *.tar.gz 2>/dev/null | wc -l)
    
    if [ "$TOTAL_ARQUIVOS" -gt 10 ]; then
        echo "Total de arquivos ($TOTAL_ARQUIVOS) excede o limite de 10. Removendo os mais antigos..."
        
        # Lista os arquivos ordenados por data (mais novos primeiro)
        # O tail -n +11 pega tudo do 11º arquivo em diante para apagar
        ARQUIVOS_PARA_DELETAR=$(ls -t *.tar.gz | tail -n +11)
        
        # Salva o nome dos arquivos que serão excluídos para enviar pro n8n
        ARQUIVOS_EXCLUIDOS=$(echo "$ARQUIVOS_PARA_DELETAR" | tr '\n' ' ')
        
        # Apaga os arquivos antigos
        echo "$ARQUIVOS_PARA_DELETAR" | xargs rm -f
        echo "Arquivos removidos: $ARQUIVOS_EXCLUIDOS"
    fi

else
    STATUS="erro"
    ARQUIVOS_BAIXADOS="Nenhum"
    MENSAGEM="Falha ao transferir arquivos via SCP interno. Erro: $DOWNLOAD_LOG"
fi

# 3. Envia o relatório estruturado para o seu n8n
echo "Enviando dados para o n8n..."

# Criando o JSON de forma limpa, isolada e incluindo a origem automática
JSON_DATA=$(cat <<EOF
{
  "status": "$STATUS",
  "arquivo_criado": "${ARQUIVOS_BAIXADOS//[$'\t\r\n']}",
  "arquivo_excluido": "${ARQUIVOS_EXCLUIDOS//[$'\t\r\n']}",
  "mensagem": "$MENSAGEM",
  "origem": "$HOSTNAME"
}
EOF
)

curl -X POST "$N8N_WEBHOOK_URL" \
     -H "Content-Type: application/json" \
     -d "$JSON_DATA"

echo "=== Processo Finalizado ==="
