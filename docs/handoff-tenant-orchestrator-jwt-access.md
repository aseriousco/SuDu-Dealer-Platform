# Tenant Orchestrator JWT Access Handoff

Date: 2026-08-19  
Audience: developers integrating an internal service with the Sudu tenant orchestrator, and orchestrator administrators who register caller identities

## Purpose

The tenant orchestrator authenticates internal callers with short-lived JWTs signed by the caller. It does not accept a BladeX login token as its API credential.

Access setup is a two-party process:

1. The calling service generates an ES256/P-256 key pair.
2. The caller retains the private key.
3. An orchestrator administrator registers the public key, service ID, KID, and permitted scopes.
4. The caller signs JWTs using the issuer and audience configured by the orchestrator.

The private key must never be sent to or stored by the orchestrator.

## Values and Ownership

| Value | Owner/source | Secret? | Purpose |
| --- | --- | --- | --- |
| `TENANT_ORCHESTRATOR_JWT_PRIVATE_KEY` | Generated and retained by the caller | Yes | Signs JWTs sent to the orchestrator |
| `TENANT_ORCHESTRATOR_JWT_KID` | Chosen when the key pair is created | No | Identifies the registered public key; placed in the JWT header as `kid` |
| `TENANT_ORCHESTRATOR_SERVICE_ID` | Agreed stable name for the calling service | No | Identifies the caller; placed in the JWT payload as `sub` |
| `TENANT_ORCHESTRATOR_JWT_ISSUER` | Provided by the orchestrator administrator | No | Placed in the JWT payload as `iss` |
| `TENANT_ORCHESTRATOR_JWT_AUDIENCE` | Provided by the orchestrator administrator | No | Placed in the JWT payload as `aud` |
| Public key PEM | Generated with the private key and sent to the administrator | No | Registered in `ServiceIdentity.publicKeyPem` for signature verification |
| Allowed scopes | Approved by the orchestrator administrator | No | Limits the API operations available to the caller |

The confirmed issuer and audience values are:

```env
TENANT_ORCHESTRATOR_JWT_ISSUER=internal-identity
TENANT_ORCHESTRATOR_JWT_AUDIENCE=tenant-provisioning-service
```

The caller may instead name these variables `INTERNAL_JWT_ISSUER` and `INTERNAL_JWT_AUDIENCE`. Environment-variable names are caller-specific; the resulting JWT claim values must exactly match the orchestrator deployment.

## Responsibility Split

### Calling-service owner

- Choose a stable service ID.
- Generate the ES256 key pair in a secure environment.
- Keep the private key in the caller's secret manager.
- Provide only the service ID, KID, public key, and requested scopes to the administrator.
- Generate short-lived JWTs and request only the scopes needed for each operation.
- Rotate or revoke the signing key when required.

### Orchestrator administrator

- Confirm the deployment's issuer and audience.
- Review and approve the requested scopes using least privilege.
- Register the service ID, KID, public key, and allowed scopes in `ServiceIdentity`.
- Confirm that the identity is enabled.
- Disable the old identity after a key rotation or immediately after a compromise.

## Step 1: Choose the Identifiers

Use a stable, environment-specific service ID. Examples:

```text
dealer-api-prod
autocount-sync-prod
tenant-admin-tool-staging
```

Use a unique KID for each key pair. A readable convention is:

```text
<service-id>-<generation-date>-<sequence>
```

Example:

```text
Service ID: dealer-api-prod
KID: dealer-api-prod-20260819-01
```

Do not reuse a KID for a replacement key pair.

## Step 2: Generate the ES256 Key Pair

Node.js is required. Create `generate-orchestrator-key.mjs` in a temporary secure directory outside the application repository:

```javascript
import { generateKeyPairSync } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const serviceId = process.argv[2];
const kid = process.argv[3];

if (!serviceId || !kid) {
  console.error(
    'Usage: node generate-orchestrator-key.mjs <service-id> <kid>',
  );
  process.exit(1);
}

const { publicKey, privateKey } = generateKeyPairSync('ec', {
  namedCurve: 'P-256',
});

const privateKeyPem = privateKey.export({
  type: 'pkcs8',
  format: 'pem',
});

const publicKeyPem = publicKey.export({
  type: 'spki',
  format: 'pem',
});

writeFileSync('tenant-orchestrator-private.pem', privateKeyPem, {
  flag: 'wx',
  mode: 0o600,
});

writeFileSync('tenant-orchestrator-public.pem', publicKeyPem, {
  flag: 'wx',
});

console.log(`Service ID: ${serviceId}`);
console.log(`KID: ${kid}`);
console.log('Private key: tenant-orchestrator-private.pem');
console.log('Public key: tenant-orchestrator-public.pem');
```

Run it with the chosen identifiers:

```powershell
node generate-orchestrator-key.mjs `
  dealer-api-prod `
  dealer-api-prod-20260819-01
```

It creates:

```text
tenant-orchestrator-private.pem
tenant-orchestrator-public.pem
```

The `wx` file flag prevents accidentally overwriting an existing key file. On Windows, the file-mode setting may not enforce Unix-style permissions; restrict access using the operating system or secret-management platform.

## Step 3: Exchange the Registration Information

The calling-service owner sends the administrator only:

```text
Service ID: dealer-api-prod
KID: dealer-api-prod-20260819-01
Public key: complete contents of tenant-orchestrator-public.pem
Requested scopes:
  - tenant:create
  - job:read
```

The public key should have this form:

```text
-----BEGIN PUBLIC KEY-----
...
-----END PUBLIC KEY-----
```

Do not send `tenant-orchestrator-private.pem`.

Use an approved authenticated channel for the registration information so the administrator can confirm who requested the access and which scopes were approved.

## Step 4: Register the Service Identity

There is no public API for creating a `ServiceIdentity`. The orchestrator administrator must use the approved database or bootstrap procedure to create an enabled record with:

```text
ServiceIdentity.serviceId    = dealer-api-prod
ServiceIdentity.keyId        = dealer-api-prod-20260819-01
ServiceIdentity.publicKeyPem = <complete public key PEM>
ServiceIdentity.scopes       = <approved scopes>
ServiceIdentity.enabled      = true
```

The combination of `serviceId` and `keyId` must be unique.

Both permission checks must pass when an API is called:

1. The JWT's `scope` claim must contain the route's required scope.
2. The registered `ServiceIdentity.scopes` must also allow that scope.

## Step 5: Configure the Calling Service

Store the following in the caller's secret/configuration system:

```env
TENANT_ORCHESTRATOR_JWT_PRIVATE_KEY=<complete private key PEM>
TENANT_ORCHESTRATOR_JWT_KID=dealer-api-prod-20260819-01
TENANT_ORCHESTRATOR_SERVICE_ID=dealer-api-prod
TENANT_ORCHESTRATOR_JWT_ISSUER=internal-identity
TENANT_ORCHESTRATOR_JWT_AUDIENCE=tenant-provisioning-service
```

Only the private key is secret. Nevertheless, manage all five values as deployment configuration so that environment changes and key rotations are explicit.

The signing library must receive a PEM string containing real newline characters. If the deployment platform stores the PEM with literal `\n` sequences, normalize it in the caller before constructing the private key:

```javascript
const privateKeyPem = process.env.TENANT_ORCHESTRATOR_JWT_PRIVATE_KEY
  ?.replace(/\\n/g, '\n');
```

Prefer a secret manager or mounted secret file over committing a `.env` file. Never commit the private key.

## Step 6: Sign a Short-Lived JWT

Required JWT header:

```json
{
  "alg": "ES256",
  "typ": "JWT",
  "kid": "dealer-api-prod-20260819-01"
}
```

Required payload shape:

```json
{
  "iss": "internal-identity",
  "aud": "tenant-provisioning-service",
  "sub": "dealer-api-prod",
  "iat": 1787072400,
  "exp": 1787073300,
  "jti": "a-new-unique-id-for-this-token",
  "scope": "tenant:create job:read"
}
```

Generate a new `jti` for every token. Use a token lifetime of 5 to 15 minutes. `scope` is a space-delimited string and should include only the scopes required for the intended call.

Reference Node.js signer:

```javascript
import { createSign, randomUUID } from 'node:crypto';

function base64urlJson(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

export function createTenantOrchestratorJwt({
  privateKeyPem,
  kid,
  serviceId,
  issuer,
  audience,
  scopes,
}) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'ES256', typ: 'JWT', kid };
  const payload = {
    iss: issuer,
    aud: audience,
    sub: serviceId,
    iat: now,
    exp: now + 15 * 60,
    jti: randomUUID(),
    scope: scopes.join(' '),
  };

  const signingInput = [base64urlJson(header), base64urlJson(payload)].join('.');
  const signature = createSign('sha256')
    .update(signingInput)
    .end()
    .sign({ key: privateKeyPem, dsaEncoding: 'ieee-p1363' });

  return `${signingInput}.${signature.toString('base64url')}`;
}
```

The `ieee-p1363` signature encoding is required by the current ES256 verification implementation.

## Step 7: Call and Verify the API

Send the token as a bearer token:

```http
Authorization: Bearer <signed-jwt>
```

Every job-creating `POST` also requires a unique idempotency key for that exact request:

```http
Idempotency-Key: <unique-request-id>
Content-Type: application/json
```

For an initial non-mutating access check, an identity with `provisioning_profile:read` can call:

```http
GET /v1/provisioning-profiles
Authorization: Bearer <signed-jwt>
```

Expected authentication failures:

| Response/error | Likely cause |
| --- | --- |
| `Missing bearer token` | Missing or malformed `Authorization` header |
| `Missing JWT key id` | JWT header does not contain `kid` |
| `Unknown service identity` | `sub`/`kid` pair is not registered or is disabled |
| `Invalid JWT signature` | Private key does not match the registered public key |
| `Invalid JWT issuer` | `iss` differs from the deployed issuer |
| `Invalid JWT audience` | `aud` differs from the deployed audience |
| `JWT expired` | Token `exp` is in the past |
| `Missing required scope` | The token or registered identity lacks the route scope |

## Key Rotation and Revocation

Rotate the private key and KID together. Keep the service ID, issuer, and audience stable unless the calling service or orchestrator trust boundary changes.

Recommended rotation sequence:

1. Generate a new ES256 key pair.
2. Assign a new KID.
3. Register a second enabled `ServiceIdentity` with the same service ID and approved scopes.
4. Deploy the new private key and KID to the caller.
5. Confirm that tokens signed with the new key work.
6. Wait until all tokens signed with the old key have expired.
7. Disable the old `ServiceIdentity` record.
8. Remove the old private key from the caller's secret manager.

Rotate immediately if the private key is exposed, committed, transmitted through an insecure channel, accessed by an unauthorized person, or potentially affected by a system compromise.

The orchestrator does not currently enforce a scheduled key expiry. The owning teams must define and operate the rotation schedule. A yearly rotation is a reasonable starting policy unless organizational or compliance requirements require a shorter period.

## Security Rules

- Never place the private key in source control, tickets, email, chat, API request bodies, or general documentation.
- Never send the private key to the orchestrator administrator.
- Store the private key in the caller's secret manager with access limited to the signing workload and authorized operators.
- Register only the public key in the orchestrator database.
- Give each calling service its own service ID and key pair.
- Use separate identities and keys for development, staging, and production.
- Grant only the required scopes.
- Do not reuse a production key in local development.
- Do not log JWTs or private-key material.

## Handoff Checklist

### Caller

- [ ] Service ID chosen and confirmed
- [ ] Unique KID chosen
- [ ] ES256/P-256 key pair generated securely
- [ ] Private key stored in the caller's secret manager
- [ ] Public key and requested scopes sent to the administrator
- [ ] Issuer and audience configured
- [ ] JWT signer uses ES256 and short-lived tokens
- [ ] Private key and JWTs excluded from logs and source control

### Orchestrator administrator

- [ ] Caller identity and environment confirmed
- [ ] Requested scopes reviewed and approved
- [ ] Public key registered under the exact service ID and KID
- [ ] `ServiceIdentity.enabled` set to `true`
- [ ] Issuer and audience supplied to the caller
- [ ] Initial authenticated request verified
- [ ] Rotation owner and schedule recorded

## Source of Truth

- API authentication and route handoff: `docs/sudu-tenant-orchestrator-api-handoff-2026-08-06.md`
- Full project authentication documentation: `docs/tenant-provisioning-project-documentation.md`
- Service identity schema: `prisma/schema.prisma`
- JWT verification behavior: `src/auth/internal-jwt-auth.guard.ts`

