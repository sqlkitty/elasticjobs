/* code to run in terminal to create this bicep - change the path for your path and use backslash for windows 
    az deployment group create -g 'yourrgname' -f ./my-bicep/elastic-jobs.bicep -c  

    NOTE you need to change out with your values for the following: 
    yoursubid 
    yourrgname
    yoursqlservername 
*/

/* need azure sql db of s1 or higher for the elastic job agent 
   and I'm putting it on an existing server
*/

resource SQLElasticJobAgentDB 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 20
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 268435456000
    catalogCollation: 'SQL_Latin1_General_CP1_CI_AS'
    zoneRedundant: false
    readScale: 'Disabled'
    requestedBackupStorageRedundancy: 'Geo'
    isLedgerOn: false
    availabilityZone: 'NoPreference'
  }
  location: 'eastus2'
  tags: {}
  name: 'yoursqlservername/SQLElasticJobAgentDB'
}

/* next we need to setup the elastic job agent with managed identity and using the s1 or higher azure sql db */
resource SQLElasticJobAgent 'Microsoft.Sql/servers/jobAgents@2023-08-01-preview' = {
  sku: {
    name: 'JA100'
    capacity: 100
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '/subscriptions/yoursubid/resourcegroups/yourgname/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ElasticAgentJobsManagedID': {
      }
    }
  }
  properties: {
    databaseId: '/subscriptions/yoursubid/resourceGroups/yourgname/providers/Microsoft.Sql/servers/yoursqlservername/databases/SQLElasticJobAgentDB'
  }
  location: 'eastus2'
  tags: {}
  name: 'yoursqlservername/SQLElasticJobAgent'
}


/* now we need to create some target groups and add some members to exec our jobs on */
resource SQLElasticJobAgentTargetGroup 'Microsoft.Sql/servers/jobAgents/targetGroups@2023-08-01-preview' = {
  name: 'AzureSQLDBs'
  parent : SQLElasticJobAgent
  properties: {
    members: [
      {
        membershipType: 'Include'
        type: 'SqlServer'
        serverName: 'yoursqlservername.database.windows.net'
      }
      {
        membershipType: 'Exclude'
        type: 'SqlDatabase'
        serverName: 'yoursqlservername.database.windows.net'
        databaseName: 'josephineadventureworks'
      }
      {
        membershipType: 'Exclude'
        type: 'SqlDatabase'
        serverName: 'yoursqlservername.database.windows.net'
        databaseName: 'DWIngestion'
      }
      {
        membershipType: 'Include'
        type: 'SqlServer'
        serverName: 'yoursqlservername2.database.windows.net'
      }
    ]
  }
}

/* now we need to create a job to run on the target group - mine will run once a day at 11pm UTC */
resource SQLElasticJobAgentJob 'Microsoft.Sql/servers/jobAgents/jobs@2023-08-01-preview' = {
  name: 'OlaStatsUpdateJob'
  parent: SQLElasticJobAgent
  properties: {
    schedule: {
      enabled: true
      startTime: '2024-04-16T23:00:00Z'
      endTime: '9999-12-31T11:59:59Z'
      interval: 'P1D'
      type: 'Recurring'
    }
  }
}

/* now we need to add steps to the job so something actually executes :) 
   don't change the spacing on the sql as it breaks the bicep 
   in this case step 1 runs ola stats update and step 2 runs cleanup on the commandlog table 
*/

resource SQLElasticJobAgentJobStep1 'Microsoft.Sql/servers/jobAgents/jobs/steps@2023-05-01-preview' = {
  name: 'StatsUpdateStep'
  parent: SQLElasticJobAgentJob
  properties: {
    action: {
      source: 'Inline'
      type: 'TSql'
      value: 'EXECUTE [dbo].[IndexOptimize]\n            @Databases = \'USER_DATABASES\' ,\n            @FragmentationLow = NULL ,\n            @FragmentationMedium = NULL ,\n            @FragmentationHigh = NULL ,\n            @UpdateStatistics = \'ALL\' ,\n            @LogToTable = \'Y\';'
    }
  stepId: 1
  targetGroup: SQLElasticJobAgentTargetGroup.id
  }
}

resource SQLElasticJobAgentJobStep2 'Microsoft.Sql/servers/jobAgents/jobs/steps@2023-05-01-preview' = {
  name: 'CleanUpCommandLogStep'
  parent: SQLElasticJobAgentJob
  properties: {
    action: {
      source: 'Inline'
      type: 'TSql'
      value: 'DELETE FROM [dbo].[CommandLog]\n              WHERE StartTime <= DATEADD(DAY, -30, GETDATE());'
    }
  stepId: 2
  targetGroup: SQLElasticJobAgentTargetGroup.id
  }
}

/* action group for alerts */
resource dbactiongroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'dbactiongroup'
  location: 'Global'
  properties: {
    groupShortName: 'dbactgrp'
    enabled: true
    emailReceivers: [
      {
        name: 'sendtome'
        emailAddress: 'youremail@domain.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

/* alert for elastic job failed */
resource ElasticJobFailed 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'ElasticJobFailed'
  location: 'global'
  tags: {}
  properties: {
    description: ''
    severity: 1
    enabled: true
    scopes: [
      '/subscriptions/yoursubid/resourceGroups/yourgname/providers/Microsoft.Sql/servers/yoursqlservername/jobAgents/SQLElasticJobAgent'
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          threshold: json('0.0')
          name: 'Metric1'
          metricNamespace: 'Microsoft.Sql/servers/jobAgents'
          metricName: 'elastic_jobs_failed'
          operator: 'GreaterThan'
          timeAggregation: 'Total'
          skipMetricValidation: false
          criterionType: 'StaticThresholdCriterion'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    autoMitigate: true
    targetResourceType: 'Microsoft.Sql/servers/jobAgents'
    targetResourceRegion: 'eastus2'
    actions: [
      {
        actionGroupId: '/subscriptions/yoursubid/resourcegroups/yourgname/providers/microsoft.insights/actiongroups/dbactiongroup'
        webHookProperties: {}
      }
    ]
  }
}

/* alert for elastic job timed out */
resource ElasticJobTimedOut 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'ElasticJobTimedOut'
  location: 'global'
  tags: {}
  properties: {
    description: ''
    severity: 1
    enabled: true
    scopes: [
      '/subscriptions/yoursubid/resourceGroups/yourgname/providers/Microsoft.Sql/servers/yoursqlservername/jobAgents/SQLElasticJobAgent'
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          threshold: json('0.0')
          name: 'Metric1'
          metricNamespace: 'Microsoft.Sql/servers/jobAgents'
          metricName: 'elastic_jobs_timeout'
          operator: 'GreaterThan'
          timeAggregation: 'Total'
          skipMetricValidation: false
          criterionType: 'StaticThresholdCriterion'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }
    autoMitigate: true
    targetResourceType: 'Microsoft.Sql/servers/jobAgents'
    targetResourceRegion: 'eastus2'
    actions: [
      {
        actionGroupId: '/subscriptions/yoursubid/resourcegroups/yourgname/providers/microsoft.insights/actiongroups/dbactiongroup'
        webHookProperties: {}
      }
    ]
  }
}
