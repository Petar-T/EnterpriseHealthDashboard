/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : 01-central/06-purge.sql
  Run in : the CENTRAL repository database

  Retention is the single biggest difference between a central repository that
  stays healthy for years and one that quietly becomes a 400 GB liability.

  Design points:

  * BATCHED DELETES. A single DELETE of 40 million rows takes a lock escalation,
    blows out the log, and can trip the log rate governor on the central
    database itself. Everything here deletes in configurable batches with a
    CHECKPOINT-friendly gap between them.

  * ORDERED BY OLDEST FIRST. Deleting on a clustered index that leads with the
    timestamp means each batch is a range scan, not a table scan.

  * STAGING IS PURGED SEPARATELY AND AGGRESSIVELY. Staging rows are transient.
    Once core.usp_Normalize has consumed them they only exist so you can debug
    a bad load. Retention.StagingHours defaults to 48.

  * A SAFETY FLOOR. If somebody sets a retention value to 0 or a negative
    number, the purge would delete everything including today. Each value is
    clamped to a minimum of 1 day.
==============================================================================*/
/* Required SET options. sqlcmd.exe defaults QUOTED_IDENTIFIER to OFF, which makes
   CREATE INDEX fail on any filtered index and bakes the wrong options into views
   and procedures. SSMS and Invoke-Sqlcmd default it ON, so this only bites when
   deploying the documented way - with sqlcmd. Set it explicitly and the script
   behaves identically from every client. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE core.usp_Purge
    @DryRun bit = 0   -- 1 = report what WOULD be deleted, delete nothing
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @runId bigint;
    INSERT core.ProcessRun (StepName, Status)
    VALUES (CASE WHEN @DryRun = 1 THEN 'Purge(DryRun)' ELSE 'Purge' END, 'Running');
    SET @runId = SCOPE_IDENTITY();

    /* clamped so a mis-typed setting cannot wipe live data */
    DECLARE @freqDays  int = CASE WHEN cfg.fn_Int('Retention.FrequentDays',     7) < 1 THEN 1 ELSE cfg.fn_Int('Retention.FrequentDays',     7) END,
            @stdDays   int = CASE WHEN cfg.fn_Int('Retention.StandardDays',    35) < 1 THEN 1 ELSE cfg.fn_Int('Retention.StandardDays',    35) END,
            @dailyDays int = CASE WHEN cfg.fn_Int('Retention.DailyDays',      400) < 1 THEN 1 ELSE cfg.fn_Int('Retention.DailyDays',      400) END,
            @alertDays int = CASE WHEN cfg.fn_Int('Retention.AlertHistoryDays',180) < 1 THEN 1 ELSE cfg.fn_Int('Retention.AlertHistoryDays',180) END,
            @stgHours  int = CASE WHEN cfg.fn_Int('Retention.StagingHours',    48) < 1 THEN 1 ELSE cfg.fn_Int('Retention.StagingHours',    48) END,
            @batch     int = CASE WHEN cfg.fn_Int('Retention.PurgeBatchRows',50000) < 1000 THEN 1000 ELSE cfg.fn_Int('Retention.PurgeBatchRows',50000) END;

    DECLARE @freqCut  datetime2(3) = DATEADD(DAY,  -@freqDays,  SYSUTCDATETIME()),
            @stdCut   datetime2(3) = DATEADD(DAY,  -@stdDays,   SYSUTCDATETIME()),
            @dailyCut date         = CAST(DATEADD(DAY, -@dailyDays, SYSUTCDATETIME()) AS date),
            @alertCut datetime2(3) = DATEADD(DAY,  -@alertDays, SYSUTCDATETIME());

    /*--------------------------------------------------------------------------
      The work list. Adding a table to the system means adding one row here.
      TimeColumn must be the leading column of the clustered index for the
      batched delete to stay cheap.
    --------------------------------------------------------------------------*/
    DECLARE @work TABLE
    (
        Seq         int IDENTITY(1,1) PRIMARY KEY,
        TableName   sysname,
        TimeColumn  sysname,
        CutoffText  nvarchar(40),
        Tier        varchar(20),
        Deleted     bigint NULL
    );

    INSERT @work (TableName, TimeColumn, CutoffText, Tier) VALUES
        -- frequent tier: high volume, short life
        ('core.ResourceUsage',        'EndTimeUtc',   CONVERT(nvarchar(30), @freqCut, 126),  'Frequent'),
        ('core.ActiveRequest',        'SnapshotUtc',  CONVERT(nvarchar(30), @freqCut, 126),  'Frequent'),
        ('core.BlockingChain',        'SnapshotUtc',  CONVERT(nvarchar(30), @freqCut, 126),  'Frequent'),
        ('core.SessionActivity',      'SnapshotUtc',  CONVERT(nvarchar(30), @freqCut, 126),  'Frequent'),
        -- standard tier: the bulk of the repository
        ('core.WaitStats',            'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.QueryStats',           'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.QueryStoreTopQuery',   'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.DatabaseSpace',        'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.LogSpace',             'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.TempDbUsage',          'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.IoFileStats',          'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.ErrorEvent',           'EventTimeUtc', CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.Deadlock',             'EventTimeUtc', CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.WaitEvent',            'EventTimeUtc', CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        ('core.XeSessionHealth',      'SnapshotUtc',  CONVERT(nvarchar(30), @stdCut, 126),   'Standard'),
        -- daily tier: small rows, long history, this is the trend data
        ('core.IndexUsage',           'SnapshotDate', CONVERT(nvarchar(10), @dailyCut, 23),  'Daily'),
        ('core.MissingIndex',         'SnapshotDate', CONVERT(nvarchar(10), @dailyCut, 23),  'Daily'),
        ('core.IndexFragmentation',   'SnapshotDate', CONVERT(nvarchar(10), @dailyCut, 23),  'Daily'),
        ('core.TableSpace',           'SnapshotDate', CONVERT(nvarchar(10), @dailyCut, 23),  'Daily'),
        ('core.SecurityPrincipal',    'SnapshotDate', CONVERT(nvarchar(10), @dailyCut, 23),  'Daily'),
        ('core.SecurityPermission',   'SnapshotDate', CONVERT(nvarchar(10), @dailyCut, 23),  'Daily'),
        -- housekeeping
        ('core.AlertHistory',         'RaisedUtc',    CONVERT(nvarchar(30), @alertCut, 126), 'Alerts'),
        ('core.ServiceObjectiveChange','DetectedUtc', CONVERT(nvarchar(30), @alertCut, 126), 'Alerts');

    DECLARE @seq int = 1, @maxSeq int = (SELECT MAX(Seq) FROM @work);
    DECLARE @tbl sysname, @col sysname, @cut nvarchar(40), @sql nvarchar(max),
            @thisTable bigint, @totalDeleted bigint = 0, @errors int = 0;

    WHILE @seq <= @maxSeq
    BEGIN
        SELECT @tbl = TableName, @col = TimeColumn, @cut = CutoffText
        FROM   @work WHERE Seq = @seq;

        SET @thisTable = 0;

        BEGIN TRY
            /* skip tables that do not exist yet - the system is deployable in
               stages and a missing table is not an error */
            IF OBJECT_ID(@tbl) IS NULL
            BEGIN
                UPDATE @work SET Deleted = NULL WHERE Seq = @seq;
                SET @seq += 1;
                CONTINUE;
            END

            IF @DryRun = 1
            BEGIN
                SET @sql = N'SELECT @out = COUNT_BIG(*) FROM ' + @tbl
                         + N' WHERE ' + QUOTENAME(@col) + N' < @cutoff;';
                EXEC sys.sp_executesql @sql,
                     N'@cutoff nvarchar(40), @out bigint OUTPUT', @cut, @thisTable OUTPUT;
            END
            ELSE
            BEGIN
                /* batched loop: each pass is its own transaction, so the log
                   can be truncated between batches */
                SET @sql = N'DELETE TOP (@n) FROM ' + @tbl
                         + N' WHERE ' + QUOTENAME(@col) + N' < @cutoff;';

                DECLARE @rows int = 1, @guard int = 0;
                WHILE @rows > 0 AND @guard < 1000
                BEGIN
                    EXEC sys.sp_executesql @sql,
                         N'@n int, @cutoff nvarchar(40)', @batch, @cut;
                    SET @rows = @@ROWCOUNT;
                    SET @thisTable += @rows;
                    SET @guard += 1;

                    /* let other work in - purge is never urgent */
                    IF @rows > 0 WAITFOR DELAY '00:00:00.100';
                END

                /* @guard is a runaway stop. 1000 batches x 50k = 50M rows in one
                   pass; if we hit it, something is wrong (a bad cutoff, or the
                   table is genuinely enormous) and the next run continues. */
                IF @guard >= 1000
                    INSERT core.ProcessRun (StepName, CompletedUtc, Status, RowsAffected, ErrorMessage)
                    VALUES (CONCAT('Purge:', @tbl), SYSUTCDATETIME(), 'PartialSuccess', @thisTable,
                            'Hit the 1000-batch guard - more rows remain, next run will continue.');
            END

            UPDATE @work SET Deleted = @thisTable WHERE Seq = @seq;
            SET @totalDeleted += @thisTable;
        END TRY
        BEGIN CATCH
            SET @errors += 1;
            INSERT core.ProcessRun (StepName, CompletedUtc, Status, ErrorNumber, ErrorMessage)
            VALUES (CONCAT('Purge:', @tbl), SYSUTCDATETIME(), 'Failed',
                    ERROR_NUMBER(), CONCAT('Line ', ERROR_LINE(), ': ', ERROR_MESSAGE()));
            UPDATE @work SET Deleted = -1 WHERE Seq = @seq;
        END CATCH

        SET @seq += 1;
    END

    /*--------------------------------------------------------------------------
      Staging. Handled separately because it is time-boxed in HOURS and the
      staging tables are created by the Elastic Job agent, not by us - so their
      exact shape is not guaranteed. core.usp_PurgeStaging (in 02-normalize.sql)
      already knows how to find the right timestamp column defensively.
    --------------------------------------------------------------------------*/
    DECLARE @stgDeleted bigint = 0;
    IF @DryRun = 0
    BEGIN
        BEGIN TRY
            EXEC core.usp_PurgeStaging;
        END TRY
        BEGIN CATCH
            SET @errors += 1;
            INSERT core.ProcessRun (StepName, CompletedUtc, Status, ErrorNumber, ErrorMessage)
            VALUES ('Purge:staging', SYSUTCDATETIME(), 'Failed',
                    ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH
    END

    /* ProcessRun itself - keep 90 days of our own audit trail */
    IF @DryRun = 0
        DELETE FROM core.ProcessRun
        WHERE StartedUtc < DATEADD(DAY, -90, SYSUTCDATETIME())
          AND ProcessRunId <> @runId;

    /* FeedArrival rows for targets that no longer exist in the registry */
    IF @DryRun = 0
        DELETE fa
        FROM   core.FeedArrival AS fa
        WHERE  NOT EXISTS (SELECT 1 FROM cfg.Target t
                           WHERE t.ServerName = fa.ServerName
                             AND t.DatabaseName = fa.DatabaseName);

    UPDATE core.ProcessRun
       SET CompletedUtc = SYSUTCDATETIME(),
           Status       = CASE WHEN @errors > 0 THEN 'PartialSuccess' ELSE 'Success' END,
           RowsAffected = @totalDeleted,
           ErrorMessage = CASE WHEN @errors > 0
                               THEN CONCAT(@errors, ' table(s) failed - see Purge: rows') END
     WHERE ProcessRunId = @runId;

    /* per-table report, ordered by impact */
    SELECT  TableName,
            RetentionTier = Tier,
            CutoffUtc     = CutoffText,
            RowsDeleted   = CASE WHEN Deleted = -1 THEN NULL ELSE Deleted END,
            Outcome       = CASE WHEN Deleted IS NULL THEN 'skipped (table not deployed)'
                                 WHEN Deleted = -1    THEN 'FAILED - see core.ProcessRun'
                                 WHEN @DryRun = 1     THEN 'would delete'
                                 ELSE 'deleted' END
    FROM    @work
    ORDER BY CASE WHEN Deleted IS NULL THEN 1 ELSE 0 END, Deleted DESC;
END
GO


/*==============================================================================
  core.usp_StorageReport
  What is actually consuming the central repository, newest first.
  Run this before tuning retention - the answer is almost always WaitStats.
==============================================================================*/
CREATE OR ALTER PROCEDURE core.usp_StorageReport
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  TableName   = CONCAT(s.name, '.', t.name),
            RowCountEst = SUM(CASE WHEN i.index_id IN (0,1) THEN p.rows ELSE 0 END),
            TotalMB     = CAST(SUM(a.total_pages) * 8.0 / 1024 AS decimal(19,2)),
            UsedMB      = CAST(SUM(a.used_pages)  * 8.0 / 1024 AS decimal(19,2)),
            PctOfRepo   = CAST(SUM(a.total_pages) * 100.0
                               / NULLIF(SUM(SUM(a.total_pages)) OVER (), 0) AS decimal(9,2))
    FROM    sys.tables AS t
    JOIN    sys.schemas AS s   ON s.schema_id = t.schema_id
    JOIN    sys.indexes AS i   ON i.object_id = t.object_id
    JOIN    sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id
    JOIN    sys.allocation_units AS a ON a.container_id = p.partition_id
    WHERE   s.name IN ('core', 'stg', 'cfg')
    GROUP BY s.name, t.name
    ORDER BY SUM(a.total_pages) DESC;

    SELECT  TotalRepositoryMB = CAST(SUM(a.total_pages) * 8.0 / 1024 AS decimal(19,2)),
            TargetCount       = (SELECT COUNT(*) FROM cfg.Target WHERE IsEnabled = 1),
            MBPerTarget       = CAST(SUM(a.total_pages) * 8.0 / 1024
                                / NULLIF((SELECT COUNT(*) FROM cfg.Target WHERE IsEnabled = 1), 0)
                                AS decimal(19,2))
    FROM    sys.tables AS t
    JOIN    sys.schemas AS s ON s.schema_id = t.schema_id
    JOIN    sys.indexes AS i ON i.object_id = t.object_id
    JOIN    sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id
    JOIN    sys.allocation_units AS a ON a.container_id = p.partition_id
    WHERE   s.name IN ('core', 'stg', 'cfg');
END
GO

PRINT '=== retention deployed ===';
PRINT 'Preview before the first real run:  EXEC core.usp_Purge @DryRun = 1;';
PRINT 'Size the repository:                EXEC core.usp_StorageReport;';
GO
