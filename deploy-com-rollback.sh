#!/bin/bash
set -e

# ============================================================
# Configuração — troque para o ambiente com ALB se necessário
# ============================================================
CLUSTER="cluster-bia-alb"
SERVICE="service-bia-alb"

REGION="us-east-2"
ECR_REGISTRY="676782900636.dkr.ecr.us-east-2.amazonaws.com"
ECR_REPO="fundamentos"

# Infere a task definition a partir do nome do service
# service-bia     → task-def-bia
# service-bia-alb → task-def-bia-alb
TASK_FAMILY="task-def-${SERVICE#service-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ============================================================
# Funções auxiliares
# ============================================================

_ecr_login() {
  echo ">>> Login no ECR..."
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" 2>&1 \
    | grep -v "WARNING"
}

_get_current_task_def() {
  aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION" \
    --query "services[0].taskDefinition" \
    --output text
}

_list_revisions() {
  aws ecs list-task-definitions \
    --family-prefix "$TASK_FAMILY" \
    --region "$REGION" \
    --sort DESC \
    --query "taskDefinitionArns[:10]" \
    --output json
}

_describe_revision() {
  local ARN="$1"
  aws ecs describe-task-definition \
    --task-definition "$ARN" \
    --region "$REGION" \
    --query "taskDefinition.{rev:revision,img:containerDefinitions[0].image,date:registeredAt}" \
    --output json
}

# ============================================================
# deploy
# ============================================================
cmd_deploy() {
  COMMIT_HASH=$(git rev-parse --short HEAD)
  IMAGE_URI="$ECR_REGISTRY/$ECR_REPO:$COMMIT_HASH"

  echo "============================================"
  echo " Deploy — $CLUSTER / $SERVICE"
  echo " Commit : $COMMIT_HASH"
  echo " Imagem : $IMAGE_URI"
  echo "============================================"

  # Detecta o IP público da instância ECS e atualiza o Dockerfile
  ECS_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=ECS Instance - $CLUSTER" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text 2>/dev/null || true)

  if [ -z "$ECS_IP" ] || [ "$ECS_IP" == "None" ]; then
    echo "⚠️  IP da instância ECS não detectado. Mantendo VITE_API_URL atual no Dockerfile."
  else
    echo ">>> IP da instância ECS: $ECS_IP"
    # sed -i "s|VITE_API_URL=http://[^[:space:]]*|VITE_API_URL=http://$ECS_IP|g" Dockerfile
    echo ">>> Dockerfile atualizado: VITE_API_URL=http://$ECS_IP"
  fi

  # Build e push
  _ecr_login
  echo ">>> Build da imagem ($COMMIT_HASH)..."
  docker build -t "bia:$COMMIT_HASH" .

  echo ">>> Push para ECR..."
  docker tag "bia:$COMMIT_HASH" "$IMAGE_URI"
  docker push "$IMAGE_URI"

  # Clona a task definition atual substituindo apenas a tag da imagem
  echo ">>> Criando nova revisão da task definition..."
  CURRENT_TD=$(_get_current_task_def)

  aws ecs describe-task-definition \
    --task-definition "$CURRENT_TD" \
    --region "$REGION" \
    --query "taskDefinition" \
    --output json > "$TMP/current_td.json"

  python3 - "$TMP/current_td.json" "$COMMIT_HASH" > "$TMP/new_td.json" << 'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    td = json.load(f)

commit_hash = sys.argv[2]

for c in td["containerDefinitions"]:
    repo = c["image"].rsplit(":", 1)[0]
    c["image"] = repo + ":" + commit_hash

for field in ["taskDefinitionArn", "revision", "status", "requiresAttributes",
              "compatibilities", "registeredAt", "registeredBy"]:
    td.pop(field, None)

print(json.dumps(td))
PYEOF

  NEW_REVISION=$(aws ecs register-task-definition \
    --region "$REGION" \
    --cli-input-json "file://$TMP/new_td.json" \
    --query "taskDefinition.revision" \
    --output text)

  echo ">>> Revisão criada: $TASK_FAMILY:$NEW_REVISION"

  # Atualiza o service
  echo ">>> Atualizando service..."
  aws ecs update-service \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TASK_FAMILY:$NEW_REVISION" \
    --query "service.{Status:status,TaskDef:taskDefinition}" \
    --output json

  # Aguarda estabilizar
  echo ">>> Aguardando deploy estabilizar..."
  aws ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION"

  echo ""
  echo "✅ Deploy concluído! $TASK_FAMILY:$NEW_REVISION ($COMMIT_HASH)"
}

# ============================================================
# rollback
# ============================================================
cmd_rollback() {
  echo "============================================"
  echo " Rollback — $CLUSTER / $SERVICE"
  echo "============================================"
  echo ""

  _list_revisions > "$TMP/revisions.json"
  COUNT=$(python3 -c "import json; print(len(json.load(open('$TMP/revisions.json'))))")

  if [ "$COUNT" -eq 0 ]; then
    echo "Nenhuma revisão encontrada para $TASK_FAMILY."
    exit 1
  fi

  echo "Revisões disponíveis:"
  echo ""

  # Busca e exibe cada revisão
  python3 - "$TMP/revisions.json" "$REGION" << 'PYEOF'
import sys, json, subprocess

with open(sys.argv[1]) as f:
    arns = json.load(f)

region = sys.argv[2]

for i, arn in enumerate(arns, 1):
    result = subprocess.run(
        ["aws", "ecs", "describe-task-definition",
         "--task-definition", arn,
         "--region", region,
         "--query", "taskDefinition.{rev:revision,img:containerDefinitions[0].image,date:registeredAt}",
         "--output", "json"],
        capture_output=True, text=True
    )
    d    = json.loads(result.stdout)
    tag  = d["img"].rsplit(":", 1)[-1] if d["img"] else "?"
    date = d["date"][:19].replace("T", " ") if d["date"] else "?"
    print("  [{}] Revisao {:>3}  |  {:<22}  |  {}".format(i, d["rev"], tag, date))
PYEOF

  echo ""
  printf "Escolha o número da revisão para restaurar: "
  read -r CHOICE

  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$COUNT" ]; then
    echo "Opção inválida."
    exit 1
  fi

  TARGET_ARN=$(python3 -c "
import json
arns = json.load(open('$TMP/revisions.json'))
print(arns[$((CHOICE - 1))])
")

  TARGET_REV=$(echo "$TARGET_ARN" | grep -oE '[0-9]+$')

  echo ""
  echo ">>> Restaurando para $TASK_FAMILY:$TARGET_REV..."
  aws ecs update-service \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$TARGET_ARN" \
    --query "service.{Status:status,TaskDef:taskDefinition}" \
    --output json

  echo ">>> Aguardando deploy estabilizar..."
  aws ecs wait services-stable \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION"

  echo ""
  echo "✅ Rollback concluído! Rodando $TASK_FAMILY:$TARGET_REV"
}

# ============================================================
# list
# ============================================================
cmd_list() {
  echo "============================================"
  echo " Revisões — $TASK_FAMILY"
  echo "============================================"
  echo ""

  CURRENT_TD=$(_get_current_task_def)
  CURRENT_REV=$(echo "$CURRENT_TD" | grep -oE '[0-9]+$')

  _list_revisions > "$TMP/revisions.json"

  python3 - "$TMP/revisions.json" "$REGION" "$CURRENT_REV" << 'PYEOF'
import sys, json, subprocess

with open(sys.argv[1]) as f:
    arns = json.load(f)

region = sys.argv[2]
active = sys.argv[3]

print("  {:>7}  {:<22}  {:<19}  {}".format("Revisao", "Imagem (tag/hash)", "Criado em", ""))
print("  {:>7}  {:<22}  {:<19}".format("-------", "----------------------", "-------------------"))

for arn in arns:
    result = subprocess.run(
        ["aws", "ecs", "describe-task-definition",
         "--task-definition", arn,
         "--region", region,
         "--query", "taskDefinition.{rev:revision,img:containerDefinitions[0].image,date:registeredAt}",
         "--output", "json"],
        capture_output=True, text=True
    )
    d    = json.loads(result.stdout)
    tag  = d["img"].rsplit(":", 1)[-1] if d["img"] else "?"
    date = d["date"][:19].replace("T", " ") if d["date"] else "?"
    rev  = str(d["rev"])
    flag = "<-- ativo" if rev == active else ""
    print("  {:>7}  {:<22}  {:<19}  {}".format(rev, tag, date, flag))
PYEOF

  echo ""
}

# ============================================================
# Entrypoint
# ============================================================
case "${1:-}" in
  deploy)   cmd_deploy   ;;
  rollback) cmd_rollback ;;
  list)     cmd_list     ;;
  *)
    echo ""
    echo "Uso: ./deploy-com-rollback.sh <comando>"
    echo ""
    echo "  deploy    Build, push e deploy de nova versão (usa short hash do Git)"
    echo "  rollback  Escolhe uma revisão anterior e restaura o service"
    echo "  list      Lista as últimas revisões da task definition"
    echo ""
    ;;
esac
