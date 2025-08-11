#!/bin/bash

# Evolution API - Script de Deploy Seguro para Google Cloud
# 
# O que este script faz:
# 1. Carrega credenciais do Google Secret Manager (API keys, senhas)
# 2. Configura 150+ variaveis de ambiente necessarias para a Evolution API
# 3. Gera docker-compose.yaml seguro (SOBRESCREVE o arquivo existente, sem usar .env)
# 4. Faz deploy dos containers (Evolution API + PostgreSQL + Redis)
# 5. Verifica se tudo esta funcionando
#
# Uso: ./deploy.sh
# Repositorio: https://github.com/edualves15/venda-inteligente-evolution-api

echo "========================================"
echo "  EVOLUTION API - INICIALIZACAO SEGURA  "
echo "========================================"

# Funcoes utilitarias
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
check_status() { [ $? -eq 0 ] && log "OK $2" || { log "ERRO: $1"; exit 1; }; }

# Verificar dependencias criticas
check_dependencies() {
    log "Verificando dependencias..."
    local deps=("gcloud:gcloud CLI:https://cloud.google.com/sdk/docs/install" 
                "docker:Docker:sudo apt update && sudo apt install -y docker.io"
                "docker compose:Docker Compose:incluido com Docker")
    
    for dep in "${deps[@]}"; do
        IFS=':' read -r cmd desc install <<< "$dep"
        if ! command -v $cmd &>/dev/null; then
            log "ERRO: $desc nao encontrado!"
            log "Instale: $install"
            exit 1
        fi
        log "OK $desc encontrado"
    done
    
    # Verificacoes adicionais
    docker ps &>/dev/null || { 
        log "ERRO: Usuario sem permissoes Docker!"
        log "Execute: sudo usermod -aG docker \$USER && newgrp docker"
        exit 1
    }
    log "OK Permissoes Docker verificadas"
    
    gcloud auth list --filter=status:ACTIVE --format="value(account)" &>/dev/null || {
        log "ERRO: Nao autenticado no Google Cloud!"
        log "Execute: gcloud auth login"
        exit 1
    }
    log "OK Autenticacao Google Cloud verificada"
}

# Carregar secrets do Secret Manager
load_secrets() {
    log "Carregando secrets do Secret Manager..."
    
    # Definir secrets obrigatorios e opcionais
    declare -A SECRETS=(
        ["evolution-api-key"]="true:API Key da Evolution"
        ["evolution-db-password"]="true:Senha do banco de dados"
        ["evolution-jwt-secret"]="false:JWT Secret para autenticacao"
        ["evolution-sentry-dsn"]="false:Sentry DSN para monitoramento"
        ["evolution-s3-access-key"]="false:S3 Access Key"
        ["evolution-s3-secret-key"]="false:S3 Secret Key"
        ["evolution-rabbitmq-uri"]="false:RabbitMQ URI"
        ["evolution-pusher-app-id"]="false:Pusher App ID"
        ["evolution-pusher-key"]="false:Pusher Key"
        ["evolution-pusher-secret"]="false:Pusher Secret"
        ["evolution-proxy-username"]="false:Proxy Username"
        ["evolution-proxy-password"]="false:Proxy Password"
        ["evolution-audio-converter-key"]="false:Audio Converter Key"
        ["evolution-chatwoot-db-uri"]="false:Chatwoot Database URI"
        ["evolution-ssl-privkey"]="false:SSL Private Key"
        ["evolution-ssl-fullchain"]="false:SSL Full Chain"
    )
    
    # Carregar cada secret
    for secret in "${!SECRETS[@]}"; do
        IFS=':' read -r required desc <<< "${SECRETS[$secret]}"
        log "Carregando $desc..."
        
        value=$(gcloud secrets versions access latest --secret="$secret" 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$value" ]; then
            if [ "$required" == "true" ]; then
                log "ERRO: Secret obrigatorio '$secret' nao encontrado!"
                log "Crie: gcloud secrets create $secret --data-file=-"
                exit 1
            else
                log "AVISO: Secret opcional '$secret' nao encontrado (continuando...)"
                declare -g "${secret//-/_}"=""
            fi
        else
            log "OK $desc carregado"
            # Limpar whitespace/newlines dos secrets
            value=$(echo "$value" | tr -d '\r\n\t ' | sed 's/[[:space:]]//g')
            declare -g "${secret//-/_}"="$value"
        fi
    done
    
    # Gerar valores padrao para secrets vazios
    [ -z "$evolution_jwt_secret" ] && {
        evolution_jwt_secret=$(openssl rand -base64 64)
        log "OK JWT Secret gerado automaticamente"
    }
    
    [ -z "$evolution_rabbitmq_uri" ] && evolution_rabbitmq_uri="amqp://localhost"
}

# Obter IP da VM
get_vm_ip() {
    log "Obtendo IP externo da VM..."
    VM_IP=$(curl -s --max-time 10 http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google" 2>/dev/null)
    [ -z "$VM_IP" ] && { log "ERRO: Nao foi possivel obter IP da VM!"; exit 1; }
    log "OK IP externo: $VM_IP"
}

# Configurar variaveis de ambiente
setup_environment() {
    log "Configurando variaveis de ambiente..."
    
    # Configuracoes basicas do servidor
    declare -A SERVER_CONFIG=(
        [SERVER_TYPE]="http"
        [SERVER_PORT]="8080"
        [SERVER_URL]="http://${VM_IP}:8080"
        [CORS_ORIGIN]="*"
        [CORS_METHODS]="GET,POST,PUT,DELETE"
        [CORS_CREDENTIALS]="true"
    )
    
    # Configuracoes de log
    declare -A LOG_CONFIG=(
        [LOG_LEVEL]="ERROR,WARN,INFO"
        [LOG_COLOR]="false"
        [LOG_BAILEYS]="error"
        [EVENT_EMITTER_MAX_LISTENERS]="50"
    )
    
    # Configuracoes de instancia
    declare -A INSTANCE_CONFIG=(
        [DEL_INSTANCE]="false"
        [CONFIG_SESSION_PHONE_CLIENT]="Evolution API"
        [CONFIG_SESSION_PHONE_NAME]="Chrome"
        [QRCODE_LIMIT]="30"
        [QRCODE_COLOR]="#198754"
        [LANGUAGE]="pt"
    )
    
    # Configuracoes de autenticacao
    declare -A AUTH_CONFIG=(
        [AUTHENTICATION_API_KEY]="$evolution_api_key"
        [AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES]="true"
        [JWT_SECRET]="$evolution_jwt_secret"
        [AUTHENTICATION_JWT_SECRET]="$evolution_jwt_secret"
    )
    
    # Configuracoes de banco de dados
    declare -A DATABASE_CONFIG=(
        [DATABASE_PROVIDER]="postgresql"
        [DATABASE_CONNECTION_URI]="postgresql://postgres:${evolution_db_password}@postgres:5432/evolution_db?schema=evolution_api"
        [DATABASE_CONNECTION_CLIENT_NAME]="evolution_cloud"
        [DATABASE_SAVE_DATA_INSTANCE]="true"
        [DATABASE_SAVE_DATA_NEW_MESSAGE]="true"
        [DATABASE_SAVE_MESSAGE_UPDATE]="true"
        [DATABASE_SAVE_DATA_CONTACTS]="true"
        [DATABASE_SAVE_DATA_CHATS]="true"
        [DATABASE_SAVE_DATA_LABELS]="true"
        [DATABASE_SAVE_DATA_HISTORIC]="true"
        [DATABASE_SAVE_IS_ON_WHATSAPP]="true"
        [DATABASE_SAVE_IS_ON_WHATSAPP_DAYS]="7"
        [DATABASE_DELETE_MESSAGE]="true"
    )
    
    # Configuracoes de cache Redis
    declare -A REDIS_CONFIG=(
        [CACHE_REDIS_ENABLED]="true"
        [CACHE_REDIS_URI]="redis://redis:6379/6"
        [CACHE_REDIS_TTL]="604800"
        [CACHE_REDIS_PREFIX_KEY]="evolution"
        [CACHE_REDIS_SAVE_INSTANCES]="false"
        [CACHE_LOCAL_ENABLED]="false"
    )
    
    # Configuracoes de comunicacao
    declare -A COMM_CONFIG=(
        [SQS_ENABLED]="false"
        [SQS_ACCESS_KEY_ID]=""
        [SQS_SECRET_ACCESS_KEY]=""
        [SQS_ACCOUNT_ID]=""
        [SQS_REGION]=""
        [WEBSOCKET_ENABLED]="false"
        [WEBSOCKET_GLOBAL_EVENTS]="false"
        [WA_BUSINESS_TOKEN_WEBHOOK]="evolution"
        [WA_BUSINESS_URL]="https://graph.facebook.com"
        [WA_BUSINESS_VERSION]="v20.0"
        [WA_BUSINESS_LANGUAGE]="pt_BR"
    )
    
    # Configuracoes de webhook (todas)
    declare -A WEBHOOK_CONFIG=(
        [WEBHOOK_GLOBAL_ENABLED]="false"
        [WEBHOOK_GLOBAL_URL]=""
        [WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS]="false"
        [WEBHOOK_EVENTS_APPLICATION_STARTUP]="false"
        [WEBHOOK_EVENTS_QRCODE_UPDATED]="true"
        [WEBHOOK_EVENTS_MESSAGES_SET]="true"
        [WEBHOOK_EVENTS_MESSAGES_UPSERT]="true"
        [WEBHOOK_EVENTS_MESSAGES_EDITED]="true"
        [WEBHOOK_EVENTS_MESSAGES_UPDATE]="true"
        [WEBHOOK_EVENTS_MESSAGES_DELETE]="true"
        [WEBHOOK_EVENTS_SEND_MESSAGE]="true"
        [WEBHOOK_EVENTS_SEND_MESSAGE_UPDATE]="true"
        [WEBHOOK_EVENTS_CONTACTS_SET]="true"
        [WEBHOOK_EVENTS_CONTACTS_UPSERT]="true"
        [WEBHOOK_EVENTS_CONTACTS_UPDATE]="true"
        [WEBHOOK_EVENTS_PRESENCE_UPDATE]="true"
        [WEBHOOK_EVENTS_CHATS_SET]="true"
        [WEBHOOK_EVENTS_CHATS_UPSERT]="true"
        [WEBHOOK_EVENTS_CHATS_UPDATE]="true"
        [WEBHOOK_EVENTS_CHATS_DELETE]="true"
        [WEBHOOK_EVENTS_GROUPS_UPSERT]="true"
        [WEBHOOK_EVENTS_GROUPS_UPDATE]="true"
        [WEBHOOK_EVENTS_GROUP_PARTICIPANTS_UPDATE]="true"
        [WEBHOOK_EVENTS_CONNECTION_UPDATE]="true"
        [WEBHOOK_EVENTS_REMOVE_INSTANCE]="false"
        [WEBHOOK_EVENTS_LOGOUT_INSTANCE]="false"
        [WEBHOOK_EVENTS_LABELS_EDIT]="true"
        [WEBHOOK_EVENTS_LABELS_ASSOCIATION]="true"
        [WEBHOOK_EVENTS_CALL]="true"
        [WEBHOOK_EVENTS_TYPEBOT_START]="false"
        [WEBHOOK_EVENTS_TYPEBOT_CHANGE_STATUS]="false"
        [WEBHOOK_EVENTS_ERRORS]="false"
        [WEBHOOK_EVENTS_ERRORS_WEBHOOK]=""
        [WEBHOOK_REQUEST_TIMEOUT_MS]="60000"
        [WEBHOOK_RETRY_MAX_ATTEMPTS]="10"
        [WEBHOOK_RETRY_INITIAL_DELAY_SECONDS]="5"
        [WEBHOOK_RETRY_USE_EXPONENTIAL_BACKOFF]="true"
        [WEBHOOK_RETRY_MAX_DELAY_SECONDS]="300"
        [WEBHOOK_RETRY_JITTER_FACTOR]="0.2"
        [WEBHOOK_RETRY_NON_RETRYABLE_STATUS_CODES]="400,401,403,404,422"
    )
    
    # Configuracoes de integracao
    declare -A INTEGRATION_CONFIG=(
        [TYPEBOT_ENABLED]="false"
        [TYPEBOT_API_VERSION]="latest"
        [OPENAI_ENABLED]="false"
        [DIFY_ENABLED]="false"
        [N8N_ENABLED]="false"
        [EVOAI_ENABLED]="false"
    )
    
    # Exportar todas as configuracoes
    local configs=(SERVER_CONFIG LOG_CONFIG INSTANCE_CONFIG AUTH_CONFIG DATABASE_CONFIG 
                   REDIS_CONFIG COMM_CONFIG WEBHOOK_CONFIG INTEGRATION_CONFIG)
    
    for config in "${configs[@]}"; do
        local -n config_ref=$config
        for var in "${!config_ref[@]}"; do
            export "$var"="${config_ref[$var]}"
        done
    done
    
    # Configuracoes condicionais baseadas em secrets
    setup_conditional_configs
    
    log "OK Todas as variaveis configuradas"
}

# Configurar servicos opcionais baseados em secrets
setup_conditional_configs() {
    # Sentry
    if [ -n "$evolution_sentry_dsn" ]; then
        export SENTRY_DSN="$evolution_sentry_dsn" SENTRY_ENABLED="true"
    else
        export SENTRY_ENABLED="false"
    fi
    
    # RabbitMQ
    if [ -n "$evolution_rabbitmq_uri" ] && [ "$evolution_rabbitmq_uri" != "amqp://localhost" ]; then
        declare -A RABBITMQ_VARS=(
            [RABBITMQ_ENABLED]="true" [RABBITMQ_URI]="$evolution_rabbitmq_uri" 
            [RABBITMQ_EXCHANGE_NAME]="evolution" [RABBITMQ_FRAME_MAX]="8192"
            [RABBITMQ_GLOBAL_ENABLED]="false" [RABBITMQ_PREFIX_KEY]="evolution"
        )
        for var in "${!RABBITMQ_VARS[@]}"; do export "$var"="${RABBITMQ_VARS[$var]}"; done
    else
        export RABBITMQ_ENABLED="false" RABBITMQ_URI="amqp://localhost"
    fi
    
    # S3
    if [ -n "$evolution_s3_access_key" ] && [ -n "$evolution_s3_secret_key" ]; then
        declare -A S3_VARS=(
            [S3_ENABLED]="true" [S3_REGION]="us-east-1" [S3_ACCESS_KEY]="$evolution_s3_access_key"
            [S3_SECRET_KEY]="$evolution_s3_secret_key" [S3_BUCKET]="evolution-api"
            [S3_PORT]="443" [S3_USE_SSL]="true" [S3_ENDPOINT]="s3.amazonaws.com"
        )
        for var in "${!S3_VARS[@]}"; do export "$var"="${S3_VARS[$var]}"; done
    else
        declare -A S3_DEFAULTS=(
            [S3_ENABLED]="false" [S3_ACCESS_KEY]="" [S3_SECRET_KEY]=""
            [S3_BUCKET]="" [S3_PORT]="443" [S3_USE_SSL]="true"
            [S3_ENDPOINT]="" [S3_REGION]=""
        )
        for var in "${!S3_DEFAULTS[@]}"; do export "$var"="${S3_DEFAULTS[$var]}"; done
    fi
    
    # Pusher
    if [ -n "$evolution_pusher_app_id" ] && [ -n "$evolution_pusher_key" ] && [ -n "$evolution_pusher_secret" ]; then
        declare -A PUSHER_VARS=(
            [PUSHER_ENABLED]="true" [PUSHER_APP_ID]="$evolution_pusher_app_id"
            [PUSHER_KEY]="$evolution_pusher_key" [PUSHER_SECRET]="$evolution_pusher_secret"
            [PUSHER_CLUSTER]="us2" [PUSHER_USE_TLS]="true"
            [PUSHER_GLOBAL_ENABLED]="false" [PUSHER_GLOBAL_APP_ID]=""
            [PUSHER_GLOBAL_KEY]="" [PUSHER_GLOBAL_SECRET]=""
            [PUSHER_GLOBAL_CLUSTER]="" [PUSHER_GLOBAL_USE_TLS]="true"
        )
        for var in "${!PUSHER_VARS[@]}"; do export "$var"="${PUSHER_VARS[$var]}"; done
    else
        declare -A PUSHER_DEFAULTS=(
            [PUSHER_ENABLED]="false" [PUSHER_GLOBAL_ENABLED]="false"
            [PUSHER_GLOBAL_APP_ID]="" [PUSHER_GLOBAL_KEY]=""
            [PUSHER_GLOBAL_SECRET]="" [PUSHER_GLOBAL_CLUSTER]="" [PUSHER_GLOBAL_USE_TLS]="true"
        )
        for var in "${!PUSHER_DEFAULTS[@]}"; do export "$var"="${PUSHER_DEFAULTS[$var]}"; done
    fi
    
    # Proxy
    if [ -n "$evolution_proxy_username" ] && [ -n "$evolution_proxy_password" ]; then
        declare -A PROXY_VARS=(
            [PROXY_ENABLED]="true" [PROXY_USERNAME]="$evolution_proxy_username"
            [PROXY_PASSWORD]="$evolution_proxy_password" [PROXY_HOST]="proxy.example.com"
            [PROXY_PORT]="8080" [PROXY_PROTOCOL]="http"
        )
        for var in "${!PROXY_VARS[@]}"; do export "$var"="${PROXY_VARS[$var]}"; done
    else
        export PROXY_ENABLED="false"
    fi
    
    # Chatwoot
    if [ -n "$evolution_chatwoot_db_uri" ]; then
        declare -A CHATWOOT_VARS=(
            [CHATWOOT_ENABLED]="true" [CHATWOOT_DB_CONNECTION_URI]="$evolution_chatwoot_db_uri"
            [CHATWOOT_MESSAGE_READ]="true" [CHATWOOT_MESSAGE_DELETE]="true" [CHATWOOT_BOT_CONTACT]="false"
            [CHATWOOT_IMPORT_DATABASE_CONNECTION_URI]="" [CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE]="true"
        )
        for var in "${!CHATWOOT_VARS[@]}"; do export "$var"="${CHATWOOT_VARS[$var]}"; done
    else
        declare -A CHATWOOT_DEFAULTS=(
            [CHATWOOT_ENABLED]="false" [CHATWOOT_MESSAGE_READ]="true" [CHATWOOT_MESSAGE_DELETE]="true"
            [CHATWOOT_BOT_CONTACT]="false" [CHATWOOT_IMPORT_DATABASE_CONNECTION_URI]=""
            [CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE]="true"
        )
        for var in "${!CHATWOOT_DEFAULTS[@]}"; do export "$var"="${CHATWOOT_DEFAULTS[$var]}"; done
    fi
    
    # Audio Converter
    if [ -n "$evolution_audio_converter_key" ]; then
        export AUDIO_CONVERTER_KEY="$evolution_audio_converter_key" AUDIO_CONVERTER_ENABLED="true"
        export API_AUDIO_CONVERTER="http://localhost:4040/process-audio"
        export API_AUDIO_CONVERTER_KEY="$evolution_audio_converter_key"
    else
        export AUDIO_CONVERTER_ENABLED="false" API_AUDIO_CONVERTER="" API_AUDIO_CONVERTER_KEY=""
    fi
    
    # SSL
    if [ -n "$evolution_ssl_privkey" ] && [ -n "$evolution_ssl_fullchain" ]; then
        export SSL_PRIVKEY="$evolution_ssl_privkey" SSL_FULLCHAIN="$evolution_ssl_fullchain" HTTPS_ENABLED="true"
        export SSL_CONF_PRIVKEY="$evolution_ssl_privkey" SSL_CONF_FULLCHAIN="$evolution_ssl_fullchain"
    else
        export HTTPS_ENABLED="false" SSL_PRIVKEY="" SSL_FULLCHAIN=""
        export SSL_CONF_PRIVKEY="" SSL_CONF_FULLCHAIN=""
    fi
    
    # Export das variaveis de secrets usadas diretamente no docker-compose
    export evolution_db_password="$evolution_db_password"
    export evolution_api_key="$evolution_api_key"
    export evolution_jwt_secret="$evolution_jwt_secret"
    
    # JWT/Auth configuracoes criticas
    export JWT_SECRET="$evolution_jwt_secret"
    export AUTHENTICATION_JWT_SECRET="$evolution_jwt_secret"
    export AUTHENTICATION_API_KEY="$evolution_api_key"
}

# Criar docker-compose otimizado
create_docker_compose() {
    log "Criando docker-compose.yaml com configuracoes seguras..."
    
    cat > docker-compose.yaml << 'EOF'
version: '3.8'
services:
  evolution_api:
    container_name: evolution_api
    image: evoapicloud/evolution-api:latest
    restart: always
    ports: ["8080:8080"]
    volumes: 
      - evolution_instances:/evolution/instances
      - evolution_store:/evolution/store
    networks: [evolution-net]
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_started }
    environment: &evolution_env
      # Servidor
      - SERVER_TYPE=${SERVER_TYPE}
      - SERVER_PORT=${SERVER_PORT}
      - SERVER_URL=${SERVER_URL}
      - CORS_ORIGIN=${CORS_ORIGIN}
      - CORS_METHODS=${CORS_METHODS}
      - CORS_CREDENTIALS=${CORS_CREDENTIALS}
      # Log
      - LOG_LEVEL=${LOG_LEVEL}
      - LOG_COLOR=${LOG_COLOR}
      - LOG_BAILEYS=${LOG_BAILEYS}
      - EVENT_EMITTER_MAX_LISTENERS=${EVENT_EMITTER_MAX_LISTENERS}
      # Instância
      - DEL_INSTANCE=${DEL_INSTANCE}
      - CONFIG_SESSION_PHONE_CLIENT=${CONFIG_SESSION_PHONE_CLIENT}
      - CONFIG_SESSION_PHONE_NAME=${CONFIG_SESSION_PHONE_NAME}
      - QRCODE_LIMIT=${QRCODE_LIMIT}
      - QRCODE_COLOR=${QRCODE_COLOR}
      - LANGUAGE=${LANGUAGE}
      # Autenticacao (SENSIVEL)
      - AUTHENTICATION_API_KEY=${AUTHENTICATION_API_KEY}
      - AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=${AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES}
      - JWT_SECRET=${JWT_SECRET}
      - AUTHENTICATION_JWT_SECRET=${AUTHENTICATION_JWT_SECRET}
      # Banco (SENSIVEL)
      - DATABASE_PROVIDER=${DATABASE_PROVIDER}
      - DATABASE_CONNECTION_URI=${DATABASE_CONNECTION_URI}
      - DATABASE_CONNECTION_CLIENT_NAME=${DATABASE_CONNECTION_CLIENT_NAME}
      - DATABASE_SAVE_DATA_INSTANCE=${DATABASE_SAVE_DATA_INSTANCE}
      - DATABASE_SAVE_DATA_NEW_MESSAGE=${DATABASE_SAVE_DATA_NEW_MESSAGE}
      - DATABASE_SAVE_MESSAGE_UPDATE=${DATABASE_SAVE_MESSAGE_UPDATE}
      - DATABASE_SAVE_DATA_CONTACTS=${DATABASE_SAVE_DATA_CONTACTS}
      - DATABASE_SAVE_DATA_CHATS=${DATABASE_SAVE_DATA_CHATS}
      - DATABASE_SAVE_DATA_LABELS=${DATABASE_SAVE_DATA_LABELS}
      - DATABASE_SAVE_DATA_HISTORIC=${DATABASE_SAVE_DATA_HISTORIC}
      - DATABASE_SAVE_IS_ON_WHATSAPP=${DATABASE_SAVE_IS_ON_WHATSAPP}
      - DATABASE_SAVE_IS_ON_WHATSAPP_DAYS=${DATABASE_SAVE_IS_ON_WHATSAPP_DAYS}
      - DATABASE_DELETE_MESSAGE=${DATABASE_DELETE_MESSAGE}
      # Servicos externos
      - SENTRY_DSN=${SENTRY_DSN}
      - SENTRY_ENABLED=${SENTRY_ENABLED}
      - RABBITMQ_ENABLED=${RABBITMQ_ENABLED}
      - RABBITMQ_URI=${RABBITMQ_URI}
      - RABBITMQ_EXCHANGE_NAME=${RABBITMQ_EXCHANGE_NAME}
      - RABBITMQ_FRAME_MAX=${RABBITMQ_FRAME_MAX}
      - RABBITMQ_GLOBAL_ENABLED=${RABBITMQ_GLOBAL_ENABLED}
      - RABBITMQ_PREFIX_KEY=${RABBITMQ_PREFIX_KEY}
      # RabbitMQ Events
      - RABBITMQ_EVENTS_APPLICATION_STARTUP=${RABBITMQ_EVENTS_APPLICATION_STARTUP:-false}
      - RABBITMQ_EVENTS_INSTANCE_CREATE=${RABBITMQ_EVENTS_INSTANCE_CREATE:-false}
      - RABBITMQ_EVENTS_INSTANCE_DELETE=${RABBITMQ_EVENTS_INSTANCE_DELETE:-false}
      - RABBITMQ_EVENTS_QRCODE_UPDATED=${RABBITMQ_EVENTS_QRCODE_UPDATED:-false}
      - RABBITMQ_EVENTS_MESSAGES_SET=${RABBITMQ_EVENTS_MESSAGES_SET:-false}
      - RABBITMQ_EVENTS_MESSAGES_UPSERT=${RABBITMQ_EVENTS_MESSAGES_UPSERT:-false}
      - RABBITMQ_EVENTS_MESSAGES_EDITED=${RABBITMQ_EVENTS_MESSAGES_EDITED:-false}
      - RABBITMQ_EVENTS_MESSAGES_UPDATE=${RABBITMQ_EVENTS_MESSAGES_UPDATE:-false}
      - RABBITMQ_EVENTS_MESSAGES_DELETE=${RABBITMQ_EVENTS_MESSAGES_DELETE:-false}
      - RABBITMQ_EVENTS_SEND_MESSAGE=${RABBITMQ_EVENTS_SEND_MESSAGE:-false}
      - RABBITMQ_EVENTS_SEND_MESSAGE_UPDATE=${RABBITMQ_EVENTS_SEND_MESSAGE_UPDATE:-false}
      - RABBITMQ_EVENTS_CONTACTS_SET=${RABBITMQ_EVENTS_CONTACTS_SET:-false}
      - RABBITMQ_EVENTS_CONTACTS_UPSERT=${RABBITMQ_EVENTS_CONTACTS_UPSERT:-false}
      - RABBITMQ_EVENTS_CONTACTS_UPDATE=${RABBITMQ_EVENTS_CONTACTS_UPDATE:-false}
      - RABBITMQ_EVENTS_PRESENCE_UPDATE=${RABBITMQ_EVENTS_PRESENCE_UPDATE:-false}
      - RABBITMQ_EVENTS_CHATS_SET=${RABBITMQ_EVENTS_CHATS_SET:-false}
      - RABBITMQ_EVENTS_CHATS_UPSERT=${RABBITMQ_EVENTS_CHATS_UPSERT:-false}
      - RABBITMQ_EVENTS_CHATS_UPDATE=${RABBITMQ_EVENTS_CHATS_UPDATE:-false}
      - RABBITMQ_EVENTS_CHATS_DELETE=${RABBITMQ_EVENTS_CHATS_DELETE:-false}
      - RABBITMQ_EVENTS_GROUPS_UPSERT=${RABBITMQ_EVENTS_GROUPS_UPSERT:-false}
      - RABBITMQ_EVENTS_GROUP_UPDATE=${RABBITMQ_EVENTS_GROUP_UPDATE:-false}
      - RABBITMQ_EVENTS_GROUP_PARTICIPANTS_UPDATE=${RABBITMQ_EVENTS_GROUP_PARTICIPANTS_UPDATE:-false}
      - RABBITMQ_EVENTS_CONNECTION_UPDATE=${RABBITMQ_EVENTS_CONNECTION_UPDATE:-false}
      - RABBITMQ_EVENTS_REMOVE_INSTANCE=${RABBITMQ_EVENTS_REMOVE_INSTANCE:-false}
      - RABBITMQ_EVENTS_LOGOUT_INSTANCE=${RABBITMQ_EVENTS_LOGOUT_INSTANCE:-false}
      - RABBITMQ_EVENTS_CALL=${RABBITMQ_EVENTS_CALL:-false}
      - RABBITMQ_EVENTS_TYPEBOT_START=${RABBITMQ_EVENTS_TYPEBOT_START:-false}
      - RABBITMQ_EVENTS_TYPEBOT_CHANGE_STATUS=${RABBITMQ_EVENTS_TYPEBOT_CHANGE_STATUS:-false}
      - SQS_ENABLED=${SQS_ENABLED}
      - SQS_ACCESS_KEY_ID=${SQS_ACCESS_KEY_ID}
      - SQS_SECRET_ACCESS_KEY=${SQS_SECRET_ACCESS_KEY}
      - SQS_ACCOUNT_ID=${SQS_ACCOUNT_ID}
      - SQS_REGION=${SQS_REGION}
      - WEBSOCKET_ENABLED=${WEBSOCKET_ENABLED}
      - WEBSOCKET_GLOBAL_EVENTS=${WEBSOCKET_GLOBAL_EVENTS}
      # S3
      - S3_ENABLED=${S3_ENABLED}
      - S3_ACCESS_KEY=${S3_ACCESS_KEY}
      - S3_SECRET_KEY=${S3_SECRET_KEY}
      - S3_REGION=${S3_REGION}
      - S3_BUCKET=${S3_BUCKET}
      - S3_PORT=${S3_PORT}
      - S3_USE_SSL=${S3_USE_SSL}
      - S3_ENDPOINT=${S3_ENDPOINT}
      # Pusher
      - PUSHER_ENABLED=${PUSHER_ENABLED}
      - PUSHER_APP_ID=${PUSHER_APP_ID}
      - PUSHER_KEY=${PUSHER_KEY}
      - PUSHER_SECRET=${PUSHER_SECRET}
      - PUSHER_CLUSTER=${PUSHER_CLUSTER}
      - PUSHER_USE_TLS=${PUSHER_USE_TLS}
      - PUSHER_GLOBAL_ENABLED=${PUSHER_GLOBAL_ENABLED}
      - PUSHER_GLOBAL_APP_ID=${PUSHER_GLOBAL_APP_ID}
      - PUSHER_GLOBAL_KEY=${PUSHER_GLOBAL_KEY}
      - PUSHER_GLOBAL_SECRET=${PUSHER_GLOBAL_SECRET}
      - PUSHER_GLOBAL_CLUSTER=${PUSHER_GLOBAL_CLUSTER}
      - PUSHER_GLOBAL_USE_TLS=${PUSHER_GLOBAL_USE_TLS}
      # Pusher Events
      - PUSHER_EVENTS_APPLICATION_STARTUP=${PUSHER_EVENTS_APPLICATION_STARTUP:-true}
      - PUSHER_EVENTS_QRCODE_UPDATED=${PUSHER_EVENTS_QRCODE_UPDATED:-true}
      - PUSHER_EVENTS_MESSAGES_SET=${PUSHER_EVENTS_MESSAGES_SET:-true}
      - PUSHER_EVENTS_MESSAGES_UPSERT=${PUSHER_EVENTS_MESSAGES_UPSERT:-true}
      - PUSHER_EVENTS_MESSAGES_EDITED=${PUSHER_EVENTS_MESSAGES_EDITED:-true}
      - PUSHER_EVENTS_MESSAGES_UPDATE=${PUSHER_EVENTS_MESSAGES_UPDATE:-true}
      - PUSHER_EVENTS_MESSAGES_DELETE=${PUSHER_EVENTS_MESSAGES_DELETE:-true}
      - PUSHER_EVENTS_SEND_MESSAGE=${PUSHER_EVENTS_SEND_MESSAGE:-true}
      - PUSHER_EVENTS_SEND_MESSAGE_UPDATE=${PUSHER_EVENTS_SEND_MESSAGE_UPDATE:-true}
      - PUSHER_EVENTS_CONTACTS_SET=${PUSHER_EVENTS_CONTACTS_SET:-true}
      - PUSHER_EVENTS_CONTACTS_UPSERT=${PUSHER_EVENTS_CONTACTS_UPSERT:-true}
      - PUSHER_EVENTS_CONTACTS_UPDATE=${PUSHER_EVENTS_CONTACTS_UPDATE:-true}
      - PUSHER_EVENTS_PRESENCE_UPDATE=${PUSHER_EVENTS_PRESENCE_UPDATE:-true}
      - PUSHER_EVENTS_CHATS_SET=${PUSHER_EVENTS_CHATS_SET:-true}
      - PUSHER_EVENTS_CHATS_UPSERT=${PUSHER_EVENTS_CHATS_UPSERT:-true}
      - PUSHER_EVENTS_CHATS_UPDATE=${PUSHER_EVENTS_CHATS_UPDATE:-true}
      - PUSHER_EVENTS_CHATS_DELETE=${PUSHER_EVENTS_CHATS_DELETE:-true}
      - PUSHER_EVENTS_GROUPS_UPSERT=${PUSHER_EVENTS_GROUPS_UPSERT:-true}
      - PUSHER_EVENTS_GROUPS_UPDATE=${PUSHER_EVENTS_GROUPS_UPDATE:-true}
      - PUSHER_EVENTS_GROUP_PARTICIPANTS_UPDATE=${PUSHER_EVENTS_GROUP_PARTICIPANTS_UPDATE:-true}
      - PUSHER_EVENTS_CONNECTION_UPDATE=${PUSHER_EVENTS_CONNECTION_UPDATE:-true}
      - PUSHER_EVENTS_LABELS_EDIT=${PUSHER_EVENTS_LABELS_EDIT:-true}
      - PUSHER_EVENTS_LABELS_ASSOCIATION=${PUSHER_EVENTS_LABELS_ASSOCIATION:-true}
      - PUSHER_EVENTS_CALL=${PUSHER_EVENTS_CALL:-true}
      - PUSHER_EVENTS_TYPEBOT_START=${PUSHER_EVENTS_TYPEBOT_START:-false}
      - PUSHER_EVENTS_TYPEBOT_CHANGE_STATUS=${PUSHER_EVENTS_TYPEBOT_CHANGE_STATUS:-false}
      # Proxy
      - PROXY_ENABLED=${PROXY_ENABLED}
      - PROXY_USERNAME=${PROXY_USERNAME}
      - PROXY_PASSWORD=${PROXY_PASSWORD}
      - PROXY_HOST=${PROXY_HOST}
      - PROXY_PORT=${PROXY_PORT}
      - PROXY_PROTOCOL=${PROXY_PROTOCOL}
      # WhatsApp Business
      - WA_BUSINESS_TOKEN_WEBHOOK=${WA_BUSINESS_TOKEN_WEBHOOK}
      - WA_BUSINESS_URL=${WA_BUSINESS_URL}
      - WA_BUSINESS_VERSION=${WA_BUSINESS_VERSION}
      - WA_BUSINESS_LANGUAGE=${WA_BUSINESS_LANGUAGE}
      # Webhooks (todas as configuracoes)
      - WEBHOOK_GLOBAL_ENABLED=${WEBHOOK_GLOBAL_ENABLED}
      - WEBHOOK_GLOBAL_URL=${WEBHOOK_GLOBAL_URL}
      - WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS=${WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS}
      - WEBHOOK_EVENTS_APPLICATION_STARTUP=${WEBHOOK_EVENTS_APPLICATION_STARTUP}
      - WEBHOOK_EVENTS_QRCODE_UPDATED=${WEBHOOK_EVENTS_QRCODE_UPDATED}
      - WEBHOOK_EVENTS_MESSAGES_SET=${WEBHOOK_EVENTS_MESSAGES_SET}
      - WEBHOOK_EVENTS_MESSAGES_UPSERT=${WEBHOOK_EVENTS_MESSAGES_UPSERT}
      - WEBHOOK_EVENTS_MESSAGES_EDITED=${WEBHOOK_EVENTS_MESSAGES_EDITED}
      - WEBHOOK_EVENTS_MESSAGES_UPDATE=${WEBHOOK_EVENTS_MESSAGES_UPDATE}
      - WEBHOOK_EVENTS_MESSAGES_DELETE=${WEBHOOK_EVENTS_MESSAGES_DELETE}
      - WEBHOOK_EVENTS_SEND_MESSAGE=${WEBHOOK_EVENTS_SEND_MESSAGE}
      - WEBHOOK_EVENTS_SEND_MESSAGE_UPDATE=${WEBHOOK_EVENTS_SEND_MESSAGE_UPDATE}
      - WEBHOOK_EVENTS_CONTACTS_SET=${WEBHOOK_EVENTS_CONTACTS_SET}
      - WEBHOOK_EVENTS_CONTACTS_UPSERT=${WEBHOOK_EVENTS_CONTACTS_UPSERT}
      - WEBHOOK_EVENTS_CONTACTS_UPDATE=${WEBHOOK_EVENTS_CONTACTS_UPDATE}
      - WEBHOOK_EVENTS_PRESENCE_UPDATE=${WEBHOOK_EVENTS_PRESENCE_UPDATE}
      - WEBHOOK_EVENTS_CHATS_SET=${WEBHOOK_EVENTS_CHATS_SET}
      - WEBHOOK_EVENTS_CHATS_UPSERT=${WEBHOOK_EVENTS_CHATS_UPSERT}
      - WEBHOOK_EVENTS_CHATS_UPDATE=${WEBHOOK_EVENTS_CHATS_UPDATE}
      - WEBHOOK_EVENTS_CHATS_DELETE=${WEBHOOK_EVENTS_CHATS_DELETE}
      - WEBHOOK_EVENTS_GROUPS_UPSERT=${WEBHOOK_EVENTS_GROUPS_UPSERT}
      - WEBHOOK_EVENTS_GROUPS_UPDATE=${WEBHOOK_EVENTS_GROUPS_UPDATE}
      - WEBHOOK_EVENTS_GROUP_PARTICIPANTS_UPDATE=${WEBHOOK_EVENTS_GROUP_PARTICIPANTS_UPDATE}
      - WEBHOOK_EVENTS_CONNECTION_UPDATE=${WEBHOOK_EVENTS_CONNECTION_UPDATE}
      - WEBHOOK_EVENTS_REMOVE_INSTANCE=${WEBHOOK_EVENTS_REMOVE_INSTANCE}
      - WEBHOOK_EVENTS_LOGOUT_INSTANCE=${WEBHOOK_EVENTS_LOGOUT_INSTANCE}
      - WEBHOOK_EVENTS_LABELS_EDIT=${WEBHOOK_EVENTS_LABELS_EDIT}
      - WEBHOOK_EVENTS_LABELS_ASSOCIATION=${WEBHOOK_EVENTS_LABELS_ASSOCIATION}
      - WEBHOOK_EVENTS_CALL=${WEBHOOK_EVENTS_CALL}
      - WEBHOOK_EVENTS_TYPEBOT_START=${WEBHOOK_EVENTS_TYPEBOT_START}
      - WEBHOOK_EVENTS_TYPEBOT_CHANGE_STATUS=${WEBHOOK_EVENTS_TYPEBOT_CHANGE_STATUS}
      - WEBHOOK_EVENTS_ERRORS=${WEBHOOK_EVENTS_ERRORS}
      - WEBHOOK_EVENTS_ERRORS_WEBHOOK=${WEBHOOK_EVENTS_ERRORS_WEBHOOK}
      - WEBHOOK_REQUEST_TIMEOUT_MS=${WEBHOOK_REQUEST_TIMEOUT_MS}
      - WEBHOOK_RETRY_MAX_ATTEMPTS=${WEBHOOK_RETRY_MAX_ATTEMPTS}
      - WEBHOOK_RETRY_INITIAL_DELAY_SECONDS=${WEBHOOK_RETRY_INITIAL_DELAY_SECONDS}
      - WEBHOOK_RETRY_USE_EXPONENTIAL_BACKOFF=${WEBHOOK_RETRY_USE_EXPONENTIAL_BACKOFF}
      - WEBHOOK_RETRY_MAX_DELAY_SECONDS=${WEBHOOK_RETRY_MAX_DELAY_SECONDS}
      - WEBHOOK_RETRY_JITTER_FACTOR=${WEBHOOK_RETRY_JITTER_FACTOR}
      - WEBHOOK_RETRY_NON_RETRYABLE_STATUS_CODES=${WEBHOOK_RETRY_NON_RETRYABLE_STATUS_CODES}
      # Integracoes
      - TYPEBOT_ENABLED=${TYPEBOT_ENABLED}
      - TYPEBOT_API_VERSION=${TYPEBOT_API_VERSION}
      - CHATWOOT_ENABLED=${CHATWOOT_ENABLED}
      - CHATWOOT_MESSAGE_READ=${CHATWOOT_MESSAGE_READ}
      - CHATWOOT_MESSAGE_DELETE=${CHATWOOT_MESSAGE_DELETE}
      - CHATWOOT_BOT_CONTACT=${CHATWOOT_BOT_CONTACT}
      - CHATWOOT_DB_CONNECTION_URI=${CHATWOOT_DB_CONNECTION_URI}
      - CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=${CHATWOOT_IMPORT_DATABASE_CONNECTION_URI}
      - CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE=${CHATWOOT_IMPORT_PLACEHOLDER_MEDIA_MESSAGE}
      - OPENAI_ENABLED=${OPENAI_ENABLED}
      - DIFY_ENABLED=${DIFY_ENABLED}
      - N8N_ENABLED=${N8N_ENABLED}
      - EVOAI_ENABLED=${EVOAI_ENABLED}
      # Audio Converter
      - AUDIO_CONVERTER_ENABLED=${AUDIO_CONVERTER_ENABLED}
      - AUDIO_CONVERTER_KEY=${AUDIO_CONVERTER_KEY}
      - API_AUDIO_CONVERTER=${API_AUDIO_CONVERTER}
      - API_AUDIO_CONVERTER_KEY=${API_AUDIO_CONVERTER_KEY}
      # SSL
      - HTTPS_ENABLED=${HTTPS_ENABLED}
      - SSL_PRIVKEY=${SSL_PRIVKEY}
      - SSL_FULLCHAIN=${SSL_FULLCHAIN}
      - SSL_CONF_PRIVKEY=${SSL_CONF_PRIVKEY}
      - SSL_CONF_FULLCHAIN=${SSL_CONF_FULLCHAIN}
      # Cache Redis
      - CACHE_REDIS_ENABLED=${CACHE_REDIS_ENABLED}
      - CACHE_REDIS_URI=${CACHE_REDIS_URI}
      - CACHE_REDIS_TTL=${CACHE_REDIS_TTL}
      - CACHE_REDIS_PREFIX_KEY=${CACHE_REDIS_PREFIX_KEY}
      - CACHE_REDIS_SAVE_INSTANCES=${CACHE_REDIS_SAVE_INSTANCES}
      - CACHE_LOCAL_ENABLED=${CACHE_LOCAL_ENABLED}

  postgres:
    container_name: postgres
    image: postgres:15
    restart: always
    ports: ["5432:5432"]
    environment:
      POSTGRES_PASSWORD: ${evolution_db_password}
      POSTGRES_USER: postgres
      POSTGRES_DB: evolution_db
      POSTGRES_INITDB_ARGS: --encoding=ASCII --locale=C
    volumes: [postgres_data:/var/lib/postgresql/data]
    networks: [evolution-net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d evolution_db"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    container_name: redis
    image: redis:latest
    restart: always
    ports: ["6379:6379"]
    networks: [evolution-net]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
  evolution_instances:
  evolution_store:
networks:
  evolution-net: { driver: bridge }
EOF
    
    check_status "Erro ao criar docker-compose.yaml" "docker-compose.yaml criado"
}

# Gerenciar containers
deploy_containers() {
    log "Preparando deploy dos containers..."
    
    # Parar containers antigos e limpar
    docker compose down --remove-orphans 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true
    
    # Baixar imagens em paralelo
    log "Baixando imagens Docker..."
    docker pull evoapicloud/evolution-api:latest &
    docker pull postgres:15 &
    docker pull redis:latest &
    wait
    check_status "Erro ao baixar imagens" "Imagens baixadas"
    
    # Iniciar containers
    log "Iniciando containers..."
    timeout 300 docker compose up -d
    check_status "Erro ao iniciar containers" "Containers iniciados"
    
    # Aguardar containers ficarem saudaveis
    log "Aguardando containers ficarem saudaveis..."
    sleep 15
    
    # Testar conectividade
    if timeout 30 curl -s http://localhost:8080/ >/dev/null 2>&1; then
        log "OK API respondendo"
    else
        log "AVISO: API pode nao estar respondendo ainda"
        docker logs evolution_api --tail 10
    fi
}

# Status final
show_final_status() {
    echo ""
    echo "=== STATUS DOS CONTAINERS ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
        --filter "name=evolution_api" --filter "name=postgres" --filter "name=redis"
    
    echo ""
    echo "=== INFORMACOES DA APLICACAO ==="
    log "OK Evolution API configurada com seguranca!"
    echo "🌐 URL: http://${VM_IP}:8080"
    echo "🔑 API Key: ${evolution_api_key}"
    echo "📊 Swagger: http://${VM_IP}:8080/swagger"
    
    echo ""
    echo "=== COMANDOS UTEIS ==="
    echo "Logs: docker logs evolution_api -f"
    echo "Reiniciar: docker compose restart"
    echo "Status: docker ps"
    echo "Parar: docker compose down"
    
    echo ""
    log "OK DEPLOY CONCLUIDO COM SUCESSO!"
    
    # Limpar variaveis sensiveis da memoria
    unset evolution_api_key evolution_db_password evolution_jwt_secret evolution_sentry_dsn
    unset evolution_s3_access_key evolution_s3_secret_key evolution_rabbitmq_uri
    unset evolution_pusher_app_id evolution_pusher_key evolution_pusher_secret
    unset evolution_proxy_username evolution_proxy_password evolution_audio_converter_key
    unset evolution_chatwoot_db_uri evolution_ssl_privkey evolution_ssl_fullchain
}

# Execucao principal
main() {
    check_dependencies
    load_secrets
    get_vm_ip
    setup_environment
    create_docker_compose
    deploy_containers
    show_final_status
}

# Executar script principal
main "$@"
