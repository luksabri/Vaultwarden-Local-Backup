# Vaultwarden-Local-Backup
⚠️ **Nota de Segurança Importante:** Este guia assume e recomenda estritamente o uso da VPN WireGuard para todo o tráfego de dados. Caso você opte por utilizar um IP público para acessar sua instância da Oracle, desconsidere os passos de configuração do `nmcli` (Seção 1). No entanto, expor publicamente portas de SSH ou instâncias de banco de dados é **altamente desencorajada**.

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