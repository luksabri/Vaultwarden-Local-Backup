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
1.Criar o script de gatilho:Requer sudo.Crie um arquivo dentro do diretório do dispatcher do NetworkManager usando seu editor favorito (como o nano):
```Bash
sudo nano /etc/NetworkManager/dispatcher.d/99-wireguard-oracle.sh
```
2.Inserir a lógica de reconexão:Cole o código abaixo.Cole o seguinte código dentro do arquivo. Ele detecta quando qualquer interface de rede (como o Wi-Fi) fica "up" (ativa) e força o reinício da conexão "oracle":

```Bash
#!/bin/bash

INTERFACE=$1
ACTION=$2

# Quando qualquer interface de rede subir
if [ "$ACTION" = "up" ]; then
    # Ignora se for a própria interface da VPN para evitar loop infinito
    if [ "$INTERFACE" != "oracle" ]; then
        # Aguarda 2 segundos para o IP local estabilizar
        sleep 2
        # Derruba e sobe a conexão para renovar os endpoints e rotas
        nmcli connection down "oracle" >/dev/null 2>&1
        nmcli connection up "oracle" >/dev/null 2>&1
    fi
fi
```
Salve o arquivo (no nano: Ctrl+O, Enter e depois Ctrl+X para sair).3.Dar permissão de execução:Passo obrigatório.O NetworkManager só executa scripts nesse diretório se eles forem estritamente propriedade do root e tiverem permissão de execução:
```Bash
sudo chmod +x /etc/NetworkManager/dispatcher.d/99-wireguard-oracle.sh
sudo chown root:root /etc/NetworkManager/dispatcher.d/99-wireguard-oracle.sh
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
    # Opcional: Enviar webhook de erro para o n8n usando a rede pública se o n8n tiver IP público
    exit 1
fi

# 2. Executa o download seguro via IP Interno da VPN
echo "Iniciando cópia segura dos arquivos da Oracle..."

# Usamos o scp apontando explicitamente para a chave privada
DOWNLOAD_LOG=$(scp -i "$KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER"@"$REMOTE_IP":"$REMOTE_DIR"/*.tar.gz "$LOCAL_DEST/" 2>&1)

if [ $? -eq 0 ]; then
    STATUS="sucesso"
    # Captura a lista de arquivos baixados na pasta local para enviar no relatório
    ARQUIVOS_BAIXADOS=$(ls -A "$LOCAL_DEST" | grep ".tar.gz" | tr '\n' ' ')
    MENSAGEM="Backup sincronizado com sucesso via túnel WireGuard (10.13.13.1) no início do sistema."
    HOSTNAME=$(hostname)

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
  "arquivo_excluido": "Nenhum (Sincronização Local)",
  "mensagem": "$MENSAGEM",
  "origem": "$HOSTNAME"
}
EOF
)

curl -X POST "$N8N_WEBHOOK_URL" \
     -H "Content-Type: application/json" \
     -d "$JSON_DATA"

echo "=== Processo Finalizado ==="```
---
Defina as permissões corretas de segurança para a sua chave e para o script:
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
ExecStart=/home/seu-user/scripts/sync_backups.sh
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
