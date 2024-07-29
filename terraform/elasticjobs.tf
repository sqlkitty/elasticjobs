resource "azurerm_resource_group" "elasticjobrg" {
  location = var.resource_group_location
  name     = "elasticjobrg"
} 

resource "azurerm_mssql_server" "server" {
    name                         = "elastic-${azurerm_resource_group.elasticjobrg.name}"
    resource_group_name          = azurerm_resource_group.elasticjobrg.name
    location                     = azurerm_resource_group.rg.location
    version                      = "12.0"
    administrator_login          = "adminuser"
    administrator_login_password = "password@123!"
    azuread_administrator {
      login_username = "your group/login"
      object_id      = "yourobjectid"
    }
}

resource "azurerm_mssql_elasticpool" "example" {
  name                = "sqlelasticpool"
  resource_group_name = azurerm_resource_group.elasticjobrg.name
  location            = azurerm_resource_group.rg.location
  server_name         = azurerm_mssql_server.server.name

  sku {
    name     = "StandardPool"
    tier     = "Standard"
    capacity = 50
  }

   max_size_gb = 50

  per_database_settings {
    min_capacity = 0
    max_capacity = 50
  }
}


/* we need to talk about this because we can prob put the db on the existing db servers */
resource "azurerm_mssql_database" "database" {
    name              = "dbelastic-${azurerm_resource_group.elasticjobrg.name}"
    server_id         = azurerm_mssql_server.server.id
    collation         = "SQL_Latin1_General_CP1_CI_AS"
    /*
    this is getting set with the pool
    sku_name          = "S1"
    max_size_gb       = 10  # Adjust this value as needed
    */
    elastic_pool_id   = azurerm_mssql_elasticpool.example.id
}

resource "azurerm_mssql_firewall_rule" "firewallrule" {
  name                = "my-ip"
  server_id           = azurerm_mssql_server.server.id
  start_ip_address    = "yourip"
  end_ip_address      = "yourip"
  depends_on = [
     azurerm_mssql_server.server
   ]
}

resource "azurerm_mssql_firewall_rule" "azure-services-rule" {
  name                = "allow-azure-services"
  server_id           = azurerm_mssql_server.server.id
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
  depends_on = [
     azurerm_mssql_server.server
   ]
} 

/* we need to create this managed identity with terraform
so that I can add it to the dbs so the elastic agent can access them 
I will do the adding of the MI to the sql db with a sql script 
we don't automate the granting of perms 
*/
resource "azurerm_user_assigned_identity" "managed_identity" {
  name                = "ElasticAgentJobsManagedID"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.elasticjobrg.name
}

/* 
this will create elastic jobs agent with default JA100 setting 
*/ 
resource "azapi_resource" "elasticjobagent" {
  type = "Microsoft.Sql/servers/jobAgents@2023-05-01-preview"
  name = "elasticagent-${azurerm_resource_group.elasticjobrg.name}"
  location = azurerm_resource_group.rg.location
  parent_id = azurerm_mssql_server.server.id
  identity {
    type = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.managed_identity.id]
  }
  body = jsonencode({
    properties = {
      databaseId = azurerm_mssql_database.database.id
    }    
  })
}

/* 
advice from msft about the parameters in members 
https://learn.microsoft.com/en-us/azure/templates/microsoft.sql/servers/jobagents/targetgroups?pivots=deployment-language-terraform#jobtarget-2
*/
resource "azapi_resource" "elasticjobstargetgroups" {
  type = "Microsoft.Sql/servers/jobAgents/targetGroups@2023-05-01-preview"
  name = "AzureSQLDBs"
  parent_id = azapi_resource.elasticjobagent.id
  body = jsonencode({
    properties = {
      members = [
        /* this adds all the dbs in the elastic pool to the target group */
        {
          elasticPoolName = azurerm_mssql_elasticpool.example.name  # use this if your db is in an elastic pool 
          membershipType = "Include"  
          type = "SqlElasticPool" 
          serverName = azurerm_mssql_server.server.name
        },

        /* use this below to add an azure sql server or dbs to the target group 
            TF code to create additional azure sql servers not included above
            I only show the elastic pool setup fully 
            but wanted to give you examples of how to include/exclude azure sql servers/dbs
        */
        {
          membershipType = "Include"  # or "Exclude"
          serverName = putthatservernamehere #created with module and main.tf or you can manually type it here 
          type = "SqlServer" 
        },
        {
          databaseName = "josephineadventureworks"  # Name of the database to exclude
          membershipType = "Exclude"
          serverName = putthatservernamehere
          type = "SqlDatabase"
        }, 
        {
          databaseName = "dwingestion"  
          membershipType = "Exclude"
          serverName = putthatservernamehere
          type = "SqlDatabase"
        },
        {
          databaseName = "anotherdb"  # Name of the database to include
          membershipType = "Include"
          serverName = putyetanotherservernamehere
          type = "SqlDatabase"
        },
      ]
    }
  })
}


resource "azapi_resource" "elasticjobstargetgroups" {
  type = "Microsoft.Sql/servers/jobAgents/targetGroups@2023-05-01-preview"
  name = "AzureSQLDBs"
  parent_id = azapi_resource.elasticjobagent.id
  body = jsonencode({
    properties = {
      members = [
        {
          #databaseName = "string" # this is not needed if you want all the dbs on the server 
          #elasticPoolName = "string"  # use this is your db is in an elastic pool 
          membershipType = "Include"  # or "Exclude"
          #refreshCredential = "string" #don't I need this with a managed identity
          serverName = azurerm_mssql_server.example.fully_qualified_domain_name #created with module and main.tf or you can manually type it here 
          #shardMapName = "string"
          type = "SqlServer" 
        },
        {
          databaseName = "josephineadventureworks"  # Name of the database to exclude
          membershipType = "Exclude"
          serverName = azurerm_mssql_server.example.fully_qualified_domain_name
          type = "SqlDatabase"
        }, 
        {
          databaseName = "dwingestion"  # Name of the database to exclude
          membershipType = "Exclude"
          serverName = azurerm_mssql_server.example.fully_qualified_domain_name
          type = "SqlDatabase"
        }
      ]
    }
  })
}

resource "azapi_resource" "job" {
  type = "Microsoft.Sql/servers/jobAgents/jobs@2023-05-01-preview"
  name = "OlaStatsUpdateJob"
  parent_id = azapi_resource.elasticjobagent.id
  body = jsonencode({
    properties = {
      description = "Runs ola stats update only on all dbs in the target group"
      schedule = {
        enabled: true
        startTime: "2024-04-16T23:00:00Z"
        endTime: "9999-12-31T11:59:59Z"
        interval: "P1D"
        type: "Recurring"
      }
    }
  })
}

resource "azapi_resource" "jobstep1" {
  type = "Microsoft.Sql/servers/jobAgents/jobs/steps@2023-05-01-preview"
  name = "OlaStatsUpdateStep"
  parent_id = azapi_resource.job.id
  body = jsonencode({
    properties = {
      action = {
        source = "Inline"
        type = "TSql"
        value = "EXECUTE [dbo].[IndexOptimize]\n            @Databases = 'USER_DATABASES' ,\n            @FragmentationLow = NULL ,\n            @FragmentationMedium = NULL ,\n            @FragmentationHigh = NULL ,\n            @UpdateStatistics = 'ALL' ,\n            @LogToTable = 'Y';"
      }
      stepId = 1
      targetGroup = azapi_resource.elasticjobstargetgroups.id
    }
  })
}

resource "azapi_resource" "jobstep2" {
  type = "Microsoft.Sql/servers/jobAgents/jobs/steps@2023-05-01-preview"
  name = "OlaCommandLogCleanupStep"
  parent_id = azapi_resource.job.id
  body = jsonencode({
    properties = {
      action = {
        source = "Inline"
        type = "TSql"
        value = "DELETE FROM [dbo].[CommandLog]\n              WHERE StartTime <= DATEADD(DAY, -30, GETDATE());"
      }
      #stepId = 2 
      #The job step's index within the job. If not specified when creating the job step, it will be created as the last step. If not specified when updating the job step, the step id is not modified.
      targetGroup = azapi_resource.elasticjobstargetgroups.id
    }
  })
}

