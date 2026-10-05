/* Descriptions for objects whose source comment covers a whole section rather
   than the individual object. Attributing a shared section comment to each
   object would be inaccurate, so these are written explicitly.

   Keyed by schema.object, lower case. */
module.exports = {
  /* ---------------------------------------------------------------- tables */
  'core.deadlock':
    'Deadlock graphs harvested from the ehd_errors Extended Events session. One row per deadlock, carrying the XML graph and the participating sessions. Populated only when EHD_Setup_Targets has deployed the XE session on that target; otherwise the feed returns nothing and this table stays empty.',
  'core.indexfragmentation':
    'Daily fragmentation snapshot per index. Driven from sys.dm_db_index_physical_stats in LIMITED mode, so it is cheap but reports page-level fragmentation only. Small indexes are excluded - rebuilding an index below the page threshold achieves nothing. Feeds core.vw_FragmentationWork, which turns raw percentages into a prioritised work list.',
  'core.logspace':
    'Transaction log size, used space and percentage, plus log_reuse_wait_desc and the oldest open transaction. The reuse-wait reason is the diagnostic that matters: a log that cannot truncate is almost always waiting on a specific, nameable cause. Collected on the Standard tier alongside data-file space.',
  'core.missingindex':
    'The optimiser\'s missing-index suggestions, ranked by its own impact estimate. Treat these as evidence, not instructions: the optimiser proposes an index per query shape with no awareness of existing indexes, write cost, or overlap between suggestions. Use core.vw_MissingIndexTop, which ranks and de-duplicates them.',
  'core.securitypermission':
    'Daily snapshot of granted and denied permissions per principal in each monitored database. The point is not the permission list itself but the change between snapshots - core.vw_SecurityDrift compares consecutive days and reports what appeared or disappeared.',
  'core.securityprincipal':
    'Daily snapshot of database principals: users, roles, their type and authentication type. Paired with core.SecurityPermission to answer "who gained access, and when" without needing an audit trail on the target.',
  'core.tablespace':
    'Daily per-table row counts and space used, split between data and index pages. Answers where the space actually went, which the database-level figure in core.DatabaseSpace cannot. Bounded to the largest tables per database so the feed stays small across a wide estate.',
  'core.tempdbusage':
    'tempdb total size and allocation split across user objects, internal objects and the version store. Version-store growth is the signal worth watching: it usually means a long-running transaction under snapshot isolation rather than a tempdb problem as such.',
  'core.xesessionhealth':
    'The state of the Extended Events sessions this system relies on, per database: whether each session exists, whether it is running, and its buffer statistics. Without this, a silently stopped XE session is indistinguishable from a quiet database - both produce no events.',

  /* ----------------------------------------------------------------- views */
  'core.vw_deadlocksummary':
    'Deadlocks grouped by database and day, with the most recent graph available for inspection. Use it to distinguish a one-off from a recurring pattern before spending time on a single graph.',
  'core.vw_errorsummary':
    'Errors captured by the ehd_errors XE session, grouped by database, error number and message. Severity and frequency together, so a flood of one benign error does not bury a rare serious one.',
  'core.vw_fragmentationwork':
    'A prioritised index maintenance list rather than a fragmentation report. Applies the conventional thresholds - reorganise in one band, rebuild in another, ignore below a size floor - and emits a verdict per index, so the output is directly actionable.',
  'core.vw_iolatency':
    'Read and write latency per file, derived from the cumulative counters in core.IoFileStats by differencing consecutive snapshots. Cumulative values are meaningless on their own and reset on failover; this view turns them into per-interval milliseconds.',
  'core.vw_jobexecution':
    'A flattened view of jobs.job_executions. Separates the step-level rows from the parent job rows and exposes the target server and database, so it joins cleanly to core.FeedArrival. Created as an EMPTY STUB when the jobs schema does not yet exist, so the deployment can run before the agent is created - re-run 04-job-health.sql afterwards to swap in the real definition.',
  'core.vw_missingindextop':
    'The optimiser\'s missing-index suggestions ranked by estimated impact and de-duplicated across overlapping proposals. Always read alongside core.vw_UnusedIndexes - adding an index that duplicates an existing unused one is a net loss.',
  'core.vw_openalerts':
    'Every unresolved alert across the estate, worst first. One row stays open and updates while a condition persists rather than raising a new row per evaluation, so count the open rows, not the history.',
  'core.vw_queryregression':
    'Queries whose performance changed materially between Query Store intervals, including whether the plan changed. A regression with a plan change and one without are different problems with different fixes, so the view reports them separately.',
  'core.vw_securitydrift':
    'Differences between consecutive daily security snapshots: principals and permissions added or removed, per database. This is the closest thing to an audit trail that a zero-footprint system can provide, since it requires no auditing to be enabled on the target.',
  'core.vw_topqueries':
    'The heaviest queries per database over the window, from the cumulative stats in core.QueryStats differenced into per-interval figures. Ranked by total worker time by default, which surfaces sustained cost rather than single slow executions.',
  'core.vw_unusedindexes':
    'Indexes with writes but no reads over the observed period. The "unused since" answer is trustworthy here because core.IndexUsage keeps dated snapshots: sys.dm_db_index_usage_stats is cumulative and resets on failover, scale change or index rebuild, so a single live reading cannot be dated.',

  /* ------------------------------------------------------------ procedures */
  'cfg.usp_registertarget':
    'Registers a database in cfg.Target, or updates it if already present. Registration is a declaration of intent - what you expect to be monitored - which is what lets the dashboard distinguish "this database reported nothing" from "this database was never supposed to report". Targets are also auto-registered on first data arrival.',
  'core.usp_purge':
    'Retention for the modelled core tables. Deletes in bounded batches so it never holds a long transaction, honouring the per-tier Retention.* settings. Deliberately separate from core.usp_PurgeStaging, which ages out the landing zone on a much shorter window.',

  /* ------------------------------------------------------------- functions */
  'cfg.fn_int':
    'Reads an integer setting from cfg.Setting, falling back to a supplied default if the key is missing or not parseable. The fallback is why a mistyped key silently uses the default rather than failing - run tests\\Test-SettingKeys.ps1 to prove every key the code reads is actually defined.',
  'cfg.fn_dec':
    'Reads a decimal setting from cfg.Setting with a supplied fallback. Used for threshold values such as CPU and storage percentages, where the integer form would lose meaningful precision.'
};
