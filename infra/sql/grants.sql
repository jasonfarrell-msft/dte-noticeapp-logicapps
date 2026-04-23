-- One-time grants for non-admin principals on noticesdb.
-- Run as the SQL AAD admin (the principal supplied via sqlAdminAadObjectId):
--   sqlcmd -S <server>.database.windows.net -d noticesdb -G -i infra/sql/grants.sql
--
-- Replace <ADF_NAME> with the ADF resource name (default: adf-dte-noticeapp-eus2-mx01).

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '<ADF_NAME>')
BEGIN
    CREATE USER [<ADF_NAME>] FROM EXTERNAL PROVIDER;
END
GO

ALTER ROLE db_datareader ADD MEMBER [<ADF_NAME>];
ALTER ROLE db_datawriter ADD MEMBER [<ADF_NAME>];
GO
