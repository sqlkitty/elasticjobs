/* Set up a user-managed identity and elastic job agent in the Azure portal, 
and then you can use this T-SQL script to do the rest of the setup 
See my blog post for more details 
put link here 
*/

/* setup perms for user managed id to access dbs
  add this to any db that you want to run stats/index maintenance on 
  I also added this to my Elastic Jobs db to do maintenance there, as well */  
CREATE USER ElasticAgentJobsManagedID FROM EXTERNAL PROVIDER;
ALTER ROLE db_owner ADD MEMBER ElasticAgentJobsManagedID;

/* add this to master if you want to run agent jobs on all dbs on a server 
  this will allow the dbs to be emumerated */
CREATE USER ElasticAgentJobsManagedID FROM EXTERNAL PROVIDER;

/* make sure to add Ola scripts to include these objects in each db you want maintenance on
  CommandLog - table 
  CommandExecute - stored proc
  IndexOptimize - stored proc
  from 
  https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html
*/ 

/* run all the rest of the queries while connected to the elastic jobs db */

/* Add a target group */
EXEC jobs.sp_add_target_group 'AzureSQLDBs';

/* Add a server target members */
/* this will run on all dbs on the server */
EXEC jobs.sp_add_target_group_member
@target_group_name = 'AzureSQLDBs',
@target_type = 'SqlServer',
@server_name = 'sql2-rg-sterling-rabbit.database.windows.net'; 

/* this will run on all dbs on the server */
EXEC jobs.sp_add_target_group_member
@target_group_name = 'AzureSQLDBs',
@target_type = 'SqlServer',
@server_name = 'sql-rg-sterling-rabbit.database.windows.net';

/* this will exclude a db from the members */
EXEC jobs.sp_add_target_group_member
@target_group_name = 'AzureSQLDBs',
@target_type = 'SqlDatabase',
@server_name = 'sql-rg-sterling-rabbit.database.windows.net',
@membership_type = 'Exclude',
@database_name = 'josephineadventureworks';

/* if you want to include vs exclude you would not add the server
and instead just add the db name */

/* if you need to remove a target group member */
EXEC jobs.sp_delete_target_group_member
@target_group_name = 'AzureSQLDBs',
@target_id = '1e2a8ba9-89d9-4e3c-86a8-51fce476de56';


/* View the target group and target group members */
SELECT * FROM jobs.target_groups;
SELECT * FROM jobs.target_group_members;

/* Add the stats update job */
EXEC jobs.sp_add_job 
@job_name = 'OlaStatsUpdateJob', 
@description = 'To run stats update nightly with Ola scripts'; 

/* View all jobs */
SELECT * FROM jobs.jobs;

/* Add stats update job step */
EXEC jobs.sp_add_jobstep 
@job_name = 'OlaStatsUpdateJob',
@step_name = 'OlaStatsUpdateStep',
@command = N'EXECUTE [dbo].[IndexOptimize]
            @Databases = ''USER_DATABASES'' ,
            @FragmentationLow = NULL ,
            @FragmentationMedium = NULL ,
            @FragmentationHigh = NULL ,
            @UpdateStatistics = ''ALL'' ,
            @LogToTable = ''Y'';',
@target_group_name = 'AzureSQLDBs';

/* View the steps of all versions of all jobs */
SELECT * FROM jobs.jobsteps;

/* Schedule and enable the stats update job 
   this will run once a day 
   @ 23:00 UTC */
EXEC jobs.sp_update_job
@job_name = 'OlaStatsUpdateJob',
@enabled=1,
@schedule_interval_type = 'Days',
@schedule_interval_count = 1, 
@schedule_start_time = '2024-04-16 23:00:00'; 

/* Start the job manually to test */
EXEC jobs.sp_start_job 'OlaStatsUpdateJob';

/* Monitor active job progress */
SELECT job_execution_id, job_name, step_name, target_server_name, target_database_name, 
target_type, last_message, start_time, end_time, is_active, lifecycle, current_attempts
FROM jobs.job_executions 
WHERE is_active = 1
ORDER BY start_time DESC;

/* Stop the job if needed */
EXECUTE [jobs].[sp_stop_job] 
   @job_execution_id = '65473ed5-b2ec-4139-9b6a-5b3a7c901c69'
GO

/* For ola cleanup portion of the job 
   make sure to add this on each of your dbs that need maintenance */
CREATE NONCLUSTERED INDEX NIX_CommandLog_StartTime 
        ON dbo.CommandLog (StartTime ASC);

/* add step to the stats update job to run the cleanup */
EXEC jobs.sp_add_jobstep 
@job_name = 'OlaStatsUpdateJob',
@step_name = 'OlaCommandLogCleanup',
@command = N'DELETE FROM [dbo].[CommandLog]
              WHERE StartTime <= DATEADD(DAY, -30, GETDATE());',
@target_group_name = 'AzureSQLDBs';


/* Add index maintenance job */
EXEC jobs.sp_add_job 
@job_name = 'OlaIndexMaintJob', 
@description = 'To run index maintenance weekly Ola scripts'; 

/* Add job step to index maintenance job */
EXEC jobs.sp_add_jobstep 
@job_name = 'OlaIndexMaintJob',
@step_name = 'OlaIndexMaintStep',
@command = N'EXECUTE dbo.IndexOptimize
                @Databases = ''USER_DATABASES'',
                @FragmentationLow = NULL,
                @FragmentationMedium = ''INDEX_REORGANIZE'',
                @FragmentationHigh = ''INDEX_REBUILD_ONLINE'',
                @FragmentationLevel1 = 50,
                @FragmentationLevel2 = 80,
                @UpdateStatistics = ''ALL'',
                @Indexes = ''ALL_INDEXES'',
                @LogToTable = ''Y''; ',
@target_group_name = 'AzureSQLDBs';

/* Schedule and enable the index maintenance job 
   this will run once a week on Saturdays  
   @ 20:00 UTC */
EXEC jobs.sp_update_job
@job_name = 'OlaIndexMaintJob',
@enabled=1,
@schedule_interval_type = 'Weeks',
@schedule_interval_count = 1, 
@schedule_start_time = '2024-04-20 20:00:00'; 
