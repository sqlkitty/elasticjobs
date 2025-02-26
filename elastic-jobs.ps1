# read the blog post for more info https://sqlkitty.com/powershell-elastic-jobs/

# SETUP MANAGED IDENTITY 
$resourceGroupName = "rgname"
$userManagedIdentityName = "ElasticAgentJobsManagedID"
$location = "eastus2"

New-AzUserAssignedIdentity -ResourceGroupName $resourceGroupName -Name $userManagedIdentityName -Location $location


# SETUP ELASTIC JOB SQL SERVER 
$resourceGroupName = "rgname"
$serverName = "sqlservername"
$location = "eastus2"
$adminUser = "sqladmin" # Set your admin username
$adminPassword = "YourStrongPassword!" # Set your admin password

# Create SQL Server
New-AzSqlServer -ResourceGroupName $resourceGroupName `
                -ServerName $serverName `
                -Location $location `
                -SqlAdministratorCredentials (New-Object -TypeName System.Management.Automation.PSCredential `
                                             -ArgumentList $adminUser, (ConvertTo-SecureString $adminPassword -AsPlainText -Force))

Write-Host "SQL Server $serverName created successfully."


# SETUP ELASTIC JOB DATABASE 
$resourceGroupName = "rgname"
$serverName = "sqlservername"
$databaseName = "ElasticJobsDB"
#$location = "eastus2" 

New-AzSqlDatabase -ResourceGroupName $resourceGroupName `
                  -ServerName $serverName `
                  -DatabaseName $databaseName `
                  -Edition "Standard" `
                  -RequestedServiceObjectiveName "S1"
Write-Host "Database $databaseName created successfully."

# SETUP ELASTIC JOB AGENT
$UserManagedID = Get-AzUserAssignedIdentity -ResourceGroupName "rgname" -Name "ElasticJobsMIDev" 

New-AzSqlElasticJobAgent -ResourceGroupName "rgname" `
                         -ServerName "sqlservername" `
                         -DatabaseName "ElasticJobsDB" `
                         -Name "ElasticJobsAgentDev" `
                         -IdentityType "UserAssigned" `
                         -UserAssignedIdentityId $UserManagedID.Id `
                         -SkuName "JA100" `
                         -WorkerCount 100
Write-Host "Elastic Job Agent created successfully."


# SETUP TARGETS ON THE AGENT WITHOUT ELASTIC POOL
# Get the job agent
$agent = Get-AzSqlElasticJobAgent -ResourceGroupName "rgname" -ServerName "sqlservername" -Name "ElasticJobAgent" 
# Create target group
$targetGroup = $agent | New-AzSqlElasticJobTargetGroup -Name "AzureSQLDBs"
# Add the server to the target group
$targetGroup | Add-AzSqlElasticJobTarget -ServerName "sqlservername.database.windows.net"


# SETUP TARGETS ON THE AGENT WITH ELASTIC POOL 
# Get the job agent
$agent = Get-AzSqlElasticJobAgent -ResourceGroupName "rgname" -ServerName "sqlservername" -Name "ElasticJobAgent" 
# Create target group
$targetGroup = $agent | New-AzSqlElasticJobTargetGroup -Name "AzureSQLDBs"
# Add the server to the target group
$targetGroup | Add-AzSqlElasticJobTarget -ServerName "sqlservername.database.windows.net" -ElasticPoolName "YourPoolName"


# SETUP JOB ON THE AGENT
# Get the job agent
$agent = Get-AzSqlElasticJobAgent -ResourceGroupName "rgname" -ServerName "sqlservername" -Name "ElasticJobsAgentDev"
# Create job
$agentJob = $agent | New-AzSqlElasticJob -Name "OlaStatsUpdateJob"
# Set daily schedule and enable the job 
$startTimeUTC = [datetime]::ParseExact("2025-02-7 04:00:00", "yyyy-MM-dd HH:mm:ss", $null)
$agentJob | Set-AzSqlElasticJob -IntervalType Day -IntervalCount 1 -StartTime $startTimeUTC -Enable


# SETUP JOB STEP ON THE JOB
$job = Get-AzSqlElasticJob -ResourceGroupName "rgname" `
    -ServerName "sqlservername" `
    -AgentName "ElasticJobsAgentDev" `
    -Name "OlaStatsUpdateJob"

$commandText = @"
EXECUTE [dba].[IndexOptimize] 
    @Databases = 'USER_DATABASES', 
    @FragmentationLow = NULL, 
    @FragmentationMedium = NULL, 
    @FragmentationHigh = NULL, 
    @UpdateStatistics = 'ALL', 
    @LogToTable = 'Y';
"@

$job | Add-AzSqlElasticJobStep -Name "OlaStatsUpdateStep" `
    -TargetGroupName "AzureSQLDBs" `
    -CommandText $commandText



# IMPORTANT!!!  If you have an elastic pool 
#                Update the max_parallelism setting after setting up this job otherwise the pool will be overloaded
#                that script is included below the job setup 
# SETUP INDEX MAINTENANCE JOB ON THE AGENT
# Get the job agent
$agent = Get-AzSqlElasticJobAgent -ResourceGroupName "rgname" -ServerName "servername" -Name "agentname"
# Create job
$agentJob = $agent | New-AzSqlElasticJob -Name "OlaIndexMaintJob"
# Set daily schedule and enable the job 
$startTimeUTC = [datetime]::ParseExact("2025-03-02 05:00:00", "yyyy-MM-dd HH:mm:ss", $null)
$agentJob | Set-AzSqlElasticJob -IntervalType Week -IntervalCount 1 -StartTime $startTimeUTC -Enable

# SETUP JOB STEP ON THE JOB
# Get the job
$job = Get-AzSqlElasticJob -ResourceGroupName "rgname" `
    -ServerName "sqlservername" `
    -AgentName "ElasticJobsAgentDev" `
    -Name "OlaIndexMaintJob"

# Create step code
$commandText = @"
EXECUTE dba.IndexOptimize
    @Databases = 'USER_DATABASES',
    @MinNumberOfPages = 100,
    @FragmentationLow = NULL,
    @FragmentationMedium = 'INDEX_REORGANIZE, INDEX_REBUILD_ONLINE',
    @FragmentationHigh = 'INDEX_REBUILD_ONLINE, INDEX_REORGANIZE',
    @FragmentationLevel1 = 50,
    @FragmentationLevel2 = 80,
    @LogToTable = 'Y';
"@

$job | Add-AzSqlElasticJobStep -Name "OlaIndexMaintStep" `
    -TargetGroupName "AzureSQLDBs" `
    -CommandText $commandText


# IMPORTANT!!!  Update the max_parallelism setting
# this is needed for index maintenance when dbs share a pool 
# I just run it directly in the db not with ps 

$updateQuery = @"
EXEC jobs.sp_update_jobstep  
    @job_name = 'OlaIndexMaintJob',  
    @step_name = 'OlaIndexMaintStep',  
    @max_parallelism = 1;
"@

Invoke-Sqlcmd -ServerInstance "sqlservername" `
              -Database "ElasticJobsDB" `
              -Query $updateQuery `
              -Username "get from keyvault" `
              -Password "get from keyvault"


# ADD ANOTHER STEP TO CLEANUP COMMAND LOG
# Variables
$resourceGroupName = "rgname"
$serverName = "sqlservername"
$agentName = "ElasticJobsAgentDev"
$jobName = "OlaStatsUpdateJob"
$targetGroupName = "AzureSQLDBs"

# Get the job
$job = Get-AzSqlElasticJob -ResourceGroupName $resourceGroupName -ServerName $serverName -AgentName $agentName -Name $jobName

# Add a new job step for deleting old records
$job | Add-AzSqlElasticJobStep -Name "DeleteOldCommandLogsStep" `
                               -TargetGroupName $targetGroupName `
                               -CommandText "DELETE FROM dba.CommandLog WHERE StartTime < DATEADD(DAY, -90, GETDATE());" `
                               -TimeoutSeconds 43200 `
                               -RetryAttempts 10 `
                               -InitialRetryIntervalSeconds 1 `
                               -MaximumRetryIntervalSeconds 120 `
                               -RetryIntervalBackoffMultiplier 2
                               
Write-Host "Job step 'DeleteOldCommandLogsStep' added successfully."



# START JOB 
$job = Get-AzSqlElasticJob -ResourceGroupName "rgname" -ServerName "sqlservername" -AgentName "ElasticJobsAgentDev" -Name "OlaStatsUpdateJob"
$jobExecution = $job | Start-AzSqlElasticJob
$jobExecution

<#
SELECT job_name, step_name, target_server_name, target_database_name, target_type, 
        last_message, start_time, end_time, is_active, lifecycle, current_attempts
        FROM jobs.job_executions 
WHERE is_active = 1
ORDER BY start_time DESC;
#>


# SETUP ACTION GROUP AND ALERT RULE 
$subscriptionId = (Get-AzContext).Subscription.Id
$resourceGroupName = "rgname"
$serverName = "sqlservername"
$jobAgentName = "ElasticJobAgent"
$actionGroupName = "your-action-group-name"
$actionGroupShortName = "ElasticJobFailureActionGroup"

$emailreceiver = New-AzActionGroupEmailReceiverObject -EmailAddress email@email.com -Name DataOps
$actionGroup = New-AzActionGroup -ActionGroupName $actionGroupName `
                    -ResourceGroupName $resourceGroupName `
                    -Location "Global" `
                    -ShortName $actionGroupShortName `
                    -EmailReceiver $emailreceiver 
    
# Create the Metric Alert Rule Criteria (with TimeAggregation)
$alertCriteria = New-AzMetricAlertRuleV2Criteria -MetricName "elastic_jobs_failed" `
    -Operator GreaterThan `
    -Threshold 0 `
    -TimeAggregation Total  # Set TimeAggregation to Average

# Get the Action Group again if needed by its name and resource group
$actionGroup = Get-AzActionGroup -ResourceGroupName $resourceGroupName -ActionGroupName $actionGroupName

# Create the Metric Alert Rule
Add-AzMetricAlertRuleV2 -Name "ElasticJobFailureAlert" `
    -ResourceGroupName $resourceGroupName `
    -TargetResourceId "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Sql/servers/$serverName/jobAgents/$jobAgentName" `
    -WindowSize 24:0 `
    -Frequency 24:0 `
    -Condition $alertCriteria `
    -ActionGroupId $actionGroup.Id `
    -Severity 1
