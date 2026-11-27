# Management Certificate API

**Status:** This API is part of integrated V1. See the [V1 integration checkpoint](V1_INTEGRATION_CHECKPOINT.md). Production certificate acceptance remains pending. Hindi/Devanagari certificate PDF shaping is deferred.

Base path: `/api/v1/management/certificates/`

## Authentication and permissions

All routes use JWT authentication. The account must be authenticated, eligible for
the mobile API, and active. If the account has a linked Employee record, that
Employee must also be active.

Effective Django permissions are checked independently:

| Method and route | Required permission |
|---|---|
| `GET /api/v1/management/certificates/` | `certifications.view_certificate` |
| `GET /api/v1/management/certificates/{id}/` | `certifications.view_certificate` |
| `POST /api/v1/management/certificates/{id}/revoke/` | `certifications.change_certificate` |

Change permission does not imply view permission. The API does not infer authority
from a role label, Employee ownership, or client-supplied identifiers. Revocation
rechecks the actor's current eligibility and change permission inside the service.

## List certificates

`GET /api/v1/management/certificates/`

Optional query parameters:

| Parameter | Meaning and validation |
|---|---|
| `search` | Case-insensitive match against certificate number, Employee code snapshot, Employee name snapshot, or training-title snapshot; up to 150 characters. |
| `is_revoked` | Boolean filter. When omitted, includes both active and revoked certificates. |
| `page` | 1-based page number; defaults to page 1. |
| `page_size` | Results per page; defaults to 20 and is capped at 100. |

Results are ordered by newest `issued_at`, then primary key. The response uses the
standard pagination envelope:

```json
{
  "count": 0,
  "next": null,
  "previous": null,
  "results": []
}
```

Each result contains:

```json
{
  "id": 1,
  "certificate_number": "…",
  "training_title": "…",
  "version_number": 1,
  "issued_at": "…",
  "is_revoked": false,
  "employee_name": "…",
  "employee_code": "…",
  "revoked_at": null
}
```

## Certificate detail

`GET /api/v1/management/certificates/{id}/`

Returns the list fields for one certificate, plus `revocation_reason`. An
authorized request for an unknown ID returns not found.

The Employee name/code, training title and version number are issuance-time
snapshots, not live joins. Revocation preserves the certificate record and its
historical identity and training data; this API does not return a document URL or
storage path.

## Revoke a certificate

`POST /api/v1/management/certificates/{id}/revoke/`

Request body:

```json
{
  "reason": "Required explanation"
}
```

`reason` must be a string, non-blank after trimming, and no longer than 1,000
characters after trimming. It is required; unexpected body fields are rejected.
The operation does not delete the certificate.

On success, returns HTTP 200 with only:

```json
{
  "id": 1,
  "is_revoked": true,
  "revoked_at": "…"
}
```

Revocation locks the parent assignment and certificate in a transaction, then
persists the revocation and an `AuditLog` entry in that same transaction. The
actor, target, timestamp, action and before/after state are server-derived; the
validated reason is recorded. If the audit write fails, the transaction fails
rather than reporting a successful unaudited revocation. A repeated revocation
does not create another success audit event.

## Error semantics

| Status | Meaning |
|---|---|
| `200` | Certificate list/detail read succeeded, or revocation and its audit record committed. |
| `400` | Invalid query parameter or revocation body, including a missing, blank, non-string, too-long reason, or unexpected field. |
| `401` | Authentication is missing, invalid, or rejected for an inactive user. |
| `403` | The account is ineligible (including an inactive linked Employee) or lacks the permission for that operation. Authorization is checked before certificate lookup. |
| `404` | An authorized detail or revocation request references an unknown certificate. |
| `409` | The certificate is already revoked, or the database reports the handled MySQL lock-timeout/deadlock conflicts during revocation. Refresh before retrying. |

Unsupported methods return `405`.

## Verification limits

Database-free API contract tests and MySQL validation are part of V1 verification. Refer to the [V1 integration checkpoint](V1_INTEGRATION_CHECKPOINT.md) for CI scope. Production certificate access, issuance and revocation remain deployment smoke-test areas. The broader Run 5 is deferred.
