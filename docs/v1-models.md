# V1 database models

One factory, Django's existing `auth.User`, and 20 domain models. All user
relationships use `settings.AUTH_USER_MODEL`. `accounts` and `reports` introduce
no tables. No frontend, API, notification, machine, or skill-matrix features are
included.

| App | Models |
| --- | --- |
| organization | Department, JobRole, Employee |
| training | Training, TrainingVersion, Module, Lesson, RoleTrainingRequirement, TrainingAssignment, LessonProgress, VideoWatchSession |
| assessments | Question, QuestionRevision, QuestionOption, Assessment, AssessmentQuestion, AssessmentAttempt, AttemptAnswer |
| certifications | Certificate |
| audit | AuditLog |

## History and lifecycle

- All relationships to historical entities use `PROTECT`. Employees and users
  are deactivated, not deleted; employee codes and linked user identities cannot
  be repurposed. Saving an inactive employee disables its linked user within the
  same transaction. Reactivation does not automatically re-enable a login.
- Departments, job roles, training catalog entries, and question-bank entries
  are deactivated. Assignments are cancelled. Certificates are revoked. Draft
  curriculum/question children may be deleted; referenced records remain
  protected.
- Training versions start as drafts. Publication validates modules, lessons,
  frozen questions, and exactly one final assessment. Published content cannot
  be edited or moved; retirement is the only subsequent version transition.
- A new release uses new module, lesson, and assessment rows. Frozen question
  revisions can be reused. Files must be stored under immutable paths; a model
  cannot prevent someone overwriting a media file directly on disk.
- Questions are single-choice or true/false. Freezing validates the answer key.
  Assessments store specific revisions, ordering, and marks. Closed attempts and
  their answers are immutable, including failed/expired/abandoned attempts.
- A certificate references the exact version, completed assignment, and passing
  final attempt. Its issuance snapshots are immutable. Revocation is one-way.

## Assignment and progress rules

- One assignment per employee/version, enforced by a database unique constraint
  across all statuses and sources. Retakes are attempts on that same assignment.
  Recurring recertification of the same version is intentionally not modeled.
- Role requirements reference exact published versions. Creating a requirement
  does not automatically create assignments. Future orchestration must apply
  active rules idempotently and preserve the original source if an assignment
  already exists. Employee role changes do not rewrite existing assignments.
- Assignment department and role snapshots describe placement at assignment
  time. The employee record describes current placement.
- Every required lesson and quiz must be completed before the final assessment;
  every required assessment must be passed before assignment completion.
- `LessonProgress.watched_ranges` stores sorted, merged `[start, end]` pairs in
  seconds. Resume position is independent of coverage. `watched_seconds` and
  `progress_percent` are derived properties, avoiding contradictory totals.
  Previously recorded coverage cannot be removed.
- `VideoWatchSession` records individual sessions, including an optional session
  identifier and device identifier. Identifiers are not globally unique because
  a browser/device may generate multiple viewing sessions. Open sessions can be
  updated; ended sessions are immutable. Ending positions may move backwards.
  Active watch seconds measure active elapsed time, not unique content coverage.
- Session writes do not automatically update aggregate ranges. Playback handling
  must merge actual observed intervals and save aggregate progress in the same
  transaction as the session update. Session endpoints alone cannot reconstruct
  watched intervals across seeks. `completed_normally` describes session closure,
  not lesson completion.

## Persistence contract

`config/model_utils.py` contains abstract bases only. Model `save()` calls
`full_clean()` within a transaction and locks the appropriate version, question
revision, assignment, or attempt before mutation. Reporting hierarchy edits are
serialized across employee rows to prevent concurrent cycle creation.

Save validated objects individually. Bulk create/update and queryset update are
deliberately rejected because they bypass lifecycle validation. Queryset deletion
uses each model's deletion policy. A supplied `update_fields` is expanded to a
full save so the entire validated state is persisted. Direct SQL, `save_base`,
and Django's internal base manager are not supported mutation interfaces; there
are no database triggers enforcing application-level immutability.

Cross-table rules live in model validation. Local bounds, unique identities,
timestamp relationships, and result-state combinations also have database
constraints. Manager self-reference/cycle checks use model validation because
MySQL disallows CHECK expressions referencing an AUTO_INCREMENT primary key.

Workflow services remain a later layer: publication/cloning commands, automatic
role assignment, playback ingestion, attempt initialization/grading/submission,
certificate rendering, and automatic audit-event creation are not implemented.
The models validate the persisted results of these workflows. In particular:

1. Lock the assignment and allocate the next attempt number in one transaction.
2. Create a row for every presented question, including unanswered questions.
3. Grade answers and submit the attempt in that same transaction.
4. Record business changes and their `AuditLog` entries in the caller's shared
   transaction. Audit snapshots must exclude credentials/tokens and unnecessary
   personal information; the generic JSON fields do not sanitize payloads.

## Migrations and verification

Initial migrations exist for organization, training, assessments, certifications,
and audit. They depend on Django's configured user model; there is no user swap.

Normal MySQL commands (use the existing virtual-environment Python on Windows):

```powershell
& .\.venv\Scripts\python.exe manage.py makemigrations
& .\.venv\Scripts\python.exe manage.py migrate
& .\.venv\Scripts\python.exe manage.py check
& .\.venv\Scripts\python.exe manage.py test organization training assessments certifications audit
```

The development MySQL user currently lacks permission to create
`test_gardens_training`. No credentials or grants were changed. The isolated
fallback settings affect tests only:

```powershell
& .\.venv\Scripts\python.exe manage.py test --settings=config.test_settings
```

The fallback runs migrations and model tests on an in-memory SQLite database.
It does not verify MySQL row-lock/concurrency behavior. MySQL migrations and live
schema constraint/index introspection are checked separately. For full MySQL
integration testing, a database administrator must provision appropriate access
to a disposable test database; never redirect Django's test runner at application
data.
