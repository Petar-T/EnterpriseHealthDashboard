/*==============================================================================
  ENTERPRISE HEALTH DASHBOARD
  File   : tests/Remove-DemoEstate.sql
  Run in : the CENTRAL repository database

  Removes everything tests/Seed-DemoEstate.sql created, and nothing else.

  ------------------------------------------------------------------------------
  HOW IT DECIDES WHAT TO DELETE
  ------------------------------------------------------------------------------
  One rule: ServerName LIKE 'demo-%'.

  Every demo server name begins with that prefix and no real Azure SQL logical
  server in this deployment does, so the match is unambiguous. The script does
  not carry a hand-written list of tables - it discovers every table in [core]
  and [cfg] that HAS a ServerName column, which means a table added to the
  system later is cleaned up automatically rather than quietly left behind.

  ------------------------------------------------------------------------------
  IT IS A DRY RUN BY DEFAULT
  ------------------------------------------------------------------------------
  As written, this script DELETES NOTHING. It reports exactly what it would
  delete, per table, and then stops. Set @Commit = 1 to actually remove.

  That default is deliberate: a cleanup script that deletes the moment you open
  it is one careless F5 away from removing real monitoring history.
==============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @Commit    bit     = 0;             -- <<< set to 1 to actually delete
DECLARE @Prefix    nvarchar(100) = N'demo-%';

/*------------------------------------------------------------------------------
  1. SAFETY CHECK - prove the prefix cannot match anything real.

     If a genuine monitored server ever began with 'demo-', this script would
     delete real data. Rather than trust that it never will, check it, and
     refuse to run if it is not true.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM cfg.Target
           WHERE ServerName LIKE @Prefix
             AND ISNULL(Notes, N'') NOT LIKE N'DEMO SEED%')
BEGIN
    SELECT  Problem = 'A target matching the demo prefix is NOT marked as a demo seed',
            ServerName, DatabaseName, Notes
    FROM    cfg.Target
    WHERE   ServerName LIKE @Prefix
      AND   ISNULL(Notes, N'') NOT LIKE N'DEMO SEED%';

    RAISERROR(N'ABORTED. Something matching ''demo-%%'' is not a demo seed row. Review the rows above before deleting anything.', 16, 1);
    RETURN;
END

/*------------------------------------------------------------------------------
  2. Count what would go, per table. Discovered, not hard-coded.
------------------------------------------------------------------------------*/
DECLARE @Plan TABLE (SchemaName sysname, TableName sysname, RowsMatched bigint);
DECLARE @s sysname, @t sysname, @sql nvarchar(max), @n bigint;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.name, t.name
    FROM   sys.tables  AS t
    JOIN   sys.schemas AS s ON s.schema_id = t.schema_id
    JOIN   sys.columns AS col ON col.object_id = t.object_id AND col.name = 'ServerName'
    WHERE  s.name IN ('core', 'cfg')
    ORDER BY s.name, t.name;

OPEN c; FETCH NEXT FROM c INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @cnt = COUNT_BIG(*) FROM ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
             + N' WHERE ServerName LIKE @p;';
    EXEC sys.sp_executesql @sql, N'@cnt bigint OUTPUT, @p nvarchar(100)',
         @cnt = @n OUTPUT, @p = @Prefix;
    INSERT @Plan VALUES (@s, @t, @n);
    FETCH NEXT FROM c INTO @s, @t;
END
CLOSE c; DEALLOCATE c;

SELECT  TableName   = SchemaName + '.' + TableName,
        RowsMatched,
        Action      = CASE WHEN RowsMatched = 0 THEN 'nothing to remove'
                           WHEN @Commit = 1     THEN 'DELETED'
                           ELSE 'would delete (dry run)' END
FROM    @Plan
ORDER BY RowsMatched DESC, SchemaName, TableName;

DECLARE @Total bigint = (SELECT ISNULL(SUM(RowsMatched), 0) FROM @Plan);

/*------------------------------------------------------------------------------
  3. Delete, only if asked.
------------------------------------------------------------------------------*/
IF @Commit = 0
BEGIN
    PRINT '';
    PRINT '================================================================';
    PRINT ' DRY RUN - nothing was deleted.';
    PRINT ' ' + CAST(@Total AS varchar(20)) + ' row(s) match ServerName LIKE ''demo-%''.';
    PRINT '';
    PRINT ' To remove them, edit the top of this file:   SET @Commit = 1';
    PRINT '================================================================';
    RETURN;
END

DECLARE @Deleted bigint = 0;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName, TableName FROM @Plan WHERE RowsMatched > 0;
    OPEN c2; FETCH NEXT FROM c2 INTO @s, @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'DELETE FROM ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
                 + N' WHERE ServerName LIKE @p;';
        EXEC sys.sp_executesql @sql, N'@p nvarchar(100)', @p = @Prefix;
        SET @Deleted += @@ROWCOUNT;
        FETCH NEXT FROM c2 INTO @s, @t;
    END
    CLOSE c2; DEALLOCATE c2;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

/*------------------------------------------------------------------------------
  4. Prove it is gone. Reporting "done" without re-checking is how a cleanup
     that silently skipped a table goes unnoticed.
------------------------------------------------------------------------------*/
DECLARE @Left bigint = 0;
DECLARE c3 CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.name, t.name
    FROM   sys.tables  AS t
    JOIN   sys.schemas AS s ON s.schema_id = t.schema_id
    JOIN   sys.columns AS col ON col.object_id = t.object_id AND col.name = 'ServerName'
    WHERE  s.name IN ('core', 'cfg');
OPEN c3; FETCH NEXT FROM c3 INTO @s, @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @cnt = COUNT_BIG(*) FROM ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t)
             + N' WHERE ServerName LIKE @p;';
    EXEC sys.sp_executesql @sql, N'@cnt bigint OUTPUT, @p nvarchar(100)',
         @cnt = @n OUTPUT, @p = @Prefix;
    SET @Left += @n;
    FETCH NEXT FROM c3 INTO @s, @t;
END
CLOSE c3; DEALLOCATE c3;

SELECT  RowsDeleted      = @Deleted,
        RowsStillMatching = @Left,
        RealTargetsIntact = (SELECT COUNT(*) FROM cfg.Target WHERE ServerName NOT LIKE @Prefix),
        Verdict = CASE WHEN @Left = 0 THEN 'clean - no demo rows remain'
                       ELSE 'INCOMPLETE - ' + CAST(@Left AS varchar(20)) + ' row(s) still match' END;

PRINT '';
PRINT 'Demo estate removed. Regenerate the dashboard to see the real estate only:';
PRINT '    .\04-dashboard\New-EnterpriseDashboard.ps1 -CentralServer <srv> -CentralDatabase <db>';
GO
