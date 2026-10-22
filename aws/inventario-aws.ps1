# Inventario de todo lo montado en AWS para el proyecto (solo lectura: no crea, cambia ni borra nada).
# Uso (con sesion activa de `aws login`):
#   powershell -ExecutionPolicy Bypass -File aws\inventario-aws.ps1            # en pantalla
#   powershell -ExecutionPolicy Bypass -File aws\inventario-aws.ps1 > inv.txt  # a archivo
param([string]$Region = 'us-east-1', [string]$Cluster = 'itinerarios-ecs')

$ErrorActionPreference = 'Continue'
function Seccion($titulo) { Write-Host "`n==== $titulo ====" -ForegroundColor Cyan }
# aws.exe explicito: PowerShell no distingue mayusculas y "aws" volveria a llamar a esta funcion.
function Aws { & aws.exe --region $Region @args 2>&1 }

Seccion "Cuenta"
Aws sts get-caller-identity --query "[Account,Arn]" --output text

Seccion "Stacks CloudFormation activos"
Aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE `
    --query "StackSummaries[?starts_with(StackName,'itinerarios')].[StackName,StackStatus,LastUpdatedTime||CreationTime]" --output table

Seccion "Historial de stacks (incluye los borrados en las pruebas; CloudFormation guarda ~90 dias)"
Aws cloudformation list-stacks --query "StackSummaries[?starts_with(StackName,'itinerarios')].[StackName,StackStatus,CreationTime,DeletionTime]" --output table

Seccion "Recursos creados por los stacks (ARN)"
Aws resourcegroupstaggingapi get-resources --tag-filters Key=aws:cloudformation:stack-name `
    --query "ResourceTagMappingList[].[Tags[?Key=='aws:cloudformation:stack-name']|[0].Value,ResourceARN]" --output table

Seccion "ECS: servicios del cluster $Cluster (deseadas/corriendo) e IP publica de cada tarea"
$servicios = (Aws ecs list-services --cluster $Cluster --query "serviceArns" --output text) -split '\s+' | Where-Object { $_ -like 'arn:*' }
foreach ($s in $servicios) {
    $info = Aws ecs describe-services --cluster $Cluster --services $s --query "services[0].[serviceName,desiredCount,runningCount]" --output text
    $tarea = Aws ecs list-tasks --cluster $Cluster --service-name $s --query "taskArns[0]" --output text
    $ip = '-'
    if ($tarea -like 'arn:*') {
        $eni = Aws ecs describe-tasks --cluster $Cluster --tasks $tarea --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text
        if ($eni -like 'eni-*') { $ip = Aws ec2 describe-network-interfaces --network-interface-ids $eni --query "NetworkInterfaces[0].Association.PublicIp" --output text }
    }
    Write-Host ("{0,-60} IP {1}" -f ($info -replace '\s+', '  '), $ip)
}

Seccion "RDS"
Aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,EngineVersion,DBInstanceStatus,Endpoint.Address]" --output table

Seccion "Lambda"
Aws lambda list-functions --query "Functions[].[FunctionName,Runtime,MemorySize,LastModified]" --output table

Seccion "ECR: repositorios e imagenes"
$repos = (Aws ecr describe-repositories --query "repositories[?starts_with(repositoryName,'itinerarios')].repositoryName" --output text) -split '\s+' | Where-Object { $_ }
foreach ($r in $repos) {
    $n = Aws ecr list-images --repository-name $r --query "length(imageIds)" --output text
    Write-Host ("{0,-35} {1} imagen(es)" -f $r, $n)
}

Seccion "S3"
Aws s3api list-buckets --query "Buckets[].[Name,CreationDate]" --output table

Seccion "SSM Parameter Store (solo nombres y tipo; los valores no se muestran)"
Aws ssm describe-parameters --query "Parameters[].[Name,Type,Tier]" --output table

Seccion "Secrets Manager"
Aws secretsmanager list-secrets --query "SecretList[].[Name,CreatedDate]" --output table

Seccion "Cloud Map (DNS interno *.itinerarios.local)"
Aws servicediscovery list-services --query "Services[].Name" --output table

Seccion "Red: VPC, IPs publicas en uso y rangos permitidos en Security Groups"
Aws ec2 describe-vpcs --filters "Name=tag:aws:cloudformation:stack-name,Values=itinerarios-network" --query "Vpcs[].[VpcId,CidrBlock]" --output table
Aws ec2 describe-network-interfaces --query "NetworkInterfaces[?Association.PublicIp].[Association.PublicIp,Description]" --output table
Aws ec2 describe-security-groups --query "SecurityGroups[?IpPermissions[?IpRanges[?CidrIp!='0.0.0.0/0']]].[GroupName,join(', ',IpPermissions[].IpRanges[].CidrIp)]" --output table

Seccion "IAM: rol OIDC de GitHub y presupuesto"
Aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[].Arn" --output table
Aws budgets describe-budgets --account-id (Aws sts get-caller-identity --query Account --output text) `
    --query "Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]" --output table

# Cost Explorer cobra USD 0,01 por consulta (una sola por ejecucion).
Seccion "Costo del mes en curso (Cost Explorer, USD)"
$ini = (Get-Date -Day 1).ToString('yyyy-MM-dd'); $fin = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
Aws ce get-cost-and-usage --time-period "Start=$ini,End=$fin" --granularity MONTHLY --metrics UnblendedCost `
    --group-by "Type=DIMENSION,Key=SERVICE" --query "ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>'0.001'].[Keys[0],Metrics.UnblendedCost.Amount]" --output table
