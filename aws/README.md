# aws/ - Infraestructura AWS (Fase 14, primera parte)

Plantillas CloudFormation en `cloudformation/`, validadas con `cfn-lint` (pasan sin
errores). **No se han desplegado**: validar la sintaxis no prueba que funcionen en una
cuenta real.

## Que incluye (y que NO)

| Plantilla | Recursos | Costo |
|---|---|---|
| `00-budget.yaml` | Presupuesto mensual con alertas (50% real, 80% real, 100% previsto) | Gratis (los 2 primeros presupuestos) |
| `01-github-oidc.yaml` | Proveedor OIDC de GitHub + rol IAM de minimo privilegio (solo push a ECR) | Gratis |
| `02-ecr.yaml` | 5 repositorios ECR (scan on push, conserva las ultimas 20 imagenes) | Almacenamiento por GB; centavos con estas imagenes |
| `03-network.yaml` | VPC, 2 subredes publicas, IGW, SG de app y de RDS (sin NAT) | Gratis |
| `04-rds.yaml` | PostgreSQL 16 db.t4g.micro, 3 bases logicas (`../init-rds-databases.sql`) | USD 0,016/h: **encender solo para probar** |

Estado 2026-10-09 (ADR-017): 00-03 desplegados (USD 0). 04 probado y **eliminado**.

**Pendiente, con costo real (no incluido hasta que lo apruebes):** VPC/subnets, RDS
PostgreSQL, RabbitMQ (p. ej. Amazon MQ), ECS/Fargate + Load Balancer, Lambda y
ElastiCache/Redis. La seccion 48 pide revisar precios y Free Tier vigentes antes de
crear cada uno; los precios cambian y no se asumen aqui.

## Orden de despliegue

Requiere AWS CLI configurado con un usuario administrador (una sola vez, solo para
este bootstrap; despues el pipeline usa OIDC).

```bash
cd cloudformation

# 1. Alertas de costo PRIMERO (seccion 48)
aws cloudformation deploy --stack-name itinerarios-budget \
  --template-file 00-budget.yaml \
  --parameter-overrides AlertEmail=tu@correo.com MonthlyLimitUsd=20

# 2. OIDC + rol (requiere CAPABILITY_NAMED_IAM por el nombre fijo del rol)
aws cloudformation deploy --stack-name itinerarios-github-oidc \
  --template-file 01-github-oidc.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubOwner=<tu-usuario-o-org>
# Si la cuenta ya tiene el proveedor OIDC de GitHub:
#   CreateOidcProvider=false ExistingOidcProviderArn=arn:aws:iam::<id>:oidc-provider/token.actions.githubusercontent.com

# 3. Repositorios ECR
aws cloudformation deploy --stack-name itinerarios-ecr --template-file 02-ecr.yaml

# 4. Red (AdminCidr opcional, /29-/32, solo para pruebas temporales contra RDS)
aws cloudformation deploy --stack-name itinerarios-network --template-file 03-network.yaml

# 5. RDS (COSTO): crear, probar y borrar con delete-stack al terminar
aws cloudformation deploy --stack-name itinerarios-rds --template-file 04-rds.yaml
aws cloudformation delete-stack --stack-name itinerarios-rds
```

## Luego, en cada repo de GitHub

Definir las variables `AWS_ACCOUNT_ID`, `AWS_REGION` y `AWS_ROLE_NAME`
(`github-actions-itinerarios`), y crear el Environment `production`. Con eso el job
`push-image` de `ci.yml` queda operativo. Ver
`itinerarios-docs/deployment/ci-cd.md`.

## Notas

- Solo los repos listados en la trust policy, y solo desde el Environment
  `production`, pueden asumir el rol. Si renombras repos o el environment, actualiza
  `01-github-oidc.yaml`.
- Para eliminar: `aws cloudformation delete-stack`. Un repositorio ECR con imagenes
  no se borra hasta vaciarlo.
