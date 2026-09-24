# CLAUDE.md

PowerShell toolkit that runs IT tasks against lists of remote Windows machines via `psexec.exe`: deploy apps, copy files, copy+install, run a remote command, install Windows KB patches, update Office, trigger a Nessus/Tenable scan. Code, comments, logs and docs are in Spanish (`Equipo` = host/computer).

Read before changing anything non-trivial:
- `ARQUITECTURA.md` — full design (module layout, job runner, GUI/web plumbing, maintainer gotchas in §8). Keep it in sync when design changes.
- `CHANGES.md` — history of real bugs fixed; explains *why* much of the defensive code exists.
- `README.md` — end-user install/usage.

## Working rules (from `restricciones.txt` — mandatory)

- **Propose before editing**: explain which files, what change, why, and which new branch; wait for approval before writing or modifying files.
- **Every change goes on a new branch** (propose the name first). Never work on `main`.
- **Never `git add` / `commit` / `push` / merge** without explicit instruction for that step.
- **No new external dependencies** without asking. Prefer PowerShell, PsTools and native Windows/.NET.
- Do not delete files, functions or features, and do not rewrite or refactor "for cleanliness", unless asked. Keep diffs small and on-task.
- No destructive commands (`git reset --hard`, `git clean`, `git restore`, deleting files) without asking.

## Commands

```powershell
# Test suite: no psexec or network needed, runs on Windows/macOS/Linux (pwsh). Writes only to the system temp dir.
pwsh -NoProfile -File ./tests/Test-DeploymentToolkit.ps1      # expect "68 OK / 0 fallidos"

# Web UI, safe on macOS: -Simular never touches a machine (hosts containing "fail" report as failed)
pwsh ./Deploy-Web.ps1 -Simular [-Port <n>] [-NoBrowser] [-MaxTareas <n>]   # -Simular still writes to logs/<task>.log

# Windows only
powershell.exe -STA -File .\Deploy-Gui.ps1      # WPF, requires STA
.\Deploy-Menu.ps1                                # console menu
.\scripts\run_kb_deployment.ps1 -ComputersFile computers.txt -KbPatch KB5099414 -KbFolder 2026-09
```

There is no build, linter, or Pester. The suite is a custom `Test-Case`/`Assert-*` harness in one file. Add new tests there. Real psexec/copy/Tenable behavior can only be verified on Windows against 2–3 test hosts.

## Architecture in brief

One module (`Module/Deployment/`), four front-ends that never duplicate logic: `Deploy-Web.ps1` (HttpListener, cross-platform), `Deploy-Gui.ps1` (WPF), `Deploy-Menu.ps1` (console), and `scripts/run_*.ps1` (non-interactive, for Scheduled Tasks; `exit 1` if any host failed). `cmd_execute/*.cmd` are double-click launchers.

- `Public/` = exported API; `Private/` = internal only. The `.psm1` dot-sources both and exports `Public/` basenames, **and** `Deployment.psd1` `FunctionsToExport` must list the same names (a test compares them).
- **`Module/Deployment/Deployment.Constants.psd1` holds every meaningful value** (per-task `LogFile`/`MutexName`/`ImportFile`/`RemoteSubPath`, timeouts, throttles, success codes, log date format, validation regexes, tool paths, Office registry key, UI port/intervals). `Get-DeploymentConfig` merges it with `config/config.psd1` and returns one object: tunables, `.Tasks.<id>` (identity + resolved `ThrottleLimit`/`ElapsedTime` in seconds), and fixed sections (`.Log`, `.Remote`, `.Validation`, `.Office`, `.Simulation`, `.Runner`, `.Ui`, `.Paths`). `config.psd1` may override **only** keys in the `Tunable` section (plus `TaskDefaults.<id>.ThrottleLimit|ElapsedTime`); anything else is ignored with a warning. Details in ARQUITECTURA §3.6.
- `Classes/` (`BaseDeploy`, `KbWindows : BaseDeploy`) are **not** loaded by the module. `Invoke-ThrottledDeployment` dot-sources them inside each `Start-Job` via `-ClassPaths` and injects the config as JSON into `[BaseDeploy]::Settings`. Classes read timeouts, psexec path, etc. from there. Code that uses the classes outside the runner (tests) must set `[BaseDeploy]::Settings` first. A derived class must come after its base in `-ClassPaths`.
- Each public `Invoke-*` does `$task = $config.Tasks.<id>`, fills unset `ThrottleLimit`/`ElapsedTime`/`LogPath`/`LogMutexName` from it, builds an `$action` scriptblock `param($Equipo, $LogPath, $LogMutexName, ...)`, passes task args as an `[ordered]` `$actionArgs` in the **same order** as that `param()` (tested), calls `Invoke-ThrottledDeployment ... -Settings $config`, and returns `Write-DeploymentSummary`. Steps for adding a task are in ARQUITECTURA §3.4.
- `Get-DeploymentTaskCatalog` is the declarative task/form definition shared by the GUI and web UI. It holds only labels, hints and field types; defaults come from the config. Field `Name`s must match real parameter names (tested). `Deploy-Menu.ps1` and `scripts/` do **not** read the catalog, so a new task must be added there separately.
- All 7 public tasks pass through `-ProgressQueue` (ConcurrentQueue of JobStart/JobDone events) and `-CancelFlag` (synchronized hashtable). The UIs run tasks in a separate runspace.
- Logs: one file per task in `logs/` (the task's `LogFile`), written through `BaseDeploy.WriteLogSafe` under the task's named mutex (`MutexName`). Line format: `<Log.DateFormat> | <equipo> | <mensaje>`.

## Invariants and gotchas (tests enforce most of these)

- **No magic strings.** A new meaningful value goes in `Deployment.Constants.psd1` (under `Tunable` if operators should be able to change it) and is read via `Get-DeploymentConfig`. A test fails if any string value from the constants appears as a string literal in a `.ps1`. What stays inline on purpose: the `Module\Deployment\Deployment.psd1` bootstrap path in entry points, command syntax (psexec flags, `Get-HotFix`), user-facing text, and display formatting.
- Validation attributes (`[ValidatePattern]`, `[ValidateRange]`) only accept literals, so `-KbFolder`, `-MaxTareas` and `-Port` are validated/resolved in the body after the config is loaded.
- Inside a class, a local variable can't share a name with a class property (`$settings` vs `static Settings` is a parse error). Class locals use `$cfg`.
- **Never `exit` inside a job `$action`.** Always `return [pscustomobject]@{ Equipo; Success; ExitCode; Message }`.
- Class methods return objects, never bare bools. Check `.Success` explicitly, never `if (-not $result)`.
- Class methods can't have default parameter values. Use overloads (see `InvokePsExec`).
- `ElapsedTime` is in **seconds**. UIs and wrappers take minutes and multiply by 60.
- Use `return ,@(...)` (unary comma) where an empty collection must not collapse to `$null`. Exception: `Read-ComputerList` returns a plain `@(...)`, so callers must assign it as `$x = @(Read-ComputerList ...)` (tested); adding the comma there would break callers that already wrap it in `@()`. Use `[AllowEmptyCollection()]` on mandatory array params that can be empty (`ComputerList`, `ClassPaths`).
- The progress peek uses `Receive-Job -Keep`. Removing `-Keep` empties the final summary.
- **Any `.ps1`/`.psd1` containing non-ASCII characters must be saved as UTF-8 with BOM.** Production runs Windows PowerShell 5.1, which reads BOM-less files as ANSI. When editing with tools that may drop the BOM, check the first bytes (`head -c3 file | xxd -p` → `efbbbf`). Pure-ASCII files may stay BOM-less.
- **No environment data in code**: no IPs, server paths, or scan UUIDs (a test greps for them). These values live only in `config/config.psd1` (copied from `config.example.psd1`, not meant to be committed; note there is no `.gitignore` yet). They default to empty in the constants and the task that needs one fails with a clear message.
- Target runtime is PowerShell 5.1 (`#Requires -Version 5.1`). Don't use pwsh-7-only syntax (`??`, `?.`, ternary, `ForEach-Object -Parallel`) in module/entry-point code.
- In the GUI, long work runs in the worker runspace and control updates run on the UI thread (`DispatcherTimer`).
- `imports/*.txt` are host lists copied from the original project. Some filenames have typos (e.g. `copy_install._computers.txt`); leave them as they are.
