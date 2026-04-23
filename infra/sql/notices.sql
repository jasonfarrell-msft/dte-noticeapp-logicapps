-- Idempotent DDL for unified notices landing table.
-- Mirrors the canonical schema documented in README.md.
-- Run as the SQL AAD admin via sqlcmd:
--   sqlcmd -S <server>.database.windows.net -d noticesdb -G -i infra/sql/notices.sql

IF OBJECT_ID('dbo.notices', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.notices (
        source              NVARCHAR(40)   NOT NULL,
        pipeline            NVARCHAR(40)   NOT NULL,
        pipelineName        NVARCHAR(200)  NULL,
        noticeId            NVARCHAR(80)   NOT NULL,
        noticeType          NVARCHAR(80)   NULL,
        status              NVARCHAR(40)   NULL,
        isCritical          BIT            NULL,
        title               NVARCHAR(1000) NULL,
        description         NVARCHAR(MAX)  NULL,
        postedDate          DATETIME2      NULL,
        effectiveDate       DATETIME2      NULL,
        endDate             DATETIME2      NULL,
        affectedLocations   NVARCHAR(MAX)  NULL,   -- JSON array as string
        responseRequired    BIT            NULL,
        rawBlobPath         NVARCHAR(400)  NULL,
        parsedAt            DATETIME2      NULL,
        foundryModel        NVARCHAR(80)   NULL,
        tokensUsed          INT            NULL,
        ingestedAt          DATETIME2      NOT NULL CONSTRAINT DF_notices_ingestedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_notices PRIMARY KEY (source, pipeline, noticeId)
    );

    CREATE INDEX IX_notices_postedDate ON dbo.notices (postedDate DESC);
    CREATE INDEX IX_notices_source_pipeline ON dbo.notices (source, pipeline);
END
GO

IF OBJECT_ID('dbo.notice_locations', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.notice_locations (
        source     NVARCHAR(40)  NOT NULL,
        pipeline   NVARCHAR(40)  NOT NULL,
        noticeId   NVARCHAR(80)  NOT NULL,
        location   NVARCHAR(400) NOT NULL,
        CONSTRAINT FK_notice_locations_notices FOREIGN KEY (source, pipeline, noticeId)
            REFERENCES dbo.notices (source, pipeline, noticeId) ON DELETE CASCADE
    );

    CREATE INDEX IX_notice_locations_key ON dbo.notice_locations (source, pipeline, noticeId);
END
GO

-- Idempotent flatten of dbo.notices.affectedLocations (JSON array) into dbo.notice_locations.
-- When @source/@pipeline/@noticeId are all supplied, only that one notice is reprocessed;
-- when any is NULL/empty, the full table is rebuilt. Safe to re-run.
CREATE OR ALTER PROCEDURE dbo.usp_FlattenAffectedLocations
    @source   NVARCHAR(40)  = NULL,
    @pipeline NVARCHAR(40)  = NULL,
    @noticeId NVARCHAR(80)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (NULLIF(@source,'') IS NOT NULL AND NULLIF(@pipeline,'') IS NOT NULL AND NULLIF(@noticeId,'') IS NOT NULL)
    BEGIN
        DELETE FROM dbo.notice_locations
            WHERE source = @source AND pipeline = @pipeline AND noticeId = @noticeId;

        INSERT INTO dbo.notice_locations (source, pipeline, noticeId, location)
        SELECT n.source, n.pipeline, n.noticeId, LEFT(j.[value], 400)
        FROM dbo.notices n
        CROSS APPLY OPENJSON(n.affectedLocations) j
        WHERE n.source = @source AND n.pipeline = @pipeline AND n.noticeId = @noticeId
          AND n.affectedLocations IS NOT NULL
          AND ISJSON(n.affectedLocations) = 1
          AND j.[value] IS NOT NULL AND LTRIM(RTRIM(j.[value])) <> '';
    END
    ELSE
    BEGIN
        DELETE FROM dbo.notice_locations;

        INSERT INTO dbo.notice_locations (source, pipeline, noticeId, location)
        SELECT n.source, n.pipeline, n.noticeId, LEFT(j.[value], 400)
        FROM dbo.notices n
        CROSS APPLY OPENJSON(n.affectedLocations) j
        WHERE n.affectedLocations IS NOT NULL
          AND ISJSON(n.affectedLocations) = 1
          AND j.[value] IS NOT NULL AND LTRIM(RTRIM(j.[value])) <> '';
    END
END
GO
